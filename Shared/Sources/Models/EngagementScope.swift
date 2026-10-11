import Foundation

// MARK: - Auto-cut policy

/// Drives how the helper picks targets when devices are discovered.
/// Stored on disk per engagement and re-applied on app/helper restart.
public enum AutoCutPolicy: String, Codable, Sendable, CaseIterable {
    /// Cut only the targets the operator manually added. New devices joining
    /// the LAN are observed but never automatically cut.
    case manual

    /// Cut every newly-discovered device that passes the engagement scope
    /// check and is not allowlisted. The fix the user asked for: any new
    /// joiner gets cut on the next scan tick without restarting the app.
    case autoCutInScope

    /// Cut every non-allowlisted device on the LAN, regardless of scope.
    /// Refused unless the engagement scope itself covers the entire local
    /// subnet — keeps the legal gate honest.
    case allowlistOnly
}

// MARK: - Target descriptor

/// What we're about to dispatch an action against. Every offensive call goes
/// through `EngagementScope.validate(target:)` with one of these.
public enum TargetDescriptor: Sendable, Hashable {
    case ipv4(String)
    case ipv6(String)
    case mac(MACAddress)
    case essid(String)
    case bssid(String)
}

// MARK: - Scope rejection

public enum ScopeRejection: Error, CustomStringConvertible, Sendable {
    case notYetValid(validFrom: Date)
    case expired(validUntil: Date)
    case notInScope(target: String)
    case excluded(target: String)
    case malformedTarget(String)
    case malformedScopeEntry(String)

    public var description: String {
        switch self {
        case .notYetValid(let d):     return "engagement window has not started yet (valid from \(d))"
        case .expired(let d):         return "engagement window expired at \(d)"
        case .notInScope(let t):      return "\(t) is not inside the engagement scope"
        case .excluded(let t):        return "\(t) is on the engagement exclusion list"
        case .malformedTarget(let t): return "malformed target: \(t)"
        case .malformedScopeEntry(let e): return "malformed scope entry: \(e)"
        }
    }
}

// MARK: - EngagementScope

/// The legal gate. Loaded from a signed JSON file at engagement start.
/// Every offensive dispatch in the helper or the KaliClient must pass
/// `validate(target:)` before any frame touches the wire.
///
/// The signature field is a placeholder for now — the scope file format
/// is the contract; signing/verification with an Ed25519 keypair plugs in
/// at a single choke point in the loader without changing this struct.
public struct EngagementScope: Codable, Sendable, Hashable {

    public let id: String
    public let client: String
    public let authorizedBy: String
    public let validFrom: Date
    public let validUntil: Date

    /// IPv4 CIDR allowlist. Examples: "192.168.11.0/24", "10.0.0.0/8".
    public let cidrs4: [String]
    /// IPv6 CIDR allowlist. Examples: "fd00::/8", "2001:db8::/32".
    public let cidrs6: [String]
    /// Wi-Fi network names allowed.
    public let essids: [String]
    /// Specific BSSIDs allowed (lower-cased, colon-separated).
    public let bssids: [String]
    /// MAC ranges as either full MACs ("aa:bb:cc:dd:ee:ff") or OUI prefixes
    /// ("aa:bb:cc"). Lower-cased, colon-separated.
    public let macRanges: [String]

    /// Exclusion list. Same syntax mix as the allowlists. Always wins over
    /// any allow rule — if a target matches any exclusion, it is rejected
    /// even if it would otherwise match an allow.
    public let exclusions: [String]

    /// Free-text rules of engagement from the signed contract.
    public let rulesOfEngagement: String

    /// Detached signature over the canonical JSON of this struct.
    /// Leave empty for now; loader is responsible for verifying.
    public let signatureBase64: String

    public init(
        id: String, client: String, authorizedBy: String,
        validFrom: Date, validUntil: Date,
        cidrs4: [String], cidrs6: [String],
        essids: [String], bssids: [String],
        macRanges: [String], exclusions: [String],
        rulesOfEngagement: String,
        signatureBase64: String = ""
    ) {
        self.id = id
        self.client = client
        self.authorizedBy = authorizedBy
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.cidrs4 = cidrs4
        self.cidrs6 = cidrs6
        // ESSIDs are case-sensitive per 802.11. Do NOT lowercase them.
        self.essids = essids
        // Hex fields: normalise case so "AA:BB:CC" and "aa:bb:cc" compare equal.
        self.bssids = bssids.map { $0.lowercased() }
        self.macRanges = macRanges.map { $0.lowercased() }
        // Exclusions are a mix — preserve original case so an ESSID exclusion
        // like "ApprovedAP" stays distinct from a network named "approvedap".
        // Hex-only exclusions (MAC/BSSID/IPv6 strings) are lowercased at
        // comparison time, not at storage time.
        self.exclusions = exclusions
        self.rulesOfEngagement = rulesOfEngagement
        self.signatureBase64 = signatureBase64
    }

