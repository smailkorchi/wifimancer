import Foundation
import Network

/// Minimal Cloudflare-based speed tester:
///   - download: GET https://speed.cloudflare.com/__down?bytes=N
///   - upload:   POST https://speed.cloudflare.com/__up
///   - latency:  ICMP-style TCP connect time × samples
final class SpeedTester {

    func run() async -> SpeedSample {
        async let down = measureDownload()
        async let up   = measureUpload()
        async let lat  = measureLatency()
        let (d, u, (l, j, p)) = await (down, up, lat)
        return SpeedSample(
            timestamp: .now,
            downloadMbps: d, uploadMbps: u,
            latencyMs: l, jitterMs: j, lossPct: p
        )
    }

    private func measureDownload(bytes: Int = 25_000_000) async -> Double {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(bytes)") else { return 0 }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg)
        let start = Date.now
        do {
            let (data, _) = try await session.data(for: req)
            let dur = Date.now.timeIntervalSince(start)
            guard dur > 0 else { return 0 }
            return Double(data.count) * 8.0 / dur / 1_000_000
        } catch { return 0 }
    }

    private func measureUpload(bytes: Int = 10_000_000) async -> Double {
        guard let url = URL(string: "https://speed.cloudflare.com/__up") else { return 0 }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let payload = Data(count: bytes)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg)
        let start = Date.now
        do {
            let (_, _) = try await session.upload(for: req, from: payload)
            let dur = Date.now.timeIntervalSince(start)
            guard dur > 0 else { return 0 }
            return Double(bytes) * 8.0 / dur / 1_000_000
        } catch { return 0 }
    }

    private func measureLatency(samples: Int = 8) async -> (Double, Double, Double) {
        var rtts: [Double] = []
        var failures = 0
        for _ in 0..<samples {
            if let rtt = await tcpHandshakeLatency(host: "1.1.1.1", port: 443) {
                rtts.append(rtt)
            } else {
                failures += 1
            }
        }
        guard !rtts.isEmpty else { return (0, 0, 100) }
        let mean = rtts.reduce(0, +) / Double(rtts.count)
        let varSum = rtts.reduce(0) { $0 + pow($1 - mean, 2) }
        let jitter = sqrt(varSum / Double(rtts.count))
        let loss = Double(failures) / Double(samples) * 100
        return (mean, jitter, loss)
    }

    private func tcpHandshakeLatency(host: String, port: UInt16) async -> Double? {
        let start = Date.now
        // The state-update handler fires multiple times: .ready then .cancelled
        // when we tear down. Without dedup, we'd resume the continuation twice
        // and crash the helper with "SWIFT TASK CONTINUATION MISUSE".
        let resumed = ResumeGate()
        return await withCheckedContinuation { cont in
            let nwHost = NWEndpoint.Host(host)
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let rtt = Date.now.timeIntervalSince(start) * 1000
                    if resumed.fire() { cont.resume(returning: rtt) }
                    conn.cancel()
                case .failed, .cancelled:
                    if resumed.fire() { cont.resume(returning: nil) }
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if resumed.fire() { cont.resume(returning: nil) }
                conn.cancel()
            }
        }
    }
}

/// One-shot latch — `fire()` returns true exactly once.
private final class ResumeGate: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}
