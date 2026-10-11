import Foundation
import Combine
import SwiftUI

/// Single-source-of-truth for the app's UI state.
@MainActor
final class AppStore: ObservableObject {

    // MARK: navigation
    enum Tab: String, CaseIterable, Identifiable {
        case recon, arsenal, lobby, devices, throughput, networks, profiles, schedule, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recon: "Recon"
            case .arsenal: "Arsenal"
            case .lobby: "Lobby"
            case .devices: "Devices"
            case .throughput: "Throughput"
            case .networks: "Networks"
            case .profiles: "Profiles"
            case .schedule: "Schedule"
            case .settings: "Settings"
            }
        }
        var icon: String {
            switch self {
            case .recon: "scope"
            case .arsenal: "burst.fill"
            case .lobby: "circle.hexagongrid.fill"
            case .devices: "rectangle.stack.fill"
            case .throughput: "waveform.path.ecg"
            case .networks: "wifi"
            case .profiles: "person.crop.rectangle.stack"
            case .schedule: "calendar"
            case .settings: "gearshape"
            }
        }
    }

    @Published var tab: Tab = .recon
    @Published var hasOnboarded: Bool = UserDefaults.standard.bool(forKey: "hasOnboarded")

    // MARK: data
    @Published var context: NetworkContext?
    @Published var devices: [Device] = []
    @Published var profile: NetworkProfile = NetworkProfile(ssid: "default")
    @Published var profiles: [NetworkProfile] = []
    @Published var blocking: Bool = false
    @Published var blockingRequested: Bool = false
    @Published var helperSessionReady: Bool = false
    @Published var blockedAt: Date?
    @Published var armedTargetIPv4s: Set<String> = []
    /// Last cut-status verdict from the helper. Drives the Lobby header badge
    /// and MenuBar tile so users see *honest* cut feedback ("engaged" / "your
    /// router blocks this") instead of a silent toggle that does nothing.
    @Published var cutStatus: CutStatus = .idle
    @Published var lastSpeed: SpeedSample?
    @Published var preCutSpeed: SpeedSample?
    @Published var throughputHistory: [ThroughputTick] = []
    @Published var wifiList: [WiFiNetwork] = []
    @Published var pulseTrigger: Int = 0
    @Published var pendingPasswordSheet: WiFiNetwork?
    @Published var toastMessage: String?

    /// App-side mDNS enricher. Runs in parallel to the helper's
    /// MDNSBrowser so devices get rich names + model + service counts
    /// even before the user re-registers a new helper. Field is
    /// `let` because the enricher is a singleton — its internal cache
    /// is the live state.
    let mdns = MDNSAppEnricher()
    private var identityCache = DeviceIdentityCache()
    private var identityTask: Task<Void, Never>?
    private var identityGeneration: UInt64 = 0
    private var lastIdentityProbe = Date.distantPast

    // MARK: derived
    var startingBlocking: Bool { blockingRequested && !blocking }
    var stoppingBlocking: Bool { blocking && !blockingRequested }

    var allowlistedDevices: [Device] {
        devices.filter { $0.isAllowlisted && !$0.isSelf && !$0.isGateway }
    }
    var blockedDevices: [Device] {
        devices.filter {
            !$0.isAllowlisted && !$0.isSelf && !$0.isGateway
                && (!blocking || $0.ipv4.map(armedTargetIPv4s.contains) == true)
        }
    }
    var selfDevice: Device? { devices.first { $0.isSelf } }
    var gatewayDevice: Device? { devices.first { $0.isGateway } }

    // MARK: I/O
    private var bag = Set<AnyCancellable>()
    private var pollTimer: Timer?

    init() {
        loadProfiles()
        NotificationCenter.default.publisher(for: .helperEvent)
            .compactMap { $0.object as? HelperEvent }
            .sink { [weak self] evt in self?.handle(event: evt) }
            .store(in: &bag)
        // Fire up the App-side mDNS browser immediately. It listens for
        // the lifetime of the app; its cache feeds `mergeDevices` so the
        // device list shows model + Bonjour name + service count without
        // depending on the helper version that's currently registered.
        mdns.start()
        // Re-merge whenever the mDNS cache updates so newly-resolved
        // services flow into the visible device list within one update
        // tick rather than waiting for the next ARP scan.
        mdns.$byIP
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Pure re-merge — feed the existing devices back through
                // the same path so vendor / model / hostname / services
                // get re-applied with the freshest mDNS state.
                self.mergeDevices(self.devices)
            }
            .store(in: &bag)
    }

    func handle(event: HelperEvent) {
        switch event {
        case .context(let ctx):
            updateContext(ctx)
        case .devicesUpdated(let devs):
            mergeDevices(devs)
        case .spoofStateChanged(let targets, let active):
            // A late confirmation cannot re-arm the UI after the user cancels.
            if active && !blockingRequested { return }
            let wasBlocking = blocking
            blocking = active
            armedTargetIPv4s = active ? Set(targets) : []
            if active && blockedAt == nil { blockedAt = .now }
            if !active {
                blockedAt = nil
                cutStatus = .idle
                // The helper emits idle while preparing a new start. Preserve
                // that pending request; an ended confirmed session is final.
                if wasBlocking { blockingRequested = false }
            }
            pulseTrigger += 1
        case .throughput(let tick):
            throughputHistory.append(tick)
            if throughputHistory.count > 600 {
                throughputHistory.removeFirst(throughputHistory.count - 600)
            }
        case .speedTest(let s):
            lastSpeed = s
        case .log: break
        case .error(let msg):
            toastMessage = msg
        case .cutStatus(let s):
            if s != .idle && !blockingRequested { return }
            cutStatus = s
        }
    }

    func resetBlockingState() {
        blocking = false
        blockingRequested = false
        blockedAt = nil
        armedTargetIPv4s.removeAll()
        cutStatus = .idle
    }

    func updateContext(_ next: NetworkContext?) {
        let changed: Bool
        if let old = context, let next {
            changed = !NetworkSessionIdentity(context: old).matches(next)
        } else {
            changed = (context != nil) != (next != nil)
        }
        if changed {
            identityGeneration &+= 1
            identityTask?.cancel()
            identityTask = nil
            identityCache.reset()
            lastIdentityProbe = .distantPast
            devices.removeAll()
            mdns.reset()
            resetBlockingState()
            throughputHistory.removeAll()
            preCutSpeed = nil
            lastSpeed = nil
        }
        var resolved = next
        if !changed, resolved?.ssid == nil { resolved?.ssid = context?.ssid }
        context = resolved
        if let ssid = next?.ssid { adoptProfile(ssid: ssid) }
    }

    private func mergeDevices(_ incoming: [Device]) {
        let previous = Dictionary(uniqueKeysWithValues: devices.map { ($0.mac, $0) })
        var byMac: [MACAddress: Device] = [:]
        let previousBindings = identityCache.bindings
        let ownershipChanged = identityCache.update(incoming)
        if ownershipChanged {
            identityGeneration &+= 1
            identityTask?.cancel()
            identityTask = nil
            let changedAddresses = Set(previousBindings.keys).union(identityCache.bindings.keys)
                .filter { previousBindings[$0] != identityCache.bindings[$0] }
            mdns.refresh(invalidatingIPv4s: Set(changedAddresses))
        }
        let mdnsSnap = mdns.byIP
        for var d in incoming {
            let isNewToSession = previous[d.mac] == nil
            if let existing = previous[d.mac] {
                d.firstSeen = existing.firstSeen
                d.bandwidthBps = existing.bandwidthBps
                d.threatScore = existing.threatScore
            }
            d.isAllowlisted = profile.allowlist.contains { $0.mac == d.mac } || d.isSelf || d.isGateway
            d.vendor = d.mac.isLocallyAdministered ? nil : (d.vendor ?? VendorDB.shared.vendor(for: d.mac))

            d = identityCache.enriched(d,
                bonjour: d.ipv4.flatMap { mdnsSnap[$0]?.identification })
            if let model = d.identification?.modelName,
               let name = AppleModelResolver.shared.name(for: model) {
                d.identification?.modelName = name
            }

            byMac[d.mac] = d
            // Fire a notification for genuinely new devices (not already in the
            // current device list). Notifier dedupes per session in case the
            // same MAC bounces in and out of view.
            if isNewToSession, !d.isSelf, !d.isGateway, profile.notifyOnNewDevice {
                Notifier.shared.newDevice(d, ssid: profile.ssid)
            }
        }
        devices = Array(byMac.values).sorted {
            if $0.isSelf != $1.isSelf { return $0.isSelf }
            if $0.isGateway != $1.isGateway { return $0.isGateway }
            if $0.isAllowlisted != $1.isAllowlisted { return $0.isAllowlisted }
            return ($0.ipv4 ?? "") < ($1.ipv4 ?? "")
        }
        refreshDeviceIdentities(force: ownershipChanged)
    }

    func hasAddressConflict(_ device: Device) -> Bool {
        device.ipv4.map(identityCache.conflictingIPv4s.contains) == true
    }

    private func refreshDeviceIdentities(force: Bool = false) {
        guard identityTask == nil, let context,
              force || Date.now.timeIntervalSince(lastIdentityProbe) >= 60 else { return }
        let requestedBindings = identityCache.bindings
        let allowed = Set(requestedBindings.filter { $0.value.mac != context.selfMAC }.keys.prefix(128))
        guard !allowed.isEmpty else { return }
        let generation = identityGeneration
        lastIdentityProbe = .now
        identityTask = Task { [weak self] in
            async let descriptions = UPnPDiscovery.discover(sourceIPv4: context.selfIPv4, allowedIPv4s: allowed)
            async let names = ReverseNameDiscovery.discover(interface: context.interface, allowedIPv4s: allowed)
            let (records, hostnames) = await (descriptions, names)
            guard let self, !Task.isCancelled, generation == self.identityGeneration else { return }
            self.identityCache.accept(records, requestedBindings: requestedBindings)
            self.identityCache.acceptHostnames(hostnames, requestedBindings: requestedBindings)
            // Keep the task marked active while re-merging to avoid scheduling
            // another discovery pass from its own publication.
            self.mergeDevices(self.devices)
            self.identityTask = nil
        }
    }

    // MARK: profiles persistence

    private var profilesURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("WifiMancer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("profiles.json")
    }

    func loadProfiles() {
        guard let data = try? Data(contentsOf: profilesURL),
              let list = try? JSONDecoder().decode([NetworkProfile].self, from: data) else { return }
        // Drop garbage profiles created before SSID redaction was handled —
        // those were saved with literal name "<redacted>" or empty.
        profiles = list.filter { p in
            !p.ssid.isEmpty && p.ssid != "<redacted>"
        }
        if profiles.count != list.count { saveProfiles() }
    }

    func deleteProfile(ssid: String) {
        profiles.removeAll { $0.ssid == ssid }
        saveProfiles()
        if profile.ssid == ssid {
            profile = profiles.first ?? NetworkProfile(ssid: context?.ssid ?? "default")
        }
    }

    func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            try? data.write(to: profilesURL, options: .atomic)
        }
    }

    func adoptProfile(ssid: String) {
        // Refuse to adopt a redacted/empty SSID — that's not a real network,
        // it's macOS withholding the name. Wait for a real SSID instead.
        guard !ssid.isEmpty, ssid != "<redacted>" else { return }
        if let existing = profiles.first(where: { $0.ssid == ssid }) {
            profile = existing
        } else {
            profile = NetworkProfile(ssid: ssid)
            profiles.append(profile)
            saveProfiles()
        }
    }

    func upsertCurrentProfile() {
        if let idx = profiles.firstIndex(where: { $0.ssid == profile.ssid }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    // MARK: actions

    func toggleAllowlist(for device: Device) {
        if let idx = profile.allowlist.firstIndex(where: { $0.mac == device.mac }) {
            profile.allowlist.remove(at: idx)
        } else {
            profile.allowlist.append(AllowEntry(mac: device.mac, nickname: device.hostname))
        }
        upsertCurrentProfile()
        // Optimistic: flip flag on the in-memory device list so the UI reacts now
        // instead of waiting for the next 5s scan.
        if let i = devices.firstIndex(where: { $0.mac == device.mac }) {
            devices[i].isAllowlisted = profile.allowlist.contains { $0.mac == device.mac }
                                       || devices[i].isSelf || devices[i].isGateway
        }
        pulseTrigger += 1
    }

    func addAllowEntry(mac: MACAddress, nickname: String?) {
        guard !profile.allowlist.contains(where: { $0.mac == mac }) else { return }
        profile.allowlist.append(AllowEntry(mac: mac, nickname: nickname))
        upsertCurrentProfile()
        if let i = devices.firstIndex(where: { $0.mac == mac }) {
            devices[i].isAllowlisted = true
        }
        pulseTrigger += 1
    }

    func removeAllowEntry(mac: MACAddress) {
        profile.allowlist.removeAll { $0.mac == mac }
        upsertCurrentProfile()
        if let i = devices.firstIndex(where: { $0.mac == mac }) {
            devices[i].isAllowlisted = devices[i].isSelf || devices[i].isGateway
        }
        pulseTrigger += 1
    }

    /// Apply a per-MAC instantaneous bps reading from the helper to each
    /// Device's `bandwidthBps`. The poll loop runs ~1 Hz, so an EWMA with
    /// `alpha = 0.4` smooths bursts while still tracking sustained traffic
    /// within ~3 ticks. MACs not in the snapshot decay toward zero so the
    /// column doesn't get stuck showing the last burst forever after the
    /// device goes quiet.
    ///
    /// Caveat that's worth knowing about: in non-cut mode, on Wi-Fi we
    /// only see broadcast/multicast and our own unicast frames — other
    /// devices' traffic doesn't pass through us, so they will read 0 bps.
    /// Cut-mode ARP-spoofs the targets so their traffic does flow through
    /// us, and that's when the per-device numbers actually become real.
    func applyDeviceBandwidth(_ bps: [String: Double]) {
        let alpha = 0.4
        for i in devices.indices {
            let d = devices[i]
            let raw = bps[d.mac.description] ?? 0
            let prev = d.bandwidthBps
            let smoothed = alpha * raw + (1 - alpha) * prev
            // Snap small values to zero so the row doesn't sit at "12 bps"
            // forever from rounding noise.
            devices[i].bandwidthBps = smoothed < 50 ? 0 : smoothed
        }
    }

    func toast(_ msg: String) {
        toastMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { if self.toastMessage == msg { self.toastMessage = nil } }
        }
    }
}
