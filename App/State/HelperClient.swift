import Foundation
import ServiceManagement
import Combine
import CryptoKit
import Security

/// Thin client around the privileged helper.
@MainActor
final class HelperClient: ObservableObject {

    static let shared = HelperClient()

    @Published var connected: Bool = false
    @Published var statusText: String = "disconnected"
    @Published var latestEvent: HelperEvent?

    private var connection: NSXPCConnection?
    private var receiverListener: NSXPCListener?
    private var reconnectAttempts: Int = 0
    private var reconnectTask: Task<Void, Never>?
    private var installTask: Task<Void, Error>?

    // MARK: install / connect

    func install() async throws {
        if let installTask { try await installTask.value; return }
        let operation = Task<Void, Error> { @MainActor in
            let binary = Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/LaunchDaemons/com.wifimancer.helper"
            )
            let digest = SHA256.hash(data: try Data(contentsOf: binary))
                .map { String(format: "%02x", $0) }.joined()
            let manualPlist = "/Library/LaunchDaemons/com.wifimancer.helper.plist"
            let manualBinary = "/Library/PrivilegedHelperTools/com.wifimancer.helper"
            if let data = FileManager.default.contents(atPath: manualPlist),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               plist["Label"] as? String == kHelperMachServiceName,
               plist["Program"] as? String == manualBinary {
                for path in [manualPlist, manualBinary, "/Library/PrivilegedHelperTools/com.wifimancer.client-requirement"] {
                    let attributes = try FileManager.default.attributesOfItem(atPath: path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                          let mode = attributes[.posixPermissions] as? NSNumber,
                          mode.intValue & 0o022 == 0 else {
                        throw HC.error("Manual helper files require a safe reinstall")
                    }
                }
                guard try Data(contentsOf: URL(fileURLWithPath: manualBinary)) == Data(contentsOf: binary) else {
                    throw HC.error("Manual helper needs updating with Scripts/install-helper.sh")
                }
                let pin = try String(contentsOfFile: "/Library/PrivilegedHelperTools/com.wifimancer.client-requirement",
                                     encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                var requirement: SecRequirement?
                var appCode: SecStaticCode?
                let flags = SecCSFlags(rawValue: 0)
                guard SecRequirementCreateWithString(pin as CFString, flags, &requirement) == errSecSuccess,
                      SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, flags, &appCode) == errSecSuccess,
                      let appCode, let requirement,
                      SecStaticCodeCheckValidity(appCode, flags, requirement) == errSecSuccess else {
                    throw HC.error("App identity changed; update with Scripts/install-helper.sh")
                }
                return
            }
            let key = "registeredHelperSHA256"
            let registeredDigest = UserDefaults.standard.string(forKey: key)
            let service = SMAppService.daemon(plistName: "com.wifimancer.helper.plist")
            if service.status == .requiresApproval,
               registeredDigest == nil || registeredDigest == digest {
                self.statusText = "helper approval required in System Settings"
                SMAppService.openSystemSettingsLoginItems()
                return
            }
            if service.status == .enabled,
               registeredDigest == digest { return }
            if service.status == .enabled || service.status == .requiresApproval {
                // The completion variant waits for teardown before re-registering
                // the changed binary against its current code requirement.
                try await service.unregister()
            }
            do { try service.register() }
            catch {
                guard service.status == .requiresApproval else { throw error }
                UserDefaults.standard.set(digest, forKey: key)
                self.statusText = "helper approval required in System Settings"
                SMAppService.openSystemSettingsLoginItems()
                return
            }
            UserDefaults.standard.set(digest, forKey: key)
            if service.status == .requiresApproval {
                self.statusText = "helper approval required in System Settings"
            }
        }
        installTask = operation
        defer { installTask = nil }
        do { try await operation.value }
        catch { statusText = "helper install: \(error.localizedDescription)"; throw error }
    }

    func connect() {
        guard connection == nil else { return }
        let conn = NSXPCConnection(machServiceName: kHelperMachServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: HelperEventReceiver.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connected = false
                self?.statusText = "invalidated"
                self?.connection = nil
                self?.scheduleReconnect()
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.connected = false
                self.statusText = "interrupted — reconnecting"
                // CRITICAL: tear down the dead connection. Without this,
                // scheduleReconnect → connect() short-circuits on
                // `guard connection == nil` and the reconnect loop wedges
                // until the user manually quits and relaunches the app —
                // exactly the "onboarding helper says reconnecting forever"
                // symptom.
                self.connection?.invalidate()
                self.connection = nil
                self.scheduleReconnect()
            }
        }
        conn.resume()
        self.connection = conn

