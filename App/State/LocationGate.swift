import Foundation
import CoreLocation
import AppKit

/// On macOS 14+, `CWInterface.ssid()` returns the literal string `"<redacted>"`
/// to apps that don't have Location permission. We never need the user's real
/// location — we just request authorization so macOS lifts the SSID redaction.
@MainActor
final class LocationGate: NSObject, ObservableObject, CLLocationManagerDelegate {

    static let shared = LocationGate()

    @Published var status: CLAuthorizationStatus = .notDetermined
    @Published var ssidUnlocked: Bool = false

    /// Optional callback fired when status flips to authorized. Set this from
    /// `AppCoordinator.boot()` to re-fetch network context once the redaction
    /// is lifted.
    var onUnlock: (@MainActor () -> Void)?

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // Don't read manager.authorizationStatus here. On a freshly installed
        // bundle, the first call into CLLocationManager triggers a sync XPC
        // roundtrip to locationd that can hang the main thread for tens of
        // seconds — long enough that the SwiftUI scene-graph attribute update
        // never finishes and no window is ever drawn. The delegate's
        // `didChangeAuthorization` fires once registration completes, which
        // is where we update status instead.
    }

    /// Pop the system prompt. `requestWhenInUseAuthorization` must be called
    /// on the main thread for the system sheet to actually appear; on background
    /// queues macOS swallows the call. CLLocationManager itself ignores the
    /// call when status is already determined, so we don't read
    /// `authorizationStatus` first — that read does a sync XPC roundtrip to
    /// locationd which hangs the main thread on the first launch after a fresh
    /// install (which is the very moment we want the prompt to appear).
    func request() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let s = manager.authorizationStatus
        Task { @MainActor in
            let unlocked = (s == .authorized || s == .authorizedAlways)
            let wasLocked = !self.ssidUnlocked
            self.status = s
            self.ssidUnlocked = unlocked
            if unlocked && wasLocked { self.onUnlock?() }
        }
    }
}
