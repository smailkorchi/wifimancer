import Foundation

/// The controller source is compiled unchanged; only OS detection, discovery,
/// display enrichment and unused legacy layers are replaced with fixtures.
private final class FixtureContext: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NetworkContext?
    private var reads = 0
    func set(_ context: NetworkContext?) { lock.lock(); value = context; lock.unlock() }
    func get() -> NetworkContext? { lock.lock(); defer { lock.unlock() }; reads += 1; return value }
    func readCount() -> Int { lock.lock(); defer { lock.unlock() }; return reads }
}

/// Occupies the real engine actor until the controller has changed its policy.
/// All pcap calls still resolve to the offline fixtures.
private final class HeldEngineFixture: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    func hold() {
        condition.lock(); defer { condition.unlock() }
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
    }
    func isHolding() -> Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
private enum ContextDetector {
    static let fixture = FixtureContext()
    static func detect() -> NetworkContext? { fixture.get() }
}
private struct MDNSRecord: Sendable { let modelIdentifier: String?; let prettyName: String? }
private final class MDNSEnrichmentCache: Sendable {
    func snapshot() -> [String: MDNSRecord] { [:] }
}
private final class EventBus: @unchecked Sendable {
    static let shared = EventBus()
    private let lock = NSLock()
    private var events: [HelperEvent] = []
    func emit(_ event: HelperEvent) { lock.lock(); events.append(event); lock.unlock() }
    func snapshot() -> [HelperEvent] { lock.lock(); defer { lock.unlock() }; return events }
    func reset() { lock.lock(); events.removeAll(); lock.unlock() }
}
private actor CutLayers { func stop() {} }
private actor DHCPAttacker { func stop() {} }
private actor IPClaimer { func clearAll() {} }
private struct ARPScanner: Sendable {
    struct Result: Sendable { let ip: String; let mac: MACAddress }
    let context: NetworkContext
    func scan(durationMs: Int) async throws -> [Result] { await ScannerFixture.shared.scan() }
}
private actor ScannerFixture {
    static let shared = ScannerFixture()
    private var results: [ARPScanner.Result] = []
    private var held = false
    private var waiter: CheckedContinuation<[ARPScanner.Result], Never>?
    func configure(_ observations: [ARPScanner.Result], held: Bool = false) {
        results = observations; self.held = held
    }
    func scan() async -> [ARPScanner.Result] {
        if held { return await withCheckedContinuation { waiter = $0 } }
        return results
    }
    func isWaiting() -> Bool { waiter != nil }
    func release() { held = false; waiter?.resume(returning: results); waiter = nil }
}
