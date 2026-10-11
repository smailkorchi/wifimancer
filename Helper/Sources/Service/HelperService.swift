import Foundation

/// Lock-protected map populated by the mDNS sink and read by the
/// scan completion path. Holds raw identifiers — the App resolves them
/// to marketing names through its own bundled `AppleModelResolver`,
/// because the helper is a command-line tool target with no bundle
/// resources, so it cannot ship `apple-models.json` itself.
struct MDNSRecord: Sendable, Hashable {
    let modelIdentifier: String?    // e.g. "MacBookPro17,1"
    let prettyName: String?         // e.g. "Ismail's MacBook Pro"
}

final class MDNSEnrichmentCache: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var byIP: [String: MDNSRecord] = [:]
    func merge(ip: String, model: String?, name: String?) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let existing = byIP[ip]
        byIP[ip] = MDNSRecord(
            modelIdentifier: model ?? existing?.modelIdentifier,
            prettyName: name ?? existing?.prettyName
        )
    }
    func record(for ip: String) -> MDNSRecord? {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return byIP[ip]
    }
    func snapshot() -> [String: MDNSRecord] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return byIP
    }
}

final class HelperService: NSObject, HelperProtocol, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.wifimancer.helper.svc")

    private var trafficCtx: OpaquePointer?
    private var trafficInterface: String?
    private var trafficGeneration: UInt64 = 0
    private let wifi = WiFiManager()
    private var mdnsBrowser: MDNSBrowser?
    private let mdnsCache = MDNSEnrichmentCache()
    private let lifecycleGate = SessionLifecycleGate()
    private var sessions: NetworkCutController!

    override init() {
        super.init()
        sessions = NetworkCutController(mdnsCache: mdnsCache, lifecycleGate: lifecycleGate) { [weak self] context in
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.updateTrafficInterface(context?.interface)
                if let context { self.startMDNSBrowserIfNeeded(selfIP: context.selfIPv4) }
            }
        }
    }

    // MARK: lifecycle / sanity

    func ping(reply: @escaping (String) -> Void) {
        reply("pong: \(Bundle.main.bundleIdentifier ?? "helper")")
    }

    func version(reply: @escaping (String) -> Void) {
        reply("0.1.0")
    }

    // MARK: context + scan

    func detectContext(reply: @escaping (Data?, String?) -> Void) {
        Task {
            do { reply(try JSONEncoder().encode(await sessions.detectContext()), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    func scan(timeoutSeconds: Int, reply: @escaping (Data?, String?) -> Void) {
        Task {
            do { reply(try JSONEncoder().encode(await sessions.scan(timeoutSeconds: timeoutSeconds)), nil) }
            catch { reply(nil, error.localizedDescription) }
        }
    }

    // MARK: mDNS browser bootstrap

    /// Start the continuous mDNS browser exactly once. The sink populates
    /// `mdnsCache` keyed on IPv4 — for that we resolve each Discovery's
    /// `hostTarget` (e.g. `Ismails-MacBook-Pro.local.`) to an IPv4 via the
    /// system resolver, which goes through mDNSResponder for `.local.`
    /// names and resolves in milliseconds.
    private func startMDNSBrowserIfNeeded(selfIP: String) {
        guard mdnsBrowser == nil else { return }
        let browser = MDNSBrowser()
        let cache = self.mdnsCache
        Task {
            await browser.start { discovery in
                // Capture both signals — model identifier from TXT, and
                // pretty name from the Bonjour instance — so randomized-MAC
                // hosts (iPhone, iPad, etc.) still surface a human label.
                let modelId = discovery.appleModelIdentifier
                let pretty = discovery.prettyName.isEmpty ? nil : discovery.prettyName
                guard !discovery.hostTarget.isEmpty else { return }

                // Resolve the Bonjour hostTarget to one or more LAN IPv4
                // addresses. For the local Mac, mDNSResponder will hand
                // back loopback in addition to the real interface IP — so
                // we keep all real LAN IPs, drop loopback/link-local, and
                // when we know our own selfIPv4 we associate the local
                // Mac's records with it directly.
                let ips = await Self.resolveLocalToIPv4(discovery.hostTarget)
                let usable = ips.filter { ip in
                    !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.")
                }
                for ip in usable {
                    cache.merge(ip: ip, model: modelId, name: pretty)
                }
                // Best-effort: if hostTarget belongs to this Mac, also
                // attach the record to selfIP. mDNS announcements from
                // localhost sometimes resolve to interface aliases that
                // don't match selfIP exactly.
                if discovery.hostTarget.lowercased()
                    .replacingOccurrences(of: ".local.", with: "")
                    .replacingOccurrences(of: ".local", with: "")
                    .hasPrefix(Host.current().localizedName?.lowercased()
                        .replacingOccurrences(of: " ", with: "-") ?? "__nope__")
                {
                    cache.merge(ip: selfIP, model: modelId, name: pretty)
                }
            }
        }
        self.mdnsBrowser = browser
        Log.root.info("mdns browser started")
    }

    /// Resolve a `.local.` hostname via the system resolver. Returns ALL
    /// IPv4 addresses found (mDNS responders can advertise multiple
    /// interfaces for the same name; for our own Mac, that includes both
    /// the LAN IP and 127.0.0.1). Caller is responsible for filtering
    /// loopback / link-local. Runs in a detached Task because
    /// `getaddrinfo` blocks; `.local.` lookups are fast (sub-100ms).
    nonisolated private static func resolveLocalToIPv4(_ host: String) async -> [String] {
        await Task.detached(priority: .background) { () -> [String] in
            var hints = addrinfo(
                ai_flags: AI_DEFAULT,
                ai_family: AF_INET,
                ai_socktype: SOCK_STREAM,
                ai_protocol: 0,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var result: UnsafeMutablePointer<addrinfo>?
            defer { if let r = result { freeaddrinfo(r) } }
            guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
            var out: [String] = []
            var p = result
            while p != nil {
                if let saPtr = p?.pointee.ai_addr,
                   p?.pointee.ai_family == AF_INET {
                    saPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { saIn in
                        var addr = saIn.pointee.sin_addr
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        if inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil {
                            let ip = String(cString: buf)
                            if !out.contains(ip) { out.append(ip) }
                        }
                    }
                }
                p = p?.pointee.ai_next
            }
            return out
        }.value
    }

    // MARK: allowlist + spoof

    func setAllowlist(_ data: Data, reply: @escaping (Bool, String?) -> Void) {
        Task {
            do {
                let entries = try JSONDecoder().decode([AllowEntry].self, from: data)
                try await sessions.setAllowlist(Set(entries.map(\.mac)))
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    func startSpoof(targetsData: Data, blockModeRaw: String, ipv6Enabled: Bool,
                    reply: @escaping (Bool, String?) -> Void) {
        let epoch = lifecycleGate.invalidate()
        Task {
            do {
                try await sessions.start(data: targetsData, blockModeRaw: blockModeRaw, epoch: epoch)
                reply(true, nil)
            } catch { reply(false, error.localizedDescription) }
        }
    }

    func stopSpoof(reply: @escaping (Bool, String?) -> Void) {
        let epoch = lifecycleGate.invalidate()
        Task {
            await sessions.stop(epoch: epoch)
            reply(true, nil)
        }
    }

    func pauseSpoof(seconds: Int, reply: @escaping (Bool, String?) -> Void) {
        // Pausing ends the session; a delayed timer must never re-arm after stop.
        let epoch = lifecycleGate.invalidate()
        Task {
            await sessions.stop(epoch: epoch)
            reply(true, nil)
        }
    }

    // MARK: throughput

    /// All access to the pcap handle, including close, runs on this queue.
    private func updateTrafficInterface(_ interface: String?) {
        guard trafficInterface != interface else { return }
        trafficGeneration &+= 1
        if let ctx = trafficCtx { wm_traffic_close(ctx) }
        trafficCtx = nil
        trafficInterface = interface
        guard let interface else { return }
        var errbuf = [CChar](repeating: 0, count: 256)
        guard let ctx = wm_traffic_open(interface, &errbuf) else { return }
        trafficCtx = ctx
        pumpTraffic(generation: trafficGeneration)
    }

    private func pumpTraffic(generation: UInt64) {
        guard generation == trafficGeneration, let ctx = trafficCtx else { return }
        wm_traffic_pump(ctx, 256)
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.pumpTraffic(generation: generation)
        }
    }

    func throughputSnapshot(reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            guard let ctx = self.trafficCtx else { reply(nil, "no traffic ctx"); return }
            let cap = 256
            var macFlat = [UInt8](repeating: 0, count: cap * 6)
            var bytes = [UInt64](repeating: 0, count: cap)
            let n: Int32 = macFlat.withUnsafeMutableBufferPointer { mp in
                bytes.withUnsafeMutableBufferPointer { bp in
                    mp.baseAddress!.withMemoryRebound(
                        to: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8).self, capacity: cap
                    ) { wm_traffic_drain(ctx, $0, bp.baseAddress!, Int32(cap)) }
                }
            }
            var dict: [String: UInt64] = [:]
            for i in 0..<Int(n) {
                let off = i * 6
                let mac = MACAddress(bytes: Array(macFlat[off..<off+6]))
                dict[mac.description] = bytes[i]
            }
            reply(try? JSONEncoder().encode(dict), nil)
        }
    }

    // MARK: speed test

    func runSpeedTest(reply: @escaping (Data?, String?) -> Void) {
        Task.detached {
            let s = await SpeedTester().run()
            EventBus.shared.emit(.speedTest(s))
            reply(try? JSONEncoder().encode(s), nil)
        }
    }

    // MARK: hostname / mDNS

    func resolveHostnames(ipsData: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            let ips = try JSONDecoder().decode([String].self, from: ipsData)
            Task {
                var out: [String: String] = [:]
                await withTaskGroup(of: (String, String?).self) { group in
                    for ip in ips {
                        group.addTask { (ip, await Self.reverseDNS(ip)) }
                    }
                    for await (ip, name) in group {
                        if let name { out[ip] = name }
                    }
                }
                reply(try? JSONEncoder().encode(out), nil)
            }
        } catch { reply(nil, error.localizedDescription) }
    }

    private static func reverseDNS(_ ip: String) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var res: UnsafeMutablePointer<addrinfo>? = nil
                if getaddrinfo(ip, nil, &hints, &res) != 0 || res == nil {
                    cont.resume(returning: nil); return
                }
                defer { freeaddrinfo(res) }
                let host = UnsafeMutablePointer<CChar>.allocate(capacity: Int(NI_MAXHOST))
                defer { host.deallocate() }
                let rc = getnameinfo(res!.pointee.ai_addr,
                                     res!.pointee.ai_addrlen,
                                     host, socklen_t(NI_MAXHOST),
                                     nil, 0, NI_NAMEREQD)
                if rc == 0, let s = String(validatingUTF8: host) {
                    cont.resume(returning: s)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Wi-Fi

    func joinWiFi(ssid: String, password: String?, reply: @escaping (Bool, String?) -> Void) {
        Task {
            do { try await wifi.join(ssid: ssid, password: password); reply(true, nil) }
            catch { reply(false, error.localizedDescription) }
        }
    }

    func leaveWiFi(reply: @escaping (Bool, String?) -> Void) {
        wifi.disassociate(); reply(true, nil)
    }

    func scanWiFi(reply: @escaping (Data?, String?) -> Void) {
        Task {
            do {
                let nets = try await wifi.scan()
                reply(try? JSONEncoder().encode(nets), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }

    func savedWiFiSSIDs(reply: @escaping (Data?, String?) -> Void) {
        let ssids = wifi.savedNetworkSSIDs()
        reply(try? JSONEncoder().encode(ssids), nil)
    }

    /// Read a saved Wi-Fi password from the macOS system keychain. The
    /// helper runs as root, so `/usr/bin/security` inherits root privileges
    /// and can read the airportd entries in `/Library/Keychains/System.keychain`
    /// without triggering the per-app keychain auth prompt that an
    /// ad-hoc-signed app process would hit.
    func fetchSystemWiFiPassword(ssid: String,
                                 reply: @escaping (String?, String?) -> Void) {
        queue.async {
            let out = Sysinfo.runShell(
                ["/usr/bin/security", "find-generic-password", "-wa", ssid]
            )
            let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("WIFIMANCER fetchSystemWiFiPassword ssid=%@ result_len=%d",
                  ssid, s.count)
            if s.isEmpty {
                reply(nil, "no entry for \(ssid)")
            } else {
                reply(s, nil)
            }
        }
    }

    // MARK: events / subscription

    func subscribeEvents(_ endpoint: NSXPCListenerEndpoint, reply: @escaping (Bool) -> Void) {
        let conn = NSXPCConnection(listenerEndpoint: endpoint)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperEventReceiver.self)
        conn.resume()
        if let proxy = conn.remoteObjectProxy as? HelperEventReceiver {
            EventBus.shared.register(proxy)
            reply(true)
        } else {
            reply(false)
        }
    }

    func quit(reply: @escaping (Bool) -> Void) {
        let epoch = lifecycleGate.invalidate()
        Task {
            await sessions.stop(epoch: epoch)
            reply(true)
            exit(0)
        }
    }
}

/// Actor isolation owns the policy/inventory. Engine jobs are also chained so
/// actor reentrancy cannot let an old start race a stop or a trust update.
private actor NetworkCutController {
    private var state = CutSessionState()
    private var engines: SessionCutEngines?
    private var engineTail: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private let mdnsCache: MDNSEnrichmentCache
    private let lifecycleGate: SessionLifecycleGate
    private var armedEpoch: UInt64?
    private let contextChanged: @Sendable (NetworkContext?) -> Void
    // Cleanup remains available for layers used by older installed helpers.
    private let cutLayers = CutLayers()
    private let dhcpAttacker = DHCPAttacker()
    private let ipClaimer = IPClaimer()

    init(mdnsCache: MDNSEnrichmentCache, lifecycleGate: SessionLifecycleGate,
         contextChanged: @escaping @Sendable (NetworkContext?) -> Void) {
        self.mdnsCache = mdnsCache
        self.lifecycleGate = lifecycleGate
        self.contextChanged = contextChanged
    }

    func detectContext() throws -> NetworkContext {
        refreshContext()
        guard let context = state.context else { throw failure("Network context unavailable") }
        return context
    }

    private func refreshContext() {
        let wasArmed = state.request != nil
        let changed = state.updateContext(ContextDetector.detect())
        if changed {
            tearDownEngines(restore: false)
            monitorTask?.cancel(); monitorTask = nil
            emitIdle()
            EventBus.shared.emit(.devicesUpdated([]))
            if wasArmed { EventBus.shared.emit(.error("Network changed or disconnected; session stopped")) }
        }
        contextChanged(state.context)
        if let context = state.context { EventBus.shared.emit(.context(context)) }
    }

    func scan(timeoutSeconds: Int) async throws -> [Device] {
        refreshContext()
        guard let context = state.context else { throw failure("Network context unavailable") }
        let generation = state.generation
        let observations = try await ARPScanner(context: context)
            .scan(durationMs: min(max(1, timeoutSeconds), 10) * 1000)
        // A completed sweep belongs to the context and lifecycle that began it.
        refreshContext()
        guard generation == state.generation, state.context != nil else {
            throw failure("Scan superseded by a stop or network change")
        }
        let mdns = mdnsCache.snapshot()
        let devices = observations.map { observation -> Device in
            let record = mdns[observation.ip]
            return Device(mac: observation.mac, ipv4: observation.ip,
                          hostname: record?.prettyName, deviceModel: record?.modelIdentifier)
        }
        // Learning an absent gateway MAC does not constitute a network switch.
        if var current = state.context, current.gatewayMAC == nil,
           let gateway = observations.first(where: {
               $0.ip == current.gatewayIPv4 && $0.mac != current.selfMAC
                   && !$0.mac.isMulticast && $0.mac.bytes.contains(where: { $0 != 0 })
           }) {
            current.gatewayMAC = gateway.mac
            state.updateContext(current)
            EventBus.shared.emit(.context(current))
        }
        guard state.acceptScan(devices, generation: generation) else {
            throw failure("Scan superseded by a stop or network change")
        }
        let inventory = state.devices
        EventBus.shared.emit(.devicesUpdated(inventory))
        if state.request != nil, let error = await scheduleApply().value { throw failure(error) }
        return inventory
    }

    func setAllowlist(_ macs: Set<MACAddress>) async throws {
        refreshContext()
        state.allowlistedMACs = macs
        EventBus.shared.emit(.devicesUpdated(state.devices))
        if state.request != nil, let error = await scheduleApply().value { throw failure(error) }
    }

    func start(data: Data, blockModeRaw: String, epoch: UInt64) async throws {
        refreshContext()
        guard lifecycleGate.isCurrent(epoch) else { throw failure("Session start cancelled") }
        // A newest command supersedes the old session even if its payload is
        // rejected; stale packet engines must not survive with an idle policy.
        state.stop()
        monitorTask?.cancel(); monitorTask = nil
        tearDownEngines()
        emitIdle()
        guard let context = state.context else { throw failure("Network context unavailable") }
        let request: CutSessionRequest
        if let decoded = try? JSONDecoder().decode(CutSessionRequest.self, from: data) {
            request = decoded
        } else {
            // Staggered upgrades still accept explicit manual peers, but only
            // exact identities freshly known on this helper's current network.
            let manualTargets: [SpoofTarget]
            if let decoded = try? JSONDecoder().decode([SpoofTarget].self, from: data) {
                manualTargets = decoded
            } else {
                let strings = try JSONDecoder().decode([String].self, from: data)
                let macs = strings.compactMap(MACAddress.init)
                guard macs.count == strings.count else { throw failure("Malformed manual MAC target") }
                manualTargets = try macs.map { mac in
                    guard let device = state.inventory[mac], let ip = device.ipv4 else {
                        throw failure("Manual target not observed on the current network")
                    }
                    return SpoofTarget(mac: mac, ipv4: ip)
                }
            }
            for target in manualTargets {
                guard state.inventory[target.mac]?.ipv4 == target.ipv4 else {
                    throw failure("Manual target identity is stale or unobserved")
                }
            }
            request = .currentNetwork(context, policy: .manual,
                                      manualTargetMACs: Set(manualTargets.map(\.mac)))
            let accepted = CutTargetReconciler.reconcile(.init(
                devices: state.devices, scope: request.scope, policy: .manual,
                allowlistedMACs: state.allowlistedMACs,
                manualTargetMACs: request.manualTargetMACs, context: context
            )).targets
            guard Set(accepted.map(\.mac)) == request.manualTargetMACs else {
                throw failure("Manual targets include protected or invalid network identities")
            }
        }
        guard lifecycleGate.isCurrent(epoch) else { throw failure("Session start cancelled") }
        try state.start(request)
        armedEpoch = epoch
        let generation = state.generation
        engines = SessionCutEngines(context: context,
                                    mode: ARPSpoofer.BlockMode(rawValue: blockModeRaw) ?? .instant) { [weak self] error in
            Task { await self?.packetFailed(generation: generation, error: error) }
        }
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.checkSession(generation: generation)
            }
        }
        if let error = await scheduleApply().value { throw failure(error) }
        guard isCurrent(generation) else { throw failure("Session start cancelled") }
    }

    func stop(epoch: UInt64? = nil) async {
        // A stop delivered late must not cancel a newer explicit start.
        if let epoch, !lifecycleGate.isCurrent(epoch) { return }
        state.stop()
        monitorTask?.cancel(); monitorTask = nil
        let cleanup = tearDownEngines()
        emitIdle()
        await cleanup.value
    }

    private func checkSession(generation: UInt64) {
        guard isCurrent(generation) else { return }
        refreshContext()
        guard isCurrent(generation) else { return }
        if state.request?.scope.isCurrentlyValid() != true {
            state.stop()
            monitorTask?.cancel(); monitorTask = nil
            tearDownEngines()
            emitIdle()
            EventBus.shared.emit(.error("Session scope expired; session stopped"))
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        state.generation == generation && state.request != nil
            && armedEpoch.map(lifecycleGate.isCurrent) == true
    }

    private func snapshot(generation: UInt64) -> (NetworkContext, [SpoofTarget], [ARPSpoofer.Target])? {
        refreshContext()
        guard isCurrent(generation), let context = state.context,
              state.request?.scope.isCurrentlyValid() == true else { return nil }
        return (context, state.targets(), currentBindings())
    }

    private func scheduleApply() -> Task<String?, Never> {
        let generation = state.generation
        let previous = engineTail
        let engines = self.engines
        let operation = Task { [weak self] () -> String? in
            await previous?.value
            guard let self, let engines else {
                return "Session update cancelled"
            }
            while true {
                guard let (context, targets, bindings) = await self.snapshot(generation: generation) else {
                    return "Session update cancelled"
                }
                do {
                    // Unknown gateway identity and empty inventories are armed
                    // waiting states. No packet engine is opened until usable.
                    let configured = try await engines.apply(context: context, targets: targets, bindings: bindings)
                    guard await self.isCurrent(generation) else {
                        await engines.stop(restore: false)
                        return "Session update cancelled"
                    }
                    // Discovery or trust can change while the packet actors
                    // suspend. Reconcile again before reporting success; never
                    // publish a stale set that includes a newly trusted peer.
                    if await self.applied(generation: generation, targets: configured) { return nil }
                } catch {
                    await self.startFailed(generation: generation, error: error.localizedDescription)
                    return error.localizedDescription
                }
            }
        }
        engineTail = Task { _ = await operation.value }
        return operation
    }

    private func applied(generation: UInt64, targets: [SpoofTarget]) -> Bool {
        guard isCurrent(generation) else { return false }
        guard targets == state.targets() || state.context?.gatewayMAC == nil else { return false }
        EventBus.shared.emit(.spoofStateChanged(targets: targets.map(\.ipv4), active: true))
        EventBus.shared.emit(.cutStatus(targets.isEmpty ? .noTargets : .engaged))
        return true
    }

    private func startFailed(generation: UInt64, error: String) {
        guard isCurrent(generation) else { return }
        state.stop()
        monitorTask?.cancel(); monitorTask = nil
        tearDownEngines()
        emitIdle()
        EventBus.shared.emit(.error("Session failed: \(error)"))
    }

    private func packetFailed(generation: UInt64, error: String) {
        refreshContext()
        startFailed(generation: generation, error: error)
    }

    private func currentBindings() -> [ARPSpoofer.Target] {
        guard let context = state.context else { return [] }
        return state.devices.compactMap { device in
            guard let ip = device.ipv4,
                  CutTargetReconciler.isUsableIPv4(ip, in: context.subnetCIDR),
                  !device.mac.isMulticast, device.mac.bytes.contains(where: { $0 != 0 }) else { return nil }
            return ARPSpoofer.Target(ip: ip, mac: device.mac)
        }
    }

    @discardableResult
    private func tearDownEngines(restore: Bool = true) -> Task<Void, Never> {
        let previous = engineTail
        let old = engines
        let bindings = currentBindings()
        engines = nil
        let cutLayers = self.cutLayers, dhcpAttacker = self.dhcpAttacker, ipClaimer = self.ipClaimer
        let cleanup = Task {
            await previous?.value
            await old?.stop(restore: restore, bindings: bindings)
            await cutLayers.stop()
            await dhcpAttacker.stop()
            await ipClaimer.clearAll()
        }
        engineTail = cleanup
        return cleanup
    }

    private func emitIdle() {
        EventBus.shared.emit(.spoofStateChanged(targets: [], active: false))
        EventBus.shared.emit(.cutStatus(.idle))
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "CutSession", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The controller chains calls into this actor. It never enables DHCP, IP
/// aliases, DNS interception or unknown IPv6 prefixes.
private actor SessionCutEngines {
    private let arp: ARPSpoofer
    private let responder: ARPResponder
    private let mode: ARPSpoofer.BlockMode
    private var context: NetworkContext
    private var started = false

    init(context: NetworkContext, mode: ARPSpoofer.BlockMode,
         onFailure: @escaping @Sendable (String) -> Void) {
        arp = ARPSpoofer(context: context, onFailure: onFailure)
        responder = ARPResponder(context: context, onFailure: onFailure)
        self.context = context
        self.mode = mode
    }

    func apply(context: NetworkContext, targets: [SpoofTarget],
               bindings: [ARPSpoofer.Target]) async throws -> [SpoofTarget] {
        self.context = context
        guard context.gatewayMAC != nil, !targets.isEmpty else {
            if started {
                try await responder.update(targets: [])
                try await arp.update(targets: [], bindings: bindings)
            }
            return []
        }
        let peers = targets.map { ARPSpoofer.Target(ip: $0.ipv4, mac: $0.mac) }
        await arp.setContext(context)
        await responder.setContext(context)
        if !started {
            do {
                try await arp.start(targets: peers, mode: mode, bindings: bindings)
                try await responder.start(targets: peers)
                started = true
            } catch {
                await responder.stop()
                await arp.stop(bindings: bindings)
                throw error
            }
        } else {
            try await responder.update(targets: peers)
            try await arp.update(targets: peers, bindings: bindings)
        }
        return targets
    }

    func stop(restore: Bool = true, bindings: [ARPSpoofer.Target]? = nil) async {
        await responder.stop()
        // A queued explicit stop may execute after a physical network switch.
        let current = ContextDetector.detect()
        let sameNetwork = current.map { NetworkSessionIdentity(context: context).matches($0) } ?? false
        await arp.stop(restore: restore && sameNetwork, bindings: bindings)
        started = false
    }
}

/// Invalidated at XPC entry, before Tasks can reorder actor delivery.
private final class SessionLifecycleGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0

    func current() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    func isCurrent(_ token: UInt64) -> Bool { current() == token }

    @discardableResult
    func invalidate() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        epoch &+= 1
        return epoch
    }
}
