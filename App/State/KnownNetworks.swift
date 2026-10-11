import Foundation

/// Tracks SSIDs the user has successfully joined through Wifi Mancer.
/// We don't store passwords (the system keychain already does that for
/// CoreWLAN), just the SSID so the UI can pin them and call
/// `joinWiFi(ssid, password: nil)` to reuse the saved credential.
@MainActor
final class KnownNetworks: ObservableObject {

    static let shared = KnownNetworks()

    @Published private(set) var ssids: [String] = []

    private let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("WifiMancer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("known_networks.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            self.ssids = list
        }
        // One-time cleanup: a previous build dumped every system-saved SSID
        // into this store, swamping the UI. If the list is implausibly large,
        // the user almost certainly didn't curate it manually — wipe.
        let migrated = UserDefaults.standard.bool(forKey: "known_networks_v2_migrated")
        if !migrated {
            if ssids.count > 25 {
                ssids.removeAll()
                save()
            }
            UserDefaults.standard.set(true, forKey: "known_networks_v2_migrated")
        }
    }

    func remember(_ ssid: String) {
        guard !ssid.isEmpty, !ssids.contains(ssid) else { return }
        ssids.insert(ssid, at: 0)
        save()
    }

    func forget(_ ssid: String) {
        ssids.removeAll { $0 == ssid }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(ssids) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
