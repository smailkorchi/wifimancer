#ifndef WM_DHCP_H
#define WM_DHCP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* DHCP-layer cut attack.
 *
 * Apple's Wi-Fi driver on M1+ Macs filters spoofed ARP frames (sender_ip must
 * match the interface's actual IP). Bettercap, scapy, and we have all hit the
 * same wall: pcap_inject succeeds, frames never leave the radio.
 *
 * DHCP is *not* filtered — it's broadcast UDP at L3, the driver doesn't
 * validate source IPs on UDP. By forging DHCP RELEASE packets on behalf of
 * each victim MAC, we tell the DHCP server "this client no longer wants its
 * IP." The server marks the lease released. The victim's stack still uses
 * the old IP until its next renew/lease event — but the gateway no longer
 * routes that IP, and the next time the victim tries DHCP, the lease churn
 * causes a multi-second outage.
 *
 * Pair with sustained DHCP REQUEST flooding from spoofed random MACs to
 * exhaust the DHCP pool so the victim cannot obtain a new lease.
 */

/* Open BPF on `iface` for outbound-only DHCP injection. Returns NULL on error
 * with a description in `errbuf`. */
void *wm_dhcp_open(const char *iface, char *errbuf /* >=256 */);

/* Send a forged DHCPRELEASE frame from `victim_mac` claiming `victim_ip`,
 * with `server_id` as the DHCP server identifier (option 54 — almost always
 * the gateway IP on home networks).
 *
 * Frame layout: Ethernet (broadcast) → IP (src=victim_ip, dst=server_id)
 * → UDP (src=68, dst=67) → BOOTP+DHCP body (option 53 = 7 RELEASE,
 * chaddr = victim_mac, ciaddr = victim_ip, option 54 = server_id).
 *
 * Returns 0 on success, -1 on injection failure. */
int wm_dhcp_send_release(void *handle,
                         const uint8_t our_mac[6],
                         const uint8_t victim_mac[6],
                         const char   *victim_ip,
                         const char   *server_id);

/* DHCP starvation tick: send one DHCPDISCOVER from a fresh random spoofed
 * client MAC. Repeated calls exhaust the server's lease pool over time so
 * the victim cannot obtain a new IP after our RELEASE. */
int wm_dhcp_send_starve(void *handle, const uint8_t our_mac[6]);

void wm_dhcp_close(void *handle);

#ifdef __cplusplus
}
#endif
#endif
