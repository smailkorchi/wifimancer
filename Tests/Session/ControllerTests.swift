// Extensions access private state only in this generated test compilation unit.
private extension SessionCutEngines {
    func pauseForTest() async { await arp.pause(seconds: 60) }
    func holdForTest(_ fixture: HeldEngineFixture) { fixture.hold() }
}
private extension NetworkCutController {
    func pauseForTest() async { await engines?.pauseForTest() }
    func settleForTest() async { await engineTail?.value }
    func activeForTest() -> Bool { state.request != nil }
    func holdEnginesForTest(_ fixture: HeldEngineFixture) -> Task<Void, Never> {
        monitorTask?.cancel(); monitorTask = nil
        let engines = self.engines!
        return Task { await engines.holdForTest(fixture) }
    }
    func queueApplyForTest() -> Task<String?, Never> { scheduleApply() }
    func acceptScanDuringApplyForTest(_ observations: [ARPScanner.Result]) {
        precondition(state.acceptScan(observations.map { Device(mac: $0.mac, ipv4: $0.ip) },
                                      generation: state.generation))
    }
    func allowlistedForTest(_ mac: MACAddress) -> Bool { state.allowlistedMACs.contains(mac) }
}

@main
private struct ControllerTests {
    static let ours = MACAddress("02:00:00:00:00:10")!
    static let gateway = MACAddress("02:00:00:00:00:01")!
    static let peer = MACAddress("02:00:00:00:00:20")!
    static let trusted = MACAddress("02:00:00:00:00:30")!
    static let context = NetworkContext(interface: "offline", selfIPv4: "192.168.1.10", selfIPv6: [],
        selfMAC: ours, gatewayIPv4: "192.168.1.1", gatewayMAC: gateway,
        subnetCIDR: "192.168.1.0/24", ssid: "Owned", bssid: "02:11:22:33:44:55",
        ipv6Active: false, dnsServers: [])
    static let observation = ARPScanner.Result(ip: "192.168.1.20", mac: peer)
    static func newController(_ gate: SessionLifecycleGate) -> NetworkCutController {
        NetworkCutController(mdnsCache: MDNSEnrichmentCache(), lifecycleGate: gate) { _ in }
    }
    static func settleAndPause(_ controller: NetworkCutController) async throws {
        try await Task.sleep(nanoseconds: 25_000_000)
        await controller.pauseForTest()
        await controller.settleForTest()
    }
    static func frameMAC(_ index: Int32, _ offset: Int32) -> [UInt8] {
        (0..<6).map { UInt8(offline_frame_byte(index, offset + Int32($0))) }
    }
    static func latestState() -> (Bool, [String])? {
        EventBus.shared.snapshot().compactMap { event in
            if case .spoofStateChanged(let targets, let active) = event { return (active, targets) }
            return nil
        }.last
    }
    static func waitForTest(_ predicate: @Sendable () async -> Bool) async {
        let deadline = Date.now.addingTimeInterval(2)
        while await !predicate() {
            precondition(Date.now < deadline, "Timed out waiting for an offline race fixture")
            await Task.yield()
        }
    }
    static func main() async throws {
        // Unknown gateway identity keeps policy armed without opening engines.
        offline_reset(); EventBus.shared.reset()
        var unknown = context; unknown.gatewayMAC = nil
        ContextDetector.fixture.set(unknown)
        let gate = SessionLifecycleGate()
        let controller = newController(gate)
        _ = try await controller.detectContext()
        await ScannerFixture.shared.configure([observation])
        _ = try await controller.scan(timeoutSeconds: 1)
        try await controller.start(data: JSONEncoder().encode(CutSessionRequest.currentNetwork(unknown)),
                                   blockModeRaw: "instant", epoch: gate.invalidate())
        precondition(latestState()?.0 == true && latestState()?.1.isEmpty == true)
        precondition(offline_open_count() == 0 && offline_frame_count() == 0)
        ContextDetector.fixture.set(context)
        _ = try await controller.scan(timeoutSeconds: 1)
        try await settleAndPause(controller)
        precondition(latestState()?.1 == [observation.ip] && offline_open_count() == 2)
        await ScannerFixture.shared.configure([.init(ip: observation.ip, mac: ours)])
        _ = try await controller.scan(timeoutSeconds: 1)
        precondition(latestState()?.1 == [observation.ip], "Outgoing poison cannot replace discovery ownership")
        await ScannerFixture.shared.configure([observation])
        var redacted = context; redacted.ssid = nil; redacted.bssid = "<redacted>"; redacted.gatewayMAC = nil
        ContextDetector.fixture.set(redacted)
        let framesBeforeMetadata = offline_frame_count()
        try await controller.setAllowlist([])
        precondition(offline_frame_count() == framesBeforeMetadata, "Metadata updates must not silently stop/restart engines")
        precondition(latestState()?.0 == true && latestState()?.1 == [observation.ip])
        ContextDetector.fixture.set(context)
        let beforeStop = offline_frame_count()
        await controller.stop(epoch: gate.invalidate())
        precondition(offline_frame_count() == beforeStop + 10 && offline_open_count() == offline_close_count())

        // Actual controller + actors: changed AP on the same interface and /24
        // must close engines without writing any old-network repair frames.
        offline_reset(); EventBus.shared.reset()
        let apGate = SessionLifecycleGate(), apController = newController(apGate)
        ContextDetector.fixture.set(context)
        _ = try await apController.detectContext()
        _ = try await apController.scan(timeoutSeconds: 1)
        try await apController.start(data: JSONEncoder().encode(CutSessionRequest.currentNetwork(context)),
                                     blockModeRaw: "instant", epoch: apGate.invalidate())
        try await settleAndPause(apController)
        var nextAP = context; nextAP.bssid = "02:11:22:33:44:66"
        ContextDetector.fixture.set(nextAP)
        let beforeAPChange = offline_frame_count()
        _ = try await apController.detectContext()
        await apController.settleForTest()
        precondition(offline_frame_count() == beforeAPChange, "Changed AP gets zero restoration frames")
        precondition(latestState()?.0 == false && offline_open_count() == offline_close_count())
        await apController.stop(epoch: apGate.invalidate())

        // A trusted new owner of an old target IP gets repairs for its own
        // current binding, never the old cut MAC.
        offline_reset(); EventBus.shared.reset()
        let trustGate = SessionLifecycleGate(), trustController = newController(trustGate)
        ContextDetector.fixture.set(context)
        await ScannerFixture.shared.configure([observation])
        _ = try await trustController.detectContext()
        _ = try await trustController.scan(timeoutSeconds: 1)
        try await trustController.setAllowlist([trusted])
        try await trustController.start(data: JSONEncoder().encode(CutSessionRequest.currentNetwork(context)),
                                       blockModeRaw: "instant", epoch: trustGate.invalidate())
        try await settleAndPause(trustController)
        let beforeReassignment = offline_frame_count()
        await ScannerFixture.shared.configure([.init(ip: observation.ip, mac: trusted)])
        _ = try await trustController.scan(timeoutSeconds: 1)
        precondition(offline_frame_count() == beforeReassignment + 10)
        for frame in beforeReassignment..<offline_frame_count() {
            let sender = frameMAC(frame, 22)
            precondition(sender == gateway.bytes || sender == trusted.bytes, "Never restore stale cut ownership")
        }
        precondition(latestState()?.0 == true && latestState()?.1.isEmpty == true)
        await trustController.stop(epoch: trustGate.invalidate())
        precondition(offline_frame_count() == beforeReassignment + 10)

        // Hold the real engine actor after the controller snapshots its target
        // set. A superseded apply must reconcile again before reporting success,
        // even when no subsequent job is available to repair its publication.
        offline_reset(); EventBus.shared.reset()
        let raceGate = SessionLifecycleGate(), raceController = newController(raceGate)
        ContextDetector.fixture.set(context)
        await ScannerFixture.shared.configure([observation])
        _ = try await raceController.scan(timeoutSeconds: 1)
        try await raceController.start(data: JSONEncoder().encode(CutSessionRequest.currentNetwork(context)),
                                      blockModeRaw: "instant", epoch: raceGate.invalidate())
        try await settleAndPause(raceController)
        let heldDiscovery = HeldEngineFixture()
        let holdingDiscovery = await raceController.holdEnginesForTest(heldDiscovery)
        await waitForTest { heldDiscovery.isHolding() }
        EventBus.shared.reset()
        let readsBeforeDiscovery = ContextDetector.fixture.readCount()
        let discoveryApply = await raceController.queueApplyForTest()
        await waitForTest { ContextDetector.fixture.readCount() > readsBeforeDiscovery }
        let newcomer = ARPScanner.Result(ip: "192.168.1.30", mac: trusted)
        await raceController.acceptScanDuringApplyForTest([newcomer])
        heldDiscovery.release()
        await holdingDiscovery.value
        let discoveryError = await discoveryApply.value
        precondition(discoveryError == nil)
        precondition(latestState()?.1 == [observation.ip, newcomer.ip],
                     "A superseded apply must publish the current accepted targets before success")
        precondition(!EventBus.shared.snapshot().contains {
            if case .spoofStateChanged(let targets, true) = $0 { return targets == [observation.ip] }
            return false
        }, "Do not publish a target set superseded by discovery")

        // A trust change queues another real reconciliation while an old apply
        // is suspended. Neither job may publish the newly trusted peer as cut.
        let heldTrust = HeldEngineFixture()
        let holdingTrust = await raceController.holdEnginesForTest(heldTrust)
        await waitForTest { heldTrust.isHolding() }
        EventBus.shared.reset()
        let readsBeforeTrust = ContextDetector.fixture.readCount()
        let trustApply = await raceController.queueApplyForTest()
        await waitForTest { ContextDetector.fixture.readCount() > readsBeforeTrust }
        let trustUpdate = Task { try await raceController.setAllowlist([peer, trusted]) }
        await waitForTest { await raceController.allowlistedForTest(peer) }
        heldTrust.release()
        await holdingTrust.value
        let trustError = await trustApply.value
        precondition(trustError == nil)
        try await trustUpdate.value
        await raceController.settleForTest()
        precondition(latestState()?.0 == true && latestState()?.1.isEmpty == true)
        precondition(!EventBus.shared.snapshot().contains {
            if case .spoofStateChanged(let targets, true) = $0 { return !targets.isEmpty }
            return false
        }, "A concurrent trust update must never republish protected targets")
        await raceController.stop(epoch: raceGate.invalidate())
        precondition(offline_open_count() == offline_close_count())

        // Simulate task scheduling that delivers a stale stop after a newer
        // start. Entry-issued command epochs make the newest command win.
        offline_reset(); EventBus.shared.reset()
        let orderGate = SessionLifecycleGate(), orderController = newController(orderGate)
        ContextDetector.fixture.set(context)
        await ScannerFixture.shared.configure([observation])
        _ = try await orderController.detectContext()
        _ = try await orderController.scan(timeoutSeconds: 1)
        let staleStart = orderGate.invalidate()
        let staleStop = orderGate.invalidate()
        let newestStart = orderGate.invalidate()
        let requestData = try JSONEncoder().encode(CutSessionRequest.currentNetwork(context))
        try await orderController.start(data: requestData, blockModeRaw: "instant", epoch: newestStart)
        try await settleAndPause(orderController)
        await orderController.stop(epoch: staleStop)
        let activeAfterStaleStop = await orderController.activeForTest()
        precondition(activeAfterStaleStop && latestState()?.0 == true)
        do {
            try await orderController.start(data: requestData, blockModeRaw: "instant", epoch: staleStart)
            preconditionFailure("Old start delivered late must fail")
        } catch {}
        precondition(latestState()?.0 == true)
        // A scan completing after an explicit stop cannot re-arm the session.
        await ScannerFixture.shared.configure([observation], held: true)
        let lateScan = Task { try await orderController.scan(timeoutSeconds: 1) }
        while await !ScannerFixture.shared.isWaiting() { await Task.yield() }
        await orderController.stop(epoch: orderGate.invalidate())
        let beforeLateScan = offline_frame_count()
        await ScannerFixture.shared.release()
        do { _ = try await lateScan.value; preconditionFailure("Late scan accepted") } catch {}
        precondition(latestState()?.0 == false && offline_frame_count() == beforeLateScan)
        precondition(offline_open_count() == offline_close_count() && offline_broadcast_count() == 0)

        // Opening the responder can fail after the spoofer has started.
        // That partial start must be cleaned up and never reported armed.
        offline_reset(); EventBus.shared.reset()
        let partialGate = SessionLifecycleGate(), partialController = newController(partialGate)
        await ScannerFixture.shared.configure([observation])
        _ = try await partialController.detectContext()
        _ = try await partialController.scan(timeoutSeconds: 1)
        offline_set_nonblock_failure(1)
        do {
            try await partialController.start(data: requestData, blockModeRaw: "instant", epoch: partialGate.invalidate())
            preconditionFailure("Partial packet-engine failure claimed success")
        } catch {}
        await partialController.settleForTest()
        precondition(latestState()?.0 == false && offline_open_count() == offline_close_count())
        offline_set_nonblock_failure(0)

        // A fatal capture error after engagement closes both real engines,
        // clears accepted target status, and emits the generation-bound error.
        offline_reset(); EventBus.shared.reset()
        let faultGate = SessionLifecycleGate(), faultController = newController(faultGate)
        _ = try await faultController.detectContext()
        _ = try await faultController.scan(timeoutSeconds: 1)
        try await faultController.start(data: requestData, blockModeRaw: "instant", epoch: faultGate.invalidate())
        try await settleAndPause(faultController)
        offline_set_read_failure(1)
        for _ in 0..<100 {
            if latestState()?.0 == false && offline_open_count() == offline_close_count() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        precondition(latestState()?.0 == false && offline_open_count() == offline_close_count())
        precondition(EventBus.shared.snapshot().contains { if case .error = $0 { return true }; return false })
        offline_set_read_failure(0)
        await faultController.stop(epoch: faultGate.invalidate())
        precondition(offline_broadcast_count() == 0)
        print("Controller integration passed: real packet actors, metadata learning, no cross-LAN repairs, trusted reassignment, concurrent target publication, command ordering, late scans, partial start cleanup, and fatal capture errors")
    }
}
