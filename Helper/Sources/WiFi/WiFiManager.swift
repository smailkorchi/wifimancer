import Foundation
import CoreWLAN

/// CoreWLAN wrapper. Joins, scans, and switches Wi-Fi networks.
final class WiFiManager {

    private let client = CWWiFiClient.shared()
    private var iface: CWInterface? { client.interface() }

    func currentSSID() -> String? { iface?.ssid() }
    func currentBSSID() -> String? { iface?.bssid() }

    func scan() async throws -> [WiFiNetwork] {
        guard let iface else { return [] }
        let networks = try iface.scanForNetworks(withName: nil)
        let savedSSIDs = Self.savedSSIDs(for: iface)
        let currentSSID = iface.ssid()
        return networks.map { net in
            // Without Location permission, CoreWLAN serves "<redacted>" instead
            // of the real SSID. Treat that as hidden so the UI can prompt for
            // permission rather than showing useless rows.
            let raw = net.ssid
            let resolved: String = (raw == nil || raw == "<redacted>" || raw?.isEmpty == true)
                ? "(hidden)" : raw!
            return WiFiNetwork(
                ssid: resolved,
                bssid: net.bssid,
                rssi: net.rssiValue,
                security: Self.mapSecurity(net),
                channel: net.wlanChannel?.channelNumber ?? 0,
                band: Self.bandLabel(net.wlanChannel?.channelBand),
                isCurrent: raw != nil && raw == currentSSID,
                isKnown: raw.map { savedSSIDs.contains($0) } ?? false
            )
        }
        .sorted { $0.rssi > $1.rssi }
    }

    /// SSIDs the user has already saved in the system Wi-Fi configuration —
    /// these are the "known networks" macOS will auto-rejoin and whose
    /// passwords are already in the keychain.
    func savedNetworkSSIDs() -> [String] {
        guard let iface else { return [] }
        return Self.savedSSIDs(for: iface)
    }

    private static func savedSSIDs(for iface: CWInterface) -> [String] {
        let cfg = iface.configuration()
        guard let profiles = cfg?.networkProfiles.array as? [CWNetworkProfile] else {
            return []
        }
        return profiles.compactMap { $0.ssid }
    }

    func join(ssid: String, password: String?) async throws {
        // Why `networksetup` instead of CWInterface.associate?
        //
        // CWInterface.associate(to:password:nil) requires the
        // `com.apple.developer.networking.wifi-info` entitlement on macOS 14.4+
        // (Apple Developer ID signed builds only). Ad-hoc-signed apps and
        // even root daemons silently fail with "tmpErr" / generic "operation
        // couldn't be completed". `/usr/sbin/networksetup -setairportnetwork`
        // is the OS-blessed path that uses airportd's own system keychain
        // access, so it Just Works for both saved-password rejoin (no
        // password arg) and fresh joins (password arg).
        let iface = Sysinfo.defaultInterface() ?? "en0"
        var args = ["/usr/sbin/networksetup", "-setairportnetwork", iface, ssid]
        if let pw = password, !pw.isEmpty { args.append(pw) }

        let out = Sysinfo.runShell(args).trimmingCharacters(in: .whitespacesAndNewlines)
        // `networksetup` exits 0 even on failure and reports errors on stdout.
        // Anything other than empty / "Network has been changed..." means it
        // failed; surface the reason verbatim so the UI can show it.
        if !out.isEmpty
            && !out.lowercased().contains("changed")
            && !out.lowercased().contains("you are now") {
            throw NSError(domain: "WiFiManager", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: out])
        }
    }

    func disassociate() {
        iface?.disassociate()
    }

    // MARK: helpers

    private static func mapSecurity(_ n: CWNetwork) -> WiFiSecurity {
        if n.supportsSecurity(.wpa3Personal) { return .wpa3Personal }
        if n.supportsSecurity(.wpa2Personal) { return .wpa2Personal }
        if n.supportsSecurity(.wpaPersonal)  { return .wpaPersonal }
        if n.supportsSecurity(.WEP)          { return .wep }
        if n.supportsSecurity(.none)         { return .open }
        if n.supportsSecurity(.wpa2Enterprise) || n.supportsSecurity(.wpaEnterprise) {
            return .wpaEnterprise
        }
        return .unknown
    }

    private static func bandLabel(_ band: CWChannelBand?) -> String {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: ""
        }
    }
}
