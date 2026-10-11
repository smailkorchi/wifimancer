import Foundation
import Combine

/// Runtime state for the attack pad inside a `DeviceInspector`.
///
/// One instance per inspected device. Holds the live output of the most
/// recent dispatch, keeps a per-device history of completed runs, and
/// drives the streaming Task that pulls from `KaliClient.runStreaming`.
@MainActor
final class AttackPadModel: ObservableObject {

    struct OutputLine: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isStderr: Bool
        let timestamp: Date
    }

    struct CompletedRun: Identifiable, Equatable {
        let id = UUID()
        let attackID: String
        let attackTitle: String
        let exitCode: Int32
        let durationMs: Int
        let lineCount: Int
        let finishedAt: Date
    }

    enum Status: Equatable {
        case idle
        case running(attackID: String, since: Date)
        case finished(attackID: String, exitCode: Int32)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lines: [OutputLine] = []
    @Published private(set) var history: [CompletedRun] = []
    @Published private(set) var commandPreview: String = ""

    /// Currently selected attack for preview only — clicking "Run" then
    /// dispatches it. Null when nothing is selected.
    @Published var pendingAttack: Attack?

    /// Whether the user has acknowledged that they have authorization to
    /// run offensive actions in this session. Gates the run button. We
    /// intentionally store this in-memory only — there's no "trust this
    /// engagement permanently" path. The engagement scope file (last
    /// layer) replaces this checkbox once it's wired.
    @Published var attackAuthorized: Bool = false

    private var streamTask: Task<Void, Never>?

    // MARK: dispatch

    func selectAndPreview(_ attack: Attack, target: Device) {
        self.pendingAttack = attack
        self.commandPreview = expand(attack: attack, target: target)
    }

    func runPending(target: Device) {
        guard attackAuthorized else { return }
        guard let a = pendingAttack else { return }
        runImmediate(a, target: target)
    }

    func runImmediate(_ attack: Attack, target: Device) {
        guard attackAuthorized else { return }
        cancelCurrent()
        let cmd = expand(attack: attack, target: target)
        self.commandPreview = cmd

        // Decide where to dispatch. Same-LAN recon class runs locally on
        // the Mac because Kali can't route to those IPs. Kali-specific
        // tools always go remote regardless.
        let executor = chooseExecutor(for: attack, target: target)
        let executorTag = executor == .local ? "[LOCAL on Mac]" : "[KALI via tailscale]"
        self.lines = [
            OutputLine(text: "\(executorTag)  $ \(cmd)",
                       isStderr: false, timestamp: .now)
        ]
        let started = Date()
        self.status = .running(attackID: attack.id, since: started)

        let stream: AsyncStream<KaliClient.StreamEvent>
        switch executor {
        case .kali, .kaliRange:
            stream = KaliClient.shared.runStreaming(
                command: cmd, timeout: attack.timeoutSeconds)
        case .local:
            stream = LocalClient.shared.runStreaming(
                command: cmd, timeout: attack.timeoutSeconds)
        case .auto:
            stream = LocalClient.shared.runStreaming(
                command: cmd, timeout: attack.timeoutSeconds)
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
                        self.lines.append(OutputLine(text: s,
                                                     isStderr: isErr,
                                                     timestamp: .now))
                        // Cap so a runaway tool can't blow memory.
                        if self.lines.count > 4000 {
                            self.lines.removeFirst(self.lines.count - 4000)
                        }
                    }
                case .exit(let code):
                    let dur = Int(Date().timeIntervalSince(started) * 1000)
                    await MainActor.run {
                        guard let self else { return }
                        self.lines.append(OutputLine(
                            text: "[exit \(code) — \(dur) ms]",
                            isStderr: code != 0,
                            timestamp: .now
                        ))
                        self.history.insert(CompletedRun(
                            attackID: attack.id,
                            attackTitle: attack.title,
                            exitCode: code,
                            durationMs: dur,
                            lineCount: lineCount,
                            finishedAt: .now
                        ), at: 0)
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

    func clearOutput() {
        lines.removeAll()
        commandPreview = ""
        pendingAttack = nil
        status = .idle
    }

    // MARK: helpers

    private func expand(attack: Attack, target: Device) -> String {
        let ip = target.ipv4 ?? target.mac.description
        return attack.expanded(forIP: ip)
    }

    /// Pick the executor for this attack against this target. `.kali` and
    /// `.local` are honored as-is. `.auto` looks at whether the target IP
    /// belongs to the Mac's current LAN — same LAN → local, otherwise →
    /// Kali. Falls back to local if the SSID/subnet is unknown so the
    /// dispatch never silently picks an unreachable executor.
    private func chooseExecutor(for attack: Attack, target: Device) -> Attack.Executor {
        switch attack.executor {
        case .kali:       return .kali
        case .kaliRange:  return .kaliRange
        case .local: return .local
        case .auto:
            guard let ip = target.ipv4 else { return .local }
            // Heuristic: if first three octets of the target match the
            // first three octets of any Mac interface IP we know about,
            // it's the Mac LAN. We don't have full subnet here without
            // pulling from AppStore — this trims the MAC LAN case
            // without that dependency.
            let prefix = ip.split(separator: ".").prefix(3).joined(separator: ".")
            for iface in macIPv4Prefixes() where iface == prefix {
                return .local
            }
            return .kali
        }
    }

    /// Enumerate /24 prefixes for every up IPv4 interface on this Mac.
    /// Used by `.auto` executor selection. Pure POSIX `getifaddrs` so it
    /// works without elevated privileges.
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
