import Foundation
import SwiftUI

/// Drives the high-level lifecycle: install helper, detect context, scan, spoof.
@MainActor
final class AppCoordinator: ObservableObject {

    let helper = HelperClient.shared
    let store: AppStore

    private var scanTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var blockingGeneration: UInt64 = 0

    init(store: AppStore) {
        self.store = store
        // The helper can be respawned by launchd at any time (postinstall,
        // crash, log-out). Every successful re-subscribe MUST trigger a full
        // bootstrap on the new helper instance — otherwise the user toggles
        // Cut and gets nothing because the new helper has no context, no
        // allowlist, and no devices in memory.
        NotificationCenter.default.addObserver(
            forName: .helperReconnected, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.rehydrateAfterReconnect() }
        }
    }

    /// Reconnect refreshes discovery only. A helper restart ends its session.
    private func rehydrateAfterReconnect() async {
        guard await prepareHelperSession() else { return }
        await loadCurrentContext()
        try? await helper.setAllowlist(store.profile.allowlist)
        if let devs = try? await helper.scan(timeoutSeconds: 2) {
            store.handle(event: .devicesUpdated(devs))
        }
    }

    /// A reconnected helper can have outlived the GUI. End that session before
    /// enabling Engage rather than hiding its activity behind a fresh idle UI.
    private func prepareHelperSession() async -> Bool {
        blockingGeneration &+= 1
        let generation = blockingGeneration
        store.helperSessionReady = false
        store.blockingRequested = false
        do { try await helper.stopSpoof() }
        catch {
            guard generation == blockingGeneration else { return false }
            store.toast("Helper preparation failed: \(error.localizedDescription)")
            return false
        }
        guard generation == blockingGeneration else { return false }
        store.resetBlockingState()
        store.helperSessionReady = true
        return true
    }

    private func loadCurrentContext() async {
        async let appSSID = WiFiClient.shared.currentSSIDAsync()
        do {
            var context = try await helper.detectContext()
            if let ssid = await appSSID, !ssid.isEmpty, ssid != "<redacted>" {
                context.ssid = ssid
            }
            store.updateContext(context)
        } catch {
            store.updateContext(nil)
            store.toast("context: \(error.localizedDescription)")
        }
    }

    func refreshContext() {
        Task { await loadCurrentContext() }
    }

    func boot() async {
        Notifier.shared.requestAuth()
        // macOS hides SSIDs without Location permission — request it up front
        // so detectContext() and scanWiFi() return real names instead of "<redacted>".
        LocationGate.shared.onUnlock = { [weak self] in self?.refreshContext() }
        LocationGate.shared.request()

        do { try await helper.install() } catch {
            store.toast("helper install: \(error.localizedDescription)")
        }
        helper.connect()
        try? await Task.sleep(nanoseconds: 700_000_000)

        _ = await prepareHelperSession()
        await loadCurrentContext()

        // First scan — seed notifier so existing devices don't all alert at
        // once. Don't auto-engage spoofing on launch; the user toggles that.
        if let initial = try? await helper.scan(timeoutSeconds: 2) {
            Notifier.shared.seed(initial.map { $0.mac.description })
            store.handle(event: .devicesUpdated(initial))
            try? await helper.setAllowlist(store.profile.allowlist)
        }

        startContinuousScan()
        startThroughputPoll()
    }

    func startContinuousScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let devs = try await self.helper.scan(timeoutSeconds: 2)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.store.handle(event: .devicesUpdated(devs)) }
                    try? await self.helper.setAllowlist(self.store.profile.allowlist)

                    // The helper reconciles its current-network inventory.
                    // The app never resubmits a historical device snapshot.
                } catch {
                    guard !Task.isCancelled else { return }
                    await self.loadCurrentContext()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// Trust changes update the helper's policy without restarting its session.
    func resyncSpoofTargets() async {
        do { try await helper.setAllowlist(store.profile.allowlist) }
        catch { store.toast("Trust update failed: \(error.localizedDescription)") }
    }

    func startThroughputPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var lastTick = Date.now
            while !Task.isCancelled {
                guard let self else { return }
                // Skip the round-trip until the helper is actually live.
                if await !self.helper.connected {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                if let snap = try? await self.helper.throughputSnapshot() {
                    let now = Date.now
                    let dt = max(now.timeIntervalSince(lastTick), 0.001)
                    var totalDown: Double = 0, totalUp: Double = 0
                    var perDevice: [String: Double] = [:]
                    let selfMAC = self.store.context?.selfMAC.description ?? ""
                    // wm_traffic_drain returns per-MAC bytes since last drain
                    // (resets the counter), so `bytes` IS already the delta.
                    for (mac, bytes) in snap {
                        let bps = Double(bytes) / dt
                        perDevice[mac] = bps
                        if mac == selfMAC { totalDown += bps } else { totalUp += bps }
                    }
                    lastTick = now
                    let tick = ThroughputTick(timestamp: now,
                                              downBps: totalDown, upBps: totalUp)
                    await MainActor.run {
                        self.store.handle(event: .throughput(tick))
                        // Per-device fan-out: the prior version dropped the
                        // per-MAC numbers after summing the global tick,
                        // which is why the Devices list showed `0 bps`
                        // forever. Apply an EWMA so the column doesn't
                        // strobe between bursts and silence.
                        self.store.applyDeviceBandwidth(perDevice)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func runSpeedTest() async {
        if store.preCutSpeed == nil {
            store.preCutSpeed = try? await helper.runSpeedTest()
        } else {
            store.lastSpeed = try? await helper.runSpeedTest()
        }
    }

    func toggleBlocking() async {
        guard store.helperSessionReady else {
            store.toast("Waiting for helper session preparation")
            return
        }
        guard !store.stoppingBlocking else { return }
        let target = !(store.blockingRequested || store.blocking)
        if target {
            guard helper.connected else {
                store.toast("Helper not connected — open Settings → Reinstall")
                return
            }
            guard store.context != nil else {
                store.toast("No current network context")
                return
            }
        }
        blockingGeneration &+= 1
        let generation = blockingGeneration
        store.blockingRequested = target
        do {
            if target {
                try await helper.setAllowlist(store.profile.allowlist)
                guard generation == blockingGeneration, store.blockingRequested else { return }
                let context = try await helper.detectContext()
                guard generation == blockingGeneration, store.blockingRequested else { return }
                if let shown = store.context,
                   !NetworkSessionIdentity(context: shown).matches(context) {
                    store.updateContext(context)
                    throw NSError(domain: "CutSession", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Network changed; start again"])
                }
                let scanned = try await helper.scan(timeoutSeconds: 2)
                guard generation == blockingGeneration, store.blockingRequested else { return }
                store.handle(event: .devicesUpdated(scanned))
                try await helper.startSpoof(session: .currentNetwork(context),
                                            mode: store.profile.blockMode,
                                            ipv6: store.profile.ipv6Enabled)
            } else {
                try await helper.stopSpoof()
                guard generation == blockingGeneration else { return }
                store.resetBlockingState()
            }
        } catch {
            guard generation == blockingGeneration else { return }
            if target || !store.blocking {
                store.resetBlockingState()
            } else {
                // A failed stop is not evidence that the confirmed session
                // ended. Retain it and let the user retry the stop.
                store.blockingRequested = true
            }
            store.toast("Toggle failed: \(error.localizedDescription)")
        }
    }
}
