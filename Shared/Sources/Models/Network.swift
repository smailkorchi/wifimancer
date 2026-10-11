import Foundation

public enum WiFiSecurity: String, Codable, Sendable, CaseIterable {
    case open, wep, wpaPersonal, wpa2Personal, wpa3Personal, wpaEnterprise, unknown

    public var label: String {
        switch self {
        case .open: "Open"
        case .wep: "WEP"
        case .wpaPersonal: "WPA"
        case .wpa2Personal: "WPA2"
        case .wpa3Personal: "WPA3"
        case .wpaEnterprise: "Enterprise"
        case .unknown: "Unknown"
        }
    }

    public var requiresPassword: Bool { self != .open }
}

public struct WiFiNetwork: Identifiable, Hashable, Codable, Sendable {
    /// Combine BSSID + SSID + channel so duplicate-SSID rows (mesh, multi-AP)
    /// don't collapse in SwiftUI's ForEach. BSSID alone would be enough but
    /// it can be nil when CoreWLAN strips it.
    public var id: String { "\(bssid ?? "?")|\(ssid)|\(channel)" }
    public var ssid: String
    public var bssid: String?
    public var rssi: Int        // dBm (negative)
    public var security: WiFiSecurity
    public var channel: Int
    public var band: String     // "2.4 GHz" / "5 GHz" / "6 GHz"
    public var isCurrent: Bool
    public var isKnown: Bool    // saved in keychain

    public init(ssid: String, bssid: String? = nil, rssi: Int = -100,
                security: WiFiSecurity = .unknown, channel: Int = 0, band: String = "",
                isCurrent: Bool = false, isKnown: Bool = false) {
        self.ssid = ssid; self.bssid = bssid; self.rssi = rssi
        self.security = security; self.channel = channel; self.band = band
        self.isCurrent = isCurrent; self.isKnown = isKnown
    }

    /// rssi → 0..4 bar level
    public var bars: Int {
        switch rssi {
        case ..<(-90): 0
        case (-90)..<(-75): 1
        case (-75)..<(-65): 2
        case (-65)..<(-55): 3
        default: 4
        }
    }
}

public struct NetworkContext: Codable, Sendable {
    public var interface: String         // e.g. "en0"
    public var selfIPv4: String
    public var selfIPv6: [String]
    public var selfMAC: MACAddress
    public var gatewayIPv4: String
    public var gatewayMAC: MACAddress?
    public var subnetCIDR: String        // e.g. "192.168.1.0/24"
    public var ssid: String?
    public var bssid: String?
    public var ipv6Active: Bool          // any non-link-local v6 traffic seen
    public var dnsServers: [String]

    public init(interface: String, selfIPv4: String, selfIPv6: [String], selfMAC: MACAddress,
                gatewayIPv4: String, gatewayMAC: MACAddress?, subnetCIDR: String,
                ssid: String?, bssid: String?, ipv6Active: Bool, dnsServers: [String]) {
        self.interface = interface; self.selfIPv4 = selfIPv4; self.selfIPv6 = selfIPv6
        self.selfMAC = selfMAC; self.gatewayIPv4 = gatewayIPv4; self.gatewayMAC = gatewayMAC
        self.subnetCIDR = subnetCIDR; self.ssid = ssid; self.bssid = bssid
        self.ipv6Active = ipv6Active; self.dnsServers = dnsServers
    }
}
