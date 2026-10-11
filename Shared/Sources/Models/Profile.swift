import Foundation

public struct AllowEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String { mac.description }
    public var mac: MACAddress
    public var nickname: String?
    public var addedAt: Date
    public init(mac: MACAddress, nickname: String? = nil, addedAt: Date = .now) {
        self.mac = mac; self.nickname = nickname; self.addedAt = addedAt
    }
}

public struct Schedule: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var weekdays: Set<Int>      // 1..7 (Mon..Sun)
    public var startMinute: Int        // minutes since midnight
    public var endMinute: Int

    public init(enabled: Bool = false, weekdays: Set<Int> = [1,2,3,4,5],
                startMinute: Int = 9 * 60, endMinute: Int = 18 * 60) {
        self.enabled = enabled; self.weekdays = weekdays
        self.startMinute = startMinute; self.endMinute = endMinute
    }
}

public enum BlockMode: String, Codable, Sendable, CaseIterable {
    case instant       // hard cut
    case stealth       // gradual ramp 10→100% over 60s
    case stealthSlow   // 10→100% over 5 min

    public var label: String {
        switch self {
        case .instant: "Instant"
        case .stealth: "Stealth (60s)"
        case .stealthSlow: "Stealth (5m)"
        }
    }
}

public struct NetworkProfile: Codable, Hashable, Sendable, Identifiable {
    public var id: String { ssid }
    public var ssid: String
    public var allowlist: [AllowEntry]
    public var schedule: Schedule
    public var blockMode: BlockMode
    public var ipv6Enabled: Bool
    public var autoBlockHogs: Bool
    public var autoBlockBpsThreshold: Double   // bytes/sec
    public var notifyOnNewDevice: Bool

    public init(ssid: String,
                allowlist: [AllowEntry] = [],
                schedule: Schedule = Schedule(),
                blockMode: BlockMode = .instant,
                ipv6Enabled: Bool = true,
                autoBlockHogs: Bool = false,
                autoBlockBpsThreshold: Double = 5_000_000 / 8,
                notifyOnNewDevice: Bool = true) {
        self.ssid = ssid; self.allowlist = allowlist; self.schedule = schedule
        self.blockMode = blockMode; self.ipv6Enabled = ipv6Enabled
        self.autoBlockHogs = autoBlockHogs; self.autoBlockBpsThreshold = autoBlockBpsThreshold
        self.notifyOnNewDevice = notifyOnNewDevice
    }
}
