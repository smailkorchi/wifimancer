import Foundation
import UserNotifications
import AppKit

/// Native macOS user notifications. Lazy-requests authorization on first use,
/// dedupes by MAC so each device only pings once per app session.
@MainActor
final class Notifier {

    static let shared = Notifier()

    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool = false
    private var requested: Bool = false
    private var seen: Set<String> = []

    func requestAuth() {
        guard !requested else { return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, _ in
            Task { @MainActor in self?.authorized = ok }
        }
    }

    /// Mark a baseline so devices already on the network don't all fire on first scan.
    func seed(_ macs: [String]) {
        seen.formUnion(macs)
    }

    /// Fire if the MAC hasn't been seen yet this session.
    func newDevice(_ device: Device, ssid: String?) {
        let key = device.mac.description
        guard !seen.contains(key) else { return }
        seen.insert(key)
        guard authorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "New device on \(ssid ?? "network")"
        let name = device.displayName
        content.body = name == device.mac.description
            ? "Unknown device · \(device.mac.description)"
            : "\(name) · \(device.mac.description)"
        content.sound = .default
        content.userInfo = ["mac": key]

        let req = UNNotificationRequest(identifier: "wm.new.\(key)",
                                        content: content,
                                        trigger: nil)
        center.add(req, withCompletionHandler: nil)
    }

    func reset() { seen.removeAll() }
}
