import Foundation

/// Helper-side policy validation. App flags never override network identities.
public enum CutTargetReconciler {
    public struct Inputs: Sendable {
        public var devices: [Device]
        public var scope: EngagementScope?
        public var policy: AutoCutPolicy
        public var allowlistedMACs: Set<MACAddress>
        public var manualTargetMACs: Set<MACAddress>
        public var context: NetworkContext?

        public init(devices: [Device], scope: EngagementScope?, policy: AutoCutPolicy,
                    allowlistedMACs: Set<MACAddress>, manualTargetMACs: Set<MACAddress>,
                    context: NetworkContext? = nil) {
            self.devices = devices; self.scope = scope; self.policy = policy
            self.allowlistedMACs = allowlistedMACs; self.manualTargetMACs = manualTargetMACs
            self.context = context
        }
    }

    public struct Result: Sendable, Equatable {
        public var targets: [SpoofTarget]
        public var refusedOutOfScope: [SpoofTarget]
    }

    public static func reconcile(_ input: Inputs, at now: Date = .now) -> Result {
        guard let context = input.context, let scope = input.scope,
              scope.isCurrentlyValid(at: now) else {
            return Result(targets: [], refusedOutOfScope: input.devices.compactMap {
                guard let ip = $0.ipv4 else { return nil }
                return SpoofTarget(mac: $0.mac, ipv4: ip)
            })
        }
        let protectedMACs = input.allowlistedMACs.union([context.selfMAC])
            .union(context.gatewayMAC.map { [$0] } ?? [])
        var protectedIPs: Set<String> = [context.selfIPv4, context.gatewayIPv4]
        for device in input.devices where protectedMACs.contains(device.mac) || device.isAllowlisted {
            if let ip = device.ipv4 { protectedIPs.insert(ip) }
        }
        var live: [SpoofTarget] = []
        var refused: [SpoofTarget] = []
        let grouped = Dictionary(grouping: input.devices.compactMap { device -> Device? in
            guard device.ipv4 != nil else { return nil }; return device
        }, by: { $0.ipv4! })
        for device in input.devices {
            guard let ip = device.ipv4,
                  !device.isSelf, !device.isGateway, !device.isAllowlisted,
                  !protectedMACs.contains(device.mac), !protectedIPs.contains(ip),
                  !device.mac.isMulticast, device.mac.bytes.contains(where: { $0 != 0 }),
                  isUsableIPv4(ip, in: context.subnetCIDR),
                  Set(grouped[ip, default: []].map(\.mac)).count == 1
            else { continue }
            if input.policy == .manual && !input.manualTargetMACs.contains(device.mac) { continue }
            let target = SpoofTarget(mac: device.mac, ipv4: ip)
            guard scope.permits(ipv4: ip, mac: device.mac, at: now) else {
                refused.append(target); continue
            }
            if input.policy == .allowlistOnly,
               !scope.cidrs4.contains(where: { $0 == context.subnetCIDR }) {
                refused.append(target); continue
            }
            // IPv6 prefixes are absent from NetworkContext. Do not invent them.
            live.append(target)
        }
        return Result(targets: Array(Set(live)).sorted { $0.ipv4 < $1.ipv4 },
                      refusedOutOfScope: refused)
    }

    public static func isUsableIPv4(_ ip: String, in cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (1...32).contains(prefix),
              let address = EngagementScope.ipv4ToUInt32(ip),
              let network = EngagementScope.ipv4ToUInt32(String(parts[0])),
              EngagementScope.ipv4Matches(ip, cidr: cidr) else { return false }
        let first = address >> 24
        guard first > 0, first < 224, first != 127,
              address & 0xFFFF0000 != 0xA9FE0000 else { return false }
        if prefix < 31 {
            let mask = UInt32.max << (32 - prefix)
            let base = network & mask
            guard address != base, address != base | ~mask else { return false }
        }
        return true
    }
}
