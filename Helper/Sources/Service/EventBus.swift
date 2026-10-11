import Foundation

/// Forwards `HelperEvent` payloads to registered XPC clients.
final class EventBus {

    static let shared = EventBus()

    private let lock = NSLock()
    private var receivers: [HelperEventReceiver] = []

    func register(_ receiver: HelperEventReceiver) {
        lock.lock(); defer { lock.unlock() }
        receivers.append(receiver)
    }

    func emit(_ event: HelperEvent) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        let snapshot: [HelperEventReceiver]
        lock.lock(); snapshot = receivers; lock.unlock()
        for r in snapshot { r.receive(eventData: data) }
    }

    func log(_ level: HelperEvent.LogLevel, _ message: String) {
        emit(.log(level: level, message: message))
    }
}