    // MARK: validity window

    public func isCurrentlyValid(at now: Date = .now) -> Bool {
        now >= validFrom && now <= validUntil
    }

    // MARK: target check

    /// Top-level validator. Throws a `ScopeRejection` describing exactly why
    /// a target was refused, suitable for the audit log.
    public func validate(target: TargetDescriptor, at now: Date = .now) throws {
        if now < validFrom { throw ScopeRejection.notYetValid(validFrom: validFrom) }
        if now > validUntil { throw ScopeRejection.expired(validUntil: validUntil) }

        // Exclusions always win.
        if isExcluded(target: target) {
            throw ScopeRejection.excluded(target: descriptionOf(target))
        }

        guard isAllowed(target: target) else {
            throw ScopeRejection.notInScope(target: descriptionOf(target))
        }
    }

    public func isInScope(target: TargetDescriptor, at now: Date = .now) -> Bool {
        do { try validate(target: target, at: now); return true }
        catch { return false }
    }

    /// An exclusion for either identity wins over any address or MAC allow rule.
    public func permits(ipv4: String, mac: MACAddress, at now: Date = .now) -> Bool {
        isCurrentlyValid(at: now)
            && !isExcluded(target: .ipv4(ipv4)) && !isExcluded(target: .mac(mac))
            && (isAllowed(target: .ipv4(ipv4)) || isAllowed(target: .mac(mac)))
    }

    // MARK: predicates

    private func isAllowed(target: TargetDescriptor) -> Bool {
        switch target {
        case .ipv4(let ip):    return cidrs4.contains { Self.ipv4Matches(ip, cidr: $0) }
        case .ipv6(let ip):    return cidrs6.contains { Self.ipv6Matches(ip, cidr: $0) }
        case .mac(let m):      return macRanges.contains { Self.macMatches(m, rule: $0) }
        case .essid(let s):    return essids.contains(s)
        case .bssid(let b):    return bssids.contains(b.lowercased())
        }
    }

    private func isExcluded(target: TargetDescriptor) -> Bool {
        switch target {
        case .ipv4(let ip):
            let ipLower = ip.lowercased()
            return exclusions.contains { rule in
                if rule.contains("/") { return Self.ipv4Matches(ip, cidr: rule) }
                return rule.lowercased() == ipLower
            }
        case .ipv6(let ip):
            let ipLower = ip.lowercased()
            return exclusions.contains { rule in
                if rule.contains("/") { return Self.ipv6Matches(ip, cidr: rule) }
                return rule.lowercased() == ipLower
            }
        case .mac(let m):
            return exclusions.contains { Self.macMatches(m, rule: $0) }
        case .essid(let s):
            // 802.11 SSIDs are case-sensitive. Exact match only.
            return exclusions.contains(s)
        case .bssid(let b):
            let bLower = b.lowercased()
            return exclusions.contains { $0.lowercased() == bLower }
        }
    }

    private func descriptionOf(_ t: TargetDescriptor) -> String {
        switch t {
        case .ipv4(let s):    return "ipv4:\(s)"
        case .ipv6(let s):    return "ipv6:\(s)"
        case .mac(let m):     return "mac:\(m.description)"
        case .essid(let s):   return "essid:\(s)"
        case .bssid(let s):   return "bssid:\(s)"
        }
    }

    // MARK: CIDR / MAC matchers

