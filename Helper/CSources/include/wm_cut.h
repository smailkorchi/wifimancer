#ifndef WM_CUT_H
#define WM_CUT_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Layered cut amplifier. Once ARP poison redirects victim traffic to our MAC,
 * this module captures the redirected DNS queries and crafts NXDOMAIN replies
 * back to the victim. Result: cut victims see *immediate* DNS failures rather
 * than 30-second socket timeouts. Designed to run alongside the ARP poisoner —
 * if the redirect doesn't land at L2 nothing arrives in our pcap and this
 * module is a no-op (zero cost).
 *
 * Threading: open + close on one thread, pump loop on another. The victim list
 * is updated atomically under an internal mutex.
 */

/* Open BPF on iface, install filter for "ether dst == our_mac and udp port 53"
 * so we receive only DNS queries that ARP-poison redirected to us. */
void *wm_cut_open(const char *iface,
                  const uint8_t our_mac[6],
                  const char   *our_ipv4,
                  char         *errbuf /* >= 256 */);

/* Replace the active victim-IP allow-list. Only DNS queries whose source IP
 * matches one of these will be NXDOMAIN'd; everything else is left alone so
 * non-cut devices keep working if their traffic accidentally hits us. */
void wm_cut_set_victims(void *handle,
                        const char **victim_ipv4_strs,
                        int n_victims);

/* Drain pending packets, craft NXDOMAIN responses, inject. Returns number of
 * responses injected. Call repeatedly from a tight loop on a background thread.
 * `max_packets` caps a single drain so the caller can yield. */
int wm_cut_pump(void *handle, int max_packets);

/* Cumulative stats for the helper's diagnostic logging. */
void wm_cut_stats(void *handle,
                  uint64_t *out_dns_responses,
                  uint64_t *out_dns_seen,
                  uint64_t *out_inject_failures);

void wm_cut_close(void *handle);

#ifdef __cplusplus
}
#endif
#endif
