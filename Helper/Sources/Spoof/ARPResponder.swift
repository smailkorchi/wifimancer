import Foundation

/// Respond only to an exact selected device asking for the gateway, or the
/// exact gateway asking for a selected device. IP-only claims affect unrelated
/// clients; both requester addresses are required at the C boundary.
actor ARPResponder {

    private var context: NetworkContext
    private var handle: UnsafeMutableRawPointer?
    private var task: Task<Void, Never>?
    private var targets: Set<ARPSpoofer.Target> = []
    private var generation: UInt64 = 0
    private var repliesSent: UInt64 = 0
    private var lastReportAt: Date = .distantPast
    private let onFailure: @Sendable (String) -> Void

    init(context: NetworkContext, onFailure: @escaping @Sendable (String) -> Void) {
        self.context = context
        self.onFailure = onFailure
    }

    func setContext(_ ctx: NetworkContext) {
        if !ARPSpoofer.sameLAN(context, ctx) { stop() }
        self.context = ARPSpoofer.retainingKnownIdentity(ctx, previous: context)
    }

    func start(targets: [ARPSpoofer.Target]) throws {
        guard ARPSpoofer.validContext(context) else {
            throw NSError(domain: "ARPResponder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "A valid local and gateway identity is required."])
        }
        if handle == nil {
            var errbuf = [CChar](repeating: 0, count: 256)
            guard let h = context.interface.withCString({ wm_arp_resp_open($0, &errbuf) }) else {
                throw NSError(domain: "ARPResponder", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(cString: errbuf)])
            }
            self.handle = h
            Log.arp.info("ARPResponder: opened on \(self.context.interface, privacy: .public)")
        }
        self.targets = ARPSpoofer.validatedTargets(targets, context: context)
        if task == nil {
            generation &+= 1
            let currentGeneration = generation
            task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.loop(generation: currentGeneration)
            }
        }
    }

    func update(targets: [ARPSpoofer.Target]) throws {
        guard task != nil else {
            throw NSError(domain: "ARPResponder", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "ARP responder is inactive or its network identity changed."])
        }
        self.targets = ARPSpoofer.validatedTargets(targets, context: context)
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        if let h = handle {
            wm_arp_resp_close(h)
            handle = nil
        }
        targets.removeAll()
    }

    private func loop(generation: UInt64) async {
        while !Task.isCancelled && self.generation == generation {
            pump()
            // The pcap handle is nonblocking, including on macOS BPF. Yield
            // between bounded pumps so stop can always enter the actor.
            try? await Task.sleep(nanoseconds: 2_000_000)  // 2 ms
        }
    }

    private func pump() {
        guard let h = handle, !targets.isEmpty,
              let ownIP = ARPSpoofer.ipv4Bytes(context.selfIPv4),
              let gatewayIP = ARPSpoofer.ipv4Bytes(context.gatewayIPv4),
              let gatewayMAC = context.gatewayMAC?.bytes else { return }

        var targetIPs = [UInt8]()
        var targetMACs = [UInt8]()
        for target in targets {
            guard let ip = ARPSpoofer.ipv4Bytes(target.ip) else { continue }
            targetIPs.append(contentsOf: ip)
            targetMACs.append(contentsOf: target.mac.bytes)
        }
        let count = Int32(targetIPs.count / 4)
        guard count > 0 else { return }

        let mac = context.selfMAC.bytes
        let r = mac.withUnsafeBufferPointer { mp in
            ownIP.withUnsafeBufferPointer { own in
                gatewayMAC.withUnsafeBufferPointer { gateway in
                    gatewayIP.withUnsafeBufferPointer { gatewayIP in
                        targetIPs.withUnsafeBufferPointer { ips in
                            targetMACs.withUnsafeBufferPointer { macs in
                                wm_arp_resp_pump(h, mp.baseAddress, own.baseAddress,
                                                 gateway.baseAddress, gatewayIP.baseAddress,
                                                 ips.baseAddress, macs.baseAddress, count, 256)
                            }
                        }
                    }
                }
            }
        }
        if r < 0 {
            stop()
            onFailure("ARP capture or reply injection failed; the cut session was stopped.")
            return
        }
        if r > 0 { repliesSent &+= UInt64(r) }

        let now = Date.now
        if now.timeIntervalSince(lastReportAt) > 5 {
            Log.arp.info("ARPResponder: replied=\(self.repliesSent, privacy: .public) targets=\(self.targets.count, privacy: .public)")
            lastReportAt = now
        }
    }
}
