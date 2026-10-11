import Foundation

/// Best-effort PSK candidates for unknown Wi-Fi networks based on
/// SSID / BSSID pattern matching.
///
/// We do NOT magic-retrieve passwords. What this provides:
///   - ISP / vendor detection from SSID prefix and BSSID OUI
///   - Default-PSK candidate list for the matched profile
///   - For ISPs whose default PSK is published / algorithmic, we
///     surface the highest-probability candidates first
///
/// This works only on networks where the operator never changed the
/// factory default. Modern ISPs ship unique random PSKs printed on
/// the router label, but a non-trivial percentage of small / SOHO
/// deployments still run defaults — that's the niche this hits.
///
/// For everything else, the right answer is "capture a handshake and
/// crack it offline" which lives in the Arsenal.
public struct WiFiPasswordRecovery {

    /// One candidate password to try, with a confidence score so the
    /// UI can sort and the auto-test loop can stop early on high
    /// confidence hits.
    public struct Candidate: Hashable, Identifiable {
        public var id: String { "\(label):\(password)" }
        public let label: String   // human-readable origin ("Orange France default", "ISP factory")
        public let password: String
        public let confidence: Confidence

        public enum Confidence: Int, Comparable {
            case low = 0       // generic guess — admin/admin etc.
            case medium = 1    // pattern-matched ISP, broad default list
            case high = 2      // ISP-specific factory default, derived from BSSID
            public static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }
        }
    }

    /// Detected ISP / vendor profile. Drives the candidate list AND
    /// gives the UI something to render so the operator knows WHY a
    /// given guess is reasonable.
    public struct Profile: Hashable {
        public let name: String
        public let region: String
        public let note: String
    }

    public struct Result: Hashable {
        public let profile: Profile?
        public let candidates: [Candidate]
        public let needsHandshakeCrack: Bool   // true when we have nothing high-confidence

        public var summary: String {
            if let p = profile {
                return "\(p.name) — \(p.region). \(p.note)"
            }
            return "No ISP/vendor pattern matched. Default-PSK calculators don't apply."
        }
    }

    /// Compute candidates for an SSID + optional BSSID.
    public static func candidates(ssid: String, bssid: String? = nil) -> Result {
        let s = ssid
        let lower = ssid.lowercased()
        let oui = (bssid ?? "").lowercased().prefix(8)  // "aa:bb:cc"

        // ============== Region: France (Orange / SFR / Free / Bouygues) ==============
        if matchesAny(lower, ["orange-", "livebox-", "livebox_"]) {
            return .init(
                profile: .init(
                    name: "Orange France (Livebox)",
                    region: "FR",
                    note: "Default WPA key is the second half of the WPS PIN, derived from BSSID. We surface the published guesses; for real recovery, capture WPS PIN via Pixie-dust."),
                candidates: orangeFranceCandidates(ssid: s),
                needsHandshakeCrack: false)
        }
        if matchesAny(lower, ["sfr_", "neufbox_", "sfr-"]) {
            return .init(
                profile: .init(
                    name: "SFR / Neuf France",
                    region: "FR",
                    note: "Default keys are 10 hex chars derived from box serial — not pre-computable. WPS Pixie-dust is the real path."),
                candidates: [
                    .init(label: "factory admin",  password: "0000",     confidence: .low),
                    .init(label: "factory admin",  password: "12345",    confidence: .low),
                ],
                needsHandshakeCrack: true)
        }
        if matchesAny(lower, ["freewifi", "free_", "freebox-"]) {
            return .init(
                profile: .init(
                    name: "Free / Freebox France",
                    region: "FR",
                    note: "Public hotspot or 8-char alphanumeric default. Hotspot SSIDs (FreeWifi) need a Free.fr account, not a PSK."),
                candidates: [
                    .init(label: "common default", password: "freebox12345", confidence: .low),
                ],
                needsHandshakeCrack: true)
        }
        if matchesAny(lower, ["bbox-", "bbox_", "bouygues"]) {
            return .init(
                profile: .init(
                    name: "Bouygues / BBOX France",
                    region: "FR",
                    note: "8-character alphanumeric default printed on box. Not algorithmically recoverable."),
                candidates: [],
                needsHandshakeCrack: true)
        }

        // ============== Region: Morocco (IAM / Inwi / Orange MA) ==============
        if matchesAny(lower, ["iam-", "iam_", "menara", "marocte", "wifi-iam"]) {
            return .init(
                profile: .init(
                    name: "Maroc Telecom (IAM)",
                    region: "MA",
                    note: "Default WPA2 key is 10 chars printed on the router. Not algorithmically recoverable. Try common admin defaults if user never changed it."),
                candidates: [
                    .init(label: "factory admin", password: "12345678",  confidence: .low),
                    .init(label: "factory admin", password: "00000000",  confidence: .low),
                ],
                needsHandshakeCrack: true)
        }
        if matchesAny(lower, ["inwi-", "wana-", "inwi_"]) {
            return .init(
                profile: .init(
                    name: "Inwi / Wana Maroc",
                    region: "MA",
                    note: "Default key is the last 8 chars of the BSSID (without colons), uppercase, in many models. Derived candidate first."),
                candidates: inwiCandidates(bssid: bssid),
                needsHandshakeCrack: false)
        }

        // ============== Region: UK ==============
        if matchesAny(lower, ["bthub", "bthomehub", "bt-"]) {
            return .init(
                profile: .init(
                    name: "BT Home Hub / Smart Hub",
                    region: "UK",
                    note: "Older BT Home Hub used 10-char alphanumeric derived from BSSID; newer Smart Hub randomises. Pre-2014 hubs are vulnerable."),
                candidates: btHomeHubCandidates(bssid: bssid),
                needsHandshakeCrack: false)
        }
        if matchesAny(lower, ["sky", "skyq", "skyguest"]) {
            return .init(
                profile: .init(
                    name: "Sky Hub UK",
                    region: "UK",
                    note: "Default PSK is 8 uppercase chars, alphanumeric, on label. Not derivable, but admin defaults often unchanged."),
                candidates: [
                    .init(label: "admin", password: "sky", confidence: .low),
                ],
                needsHandshakeCrack: true)
        }
        if matchesAny(lower, ["virginmedia", "virgin media", "vm5", "vm6", "vm7", "vm8"]) {
            return .init(
                profile: .init(
                    name: "Virgin Media UK (Hub)",
                    region: "UK",
                    note: "Default PSK is 8-12 mixed-case alphanumeric, no algorithmic recovery. Pre-2018 some Hub 3 models had a CVE-derivable default."),
                candidates: [],
                needsHandshakeCrack: true)
        }

        // ============== Region: Spain (Movistar / Vodafone / Jazztel) ==============
        if matchesAny(lower, ["movistar_", "movistar-", "telefonica"]) {
            return .init(
                profile: .init(
                    name: "Movistar / Telefónica",
                    region: "ES",
                    note: "Some older Comtrend / Mitrastar models had algorithmic defaults; newer models randomise. Try wpa-default-keygen tools."),
                candidates: [],
                needsHandshakeCrack: true)
        }
        if matchesAny(lower, ["vodafone-", "vodafone_"]) {
            return .init(
                profile: .init(
                    name: "Vodafone Station",
                    region: "Multi",
                    note: "Default PSK printed on label. No public algorithm. Real path = handshake + crack."),
                candidates: [],
                needsHandshakeCrack: true)
        }
        if matchesAny(lower, ["jazztel_"]) {
            return .init(
                profile: .init(name: "Jazztel ES", region: "ES",
                              note: "Pre-2017 Comtrend models had reversible defaults via published keygens."),
                candidates: [], needsHandshakeCrack: true)
        }

        // ============== Region: US / Generic ==============
        if matchesAny(lower, ["xfinitywifi", "comcast"]) {
            return .init(
                profile: .init(name: "Xfinity / Comcast", region: "US",
                              note: "XfinityWiFi is an open hotspot keyed off the user's Xfinity account, not a PSK."),
                candidates: [], needsHandshakeCrack: false)
        }
        if matchesAny(lower, ["spectrumsetup", "spectrum-"]) {
            return .init(
                profile: .init(name: "Spectrum US", region: "US",
                              note: "Setup SSIDs use 8-char password from sticker. No algorithm."),
                candidates: [], needsHandshakeCrack: true)
        }
        if matchesAny(lower, ["att-wifi-", "attwifi-", "att-"]) {
            return .init(
                profile: .init(name: "AT&T", region: "US",
                              note: "Default PSK is 12-char numeric on sticker. No algorithm."),
                candidates: [], needsHandshakeCrack: true)
        }

        // ============== Region: Germany ==============
        if matchesAny(lower, ["fritz!box", "fritzbox", "telekom_"]) {
            return .init(
                profile: .init(name: "Deutsche Telekom / Fritz!Box DE", region: "DE",
                              note: "Default 16-char numeric printed on box. AVM Fritz!OS uses random PSK from factory."),
                candidates: [], needsHandshakeCrack: true)
        }

        // ============== Region: India ==============
        if matchesAny(lower, ["airtel_", "jiofi", "act-", "bsnl"]) {
            return .init(
                profile: .init(name: "Indian ISP (Airtel / Jio / BSNL)", region: "IN",
                              note: "Default PSK is 8-10 chars on sticker. JioFi MiFi devices often have 'jio12345'."),
                candidates: [
                    .init(label: "JioFi default",     password: "jio12345",   confidence: .low),
                    .init(label: "Airtel default",    password: "airtel123",  confidence: .low),
                    .init(label: "BSNL default",      password: "12345678",   confidence: .low),
                ],
                needsHandshakeCrack: true)
        }

        // ============== Generic mobile-hotspot patterns ==============
        if matchesAny(lower, ["iphone", "android", "mobile", "hotspot"]) {
            return .init(
                profile: .init(name: "Personal Hotspot", region: "Multi",
                              note: "Phone hotspot — password is set by the phone owner. No defaults."),
                candidates: [], needsHandshakeCrack: false)
        }

        // ============== Routers in default mode ==============
        if matchesAny(lower, ["tplink_", "tp-link_", "tp-link "]) {
            return .init(
                profile: .init(name: "TP-Link factory default", region: "Multi",
                              note: "Some TP-Link routers ship with PSK = last 8 of MAC, uppercase. Otherwise printed on label."),
                candidates: tpLinkCandidates(bssid: bssid),
                needsHandshakeCrack: false)
        }
        if matchesAny(lower, ["dlink_", "dlink-", "d-link"]) {
            return .init(
                profile: .init(name: "D-Link factory", region: "Multi",
                              note: "Older D-Link models open or admin/admin admin web; PSK on label."),
                candidates: [], needsHandshakeCrack: true)
        }
        if matchesAny(lower, ["netgear", "ntgr_"]) {
            return .init(
                profile: .init(name: "Netgear factory", region: "Multi",
                              note: "Default PSK is 'genie<random>' or label-printed. Some models still ship 'password'."),
                candidates: [
                    .init(label: "very old default", password: "password", confidence: .low),
                ],
                needsHandshakeCrack: true)
        }

        // No match — generic fallback list (low confidence)
        return .init(
            profile: nil,
            candidates: genericFallback(),
            needsHandshakeCrack: true)
    }

    // MARK: - per-ISP candidate generators

    /// Orange France Livebox: the default PSK is the WPS PIN's hex
    /// representation in many firmware versions. We can't compute the
    /// PSK from BSSID alone without WPS pixie-dust, but we surface the
    /// most common operator-default fallbacks here.
    private static func orangeFranceCandidates(ssid: String) -> [Candidate] {
        var out: [Candidate] = []
        // The default key is normally printed as 8 uppercase hex chars
        // — without the keygen we can only suggest format-likely guesses.
        out += [
            .init(label: "Livebox factory admin", password: "admin",       confidence: .low),
            .init(label: "Livebox factory admin", password: "0000",        confidence: .low),
            .init(label: "common Livebox PSK",   password: "12345678",     confidence: .low),
            .init(label: "common Livebox PSK",   password: "0000000000",   confidence: .low),
        ]
        return out
    }

    /// Inwi / Wana defaults: many older models use PSK = last 8 hex
    /// chars of BSSID, uppercase, no separators.
    private static func inwiCandidates(bssid: String?) -> [Candidate] {
        guard let b = bssid else {
            return [.init(label: "needs BSSID for derivation", password: "—", confidence: .low)]
        }
        let hex = b.replacingOccurrences(of: ":", with: "")
                   .replacingOccurrences(of: "-", with: "")
                   .uppercased()
        guard hex.count >= 8 else { return [] }
        let last8  = String(hex.suffix(8))
        let last10 = String(hex.suffix(10))
        return [
            .init(label: "Inwi default — last 8 of BSSID", password: last8,  confidence: .high),
            .init(label: "Inwi default — last 10 of BSSID", password: last10, confidence: .medium),
            .init(label: "Inwi factory admin",              password: "admin", confidence: .low),
        ]
    }

    /// Pre-2015 BT Home Hub: published 10-char algorithm derived from
    /// BSSID. We implement the simplified "first 5 hex of BSSID maps
    /// to a 10-char ASCII default" pattern as a candidate — full
    /// implementation is the published BTHHRev1 keygen.
    private static func btHomeHubCandidates(bssid: String?) -> [Candidate] {
        guard let b = bssid else { return [] }
        let hex = b.replacingOccurrences(of: ":", with: "").uppercased()
        guard hex.count >= 6 else { return [] }
        // Lightweight candidate: BSSID-derived likely-pattern. Real
        // BTHH keygen is more complex; this surfaces a starting point.
        return [
            .init(label: "BTHH derived (rough)", password: String(hex.suffix(10)),
                  confidence: .medium),
        ]
    }

    /// TP-Link factory: many models ship PSK = last 8 of BSSID.
    private static func tpLinkCandidates(bssid: String?) -> [Candidate] {
        guard let b = bssid else { return [] }
        let hex = b.replacingOccurrences(of: ":", with: "").uppercased()
        guard hex.count >= 8 else { return [] }
        return [
            .init(label: "TP-Link last-8-of-BSSID", password: String(hex.suffix(8)),
                  confidence: .medium),
            .init(label: "TP-Link admin default",   password: "admin", confidence: .low),
        ]
    }

    /// Generic-fallback table: if nothing else matched, here's the set
    /// the user should still try because the Long Tail of cheap routers
    /// keeps shipping these.
    private static func genericFallback() -> [Candidate] {
        [
            .init(label: "ubiquitous default", password: "password",   confidence: .low),
            .init(label: "ubiquitous default", password: "12345678",   confidence: .low),
            .init(label: "ubiquitous default", password: "00000000",   confidence: .low),
            .init(label: "ubiquitous default", password: "11111111",   confidence: .low),
            .init(label: "ubiquitous default", password: "admin",      confidence: .low),
            .init(label: "ubiquitous default", password: "qwerty",     confidence: .low),
        ]
    }

    // MARK: - helpers

    private static func matchesAny(_ s: String, _ needles: [String]) -> Bool {
        for n in needles where s.contains(n) { return true }
        return false
    }
}
