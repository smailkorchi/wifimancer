import Foundation
import Combine
import SwiftUI

/// Global state for the Arsenal page. Keeps the tool-first selection
/// model alive across tab switches so a long-running attack keeps
/// streaming while the user pokes around the rest of the app.
///
/// Composition vs the older per-inspector `AttackPadModel`: that model
/// is one-instance-per-device-row. This is one-instance-app-wide, owns
/// the `selectedAttack` + `selectedTarget` pairing, and the `runImmediate`
/// path is identical so existing dispatch / executor selection code is
/// reused.
@MainActor
final class ArsenalStore: ObservableObject {

    static let shared = ArsenalStore()

    // selection state
    @Published var selectedCategory: Attack.Category? = nil
    @Published var selectedSkill: Attack.Skill? = nil
    @Published var searchText: String = ""
    @Published var selectedAttack: Attack? = nil
    @Published var selectedTarget: Device? = nil
    /// Wireless target — used by attacks in `.wireless` category whose
    /// commands consume `{bssid}` / `{essid}` / `{channel}` placeholders
    /// instead of `{ip}`. Set this when the operator picks a network in
    /// the Wi-Fi target chips, OR when the Recovery sheet hands off to
    /// the Arsenal with a specific SSID in mind.
    @Published var selectedWiFi: WiFiNetwork? = nil
    @Published var attackAuthorized: Bool = false

    // MARK: - Kali-in-range state

    public enum RangeState: Equatable {
        case unknown
        case probing
        case inRange(iface: String, visible: [String])
        case notInRange(reason: String)
    }
    @Published private(set) var kaliRangeState: RangeState = .unknown
    @Published var kaliRangeConfirmed: Bool = false

    /// Whether the attack-detail sheet is open. Drives the modal layer
    /// in `ArsenalView`. Selecting an attack flips this true.
    @Published var detailOpen: Bool = false

    /// User-picked audio file for media attacks. Persisted to
    /// UserDefaults so the choice survives app restart. The detail
    /// sheet renders a SwiftUI `fileImporter` to set this when the
    /// selected attack has `requiresAudioFile == true`.
    @Published var audioFileURL: URL? = ArsenalStore.loadAudioURL() {
        didSet {
            Self.persistAudioURL(audioFileURL)
            if let attack = selectedAttack, attack.requiresAudioFile,
               let target = selectedTarget {
                commandPreview = expand(attack: attack, target: target)
            }
        }
    }

    // run state
    @Published private(set) var status: AttackPadModel.Status = .idle
    @Published private(set) var lines: [AttackPadModel.OutputLine] = []
    @Published private(set) var history: [AttackPadModel.CompletedRun] = []
    @Published private(set) var commandPreview: String = ""

    /// Coarse-grained phase string for the loader UI. Updated from
    /// output line tags `[PROBE]`, `[TRY]`, `[HIT]`, `[RESULT]`,
    /// `[serving]`, `[done]` so the user sees what stage the attack
    /// is in without reading raw stdout.
    @Published private(set) var phase: String = ""

    private var streamTask: Task<Void, Never>?

    init() {}

    // MARK: - audio file persistence

