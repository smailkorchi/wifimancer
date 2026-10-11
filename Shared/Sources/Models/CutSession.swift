import Foundation

/// Identity comes from the helper, before the app enriches display-only SSIDs.
public struct NetworkSessionIdentity: Codable, Sendable, Hashable {
    public let interface: String
    public let selfIPv4: String
    public let selfMAC: MACAddress
    public let selfIPv6: [String]
    public let gatewayIPv4: String
    public let gatewayMAC: MACAddress?
    public let subnetCIDR: String
    public let ssid: String?
    public let bssid: String?

    public init(context: NetworkContext) {
        interface = context.interface
        selfIPv4 = context.selfIPv4
        selfMAC = context.selfMAC
        selfIPv6 = context.selfIPv6.map { $0.lowercased() }.sorted()
        gatewayIPv4 = context.gatewayIPv4
        gatewayMAC = context.gatewayMAC
        subnetCIDR = context.subnetCIDR
        ssid = Self.available(context.ssid)
        bssid = Self.available(context.bssid)?.lowercased()
    }

    public func matches(_ context: NetworkContext) -> Bool {
        let other = Self(context: context)
        return interface == other.interface && selfIPv4 == other.selfIPv4
            && selfMAC == other.selfMAC && selfIPv6 == other.selfIPv6
            && gatewayIPv4 == other.gatewayIPv4 && subnetCIDR == other.subnetCIDR
            && Self.sameKnown(ssid, other.ssid) && Self.sameKnown(bssid, other.bssid)
            && Self.sameKnown(gatewayMAC, other.gatewayMAC)
    }

    private static func sameKnown<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    private static func available(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "<redacted>" else { return nil }
        return value
    }
}

/// Automatic mode carries a network-bound policy, never a GUI device snapshot.
public struct CutSessionRequest: Codable, Sendable {
    public let network: NetworkSessionIdentity
    public let scope: EngagementScope
    public let policy: AutoCutPolicy
    public let manualTargetMACs: Set<MACAddress>

    public init(network: NetworkSessionIdentity, scope: EngagementScope,
                policy: AutoCutPolicy, manualTargetMACs: Set<MACAddress> = []) {
        self.network = network
        self.scope = scope
        self.policy = policy
        self.manualTargetMACs = manualTargetMACs
    }

    public static func currentNetwork(_ context: NetworkContext, at now: Date = .now,
                                      policy: AutoCutPolicy = .autoCutInScope,
                                      manualTargetMACs: Set<MACAddress> = []) -> Self {
        let scope = EngagementScope(
            id: UUID().uuidString, client: "Local network", authorizedBy: "Local operator",
            validFrom: now, validUntil: .distantFuture,
            cidrs4: [context.subnetCIDR], cidrs6: [], essids: [], bssids: [],
            macRanges: [], exclusions: [],
            rulesOfEngagement: "Ends on stop, network change or helper restart."
        )
        return Self(network: NetworkSessionIdentity(context: context), scope: scope,
                    policy: policy, manualTargetMACs: manualTargetMACs)
    }
}

/// Pure state used by the helper; a missed scan does not erase an armed peer.
public struct CutSessionState: Sendable {
    public private(set) var context: NetworkContext?
    public private(set) var inventory: [MACAddress: Device] = [:]
    public private(set) var request: CutSessionRequest?
    public private(set) var generation: UInt64 = 0
    public var allowlistedMACs: Set<MACAddress> = []

    public init() {}

    public var devices: [Device] {
        inventory.values.map {
            var device = $0
            device.isAllowlisted = allowlistedMACs.contains(device.mac)
            return device
        }.sorted { ($0.ipv4 ?? "") < ($1.ipv4 ?? "") }
    }

    /// Nil is context loss. Known AP/MAC changes invalidate even on the same /24.
    @discardableResult
    public mutating func updateContext(_ next: NetworkContext?) -> Bool {
        let changed: Bool
        if let old = context, let next {
            changed = !NetworkSessionIdentity(context: old).matches(next)
        } else {
            changed = (context != nil) != (next != nil)
        }
        if changed {
            stop()
            inventory.removeAll()
        }
        var resolved = next
        if !changed, let old = context, resolved != nil {
            // Root may temporarily redact metadata or miss an ARP-cache entry.
            if resolved?.gatewayMAC == nil { resolved?.gatewayMAC = old.gatewayMAC }
            if resolved?.ssid == nil || resolved?.ssid == "<redacted>" { resolved?.ssid = old.ssid }
            if resolved?.bssid == nil || resolved?.bssid == "<redacted>" { resolved?.bssid = old.bssid }
        }
        context = resolved
        return changed
    }

    public mutating func start(_ request: CutSessionRequest, at now: Date = .now) throws {
        guard let context, request.network.matches(context) else {
            throw NSError(domain: "CutSession", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Network changed; start again on the current network"])
        }
        guard request.scope.isCurrentlyValid(at: now) else {
            throw NSError(domain: "CutSession", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Session scope is not currently valid"])
        }
        generation &+= 1
        self.request = request
    }

    public mutating func stop() {
        generation &+= 1
        request = nil
    }

    @discardableResult
    public mutating func acceptScan(_ devices: [Device], generation token: UInt64) -> Bool {
        guard token == generation, let context else { return false }
        let usable = devices.filter { device in
            guard let ip = device.ipv4 else { return false }
            // Captured outgoing poison advertises our MAC for a peer/router
            // IP. Those frames are not discovery evidence for a new owner.
            if device.mac == context.selfMAC { return ip == context.selfIPv4 }
            if ip == context.selfIPv4 { return false }
            if let gatewayMAC = context.gatewayMAC {
                if device.mac == gatewayMAC { return ip == context.gatewayIPv4 }
                if ip == context.gatewayIPv4 { return false }
            }
            return CutTargetReconciler.isUsableIPv4(ip, in: context.subnetCIDR)
                && !device.mac.isMulticast && device.mac.bytes.contains(where: { $0 != 0 })
        }
        let observedIPs = Set(usable.compactMap(\.ipv4))
        let observedMACs = Set(usable.map(\.mac))
        // Fresh ownership beats retained bindings. Keep simultaneous ambiguous
        // observations together so the reconciler refuses both owners.
        inventory = inventory.filter {
            !observedIPs.contains($0.value.ipv4 ?? "") || observedMACs.contains($0.key)
        }
        for var device in usable {
            guard let ip = device.ipv4,
                  CutTargetReconciler.isUsableIPv4(ip, in: context.subnetCIDR),
                  !device.mac.isMulticast, device.mac.bytes.contains(where: { $0 != 0 })
            else { continue }
            if let previous = inventory[device.mac] { device.firstSeen = previous.firstSeen }
            device.isSelf = device.mac == context.selfMAC || ip == context.selfIPv4
            device.isGateway = device.mac == context.gatewayMAC || ip == context.gatewayIPv4
            device.isAllowlisted = allowlistedMACs.contains(device.mac)
            inventory[device.mac] = device
        }
        return true
    }

    public func targets(at now: Date = .now) -> [SpoofTarget] {
        guard let request, let context, request.network.matches(context) else { return [] }
        return CutTargetReconciler.reconcile(.init(
            devices: devices, scope: request.scope, policy: request.policy,
            allowlistedMACs: allowlistedMACs, manualTargetMACs: request.manualTargetMACs,
            context: context
        ), at: now).targets
    }
}
