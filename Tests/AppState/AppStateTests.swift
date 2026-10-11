private extension AppCoordinator {
    func prepareForTest() async -> Bool { await prepareHelperSession() }
    func reconnectForTest() async { await rehydrateAfterReconnect() }
    func cancelPollingForTest() { scanTask?.cancel(); pollTask?.cancel() }
}

@main
private struct AppStateTests {
    @MainActor static let context = NetworkContext(interface: "offline", selfIPv4: "192.168.1.10",
        selfIPv6: [], selfMAC: MACAddress("02:00:00:00:00:10")!, gatewayIPv4: "192.168.1.1",
        gatewayMAC: MACAddress("02:00:00:00:00:01")!, subnetCIDR: "192.168.1.0/24",
        ssid: "Owned", bssid: "02:11:22:33:44:55", ipv6Active: false, dnsServers: [])

    @MainActor static func fixture() -> (AppStore, AppCoordinator, HelperClient) {
        let store = AppStore()
        store.context = context
        store.helperSessionReady = true
        let helper = HelperClient.shared
        helper.reset(store: store, context: context)
        return (store, AppCoordinator(store: store), helper)
    }

    @MainActor static func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Offline test did not reach its expected suspension")
    }

    @MainActor static func main() async {
        // Cancel at each awaited preflight boundary; none may issue a late start.
        for step in [HelperClient.Step.allowlist, .context, .scan] {
            let (store, coordinator, helper) = fixture()
            helper.held = [step]
            let starting = Task { await coordinator.toggleBlocking() }
            await waitUntil { helper.waitingCount(step) == 1 }
            precondition(store.startingBlocking && !store.blocking)
            precondition(store.blockedAt == nil && store.armedTargetIPv4s.isEmpty)
            store.handle(event: .spoofStateChanged(targets: [], active: false))
            precondition(store.startingBlocking, "The helper's startup idle event must preserve pending intent")
            await coordinator.toggleBlocking()
            precondition(helper.count(.stop) == 1 && !store.blockingRequested)
            helper.release(step)
            await starting.value
            precondition(helper.count(.start) == 0 && !store.blocking)
            store.handle(event: .spoofStateChanged(targets: ["192.168.1.20"], active: true))
            precondition(!store.blocking && store.armedTargetIPv4s.isEmpty,
                         "A late active event must not undo cancellation")
        }

        // Cancellation remains available after the helper start RPC is sent.
        do {
            let (store, coordinator, helper) = fixture()
            helper.held = [.start]
            helper.emitActiveAfterStart = true
            let starting = Task { await coordinator.toggleBlocking() }
            await waitUntil { helper.waitingCount(.start) == 1 }
            precondition(store.startingBlocking && !store.blocking)
            await coordinator.toggleBlocking()
            helper.release(.start)
            await starting.value
            precondition(helper.count(.stop) == 1 && !store.blocking && !store.startingBlocking)
            store.handle(event: .cutStatus(.engaged))
            precondition(store.cutStatus == .idle)
        }

        // A positive helper event, not the click, publishes Armed and its targets.
        do {
            let (store, coordinator, helper) = fixture()
            helper.held = [.start, .stop]
            let starting = Task { await coordinator.toggleBlocking() }
            await waitUntil { helper.waitingCount(.start) == 1 }
            store.handle(event: .spoofStateChanged(targets: ["192.168.1.20"], active: true))
            precondition(store.blocking && !store.startingBlocking && store.blockedAt != nil)
            precondition(store.armedTargetIPv4s == ["192.168.1.20"])
            helper.release(.start)
            await starting.value
            let stopping = Task { await coordinator.toggleBlocking() }
            await waitUntil { helper.waitingCount(.stop) == 1 }
            precondition(store.stoppingBlocking && store.blocking,
                         "Stop is not confirmed until the helper ends its session")
            store.cutStatus = .engaged
            store.handle(event: .spoofStateChanged(targets: [], active: false))
            precondition(store.cutStatus == .idle, "An ended session must not retain an active status message")
            helper.release(.stop)
            await stopping.value
            precondition(!store.blocking && store.blockedAt == nil)
        }

        // A failed start clears pending intent; a failed stop retains a confirmed
        // active session and allows retry instead of falsely publishing Idle.
        do {
            let (store, coordinator, helper) = fixture()
            helper.failures = [.context]
            await coordinator.toggleBlocking()
            precondition(!store.blockingRequested && !store.blocking && store.toastMessage != nil)
            helper.failures = []
            helper.emitActiveAfterStart = true
            await coordinator.toggleBlocking()
            helper.failures = [.stop]
            await coordinator.toggleBlocking()
            precondition(store.blocking && store.blockingRequested && !store.stoppingBlocking)
            helper.failures = []
            await coordinator.toggleBlocking()
            precondition(!store.blocking && !store.blockingRequested)
        }

        // Reconnect gates Engage until any old helper session has stopped.
        // Only the newest preparation may publish readiness.
        do {
            let (store, coordinator, helper) = fixture()
            store.blockingRequested = true
            store.handle(event: .spoofStateChanged(targets: ["192.168.1.20"], active: true))
            helper.held = [.stop]
            let older = Task { await coordinator.prepareForTest() }
            await waitUntil { helper.waitingCount(.stop) == 1 }
            precondition(!store.helperSessionReady && store.blocking)
            await coordinator.toggleBlocking()
            precondition(helper.count(.start) == 0)
            let newer = Task { await coordinator.prepareForTest() }
            await waitUntil { helper.waitingCount(.stop) == 2 }
            helper.release(.stop)
            let olderReady = await older.value
            precondition(!olderReady)
            precondition(!store.helperSessionReady)
            helper.release(.stop)
            let newerReady = await newer.value
            precondition(newerReady)
            precondition(store.helperSessionReady && !store.blocking)
        }

        // Boot still starts continuous discovery when reconnect supersedes its
        // preparation. A single reconnect sweep must not be the only future scan.
        do {
            let (store, coordinator, helper) = fixture()
            helper.held = [.stop]
            let boot = Task { await coordinator.boot() }
            await waitUntil { helper.waitingCount(.stop) == 1 }
            let reconnect = Task { await coordinator.reconnectForTest() }
            await waitUntil { helper.waitingCount(.stop) == 2 }
            helper.release(.stop)
            await boot.value
            await waitUntil { helper.count(.scan) >= 2 }
            precondition(!store.helperSessionReady)
            helper.release(.stop)
            await reconnect.value
            precondition(store.helperSessionReady)
            coordinator.cancelPollingForTest()
        }

        // Failed preparation keeps Engage gated; it never assumes an old session
        // ended merely because the GUI process is new.
        do {
            let (store, coordinator, helper) = fixture()
            helper.failures = [.stop]
            let ready = await coordinator.prepareForTest()
            precondition(!ready)
            precondition(!store.helperSessionReady)
            await coordinator.toggleBlocking()
            precondition(helper.count(.start) == 0)
        }
        print("PASS: app start confirmation, cancellation, stop failure, reconnect and boot ordering")
    }
}
