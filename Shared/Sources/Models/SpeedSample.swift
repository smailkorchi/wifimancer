import Foundation

public struct SpeedSample: Codable, Hashable, Sendable {
    public var timestamp: Date
    public var downloadMbps: Double
    public var uploadMbps: Double
    public var latencyMs: Double
    public var jitterMs: Double
    public var lossPct: Double

    public init(timestamp: Date = .now, downloadMbps: Double = 0, uploadMbps: Double = 0,
                latencyMs: Double = 0, jitterMs: Double = 0, lossPct: Double = 0) {
        self.timestamp = timestamp; self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps; self.latencyMs = latencyMs
        self.jitterMs = jitterMs; self.lossPct = lossPct
    }
}

public struct ThroughputTick: Codable, Hashable, Sendable, Identifiable {
    public var id: TimeInterval { timestamp.timeIntervalSince1970 }
    public var timestamp: Date
    public var downBps: Double
    public var upBps: Double
    public init(timestamp: Date = .now, downBps: Double, upBps: Double) {
        self.timestamp = timestamp; self.downBps = downBps; self.upBps = upBps
    }
}

public enum HelperEvent: Codable, Sendable {
    case devicesUpdated([Device])
    case context(NetworkContext)
    case spoofStateChanged(targets: [String], active: Bool)
    case throughput(ThroughputTick)
    case speedTest(SpeedSample)
    case log(level: LogLevel, message: String)
    case error(String)
    /// Cut effectiveness verdict, emitted ~3s after engaging Cut.
    /// `effective`: per-target bandwidth dropped meaningfully — Cut is working.
    /// `failing`: per-target bandwidth still flowing — likely AP client-isolation
    /// or modern device ARP-protection. UI surfaces a distinct warning state.
    /// `unknown`: no signal yet (no traffic to measure against).
    case cutStatus(CutStatus)

    public enum LogLevel: String, Codable, Sendable {
        case debug, info, warn, error
    }
}

public enum CutStatus: String, Codable, Sendable {
    case engaged         // cut armed, targets being poisoned
    case unsupportedAP   // scan finds no LAN peers — AP client isolation blocks any L2 cut
    case noTargets       // user toggled Cut but no eligible devices in the scan
    case idle            // not cutting
}
