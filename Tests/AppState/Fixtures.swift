import Foundation
import SwiftUI

@MainActor
final class HelperClient {
    static let shared = HelperClient()
    enum Step: String { case allowlist, context, scan, start, stop }
    var connected = true
    var context: NetworkContext!
    var store: AppStore!
    var calls: [Step] = []
    var held: Set<Step> = []
    var failures: Set<Step> = []
    var emitActiveAfterStart = false
    private var waiting: [Step: [CheckedContinuation<Void, Never>]] = [:]

    func reset(store: AppStore, context: NetworkContext) {
        precondition(waiting.values.allSatisfy(\.isEmpty))
        self.store = store; self.context = context
        calls = []; held = []; failures = []; emitActiveAfterStart = false
        connected = true
    }
    func count(_ step: Step) -> Int { calls.filter { $0 == step }.count }
    func waitingCount(_ step: Step) -> Int { waiting[step]?.count ?? 0 }
    func release(_ step: Step) {
        precondition(waitingCount(step) > 0)
        waiting[step]!.removeFirst().resume()
    }
    private func perform(_ step: Step) async throws {
        calls.append(step)
        if held.contains(step) {
            await withCheckedContinuation { waiting[step, default: []].append($0) }
        }
        if failures.contains(step) {
            throw NSError(domain: "OfflineFixture", code: 1)
        }
    }
    func install() async throws {}
    func connect() {}
    func setAllowlist(_ entries: [AllowEntry]) async throws { try await perform(.allowlist) }
    func detectContext() async throws -> NetworkContext {
        try await perform(.context)
        return context
    }
    func scan(timeoutSeconds: Int) async throws -> [Device] {
        try await perform(.scan)
        return []
    }
    func startSpoof(session: CutSessionRequest, mode: BlockMode, ipv6: Bool) async throws {
        store.handle(event: .spoofStateChanged(targets: [], active: false))
        try await perform(.start)
        if emitActiveAfterStart {
            store.handle(event: .spoofStateChanged(targets: ["192.168.1.20"], active: true))
        }
    }
    func stopSpoof() async throws {
        try await perform(.stop)
        store.handle(event: .spoofStateChanged(targets: [], active: false))
    }
    func throughputSnapshot() async throws -> [String: UInt64] { [:] }
    func runSpeedTest() async throws -> SpeedSample { SpeedSample() }
}

@MainActor final class Notifier {
    static let shared = Notifier()
    func requestAuth() {}
    func seed(_ addresses: [String]) {}
}
@MainActor final class MDNSAppEnricher {
    func reset() {}
}
@MainActor final class WiFiClient {
    static let shared = WiFiClient()
    func currentSSIDAsync() async -> String? { "Owned" }
}
@MainActor final class LocationGate {
    static let shared = LocationGate()
    var onUnlock: (() -> Void)?
    func request() {}
}
extension Notification.Name {
    static let helperReconnected = Notification.Name("OfflineHelperReconnected")
}