    /// Returns true when `ip` falls inside `cidr`. False on any malformed
    /// input — callers treat false as "not in scope" rather than throwing
    /// because a single bad scope entry must not poison the whole check.
    static func ipv4Matches(_ ip: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...32).contains(prefix),
              let netN = ipv4ToUInt32(String(parts[0])),
              let tgtN = ipv4ToUInt32(ip)
        else { return false }
        if prefix == 0 { return true }
        let mask: UInt32 = (~UInt32(0)) << (32 - prefix)
        return (netN & mask) == (tgtN & mask)
    }

    static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var r: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let v = UInt8(p), String(v) == p else { return nil }
            r = (r << 8) | UInt32(v)
        }
        return r
    }

    /// Byte-prefix CIDR match for IPv6. Sufficient for nibble-aligned
    /// real-world prefixes (most networks use /48, /56, /64). Non-nibble
    /// prefixes are exact-byte-aligned only.
    static func ipv6Matches(_ ip: String, cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...128).contains(prefix),
              let netBytes = ipv6Bytes(String(parts[0])),
              let tgtBytes = ipv6Bytes(ip)
        else { return false }
        let fullBytes = prefix / 8
        let trailingBits = prefix % 8
        for i in 0..<fullBytes {
            if netBytes[i] != tgtBytes[i] { return false }
        }
        if trailingBits == 0 { return true }
        let mask: UInt8 = UInt8(0xFF << (8 - trailingBits)) & 0xFF
        return (netBytes[fullBytes] & mask) == (tgtBytes[fullBytes] & mask)
    }

    /// Expand an IPv6 address (including `::`) to its 16-byte form.
    static func ipv6Bytes(_ s: String) -> [UInt8]? {
        let lower = s.lowercased()
        let zoneStripped = lower.split(separator: "%").first.map(String.init) ?? lower
        let split = zoneStripped.components(separatedBy: "::")
        guard split.count <= 2 else { return nil }
        func parseGroups(_ chunk: String) -> [UInt16]? {
            if chunk.isEmpty { return [] }
            var out: [UInt16] = []
            for g in chunk.split(separator: ":", omittingEmptySubsequences: false) {
                if g.isEmpty { return nil }
                guard let v = UInt16(g, radix: 16) else { return nil }
                out.append(v)
            }
            return out
        }
        var head: [UInt16] = []
        var tail: [UInt16] = []
        if split.count == 1 {
            guard let g = parseGroups(split[0]) else { return nil }
            head = g
        } else {
            guard let h = parseGroups(split[0]) else { return nil }
            guard let t = parseGroups(split[1]) else { return nil }
            head = h; tail = t
        }
        let total = head.count + tail.count
        if total > 8 { return nil }
        let zeros = [UInt16](repeating: 0, count: 8 - total)
        let full = head + zeros + tail
        guard full.count == 8 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for word in full {
            bytes.append(UInt8((word >> 8) & 0xFF))
            bytes.append(UInt8(word & 0xFF))
        }
        return bytes
    }

    /// Match a MAC against either a full MAC string (`aa:bb:cc:dd:ee:ff`),
    /// a 3-byte OUI prefix (`aa:bb:cc`), or a 6-hex no-separator OUI
    /// (`aabbcc`).
    static func macMatches(_ mac: MACAddress, rule: String) -> Bool {
        let r = rule.lowercased().replacingOccurrences(of: "-", with: ":")
        if r.contains(":") {
            let ruleBytes = r.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard ruleBytes.count == 3 || ruleBytes.count == 6 else { return false }
            if ruleBytes.count == 3 {
                return Array(mac.bytes.prefix(3)) == ruleBytes
            } else {
                return mac.bytes == ruleBytes
            }
        }
        // No separators: must be 6 (OUI) or 12 (full) hex chars.
        guard r.count == 6 || r.count == 12,
              r.allSatisfy({ $0.isHexDigit })
        else { return false }
        var bytes: [UInt8] = []
        var i = r.startIndex
        while i < r.endIndex {
            let next = r.index(i, offsetBy: 2)
            guard let b = UInt8(r[i..<next], radix: 16) else { return false }
            bytes.append(b)
            i = next
        }
        if bytes.count == 3 {
            return Array(mac.bytes.prefix(3)) == bytes
        }
        return mac.bytes == bytes
    }
}

// MARK: - Loader

extension EngagementScope {

    public static func loadFromFile(_ path: String) throws -> EngagementScope {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(EngagementScope.self, from: data)
    }

    public func encodeJSON(pretty: Bool = true) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if pretty { enc.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try enc.encode(self)
    }
}

private extension Character {
    var isHexDigit: Bool {
        ("0"..."9").contains(self) || ("a"..."f").contains(self) || ("A"..."F").contains(self)
    }
}
