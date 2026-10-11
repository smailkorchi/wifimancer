import Foundation
import CoreWLAN
import Security

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// CoreWLAN access from the **app process**.
///
/// Why not from the helper?  Location authorization is per-process and lives
/// in `/var/db/locationd/clients.plist`, separate from the standard TCC
/// infrastructure. The app has the user's Location grant; the root helper
/// does not, so CoreWLAN returns `<redacted>` SSIDs from the helper. Doing
/// the scan here means we get real SSIDs/BSSIDs.
@MainActor
final class WiFiClient: ObservableObject {

    static let shared = WiFiClient()

    private let client = CWWiFiClient.shared()
    private var iface: CWInterface? { client.interface() }

    func currentSSID() -> String? {
        let s = iface?.ssid()
        return (s == "<redacted>" || s?.isEmpty == true) ? nil : s
    }

    func scan(timeoutSeconds: Double = 8.0) async throws -> [WiFiNetwork] {
        // EVERYTHING CoreWLAN-related happens inside the detached Task,
        // including `CWWiFiClient.shared().interface()` itself. `interface()`
        // is NOT a cheap accessor — it dispatches synchronously through
        // `com.apple.wifi.xpcclient.mutex` to ask wifid for the interface
        // list, and if airportd is wedged that call blocks forever. The old
        // version that read `guard let iface` on the main actor before the
        // detach is what froze the Networks tab and the Lure picker.
        //
        // The timeout is a hard ceiling: even if the detached worker is
        // stuck inside CoreWLAN waiting on a reply that will never come,
        // the UI gets back an empty list at `timeoutSeconds` so the spinner
        // resolves and the user can retry. Without this the app looked
        // frozen indefinitely whenever airportd died.
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[WiFiNetwork], Error>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ block: () -> Void) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                block()
            }
            Task.detached(priority: .userInitiated) {
                guard let iface = CWWiFiClient.shared().interface() else {
                    finish { cont.resume(returning: []) }
                    return
                }
                do {
                    let savedSet: Set<String> = {
                        guard let cfg = iface.configuration(),
                              let profiles = cfg.networkProfiles.array as? [CWNetworkProfile]
                        else { return [] }
                        return Set(profiles.compactMap { $0.ssid })
                    }()
                    let currentSSID = iface.ssid()
                    let networks = try iface.scanForNetworks(withName: nil)
                    let result = networks.compactMap { net -> WiFiNetwork? in
                        let raw = net.ssid
                        guard let ssid = raw, !ssid.isEmpty, ssid != "<redacted>" else {
                            return nil
                        }
                        return WiFiNetwork(
                            ssid: ssid,
                            bssid: net.bssid,
                            rssi: net.rssiValue,
                            security: WiFiClient.mapSecurity(net),
                            channel: net.wlanChannel?.channelNumber ?? 0,
                            band: WiFiClient.bandLabel(net.wlanChannel?.channelBand),
                            isCurrent: ssid == currentSSID,
                            isKnown: savedSet.contains(ssid)
                        )
                    }
                    .sorted { $0.rssi > $1.rssi }
                    finish { cont.resume(returning: result) }
                } catch {
                    finish { cont.resume(throwing: error) }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                finish { cont.resume(returning: []) }
            }
        }
    }

    /// Same off-main-actor pattern for one-off SSID reads — anywhere in the
    /// app that needs the current SSID should call this, never `currentSSID()`
    /// directly, so a wedged airportd can't freeze the UI. The timeout makes
    /// it a *survivable* failure mode: if airportd doesn't reply in 3s, we
    /// return nil and the caller treats it as "SSID unknown for now."
    func currentSSIDAsync(timeoutSeconds: Double = 3.0) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let lock = NSLock()
            var resumed = false
            func finish(_ v: String?) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: v)
            }
            Task.detached(priority: .userInitiated) {
                let s = CWWiFiClient.shared().interface()?.ssid()
                let v = (s == "<redacted>" || s?.isEmpty == true) ? nil : s
                finish(v)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(nil)
            }
        }
    }

    /// SSIDs already in the macOS Wi-Fi auto-join list — these have a saved
    /// password in keychain, so `associate(to:password:nil)` rejoins instantly.
    func savedSSIDs() -> [String] {
        guard let iface else { return [] }
        let cfg = iface.configuration()
        guard let profiles = cfg?.networkProfiles.array as? [CWNetworkProfile] else {
            return []
        }
        return profiles.compactMap { $0.ssid }
    }

    /// Returns true when WE've previously joined this SSID through the app —
    /// in that case we have the password in our private keychain item and can
    /// rejoin silently. Doesn't touch any other keychain so it can't trigger
    /// the System-keychain admin prompt.
    func hasOurOwnPassword(for ssid: String) -> Bool {
        Self.readPrivatePassword(ssid: ssid) != nil
    }

    func join(ssid: String, password: String?) async throws {
        guard let iface else {
            throw NSError(domain: "WiFiClient", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No Wi-Fi interface"])
        }

        // Password resolution: user-supplied first, then our private keychain
        // (saved on the last successful join through this app).
        //
        // We CANNOT read airportd's saved passwords. The keychain ACL on
        // those entries accepts only `/usr/libexec/airportd` itself, the
        // Apple "AirPort" application group, or an interactive user prompt
        // (verified via securityd ACL logs). No amount of root, code-signing,
        // or shell-out tricks gets around this — it's a hard macOS gate that
        // requires either Apple Developer ID + the wifi-info entitlement, or
        // surfacing the keychain prompt to the user. So we don't try; the
        // password sheet IS the prompt for first-time joins, and once we've
        // saved the password ourselves every subsequent tap goes silent.
        let userTyped = password?.nilIfEmpty
        let pw: String? = userTyped ?? Self.readPrivatePassword(ssid: ssid)

        // Find the target network. A directed `scanForNetworks(withName:)` is
        // probe-based and sometimes misses APs that don't reply to the probe;
        // a broad scan + filter is more reliable. networksetup itself is
        // unusable on macOS 26 — returns -3900/-3925 even with correct
        // passwords because of API changes.
        let net = try await Task.detached(priority: .userInitiated) { () -> CWNetwork? in
            let broad = (try? iface.scanForNetworks(withName: nil)) ?? []
            // If multiple APs broadcast the same SSID (mesh / repeater), pick
            // the strongest signal — that's what a normal Wi-Fi join does.
            return broad.filter { $0.ssid == ssid }.max { $0.rssiValue < $1.rssiValue }
        }.value
        guard let net else {
            throw NSError(domain: "WiFiClient", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "\(ssid) is not in range"])
        }

        do {
            try iface.associate(to: net, password: pw)
        } catch {
            // associate() threw — the AP rejected us before we even started
            // listening for the verification step. Most common reason on a
            // known network: the saved password (system or ours) is stale.
            // Wipe our copy so the next tap doesn't reuse the same junk.
            if userTyped == nil { Self.deletePrivate(ssid: ssid) }
            throw NSError(domain: "WiFiClient", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
        }

        // Verify the join is actually stable, not just transiently linked.
        //
        // associate() returns immediately after kicking off the L2 join. The
        // L2 link comes up in ~400ms — but a wrong password still passes
        // through that. The WPA 4-way handshake then runs over the next
        // 5–15 seconds. If the PSK is wrong, airportd disassociates with
        // "failed association request" / EAPOL errors and macOS rolls back
        // to whatever was previously connected. Verifying at 1.5s would
        // wrongly declare success and we'd save a bad password.
        //
        // Poll ssid() and require it to stay matching for ~2.5s consecutively
        // before treating the join as real. The total budget is ~12s — long
        // enough for the supplicant to finish or fail.
        var stableHits = 0
        var sawAnyMatch = false
        let pollMs: UInt64 = 700_000_000
        let stableHitsRequired = 4   // ≈ 2.8s of confirmed match
        let maxIterations = 25       // ≈ 17.5s budget — covers the WPA
                                     // handshake window, which can take up
                                     // to ~14s before airportd gives up.
        for _ in 0..<maxIterations {
            try? await Task.sleep(nanoseconds: pollMs)
            if let now = iface.ssid(), now == ssid {
                sawAnyMatch = true
                stableHits += 1
                if stableHits >= stableHitsRequired {
                    if let userTyped {
                        Self.writePrivatePassword(ssid: ssid, password: userTyped)
                    }
                    return
                }
            } else {
                stableHits = 0
            }
        }
        // Two distinct failure modes here, distinguished by sawAnyMatch:
        //  - sawAnyMatch=false → we never linked to this SSID at all. Most
        //    likely wrong PSK that took longer than usual to fail, or the AP
        //    is unreachable. Wipe the silent-path password since it's bad.
        //  - sawAnyMatch=true  → we briefly associated, but couldn't hold
        //    the connection long enough to call it stable. This usually means
        //    macOS auto-join policy yanked us off (e.g. the network is set to
        //    "manual join" / disabled=yes in Wi-Fi settings, or signal flapped).
        //    The password is probably fine — DON'T wipe it, or the user will
        //    be asked to re-type a password we actually have.
        if !sawAnyMatch && userTyped == nil {
            Self.deletePrivate(ssid: ssid)
        }
        let reason = sawAnyMatch
            ? "Joined briefly but couldn't stay on \(ssid). macOS may have auto-join disabled for this network — open System Settings › Wi-Fi and re-enable it."
            : "Could not join \(ssid) — wrong password or AP unreachable."
        throw NSError(domain: "WiFiClient", code: sawAnyMatch ? 7 : 6,
                      userInfo: [NSLocalizedDescriptionKey: reason])
    }

    nonisolated private static func deletePrivate(ssid: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "WifiMancer",
            kSecAttrAccount as String: ssid
        ]
        SecItemDelete(q as CFDictionary)
    }

    func savedPassword(for ssid: String) -> String? {
        Self.readPrivatePassword(ssid: ssid)
    }

    func forgetPassword(for ssid: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "WifiMancer",
            kSecAttrAccount as String: ssid
        ]
        SecItemDelete(q as CFDictionary)
    }

    // MARK: private keychain (service: "WifiMancer", account: SSID)

    nonisolated private static func readPrivatePassword(ssid: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "WifiMancer",
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8)
        else { return nil }
        return s
    }

    nonisolated private static func writePrivatePassword(ssid: String, password: String) {
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "WifiMancer",
            kSecAttrAccount as String: ssid,
            kSecValueData as String: Data(password.utf8)
        ]
        // Insert; if already present, update.
        let st = SecItemAdd(attrs as CFDictionary, nil)
        if st == errSecDuplicateItem {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "WifiMancer",
                kSecAttrAccount as String: ssid
            ]
            let upd: [String: Any] = [kSecValueData as String: Data(password.utf8)]
            _ = SecItemUpdate(q as CFDictionary, upd as CFDictionary)
        }
    }

    private static func shell(_ launchPath: String, _ args: [String]) async throws -> (String, Int32) {
        try await Task.detached(priority: .userInitiated) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8) ?? ""
            return (s, p.terminationStatus)
        }.value
    }

    func disassociate() {
        iface?.disassociate()
    }

    // MARK: helpers

    nonisolated private static func mapSecurity(_ n: CWNetwork) -> WiFiSecurity {
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

    nonisolated private static func bandLabel(_ band: CWChannelBand?) -> String {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: ""
        }
    }
}
