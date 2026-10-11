import Foundation

public let kHelperMachServiceName = "com.wifimancer.helper"

@objc public protocol HelperProtocol {
    /// Sanity check.
    func ping(reply: @escaping (String) -> Void)

    /// Helper version (semver string).
    func version(reply: @escaping (String) -> Void)

    /// Detect current Wi-Fi context (interface, IPs, gateway, SSID).
    /// Returns JSON-encoded `NetworkContext`.
    func detectContext(reply: @escaping (Data?, String?) -> Void)

    /// Run an ARP scan over the current subnet.
    /// Returns JSON-encoded `[Device]`.
    func scan(timeoutSeconds: Int, reply: @escaping (Data?, String?) -> Void)

    /// Update allowlist (JSON-encoded `[AllowEntry]`).
    func setAllowlist(_ data: Data, reply: @escaping (Bool, String?) -> Void)

    /// Apply targets (JSON-encoded array of MAC strings) and start spoofing if any.
    func startSpoof(targetsData: Data,
                    blockModeRaw: String,
                    ipv6Enabled: Bool,
                    reply: @escaping (Bool, String?) -> Void)

    func stopSpoof(reply: @escaping (Bool, String?) -> Void)

    /// Per-MAC live throughput, JSON-encoded `[String: Double]` (mac → bps).
    func throughputSnapshot(reply: @escaping (Data?, String?) -> Void)

    /// Run a speed test against the configured target server.
    /// Returns JSON-encoded `SpeedSample`.
    func runSpeedTest(reply: @escaping (Data?, String?) -> Void)

    /// Stream events back to the app via the registered listener endpoint.
    func subscribeEvents(_ endpoint: NSXPCListenerEndpoint,
                         reply: @escaping (Bool) -> Void)

    /// Resolve hostnames via mDNS for a list of IPs (JSON: [String]).
    /// Returns JSON: [String: String] ip → hostname.
    func resolveHostnames(ipsData: Data, reply: @escaping (Data?, String?) -> Void)

    /// Trigger native Wi-Fi join. Password optional.
    func joinWiFi(ssid: String, password: String?, reply: @escaping (Bool, String?) -> Void)

    /// Disconnect current Wi-Fi.
    func leaveWiFi(reply: @escaping (Bool, String?) -> Void)

    /// Scan available Wi-Fi networks. Returns JSON [WiFiNetwork].
    func scanWiFi(reply: @escaping (Data?, String?) -> Void)

    /// SSIDs the user has saved in the system Wi-Fi configuration (auto-join list).
    /// JSON: [String].
    func savedWiFiSSIDs(reply: @escaping (Data?, String?) -> Void)

    /// Read a Wi-Fi password from the macOS system keychain for the given
    /// SSID. Runs `security find-generic-password -wa <ssid>` from the
    /// privileged helper context — which bypasses the per-app keychain ACL
    /// prompt that ad-hoc-signed apps would otherwise hit. Returns nil if
    /// no entry exists.
    func fetchSystemWiFiPassword(ssid: String,
                                 reply: @escaping (String?, String?) -> Void)

    /// Pause spoofing for N seconds (returns automatically).
    func pauseSpoof(seconds: Int, reply: @escaping (Bool, String?) -> Void)

    /// Shutdown helper cleanly.
    func quit(reply: @escaping (Bool) -> Void)
}

@objc public protocol HelperEventReceiver {
    /// Receives JSON-encoded `HelperEvent`.
    func receive(eventData: Data)
}
