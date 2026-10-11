#include "wm_pcap.h"

#include <pcap.h>
#include <arpa/inet.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>
#include <sys/time.h>
#include <unistd.h>

#pragma pack(push, 1)
typedef struct {
    uint8_t  dst[6];
    uint8_t  src[6];
    uint16_t etype;
} eth_hdr_t;

typedef struct {
    uint16_t htype, ptype;
    uint8_t  hlen, plen;
    uint16_t op;
    uint8_t  sender_mac[6];
    uint8_t  sender_ip[4];
    uint8_t  target_mac[6];
    uint8_t  target_ip[4];
} arp_pkt_t;
#pragma pack(pop)

typedef struct {
    wm_arp_observation_t *buf;
    int max;
    int count;
} arp_capture_state_t;

static void arp_handler(uint8_t *user, const struct pcap_pkthdr *h, const uint8_t *bytes) {
    arp_capture_state_t *st = (arp_capture_state_t *)user;
    if (!st || !h || !bytes) return;
    if (h->caplen < sizeof(eth_hdr_t) + sizeof(arp_pkt_t)) return;
    const eth_hdr_t *eth = (const eth_hdr_t *)bytes;
    if (ntohs(eth->etype) != 0x0806) return;
    const arp_pkt_t *arp = (const arp_pkt_t *)(bytes + sizeof(eth_hdr_t));
    if (ntohs(arp->htype) != 1 || ntohs(arp->ptype) != 0x0800
        || arp->hlen != 6 || arp->plen != 4 || ntohs(arp->op) != 2) return;
    static const uint8_t zero_mac[6] = {0};
    if ((arp->sender_mac[0] & 1) || memcmp(arp->sender_mac, zero_mac, 6) == 0
        || memcmp(eth->src, arp->sender_mac, 6) != 0
        || arp->sender_ip[0] == 0 || arp->sender_ip[0] == 127
        || arp->sender_ip[0] >= 224) return;
    if (st->count >= st->max) return;

    char ip[40];
    snprintf(ip, sizeof(ip), "%d.%d.%d.%d",
             arp->sender_ip[0], arp->sender_ip[1],
             arp->sender_ip[2], arp->sender_ip[3]);

    // dedup
    for (int i = 0; i < st->count; i++) {
        if (strcmp(st->buf[i].ip, ip) == 0
            && memcmp(st->buf[i].mac, arp->sender_mac, 6) == 0) return;
    }
    strncpy(st->buf[st->count].ip, ip, sizeof(st->buf[st->count].ip) - 1);
    memcpy(st->buf[st->count].mac, arp->sender_mac, 6);
    st->count++;
}

int wm_pcap_capture_arp(const char *iface,
                        int duration_ms,
                        wm_arp_observation_t *out_buf,
                        int max_count,
                        char *errbuf) {
    char eb[PCAP_ERRBUF_SIZE];
    pcap_t *p = pcap_create(iface, eb);
    if (!p) { snprintf(errbuf, 256, "pcap_create: %s", eb); return -1; }
    pcap_set_snaplen(p, 96);
    pcap_set_promisc(p, 1);
    pcap_set_timeout(p, 50);
    pcap_set_immediate_mode(p, 1);
    if (pcap_activate(p) < 0) {
        snprintf(errbuf, 256, "pcap_activate: %s", pcap_geterr(p));
        pcap_close(p);
        return -1;
    }
    /* Our unicast spoof/restoration replies must never become inventory
     * evidence. If inbound-only capture is unavailable, fail closed rather
     * than feeding locally generated bindings back into target selection. */
    if (pcap_setdirection(p, PCAP_D_IN) < 0) {
        snprintf(errbuf, 256, "pcap_setdirection: %s", pcap_geterr(p));
        pcap_close(p); return -1;
    }
    struct bpf_program prog;
    if (pcap_compile(p, &prog, "arp", 1, PCAP_NETMASK_UNKNOWN) < 0) {
        snprintf(errbuf, 256, "filter: %s", pcap_geterr(p));
        pcap_close(p); return -1;
    }
    int filter_result = pcap_setfilter(p, &prog);
    pcap_freecode(&prog);
    if (filter_result < 0 || pcap_setnonblock(p, 1, eb) < 0) {
        snprintf(errbuf, 256, "capture setup: %s", pcap_geterr(p));
        pcap_close(p); return -1;
    }

    arp_capture_state_t st = { out_buf, max_count, 0 };
    struct timeval start, now;
    gettimeofday(&start, NULL);
    while (1) {
        gettimeofday(&now, NULL);
        long elapsed = (now.tv_sec - start.tv_sec) * 1000
                     + (now.tv_usec - start.tv_usec) / 1000;
        if (elapsed >= duration_ms) break;
        int captured = pcap_dispatch(p, 32, arp_handler, (uint8_t *)&st);
        if (captured < 0) {
            snprintf(errbuf, 256, "capture read: %s", pcap_geterr(p));
            pcap_close(p); return -1;
        }
        if (captured == 0) usleep(1000);
    }
    pcap_close(p);
    return st.count;
}

/* ---- traffic counter (per-MAC) ---- */

#define TRAFFIC_TABLE 256

typedef struct {
    uint8_t  mac[6];
    uint64_t bytes;
    int      used;
} traffic_slot_t;

struct wm_traffic_ctx {
    pcap_t *p;
    pthread_mutex_t lock;
    traffic_slot_t table[TRAFFIC_TABLE];
};