    private static let audioURLDefaultsKey = "wm.arsenal.audioFileURL"
    private static func loadAudioURL() -> URL? {
        guard let s = UserDefaults.standard.string(forKey: audioURLDefaultsKey),
              !s.isEmpty else { return nil }
        let url = URL(fileURLWithPath: s)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private static func persistAudioURL(_ u: URL?) {
        if let u { UserDefaults.standard.set(u.path, forKey: audioURLDefaultsKey) }
        else      { UserDefaults.standard.removeObject(forKey: audioURLDefaultsKey) }
    }

    /// Called from DeviceInspector / DeviceRowCard when the user clicks
    /// "Open in Arsenal". Sets the target without changing the selected
    /// tool (so the operator can keep their workflow if they were
    /// shopping for a tool already).
    func setTarget(_ device: Device) {
        self.selectedTarget = device
    }

    /// Wireless-category attacks consume a Wi-Fi network as the target,
    /// not a LAN device. Recovery sheet calls this before tab-switching
    /// so the Arsenal opens already pinned to the right network.
    func setWiFiTarget(_ net: WiFiNetwork) {
        self.selectedWiFi = net
        if let a = selectedAttack {
            self.commandPreview = expandWireless(attack: a, network: net)
        }
    }

    /// Selecting an attack also recomputes the command preview against
    /// the current target. If no target is set yet we leave the preview
    /// blank — the right column shows a "pick a target" prompt. Also
    /// flips `detailOpen` so the sheet appears.
    func selectAttack(_ attack: Attack) {
        self.selectedAttack = attack
        self.detailOpen = true
        // Reset run state so the sheet opens fresh, not on stale output.
        self.lines.removeAll()
        if case .running = self.status {} else { self.status = .idle }
        self.phase = ""
        // Wireless-category attacks pre-render against the wireless
        // target, everything else uses the LAN device target.
        if attack.category == .wireless {
            if let n = selectedWiFi {
                self.commandPreview = expandWireless(attack: attack, network: n)
            } else {
                self.commandPreview = attack.command
            }
        } else {
            if let t = selectedTarget {
                self.commandPreview = expand(attack: attack, target: t)
            } else {
                self.commandPreview = attack.command
            }
        }
    }

    func dismissDetail() {
        self.detailOpen = false
        cancelCurrent()
    }

    func setSelectedTargetAndPreview(_ device: Device) {
        self.selectedTarget = device
        if let a = selectedAttack {
            self.commandPreview = expand(attack: a, target: device)
        }
    }

    func filteredAttacks() -> [Attack] {
        var list = AttackCatalog.all
        if let cat = selectedCategory {
            list = list.filter { $0.category == cat }
        }
        if let skill = selectedSkill {
            list = list.filter { $0.skill == skill }
        }
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.title.lowercased().contains(q) ||
                $0.description.lowercased().contains(q) ||
                $0.tool.lowercased().contains(q) ||
                $0.id.lowercased().contains(q) ||
                $0.explainer.lowercased().contains(q)
            }
        }
        return list.sorted {
            if $0.category != $1.category { return $0.category.rawValue < $1.category.rawValue }
            if $0.tier != $1.tier { return $0.tier.sortKey < $1.tier.sortKey }
            return $0.title < $1.title
        }
    }

    /// Audio receivers are discovered by protocol; the device glyph is
    /// only a heuristic and can classify Samsung TVs as phones.
    func compatibleTargets(from devices: [Device]) -> [Device] {
        guard let a = selectedAttack else { return [] }
        return devices.filter {
            if a.requiresAudioFile {
                return $0.ipv4 != nil && !$0.isGateway && !$0.isSelf
            }
            return a.appliesTo.contains($0.kind)
        }
            .sorted { ($0.displayName) < ($1.displayName) }
    }

    // MARK: - dispatch

    func runSelected() {
        guard attackAuthorized else { return }
        guard let attack = selectedAttack else { return }
        cancelCurrent()
        // Branch on category — wireless attacks need a Wi-Fi network,
        // everything else needs a LAN device.
        var userCmd: String
        if attack.category == .wireless {
            guard let net = selectedWiFi else { return }
            userCmd = expandWireless(attack: attack, network: net)
        } else {
            guard let target = selectedTarget else { return }
            userCmd = expand(attack: attack, target: target)
        }
        // Wireless attacks always go to Kali (macOS Tahoe lost
        // monitor mode / airport tooling). Other attacks pass through
        // the normal LAN-locality executor selection.
        let executor: Attack.Executor = {
            if attack.executor == .kaliRange { return .kaliRange }
            if attack.category == .wireless  { return .kali }
            if let t = selectedTarget {
                return chooseExecutor(for: attack, target: t)
            }
            return attack.executor
        }()
        let wrapped: String
        switch executor {
        case .kali, .kaliRange:
            wrapped = KaliClient.wrapWithAutoInstall(
                userCmd, tool: attack.tool, aptPackage: attack.aptPackage)
        case .local:
            wrapped = LocalClient.wrapWithAutoInstall(
                userCmd, tool: attack.tool, brewPackage: attack.brewPackage)
        case .auto:
            wrapped = userCmd
        }
        self.commandPreview = userCmd

        let executorTag: String = {
            switch executor {
            case .local:     "[LOCAL on Mac]"
            case .kaliRange: "[KALI in RF-range]"
            default:         "[KALI via tailscale]"
            }
        }()
        self.lines = [
            .init(text: "\(executorTag)  $ \(userCmd)",
                  isStderr: false, timestamp: .now)
        ]
        let started = Date()
        self.status = .running(attackID: attack.id, since: started)

        let stream: AsyncStream<KaliClient.StreamEvent>
        switch executor {
        case .kali, .kaliRange:
            stream = KaliClient.shared.runStreaming(
                command: wrapped, timeout: attack.timeoutSeconds + 30)
        case .local:
            stream = LocalClient.shared.runStreaming(
                command: wrapped, timeout: attack.timeoutSeconds + 30)
        case .auto:
            stream = LocalClient.shared.runStreaming(
                command: wrapped, timeout: attack.timeoutSeconds + 30)
        }

        streamTask = Task { [weak self] in
            var lineCount = 0
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .line(let s, let isErr):
                    lineCount += 1
                    await MainActor.run {
                        guard let self else { return }
                        self.lines.append(.init(text: s, isStderr: isErr, timestamp: .now))
                        if self.lines.count > 6000 {
                            self.lines.removeFirst(self.lines.count - 6000)
                        }
                        // Update the phase string from tagged output.
                        // Catalog scripts emit `[PROBE]`, `[TRY]`,
                        // `[HIT]`, `[RESULT]`, `[serving]`, `[done]`,
                        // `[1/2]`, `[2/2]`, `[fallback]`, etc. Mapping
                        // is best-effort — unknown tags fall through.
                        if let p = Self.parsePhase(s) { self.phase = p }
                    }
                case .exit(let code):
                    let dur = Int(Date().timeIntervalSince(started) * 1000)
                    await MainActor.run {
                        guard let self else { return }
                        self.lines.append(.init(
                            text: "[exit \(code) — \(dur) ms]",
                            isStderr: code != 0, timestamp: .now))
                        self.history.insert(.init(
                            attackID: attack.id, attackTitle: attack.title,
                            exitCode: code, durationMs: dur,
                            lineCount: lineCount, finishedAt: .now), at: 0)
                        self.status = .finished(attackID: attack.id, exitCode: code)
                    }
                }
            }
        }
    }

    func cancelCurrent() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Best-effort phase classifier for the loader UI. Returns a short
    /// human label, or nil if the line doesn't contain a recognized
    /// stage tag. The catalog scripts emit standard prefixes; new
    /// attacks should reuse them.
    private static func parsePhase(_ s: String) -> String? {
        let t = s.lowercased()
        if t.contains("[probe]")    { return "Probing target" }
        if t.contains("[try]")      { return "Trying \(s.split(separator: "]").last?.trimmingCharacters(in: .whitespaces) ?? "")" }
        if t.contains("[hit]")      { return "Got it — \(s.split(separator: "]").last?.trimmingCharacters(in: .whitespaces) ?? "")" }
        if t.contains("[accepted]") { return "Playback command accepted" }
        if t.contains("[fetch]")    { return "TV fetching audio" }
        if t.contains("[playing]")  { return "TV reports playback" }
        if t.contains("[delivered]") { return "Audio delivered" }
        if t.contains("[cancelled]") { return "Cancelled" }
        if t.contains("[miss]")     { return "Miss — falling back" }
        if t.contains("[result]")   { return "Done" }
        if t.contains("[serving]")  { return "Hosting media" }
        if t.contains("[1/2]")      { return "SetAVTransportURI" }
        if t.contains("[2/2]")      { return "Play" }
        if t.contains("[fallback]") { return "Fallback control URL" }
        if t.contains("[auto-install]") { return "Installing tooling" }
        if t.contains("[err]") || t.contains("[error]") || t.contains("[!!") { return "Error" }
        if t.contains("[done]")     { return "Done" }
        return nil
    }

    func clearOutput() {
        lines.removeAll()
        if case .running = status {} else { status = .idle }
    }

    // MARK: - Kali range probe

    func probeKaliRange() {
        guard kaliRangeState != .probing else { return }
        kaliRangeState = .probing
        Task { [weak self] in
            let report = await KaliRangeProbe.shared.probe()
            await MainActor.run {
                guard let self else { return }
                if !report.kaliReachable {
                    self.kaliRangeState = .notInRange(
                        reason: report.rawError ?? "Kali unreachable via SSH")
                    return
                }
                guard let iface = report.interface else {
                    self.kaliRangeState = .notInRange(
                        reason: "Kali has no wireless interface")
                    return
                }
                let bssids = report.visible.map { $0.bssid }
                self.kaliRangeState = .inRange(iface: iface, visible: bssids)
                // Auto-confirm if Kali sees the selected Wi-Fi target.
                if let target = self.selectedWiFi,
                   let b = target.bssid,
                   report.sees(bssid: b) != nil {
                    self.kaliRangeConfirmed = true
                }
            }
        }
    }

    func kaliRangeSees(bssid: String?) -> Bool {
        guard let b = bssid else { return false }
        if case .inRange(_, let vis) = kaliRangeState {
            return vis.contains { $0.lowercased() == b.lowercased() }
        }
        return false
    }

    // MARK: - helpers

    private func expand(attack: Attack, target: Device) -> String {
        let ip = target.ipv4 ?? target.mac.description
        if attack.requiresAudioFile {
            let protocolName: String
            switch attack.id {
            case "media.airplay.localfile": protocolName = "airplay"
            case "media.dlna.push": protocolName = "dlna"
            default: protocolName = "auto"
            }
            let file = audioFileURL ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/faaah.mp3")
            return MediaAudioCommand.make(
                script: Bundle.main.url(forResource: "audio_push", withExtension: "py"),
                target: ip, file: file, protocolName: protocolName)
        }
        return attack.expanded(forIP: ip,
                               essid: target.displayName,
                               name: target.displayName)
    }

    /// Expand placeholders for wireless-category attacks. The "ip"
    /// slot gets the BSSID (since wireless commands often want a MAC
    /// where a non-wireless command wants an IP), and `{essid}` /
    /// `{bssid}` / `{channel}` get the real values.
    private func expandWireless(attack: Attack, network: WiFiNetwork) -> String {
        let bssid = network.bssid ?? "00:00:00:00:00:00"
        return attack.expanded(forIP: bssid,
                               essid: network.ssid,
                               bssid: bssid,
                               channel: network.channel,
                               name: network.ssid)
    }

    private func chooseExecutor(for attack: Attack, target: Device) -> Attack.Executor {
        switch attack.executor {
        case .kali:       return .kali
        case .kaliRange:  return .kaliRange
        case .local:      return .local
        case .auto:
            guard let ip = target.ipv4 else { return .local }
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            for iface in macIPv4Prefixes() where iface == prefix {
                return .local
            }
            return .kali
        }
    }

    private func macIPv4Prefixes() -> Set<String> {
        var prefixes: Set<String> = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            if let sa = cur.pointee.ifa_addr,
               sa.pointee.sa_family == sa_family_t(AF_INET) {
                let saIn = UnsafeRawPointer(sa).assumingMemoryBound(to: sockaddr_in.self)
                var addr = saIn.pointee.sin_addr
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count)) != nil {
                    let ip = String(cString: buf)
                    if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                        let pref = ip.split(separator: ".").prefix(3).joined(separator: ".")
                        prefixes.insert(pref)
                    }
                }
            }
            p = cur.pointee.ifa_next
        }
        return prefixes
    }
}
