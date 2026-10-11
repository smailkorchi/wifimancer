import Foundation
import CoreWLAN

enum ContextDetector {

    /// Native-first context detection. Tries SCDynamicStore + getifaddrs; falls
    /// back to /sbin shell-outs only if the native path fails. The shell-out
    /// fallback exists because some odd network configs (multiple default
    /// routes, link-down primary) can leave SCDynamicStore stale for a
    /// fraction of a second after a Wi-Fi switch.
    static func detect() -> NetworkContext? {
        if let ctx = detectNative() { return ctx }
        Log.root.error("detectNative failed — falling back to shell-out path")
        return detectShellOut()
    }

    private static func detectNative() -> NetworkContext? {
        guard let primary = Sysinfo.nativePrimary() else {
            Log.root.error("detectNative: SCDynamicStore has no PrimaryInterface/Router (no default route?)")
            return nil
        }
        guard let info = Sysinfo.nativeIfaceInfo(primary.iface) else {
            Log.root.error("detectNative: getifaddrs found no IPv4/MAC for iface=\(primary.iface)")
            return nil
        }
        guard let mac = MACAddress(info.mac) else {
            Log.root.error("detectNative: MAC parse failed: \(info.mac)")
            return nil
        }

        let cidr = Sysinfo.cidr(ipv4: info.ipv4, prefix: info.cidrPrefix)
        let dns = Sysinfo.nativeDNSServers()
        let v6Active = info.ipv6.contains { !$0.lowercased().hasPrefix("fe80") }
        let (ssid, bssid) = currentWiFiIdentifiers(interface: primary.iface)
        // Native sysctl(PF_ROUTE, NET_RT_FLAGS, RTF_LLINFO) read of the kernel
        // ARP table — works in the daemon sandbox, no shell-out. The previous
        // shell-out path (`/usr/sbin/arp -n`) silently returned empty inside
        // a LaunchDaemon, leaving gwMac=nil for the entire spoof loop. This
        // is the single line that makes Cut work on hardened Android /
        // hardened iOS — without the gateway MAC we only sent victim-side
        // poison and the gateway kept routing return traffic to the real MAC.
        let gwMac: MACAddress? = Sysinfo.nativeArpLookup(primary.gateway).flatMap(MACAddress.init)
            ?? arpLookup(ipv4: primary.gateway, iface: primary.iface)

        Log.root.info("detectNative: iface=\(primary.iface, privacy: .public) self=\(info.ipv4, privacy: .public)/\(info.cidrPrefix, privacy: .public) gw=\(primary.gateway, privacy: .public) gwMac=\(gwMac?.description ?? "nil", privacy: .public) mac=\(info.mac, privacy: .public)")

        return NetworkContext(
            interface: primary.iface,
            selfIPv4: info.ipv4,
            selfIPv6: info.ipv6,
            selfMAC: mac,
            gatewayIPv4: primary.gateway,
            gatewayMAC: gwMac,
            subnetCIDR: cidr,
            ssid: ssid,
            bssid: bssid,
            ipv6Active: v6Active,
            dnsServers: dns
        )
    }

    private static func detectShellOut() -> NetworkContext? {
        guard let iface = Sysinfo.defaultInterface() else {
            Log.root.error("detectShellOut: defaultInterface returned nil")
            return nil
        }
        guard let ipv4 = Sysinfo.ipv4(of: iface) else {
            Log.root.error("detectShellOut: ipv4(of: \(iface)) returned nil")
            return nil
        }
        guard let macStr = Sysinfo.mac(of: iface) else {
            Log.root.error("detectShellOut: mac(of: \(iface)) returned nil")
            return nil
        }
        guard let mac = MACAddress(macStr) else {
            Log.root.error("detectShellOut: MAC parse failed: \(macStr)")
            return nil
        }
        guard let gw = Sysinfo.defaultGateway() else {
            Log.root.error("detectShellOut: defaultGateway returned nil")
            return nil
        }
        guard let cidr = Sysinfo.subnetCIDR(of: iface) else {
            Log.root.error("detectShellOut: subnetCIDR(of: \(iface)) returned nil")
            return nil
        }

        let v6 = Sysinfo.ipv6(of: iface)
        let dns = Sysinfo.dnsServers()
        let v6Active = v6.contains { !$0.lowercased().hasPrefix("fe80") }
        let (ssid, bssid) = currentWiFiIdentifiers(interface: iface)
        let gwMac = arpLookup(ipv4: gw, iface: iface)

        return NetworkContext(
            interface: iface,
            selfIPv4: ipv4,
            selfIPv6: v6,
            selfMAC: mac,
            gatewayIPv4: gw,
            gatewayMAC: gwMac,
            subnetCIDR: cidr,
            ssid: ssid,
            bssid: bssid,
            ipv6Active: v6Active,
            dnsServers: dns
        )
    }

    private static func currentWiFiIdentifiers(interface: String) -> (String?, String?) {
        let wifi = CWWiFiClient.shared().interface(withName: interface)
        let nativeSSID = availableSSID(wifi?.ssid())
        let nativeBSSID = availableBSSID(wifi?.bssid())
        if let nativeSSID, let nativeBSSID { return (nativeSSID, nativeBSSID) }

        // Root may lack Location permission. Read current association metadata
        // only when native identities are unavailable. Rewriting IPConfiguration
        // preferences on every refresh stalls the session actor for seconds.
        let summary = Sysinfo.runShell(["/usr/sbin/ipconfig", "getsummary", interface], timeout: 0.5)
        var ssid: String?, bssid: String?
        for line in summary.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("SSID :") {
                ssid = t.replacingOccurrences(of: "SSID :", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            if t.hasPrefix("BSSID :") {
                bssid = t.replacingOccurrences(of: "BSSID :", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        // Do not combine identities observed on opposite sides of a Wi-Fi
        // switch. A complete newer association takes precedence over a partial
        // native read; no historical metadata is cached here.
        let summarySSID = availableSSID(ssid)
        let summaryBSSID = availableBSSID(bssid)
        if summarySSID != nil || summaryBSSID != nil { return (summarySSID, summaryBSSID) }
        return (nativeSSID, nativeBSSID)
    }

    private static func availableSSID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "<redacted>", !value.contains("\0") else { return nil }
        return value
    }

    private static func availableBSSID(_ value: String?) -> String? {
        guard let value, let mac = MACAddress(value), !mac.isMulticast,
              mac.bytes.contains(where: { $0 != 0 }),
              mac.description != "02:00:00:00:00:00" else { return nil }
        return mac.description
    }

    /// Lookup gateway MAC from the OS arp table.
    static func arpLookup(ipv4: String, iface: String) -> MACAddress? {
        let out = Sysinfo.runShell(["/usr/sbin/arp", "-n", ipv4], timeout: 0.5)
        // typical line: "? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ..."
        for line in out.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 6, fields[1] == "(\(ipv4))", fields[2] == "at",
                  fields[4] == "on", fields[5] == iface else { continue }
            // macOS arp omits leading zeroes. Normalize only its validated
            // output; application-supplied MAC addresses stay strict.
            let octets = fields[3].split(separator: ":", omittingEmptySubsequences: false)
            guard octets.count == 6, octets.allSatisfy({
                (1...2).contains($0.count) && $0.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
            }) else { continue }
            let bytes = octets.compactMap { UInt8($0, radix: 16) }
            guard bytes.count == 6 else { continue }
            let mac = MACAddress(bytes: bytes)
            if !mac.isMulticast, bytes.contains(where: { $0 != 0 }) { return mac }
        }
        return nil
    }
}
