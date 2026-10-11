import Foundation
import os

// Local declarations shadow imported CoreWLAN types only in this test module.
final class CWWiFiClient {
    static var currentSSID: String? = "Owned"
    static var currentBSSID: String? = "02:00:00:00:02:01"
    static var requestedInterface: String?
    static func shared() -> CWWiFiClient { CWWiFiClient() }
    func interface(withName name: String) -> CWInterface? {
        Self.requestedInterface = name
        return CWInterface()
    }
}
final class CWInterface {
    func ssid() -> String? { CWWiFiClient.currentSSID }
    func bssid() -> String? { CWWiFiClient.currentBSSID }
}
enum Log {
    static let root = Logger(subsystem: "offline", category: "context")
}
enum Sysinfo {
    static var commands: [[String]] = []
    static var timeouts: [TimeInterval] = []
    static var summary = ""
    static var availablePrimary = true
    static func nativePrimary() -> (iface: String, gateway: String)? {
        availablePrimary ? ("fixture0", "192.168.1.1") : nil
    }
    static func nativeIfaceInfo(_ iface: String) -> (ipv4: String, cidrPrefix: Int, ipv6: [String], mac: String)? {
        ("192.168.1.10", 24, [], "02:00:00:00:00:10")
    }
    static func nativeDNSServers() -> [String] { [] }
    static func nativeArpLookup(_ ipv4: String) -> String? { "02:00:00:00:00:01" }
    static func cidr(ipv4: String, prefix: Int) -> String { "192.168.1.0/24" }
    static func runShell(_ command: [String], timeout: TimeInterval = 5) -> String {
        commands.append(command); timeouts.append(timeout); return summary
    }
    static func defaultInterface() -> String? { nil }
    static func ipv4(of iface: String) -> String? { nil }
    static func mac(of iface: String) -> String? { nil }
    static func defaultGateway() -> String? { nil }
    static func subnetCIDR(of iface: String) -> String? { nil }
    static func ipv6(of iface: String) -> [String] { [] }
    static func dnsServers() -> [String] { [] }
}
