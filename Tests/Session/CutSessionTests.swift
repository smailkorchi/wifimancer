import Foundation

@main
struct CutSessionTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ours = MACAddress("02:00:00:00:00:10")!
        let router = MACAddress("02:00:00:00:00:01")!
        let peer = MACAddress("02:00:00:00:00:20")!
        let newcomer = MACAddress("02:00:00:00:00:21")!
        let trusted = MACAddress("02:00:00:00:00:30")!
        let context = NetworkContext(interface: "en0", selfIPv4: "192.168.1.10", selfIPv6: [],
                                     selfMAC: ours, gatewayIPv4: "192.168.1.1", gatewayMAC: router,
                                     subnetCIDR: "192.168.1.0/24", ssid: "Owned", bssid: "02:11:22:33:44:55",
                                     ipv6Active: false, dnsServers: [])
        func device(_ mac: MACAddress, _ ip: String) -> Device { Device(mac: mac, ipv4: ip) }
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(condition(), message)
        }
        func scope(exclusions: [String] = [], until: Date = .distantFuture,
                   cidrs: [String] = ["192.168.1.0/24"], macs: [String] = []) -> EngagementScope {
            EngagementScope(id: "test", client: "test", authorizedBy: "test", validFrom: now,
                            validUntil: until, cidrs4: cidrs, cidrs6: [], essids: [], bssids: [],
                            macRanges: macs, exclusions: exclusions, rulesOfEngagement: "test")
        }
        func reconcile(_ devices: [Device], _ scope: EngagementScope?, policy: AutoCutPolicy = .autoCutInScope,
                       allowlist: Set<MACAddress> = [], manual: Set<MACAddress> = []) -> [SpoofTarget] {
            CutTargetReconciler.reconcile(.init(devices: devices, scope: scope, policy: policy,
                allowlistedMACs: allowlist, manualTargetMACs: manual, context: context), at: now).targets
        }
        let request = CutSessionRequest.currentNetwork(context, at: now)
        var state = CutSessionState()
        state.updateContext(context)
        check(state.acceptScan([device(peer, "192.168.1.20")], generation: state.generation), "initial scan")
        try state.start(request, at: now)
        check(state.targets(at: now).map(\.mac) == [peer], "initial peer armed")
        state.acceptScan([], generation: state.generation)
        check(state.targets(at: now).map(\.mac) == [peer], "missed scan retains armed peer")
        state.acceptScan([device(newcomer, "192.168.1.21")], generation: state.generation)
        check(Set(state.targets(at: now).map(\.mac)) == [peer, newcomer], "newcomer included without restart")
        state.allowlistedMACs.insert(peer)
        check(state.targets(at: now).map(\.mac) == [newcomer], "trust removes retained target immediately")
        state.allowlistedMACs.remove(peer)
        check(state.targets(at: now).count == 2, "untrust reuses current network inventory")
        state.allowlistedMACs.insert(trusted)
        state.acceptScan([device(trusted, "192.168.1.20")], generation: state.generation)
        check(state.inventory[peer] == nil, "new trusted owner removes stale IP binding")
        check(state.targets(at: now).map(\.mac) == [newcomer], "trusted reassigned IP never targeted")
        state.acceptScan([device(ours, "192.168.1.21")], generation: state.generation)
        check(state.targets(at: now).map(\.mac) == [newcomer], "outgoing self poison must not evict target")
        state.acceptScan([device(router, "192.168.1.21"), device(ours, "192.168.1.20")], generation: state.generation)
        check(state.targets(at: now).map(\.mac) == [newcomer], "mismatched gateway identity cannot evict target")
        check(state.inventory[trusted]?.ipv4 == "192.168.1.20", "poison cannot evict trusted membership")
        state.allowlistedMACs.insert(newcomer)
        state.acceptScan([device(peer, "192.168.1.40"), device(newcomer, "192.168.1.40")], generation: state.generation)
        check(state.targets(at: now).isEmpty, "ambiguous fresh owner bindings are refused")
        state.acceptScan([device(peer, "192.168.1.40")], generation: state.generation)
        check(state.targets(at: now).map(\.mac) == [peer], "unique later binding replaces ambiguity")

        let badFlags = [device(ours, "192.168.1.50"), device(peer, context.selfIPv4),
                        device(router, "192.168.1.51"), device(newcomer, context.gatewayIPv4)]
        check(reconcile(badFlags, scope()).isEmpty, "self and gateway identities survive false GUI flags")
        let trustAliases = [device(trusted, "192.168.1.30"), device(peer, "192.168.1.30")]
        check(reconcile(trustAliases, scope(), allowlist: [trusted]).isEmpty, "trusted address protects alternate MAC")
        for ip in ["192.168.1.0", "192.168.1.255", "192.168.2.20", "224.0.0.1", "127.0.0.1",
                   "169.254.1.2", "192.168.1.020", "192.168..1.20", ".192.168.1.20", "256.1.1.1"] {
            check(reconcile([device(peer, ip)], scope()).isEmpty, "invalid/noncurrent address refused: \(ip)")
        }
        check(reconcile([device(peer, "192.168.1.20")], nil).isEmpty, "missing automatic scope fails closed")
        check(reconcile([device(peer, "192.168.1.20")], nil, policy: .manual, manual: [peer]).isEmpty, "manual cannot bypass scope")
        check(reconcile([device(peer, "192.168.1.20")], scope(until: now.addingTimeInterval(-1))).isEmpty, "expired scope fails closed")
        check(reconcile([device(peer, "192.168.1.20")], scope(exclusions: [peer.description])).isEmpty, "MAC exclusion beats allowed CIDR")
        check(reconcile([device(peer, "192.168.1.20")], scope(exclusions: ["192.168.1.20"], cidrs: [], macs: [peer.description])).isEmpty, "IP exclusion beats allowed MAC")
        check(reconcile([device(peer, "192.168.1.20")], scope(cidrs: [], macs: [peer.description])).count == 1, "MAC scope can allow current-subnet peer")
        check(reconcile([device(peer, "192.168.1.20")], scope(cidrs: ["192.168.1.0/25"]), policy: .allowlistOnly).isEmpty, "whole-subnet policy refuses partial scope")
        check(reconcile([device(peer, "192.168.1.20")], scope(), policy: .manual, manual: [newcomer]).isEmpty, "manual membership enforced")

        let lateGeneration = state.generation
        state.stop()
        check(!state.acceptScan([device(newcomer, "192.168.1.21")], generation: lateGeneration), "late scan after stop cannot update/rearm")
        check(state.request == nil && state.targets(at: now).isEmpty, "stop remains idle")
        try state.start(request, at: now)
        var differentAP = context
        differentAP.bssid = "02:11:22:33:44:66"
        check(state.updateContext(differentAP), "same subnet different AP invalidates")
        check(state.request == nil && state.inventory.isEmpty, "AP change clears session and old peers")
        do { try state.start(request, at: now); preconditionFailure("stale AP request accepted") }
        catch { assertions += 1 }
        var changedSelf = differentAP
        changedSelf.selfMAC = trusted
        check(state.updateContext(changedSelf), "self MAC change invalidates")
        changedSelf.selfIPv4 = "192.168.1.11"
        check(state.updateContext(changedSelf), "self address change invalidates")
        check(state.updateContext(nil), "context loss invalidates")
        check(state.context == nil && state.inventory.isEmpty, "context loss clears discovery")
        do { try state.start(request, at: now); preconditionFailure("missing context accepted") }
        catch { assertions += 1 }
        state.updateContext(context)
        var unknownGateway = context
        unknownGateway.gatewayMAC = nil
        state.updateContext(nil)
        state.updateContext(unknownGateway)
        try state.start(.currentNetwork(unknownGateway, at: now), at: now)
        check(!state.updateContext(context), "gateway metadata learning preserves session")
        check(state.request != nil && state.context?.gatewayMAC == router, "known gateway retained")
        var unavailableMetadata = context
        unavailableMetadata.ssid = "<redacted>"
        unavailableMetadata.bssid = nil
        unavailableMetadata.gatewayMAC = nil
        check(!state.updateContext(unavailableMetadata), "unavailable metadata normalized")
        check(state.context?.ssid == "Owned" && state.context?.bssid == context.bssid, "known metadata retained")
        var replacementGateway = context
        replacementGateway.gatewayMAC = trusted
        check(state.updateContext(replacementGateway), "known changed gateway invalidates")
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CutSessionRequest.self, from: encoded)
        check(decoded.network.matches(context) && decoded.policy == .autoCutInScope, "session wire roundtrip")
        print("CutSessionTests: \(assertions) offline assertions passed")
    }
}
