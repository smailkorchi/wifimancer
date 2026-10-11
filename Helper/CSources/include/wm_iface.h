#ifndef WM_IFACE_H
#define WM_IFACE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Add an IPv4 address as an alias on the given interface. Used to make the
 * kernel "own" a victim IP — the kernel then transmits its own gratuitous
 * ARP claiming we have that IP, which is what actually pushes the cut
 * through Apple's Wi-Fi driver filter (the driver cannot drop frames that
 * its own kernel sourced).
 *
 * Returns 0 on success, errno on failure. EEXIST means the alias was
 * already there (treated as success at the call site). */
int wm_iface_add_alias(const char *iface, const char *ipv4);

/* Remove a previously-added alias. Idempotent — returns 0 if the address
 * isn't present. */
int wm_iface_remove_alias(const char *iface, const char *ipv4);

#ifdef __cplusplus
}
#endif
#endif
