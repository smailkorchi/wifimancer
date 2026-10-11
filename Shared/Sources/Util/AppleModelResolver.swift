import Foundation

/// Resolves Apple model identifiers (e.g. `MacBookPro17,1`, `iPhone16,1`) to
/// human-readable names like "MacBook Pro 13\" M1 (Late 2020)".
///
/// Identifiers come from mDNS TXT records on Apple devices. The live capture
/// path is the `model=` key in `_airplay._tcp` / `_device-info._tcp` TXT
/// records — a Bonjour browser surfacing those values feeds this resolver.
///
/// The mapping is curated and shipped as `Resources/Data/apple-models.json`.
/// Apple maintains the canonical identifier→marketing-name table internally
/// and never publishes a single machine-readable feed; covering every device
/// from the last several years catches everything that shows up on real LANs.
public final class AppleModelResolver {

    public static let shared = AppleModelResolver()

    private let map: [String: String]

    public init(map: [String: String]) {
        self.map = map
    }

    public convenience init() {
        if let url = Bundle.main.url(forResource: "apple-models", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            self.init(map: decoded)
        } else {
            self.init(map: [:])
        }
    }

    /// Test/CLI entry point — load directly from a file path.
    public static func loadFromFile(_ path: String) -> AppleModelResolver {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return AppleModelResolver(map: [:])
        }
        return AppleModelResolver(map: decoded)
    }

    /// Resolve `MacBookPro17,1` → `"MacBook Pro 13\" M1 (Late 2020)"`.
    /// Returns nil for unknown identifiers; the caller falls back to vendor
    /// lookup or the kind heuristic in `Device.kind`.
    public func name(for identifier: String) -> String? {
        if let v = map[identifier] { return v }
        // Defensive case-insensitive fallback. Apple's identifiers are always
        // case-sensitive in practice, but real-world TXT records have been
        // observed lower-cased after passing through some intermediaries.
        return map.first(where: { $0.key.caseInsensitiveCompare(identifier) == .orderedSame })?.value
    }

    /// Total number of identifiers loaded — useful for diagnostics.
    public var count: Int { map.count }
}
