import Foundation

/// One offensive (or playful, or instructive) action the operator can
/// dispatch from the device inspector. The action is a recipe — title,
/// description, the shell command, where it runs, the device classes
/// it's appropriate for, plus a learning track: explainer in one
/// sentence, a danger level, a noise level, and follow-up suggestions.
///
/// Each `command` template uses `{ip}` / `{port}` / `{essid}` / `{user}`
/// placeholders that get expanded at dispatch time against the target.
public struct Attack: Identifiable, Hashable, Sendable {
    public enum Tier: String, Sendable, Hashable {
        case quick    // < 30 s — version probe, default-cred check, banner grab
        case heavy    // 30 s – 5 min — NSE vuln scripts, nikto, gobuster
        case slow     // 5 min+ — sqlmap, hydra full sweep, hashcat
    }

    public enum Category: String, CaseIterable, Sendable, Hashable {
        case recon, web, smb, ssh, camera, router, ad, wireless, media, password
        case printer, iot, dns, bluetooth, mobile, mitm, exploit
    }

    /// Difficulty band so the UI can filter the catalog for learners.
    /// `beginner`  — safe, copy-paste-ready, well documented.
    /// `intermediate` — needs reading the explainer to get the value.
    /// `advanced`  — assumes prior recon, manual cred handling, or chained tools.
    public enum Skill: String, Sendable, Hashable {
        case beginner, intermediate, advanced
        public var label: String {
            switch self {
            case .beginner:    "BEGINNER"
            case .intermediate:"INTERMEDIATE"
            case .advanced:    "ADVANCED"
            }
        }
    }

    /// Where the command runs.
    /// - `kali`: regular Kali via Tailscale SSH. Tool is on the box, no
    ///   RF requirement.
    /// - `local`: this Mac runs the command directly.
    /// - `auto`: pick `local` if the LAN target is on the Mac's subnet,
    ///   `kali` otherwise.
    /// - `kaliRange`: Kali via SSH AND the radio sitting on Kali must be
    ///   in physical RF range of the target. The wireless ultimates
    ///   (handshake capture, PMKID, WPS pixie-dust, evil-twin, deauth
    ///   storm) only work in this mode. We pre-flight via `iw dev scan`
    ///   to confirm the BSSID is audible before dispatching.
    public enum Executor: String, Sendable, Hashable {
        case kali
        case kaliRange
        case local
        case auto
    }

    /// How much the action perturbs the target.
    /// - `passive` — observe only, no probes the target sees.
    /// - `observation` — sends benign packets, target may log.
    /// - `intrusive` — auth attempts, fuzzing, NSE scripts.
    /// - `destructive` — can change state on target (factory-reset
    ///   button, RTSP playback, deauth flooding). Always require
    ///   explicit operator authorization before running.
    public enum Danger: String, Sendable, Hashable {
        case passive, observation, intrusive, destructive
    }

    /// How loud the action looks on the wire / IDS.
    public enum Noise: String, Sendable, Hashable {
        case silent       // no probes
        case quiet        // single-target, low-rate
        case loud         // brute / fuzz / scan-all-ports
        case veryLoud     // mass scan, broadcast deauth, rogue AP
    }

    public let id: String
    public let title: String
    public let description: String
    public let explainer: String          // one paragraph — for the learning panel
    public let nextSteps: [String]        // 1-3 follow-on actions to suggest
    public let tool: String
    public let command: String
    public let timeoutSeconds: TimeInterval
    public let tier: Tier
    public let category: Category
    public let executor: Executor
    public let danger: Danger
    public let noise: Noise
    public let appliesTo: Set<DeviceKind>
    public let skill: Skill
    /// apt package name to install on Kali if `tool` is missing. Drives
    /// the auto-install pre-flight wrapper. nil means "tool ships with Kali
    /// base image, never auto-install" or "runs locally on the Mac and is
    /// expected to be a Homebrew formula."
    public let aptPackage: String?
    /// Homebrew formula name for local execution. Only used when executor
    /// resolves to `.local` and `which {tool}` returns nothing.
    public let brewPackage: String?
    /// True when the attack streams a user-chosen audio file. The UI
    /// shows a file-picker for these; dispatch passes the picked path
    /// as a quoted argument to the bundled audio runner.
    public let requiresAudioFile: Bool

    public init(id: String,
                title: String,
                description: String,
                explainer: String = "",
                nextSteps: [String] = [],
                tool: String,
                command: String,
                timeoutSeconds: TimeInterval = 60,
                tier: Tier,
                category: Category,
                executor: Executor = .auto,
                danger: Danger = .observation,
                noise: Noise = .quiet,
                appliesTo: Set<DeviceKind>,
                skill: Skill = .beginner,
                aptPackage: String? = nil,
                brewPackage: String? = nil,
                requiresAudioFile: Bool = false) {
        self.id = id; self.title = title; self.description = description
        self.explainer = explainer; self.nextSteps = nextSteps
        self.tool = tool; self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.tier = tier; self.category = category
        self.executor = executor
        self.danger = danger; self.noise = noise
        self.appliesTo = appliesTo
        self.skill = skill
        self.aptPackage = aptPackage
        self.brewPackage = brewPackage
        self.requiresAudioFile = requiresAudioFile
    }

    /// Expand `{ip}` / `{ipv4}` / `{port}` / `{essid}` / `{bssid}` /
    /// `{channel}` / `{name}` placeholders against a concrete target.
    /// Empty replacements pass through as the placeholder so a wrongly
    /// typed command surfaces rather than silently lying.
    public func expanded(forIP ip: String,
                         port: Int? = nil,
                         essid: String? = nil,
                         bssid: String? = nil,
                         channel: Int? = nil,
                         name: String? = nil) -> String {
        var s = command
        s = s.replacingOccurrences(of: "{ip}", with: ip)
        s = s.replacingOccurrences(of: "{ipv4}", with: ip)
        if let p = port    { s = s.replacingOccurrences(of: "{port}", with: "\(p)") }
        if let e = essid   { s = s.replacingOccurrences(of: "{essid}", with: e) }
        if let b = bssid   { s = s.replacingOccurrences(of: "{bssid}", with: b) }
        if let c = channel { s = s.replacingOccurrences(of: "{channel}", with: "\(c)") }
        if let n = name    { s = s.replacingOccurrences(of: "{name}", with: n) }
        return s
    }
}

extension Attack.Tier {
    var sortKey: Int {
        switch self { case .quick: 0; case .heavy: 1; case .slow: 2 }
    }
    var label: String {
        switch self { case .quick: "QUICK"; case .heavy: "HEAVY"; case .slow: "SLOW" }
    }
}

extension Attack.Danger {
    var label: String {
        switch self {
        case .passive:    "PASSIVE"
        case .observation: "OBSERVE"
        case .intrusive:  "INTRUSIVE"
        case .destructive: "CHANGES STATE"
        }
    }
}

extension Attack.Noise {
    var label: String {
        switch self {
        case .silent:    "SILENT"
        case .quiet:     "QUIET"
        case .loud:      "LOUD"
        case .veryLoud:  "VERY LOUD"
        }
    }
}

extension DeviceKind {
    static var allTargetable: [DeviceKind] {
        [.router, .laptop, .desktop, .applish, .iphone, .ipad, .watch, .audio,
         .phone, .tv, .speaker, .mediaReceiver, .camera, .printer, .gamingConsole, .iot,
         .light, .sensor, .unknown]
    }
}