static int slot_index(traffic_slot_t *table, const uint8_t mac[6]) {
    uint32_t h = (mac[0] ^ mac[1]) << 16
               | (mac[2] ^ mac[3]) << 8
               | (mac[4] ^ mac[5]);
    int idx = h % TRAFFIC_TABLE;
    for (int i = 0; i < TRAFFIC_TABLE; i++) {
        int probe = (idx + i) % TRAFFIC_TABLE;
        if (!table[probe].used) {
            memcpy(table[probe].mac, mac, 6);
            table[probe].used = 1;
            table[probe].bytes = 0;
            return probe;
        }
        if (memcmp(table[probe].mac, mac, 6) == 0) return probe;
    }
    return -1;
}

static void traffic_handler(uint8_t *user, const struct pcap_pkthdr *h, const uint8_t *bytes) {
    wm_traffic_ctx *ctx = (wm_traffic_ctx *)user;
    if (h->caplen < sizeof(eth_hdr_t)) return;
    const eth_hdr_t *eth = (const eth_hdr_t *)bytes;
    pthread_mutex_lock(&ctx->lock);
    int s = slot_index(ctx->table, eth->src);
    if (s >= 0) ctx->table[s].bytes += h->len;
    int d = slot_index(ctx->table, eth->dst);
    if (d >= 0) ctx->table[d].bytes += h->len;
    pthread_mutex_unlock(&ctx->lock);
}

wm_traffic_ctx *wm_traffic_open(const char *iface, char *errbuf) {
    char eb[PCAP_ERRBUF_SIZE];
    pcap_t *p = pcap_create(iface, eb);
    if (!p) { snprintf(errbuf, 256, "pcap_create: %s", eb); return NULL; }
    pcap_set_snaplen(p, 64);
    pcap_set_promisc(p, 1);
    pcap_set_timeout(p, 50);
    pcap_set_immediate_mode(p, 1);
    if (pcap_activate(p) < 0) {
        snprintf(errbuf, 256, "pcap_activate: %s", pcap_geterr(p));
        pcap_close(p); return NULL;
    }
    pcap_setnonblock(p, 1, eb);

    wm_traffic_ctx *ctx = (wm_traffic_ctx *)calloc(1, sizeof(wm_traffic_ctx));
    ctx->p = p;
    /* RECURSIVE mutex so wm_traffic_pump (which holds the lock across
     * pcap_dispatch to serialise against close) can re-enter the same
     * lock when traffic_handler runs synchronously inside pcap_dispatch.
     * Without recursive semantics the same-thread re-acquire deadlocks. */
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&ctx->lock, &attr);
    pthread_mutexattr_destroy(&attr);
    return ctx;
}

void wm_traffic_close(wm_traffic_ctx *ctx) {
    if (!ctx) return;
    /* INTENTIONAL LEAK on close.
     *
     * The background traffic-pump task captures `ctx` as a pointer at startup
     * and never re-reads it. If we freed `ctx` here, any in-flight or later
     * `wm_traffic_pump(ctx, ...)` call would dereference freed memory before
     * even reaching our NULL guard — UAF inside `pthread_mutex_lock(&ctx->lock)`
     * itself, because `&ctx->lock` is a freed address.
     *
     * Closing the pcap handle and zeroing `ctx->p` under the lock means:
     *   - subsequent pump calls see `ctx->p == NULL` and return 0
     *   - the lock object remains live and dereferenceable forever
     *   - we leak one `wm_traffic_ctx` (≈8 KB) per iface change
     *
     * Iface changes are rare (Wi-Fi swap, VPN flap), and the alternative
     * (cancel-and-await the Swift loop before freeing) requires async
     * propagation up through every caller of refreshContextIfChanged. The
     * leak is bounded by the number of distinct interfaces seen during the
     * helper's lifetime — fine for a long-lived daemon. */
    pthread_mutex_lock(&ctx->lock);
    pcap_t *p = ctx->p;
    ctx->p = NULL;
    /* `pcap_close` MUST run inside the lock so any concurrent pump that
     * already snapshotted `p` is still inside `pcap_dispatch` waiting on
     * the lock. Closing under the lock guarantees the snapshot becomes
     * stale only at a moment when no thread is dereferencing it. */
    if (p) pcap_close(p);
    pthread_mutex_unlock(&ctx->lock);
    /* Deliberately NOT freeing ctx, NOT destroying ctx->lock. */
}

int wm_traffic_pump(wm_traffic_ctx *ctx, int max_packets) {
    if (!ctx) return 0;
    /* Serialise pcap_dispatch against close. The existing lock was only
     * protecting the table; without also covering pcap_dispatch, close
     * could free the handle mid-dispatch and crash inside libpcap. */
    pthread_mutex_lock(&ctx->lock);
    pcap_t *p = ctx->p;
    if (!p) { pthread_mutex_unlock(&ctx->lock); return 0; }
    int rc = pcap_dispatch(p, max_packets, traffic_handler, (uint8_t *)ctx);
    pthread_mutex_unlock(&ctx->lock);
    return rc;
}

int wm_traffic_drain(wm_traffic_ctx *ctx,
                     uint8_t macs_out[][6],
                     uint64_t bytes_out[],
                     int n) {
    if (!ctx) return 0;
    int filled = 0;
    pthread_mutex_lock(&ctx->lock);
    for (int i = 0; i < TRAFFIC_TABLE && filled < n; i++) {
        if (ctx->table[i].used && ctx->table[i].bytes > 0) {
            memcpy(macs_out[filled], ctx->table[i].mac, 6);
            bytes_out[filled] = ctx->table[i].bytes;
            ctx->table[i].bytes = 0;
            filled++;
        }
    }
    pthread_mutex_unlock(&ctx->lock);
    return filled;
}
