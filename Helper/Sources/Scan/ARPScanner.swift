import Foundation

/// Native ARP scanner: sweeps the subnet with crafted ARP REQUESTs and listens
/// for REPLYs via libpcap. Replaces nmap entirely.
final class ARPScanner: @unchecked Sendable {

    struct Result: Sendable, Hashable {
        var ip: String
        var mac: MACAddress
    }

    enum ScanError: LocalizedError {
        case openFailed(String)
        case sendFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed(let message), .sendFailed(let message): return message
            }
        }
    }

    private let context: NetworkContext

    init(context: NetworkContext) {
        self.context = context
    }

    func scan(durationMs: Int = 1500) async throws -> [Result] {
        let iface = context.interface
        let macBytes = context.selfMAC.bytes
        let selfIP = context.selfIPv4
        let cidr = context.subnetCIDR

        // Spawn the capture in parallel with sender bursts.
        async let captured: [Result] = Self.runCapture(iface: iface, durationMs: durationMs)
        async let swept: Void = Self.runSweep(iface: iface, mac: macBytes, selfIP: selfIP, cidr: cidr)

        let (results, _) = try await (captured, swept)
        return results
    }

    private static func runCapture(iface: String, durationMs: Int) async throws -> [Result] {
        try await Task.detached(priority: .userInitiated) { () throws -> [Result] in
            var observations = [wm_arp_observation_t](repeating: wm_arp_observation_t(), count: 512)
            var ebuf = [CChar](repeating: 0, count: 256)
            let n = observations.withUnsafeMutableBufferPointer { ptr -> Int32 in
                iface.withCString { ic in
                    wm_pcap_capture_arp(ic, Int32(durationMs), ptr.baseAddress, 512, &ebuf)
                }
            }
            guard n >= 0 else { throw ScanError.openFailed(String(cString: ebuf)) }
            guard n > 0 else { return [] }
            var out: [Result] = []
            for i in 0..<Int(n) {
                let obs = observations[i]
                let ip = withUnsafeBytes(of: obs.ip) { ptr -> String in
                    String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
                }
                let macTuple = obs.mac
                let macArr = withUnsafeBytes(of: macTuple) { Array($0.prefix(6)) }
                out.append(Result(ip: ip, mac: MACAddress(bytes: macArr)))
            }
            return out
        }.value
    }

    private static func runSweep(iface: String, mac: [UInt8], selfIP: String, cidr: String) async throws {
        let sweep = Task.detached(priority: .userInitiated) { () throws -> Void in
            var errbuf = [CChar](repeating: 0, count: 256)
            guard let h = iface.withCString({ ic in wm_arp_open(ic, &errbuf) }) else {
                throw ScanError.openFailed(String(cString: errbuf))
            }
            defer { wm_arp_close(h) }
            for ip in subnetIPs(cidr: cidr) {
                try Task.checkCancellation()
                if ip == selfIP { continue }
                let result = ip.withCString { tgt in
                    selfIP.withCString { src in
                        mac.withUnsafeBufferPointer { mp in
                            wm_arp_send_request(h, mp.baseAddress, src, tgt)
                        }
                    }
                }
                guard result == 0 else {
                    throw ScanError.sendFailed("ARP request failed on \(iface) for \(ip)")
                }
                try await Task.sleep(nanoseconds: 500_000) // 0.5 ms pacing
            }
        }
        try await withTaskCancellationHandler {
            try await sweep.value
        } onCancel: {
            sweep.cancel()
        }
    }

    private static func subnetIPs(cidr: String) -> [String] {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 16, prefix <= 30 else { return [] }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4 else { return [] }
        let base = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        let mask: UInt32 = prefix == 0 ? 0 : 0xFFFFFFFF << (32 - prefix)
        let net = base & mask
        let bcast = net | ~mask
        var ips: [String] = []
        if bcast - net > 1 {
            for n in (net + 1)..<bcast {
                ips.append("\((n >> 24) & 0xff).\((n >> 16) & 0xff).\((n >> 8) & 0xff).\(n & 0xff)")
            }
        }
        return ips
    }
}
