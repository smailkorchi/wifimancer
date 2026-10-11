import Foundation

/// Pre-flight that asks Kali to scan for nearby Wi-Fi APs via a
/// virtual monitor interface — keeping wlan0 connected so Tailscale
/// / SSH stays alive.
///
/// Strategy: `iw phy phy0 interface add mon_probe type monitor`
/// creates a passive sniffer interface without disconnecting the
/// managed-mode wlan0. Works on Intel iwlwifi (built-in laptop Wi-Fi)
/// and most modern chipsets. The probe creates the interface, runs a
/// passive scan, emits the BSSID list, then deletes the interface.
public actor KaliRangeProbe {

    public struct Visible: Sendable, Hashable {
        public let bssid: String
        public let essid: String
        public let channel: Int
        public let signalDBm: Int
    }

    public struct Report: Sendable {
        public let kaliReachable: Bool
        public let interface: String?
        public let visible: [Visible]
        public let elapsedMs: Int
        public let rawError: String?

        public func sees(bssid: String) -> Visible? {
            let want = bssid.lowercased()
            return visible.first { $0.bssid.lowercased() == want }
        }
    }

    public static let shared = KaliRangeProbe()
    public init() {}

    public func probe(timeout: TimeInterval = 18) async -> Report {
        let start = Date()
        // Use the managed-mode scan on wlan0 — no monitor mode needed
        // for neighbor discovery, faster and more reliable than monitor
        // passive scan. We also verify the virtual monitor can be created
        // (confirms the chipset supports our capture approach).
        let cmd = """
        IFACE=$(sudo iw dev 2>/dev/null | awk '/Interface wlan/{print $2; exit}'); \
        [ -z "$IFACE" ] && { echo 'NOIFACE'; exit 2; }; \
        echo "IFACE=$IFACE"; \
        PHY=$(sudo iw dev "$IFACE" info 2>/dev/null | awk '/wiphy/{print "phy"$2}'); \
        [ -z "$PHY" ] && PHY="phy0"; \
        sudo iw dev wm_mon del 2>/dev/null; \
        sudo iw phy "$PHY" interface add wm_mon type monitor 2>/dev/null && \
          sudo ip link set wm_mon up 2>/dev/null && echo "VMON_OK" || echo "VMON_FAIL"; \
        sudo iw dev "$IFACE" scan 2>/dev/null | \
          awk '/^BSS [0-9a-fA-F]/{mac=$2;gsub(/\\(.*/,"",mac);bssid=tolower(mac);ch=0;sig=0;ess=""} \
               /\\tfreq:/{f=$2+0;if(f>=2412&&f<=2484)ch=int((f-2407)/5);else if(f>=5180)ch=int((f-5000)/5)} \
               /\\tsignal:/{sig=$2+0} \
               /\\tSSID:/{sub(/.*SSID: /,"");ess=$0} \
               /\\tcapability:/&&bssid{print "BSS|"bssid"|"ch"|"sig"|"ess;bssid=""}'; \
        sudo iw dev wm_mon del 2>/dev/null; \
        echo "DONE"
        """
        let result = await KaliClient.shared.runOneShot(command: cmd, timeout: timeout)
        let dt = Int(Date().timeIntervalSince(start) * 1000)

        if result.exitCode != 0 && !result.stdout.contains("IFACE=") {
            return Report(kaliReachable: false, interface: nil, visible: [],
                          elapsedMs: dt,
                          rawError: result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        }
        if result.stdout.contains("NOIFACE") {
            return Report(kaliReachable: true, interface: nil, visible: [],
                          elapsedMs: dt,
                          rawError: "No wlan interface found. Ensure wlan0 is up on Kali.")
        }

        var iface: String?
        var visible: [Visible] = []
        for line in result.stdout.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("IFACE=") {
                iface = String(s.dropFirst("IFACE=".count))
            } else if s.hasPrefix("BSS|") {
                let parts = s.split(separator: "|").map(String.init)
                guard parts.count >= 5 else { continue }
                visible.append(Visible(
                    bssid: parts[1],
                    essid: parts[4].trimmingCharacters(in: .whitespaces),
                    channel: Int(parts[2]) ?? 0,
                    signalDBm: Int(parts[3]) ?? 0
                ))
            }
        }
        return Report(kaliReachable: true, interface: iface ?? "wlan0",
                      visible: visible, elapsedMs: dt, rawError: nil)
    }
}
