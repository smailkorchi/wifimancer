#ifndef WM_ARP_H
#define WM_ARP_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Open a pcap handle for sending ARP frames on `iface`. */
void *wm_arp_open(const char *iface, char *errbuf /* >=256 */);
void  wm_arp_close(void *handle);

/* Send a gratuitous/spoof ARP REPLY:
 *   "claim that target_ip is at our_mac" — sent to victim_mac
 * Returns 0 on success, -1 on failure.
 */
int wm_arp_send_spoof(void *handle,
                      const uint8_t our_mac[6],
                      const uint8_t victim_mac[6],
                      const char   *victim_ip,
                      const char   *target_ip);

/* Restore: send a real ARP REPLY pairing target_ip → real_mac. */
int wm_arp_send_restore(void *handle,
                        const uint8_t real_mac[6],
                        const uint8_t victim_mac[6],
                        const char   *victim_ip,
                        const char   *target_ip);

/* Build and send ARP REQUEST (used by scanner). */
int wm_arp_send_request(void *handle,
                        const uint8_t our_mac[6],
                        const char   *our_ip,
                        const char   *target_ip);

/* Gratuitous broadcast ARP REQUEST claiming `claim_ip` belongs to our_mac.
 * Sent to ff:ff:ff:ff:ff:ff so every client on the segment processes it.
 * Modern devices (iOS 18+, Android 14+) reject unsolicited unicast ARP REPLYs
 * but generally accept gratuitous broadcast announcements per RFC 5227.
 * This is the layer that makes Cut survive against MAC-randomised iOS clients. */
int wm_arp_send_grat_broadcast(void *handle,
                               const uint8_t our_mac[6],
                               const char   *claim_ip);

/* ---- Selected-peer ARP responder ---------------------------------------- */

/* Open a dedicated nonblocking ARP-only pcap handle. Setup errors fail closed. */
void *wm_arp_resp_open(const char *iface, char *errbuf /* >=256 */);
void  wm_arp_resp_close(void *handle);

/* Drain at most `max_pkts` pending ARP frames. Reply only when the requester's
 * MAC AND IPv4 match a selected target asking for the gateway, or the gateway
 * asking for a selected target. `target_ips` contains n_targets four-byte
 * network-order addresses, paired with n_targets six-byte `target_macs`.
 * Own identities, malformed requests and empty selection receive no replies.
 * Replies are unicast; returns count, or -1 on capture/injection failure. */
int wm_arp_resp_pump(void *handle,
                     const uint8_t our_mac[6],
                     const uint8_t our_ip[4],
                     const uint8_t gateway_mac[6],
                     const uint8_t gateway_ip[4],
                     const uint8_t *target_ips,
                     const uint8_t *target_macs,
                     int            n_targets,
                     int            max_pkts);

#ifdef __cplusplus
}
#endif
#endif
