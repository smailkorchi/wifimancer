// The runner appends this test to the unmodified scanner source so a same-file
// extension can exercise its private capture wrapper without running a sweep.
extension ARPScanner {
    static func offlineCapture() async throws -> [Result] {
        try await runCapture(iface: "offline", durationMs: 1)
    }

    static func offlineSweep() async throws {
        try await runSweep(iface: "offline", mac: [2, 0, 0, 0, 0, 10],
                           selfIP: "192.168.1.1", cidr: "192.168.1.0/30")
    }
}

@main
struct ScannerCaptureTests {
    static func main() async throws {
        offline_reset()
        let empty = try await ARPScanner.offlineCapture()
        precondition(empty.isEmpty, "A successful empty capture remains empty")
        precondition(offline_frame_count() == 0 && offline_open_count() == offline_close_count())

        for (kind, configure) in [
            ("pcap_setdirection", { offline_set_direction_failure(1) }),
            ("capture setup", { offline_set_nonblock_failure(1) }),
            ("capture setup", { offline_set_filter_failure(1) }),
            ("capture read", { offline_set_read_failure(1) })
        ] {
            offline_reset()
            configure()
            do {
                _ = try await ARPScanner.offlineCapture()
                preconditionFailure("\(kind) failure was reported as an empty successful scan")
            } catch ARPScanner.ScanError.openFailed(let diagnostic) {
                precondition(diagnostic.contains(kind), "Preserve the C capture diagnostic")
                precondition(!diagnostic.isEmpty)
            }
            precondition(offline_frame_count() == 0 && offline_open_count() == offline_close_count())
        }
        offline_reset()
        try await ARPScanner.offlineSweep()
        precondition(offline_frame_count() == 1 && offline_open_count() == offline_close_count())

        offline_reset()
        offline_set_open_failure(1)
        do {
            try await ARPScanner.offlineSweep()
            preconditionFailure("Sweep open failure was ignored")
        } catch ARPScanner.ScanError.openFailed(let diagnostic) {
            precondition(diagnostic.contains("offline open failure"))
        }
        precondition(offline_frame_count() == 0 && offline_open_count() == offline_close_count())

        offline_reset()
        offline_set_inject_result(-1)
        do {
            try await ARPScanner.offlineSweep()
            preconditionFailure("Sweep injection failure was ignored")
        } catch ARPScanner.ScanError.sendFailed(let diagnostic) {
            precondition(diagnostic.contains("ARP request failed on offline for 192.168.1.2"))
        }
        precondition(offline_frame_count() == 1 && offline_open_count() == offline_close_count())
        print("Scanner wrappers passed: capture direction/nonblock/filter/read errors, sender open/injection errors, and successful offline capture/sweep")
    }
}