        // Spin up an event receiver listener on our side.
        let receiver = EventReceiver { [weak self] event in
            Task { @MainActor in
                self?.latestEvent = event
                NotificationCenter.default.post(name: .helperEvent, object: event)
            }
        }
        let listener = NSXPCListener.anonymous()
        let recvDelegate = ReceiverListenerDelegate(receiver: receiver)
        listener.delegate = recvDelegate
        listener.resume()
        self.receiverListener = listener

        proxy()?.subscribeEvents(listener.endpoint) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                self.connected = ok
                self.statusText = ok ? "connected" : "subscribe failed"
                if ok {
                    let wasReconnect = self.reconnectAttempts > 0
                    self.reconnectAttempts = 0
                    // Tell the coordinator to re-push context/allowlist/scan
                    // on EVERY successful subscribe — initial connect AND
                    // every reconnect. Without this, a launchd respawn leaves
                    // the new helper with empty state and Cut silently
                    // targets nothing.
                    if wasReconnect {
                        NotificationCenter.default.post(name: .helperReconnected, object: nil)
                    }
                } else {
                    // subscribeEvents failed but the NSXPCConnection is still
                    // alive, so scheduleReconnect → connect() would short-circuit
                    // on `guard connection == nil` and the reconnect loop would
                    // wedge forever. Tear the connection down so the next
                    // connect() can rebuild from scratch — this is what kept
                    // the onboarding "Helper… reconnecting" status frozen until
                    // the user quit and relaunched the app.
                    self.connection?.invalidate()
                    self.connection = nil
                    self.scheduleReconnect()
                }
            }
        }

        // Hold delegate alive
        objc_setAssociatedObject(listener, "del", recvDelegate, .OBJC_ASSOCIATION_RETAIN)
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.invalidate()
        connection = nil
        receiverListener = nil
        connected = false
    }

    /// Backoff-reconnect: 1s, 2s, 4s, 8s, capped at 15s. Keeps trying until the
    /// helper LaunchDaemon comes back. Resets on a successful subscribe.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectAttempts += 1
        // Clamp the bit-shift exponent before converting — otherwise after ~63
        // failed attempts the Int(pow(2.0, n)) conversion traps with
        // "Double value cannot be converted to Int because the result would be
        // greater than Int.max" and the whole app crashes (a real bug we hit
        // when the helper wasn't auto-launching after install).
        let exp = min(max(reconnectAttempts - 1, 0), 4)   // 1s, 2s, 4s, 8s, 15s+
        let delay = min(15, 1 << exp)
        statusText = "reconnect in \(delay)s (#\(reconnectAttempts))"
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let self else { return }
            await MainActor.run { self.connect() }
        }
    }

    // MARK: typed proxies

    func proxy() -> HelperProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] err in
            Task { @MainActor in
                self?.statusText = "rpc error: \(err.localizedDescription)"
            }
        } as? HelperProtocol
    }

    // MARK: convenience wrappers

    /// Each request owns its XPC error handler and completes exactly once.
    private func request<Value: Sendable>(timeout: TimeInterval? = nil,
        _ call: (HelperProtocol, @escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let reply = HelperRPCReply(continuation)
            guard let connection,
                  let helper = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
                      reply.finish(.failure(error))
                      Task { @MainActor in self?.statusText = "rpc error: \(error.localizedDescription)" }
                  }) as? HelperProtocol else {
                reply.finish(.failure(HC.error("helper not connected")))
                return
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    reply.finish(.failure(HC.error("timeout")))
                }
            }
            call(helper) { result in reply.finish(result) }
        }
    }

    nonisolated private static func decoded<Value: Decodable & Sendable>(
        _ type: Value.Type, data: Data?, error: String?
    ) -> Result<Value, Error> {
        if let error { return .failure(HC.error(error)) }
        guard let data else { return .failure(HC.error("empty response")) }
        return Result { try JSONDecoder().decode(type, from: data) }
    }

    nonisolated private static func accepted(_ ok: Bool, error: String?) -> Result<Void, Error> {
        ok ? .success(()) : .failure(HC.error(error ?? "Request rejected"))
    }

    func detectContext() async throws -> NetworkContext {
        try await request { helper, finish in
            helper.detectContext { finish(Self.decoded(NetworkContext.self, data: $0, error: $1)) }
        }
    }

    func scan(timeoutSeconds: Int = 2) async throws -> [Device] {
        try await request { helper, finish in
            helper.scan(timeoutSeconds: timeoutSeconds) {
                finish(Self.decoded([Device].self, data: $0, error: $1))
            }
        }
    }

    func setAllowlist(_ entries: [AllowEntry]) async throws {
        let data = try JSONEncoder().encode(entries)
        try await request { helper, finish in
            helper.setAllowlist(data) { finish(Self.accepted($0, error: $1)) }
        }
    }

    /// Legacy explicit targets remain helper-validated against current discovery.
    func startSpoof(targets: [SpoofTarget], mode: BlockMode, ipv6: Bool) async throws {
        try await startSpoof(data: JSONEncoder().encode(targets), mode: mode, ipv6: ipv6)
    }

    func startSpoof(session: CutSessionRequest, mode: BlockMode, ipv6: Bool) async throws {
        try await startSpoof(data: JSONEncoder().encode(session), mode: mode, ipv6: ipv6)
    }

    private func startSpoof(data: Data, mode: BlockMode, ipv6: Bool) async throws {
        try await request { helper, finish in
            helper.startSpoof(targetsData: data, blockModeRaw: mode.rawValue,
                              ipv6Enabled: ipv6) { finish(Self.accepted($0, error: $1)) }
        }
    }

    func stopSpoof() async throws {
        try await request { helper, finish in
            helper.stopSpoof { finish(Self.accepted($0, error: $1)) }
        }
    }

    func runSpeedTest() async throws -> SpeedSample {
        try await request { helper, finish in
            helper.runSpeedTest { finish(Self.decoded(SpeedSample.self, data: $0, error: $1)) }
        }
    }

    func scanWiFi() async throws -> [WiFiNetwork] {
        try await request { helper, finish in
            helper.scanWiFi { finish(Self.decoded([WiFiNetwork].self, data: $0, error: $1)) }
        }
    }

    func savedWiFiSSIDs() async throws -> [String] {
        try await request { helper, finish in
            helper.savedWiFiSSIDs { finish(Self.decoded([String].self, data: $0, error: $1)) }
        }
    }

    func joinWiFi(ssid: String, password: String?) async throws {
        try await request { helper, finish in
            helper.joinWiFi(ssid: ssid, password: password) { finish(Self.accepted($0, error: $1)) }
        }
    }

    func fetchSystemWiFiPassword(ssid: String) async -> String? {
        try? await request { helper, finish in
            helper.fetchSystemWiFiPassword(ssid: ssid) { password, error in
                if let error { finish(.failure(HC.error(error))) }
                else { finish(.success(password)) }
            }
        }
    }

    func throughputSnapshot() async throws -> [String: UInt64] {
        try await request(timeout: 2) { helper, finish in
            helper.throughputSnapshot { finish(Self.decoded([String: UInt64].self, data: $0, error: $1)) }
        }
    }
}

/// A reply and an XPC error may arrive concurrently. Retire the continuation
/// under the lock, then resume outside it; late callbacks become no-ops.
private final class HelperRPCReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

extension Notification.Name {
    static let helperEvent = Notification.Name("WMHelperEvent")
    static let helperReconnected = Notification.Name("WMHelperReconnected")
}

enum HC { static func error(_ s: String) -> NSError {
    NSError(domain: "HelperClient", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
} }

// MARK: event receiver glue

final class EventReceiver: NSObject, HelperEventReceiver {
    let onEvent: (HelperEvent) -> Void
    init(onEvent: @escaping (HelperEvent) -> Void) { self.onEvent = onEvent }
    func receive(eventData: Data) {
        guard let evt = try? JSONDecoder().decode(HelperEvent.self, from: eventData) else { return }
        onEvent(evt)
    }
}

final class ReceiverListenerDelegate: NSObject, NSXPCListenerDelegate {
    let receiver: EventReceiver
    init(receiver: EventReceiver) { self.receiver = receiver }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: HelperEventReceiver.self)
        conn.exportedObject = receiver
        conn.resume()
        return true
    }
}
