#ifndef WM_NDP_H
#define WM_NDP_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Open raw IPv6 socket for sending Neighbor Advertisements / RAs. */
void *wm_ndp_open(const char *iface, char *errbuf /* >=256 */);
void  wm_ndp_close(void *handle);

/* Send a spoofed Neighbor Advertisement:
 *   "target_ipv6 is at our_mac" — to victim_ipv6.
 * Solicited+Override flags set, lifetime 0xFFFFFFFF.
 */
int wm_ndp_send_spoof(void *handle,
                      const uint8_t our_mac[6],
                      const char   *our_ipv6_ll,    /* link-local */
                      const char   *victim_ipv6,
                      const char   *target_ipv6);

/* Send Router Advertisement with router lifetime 0 (kills victim's default route). */
int wm_ndp_send_ra_kill(void *handle,
                        const uint8_t our_mac[6],
                        const char   *our_ipv6_ll,
                        const char   *victim_ipv6);

#ifdef __cplusplus
}
#endif
#endif
