import Foundation

/// Dispatches one-shot commands to a remote Kali host over SSH and
/// streams their stdout back. Lives entirely on the App side; no
/// privileged helper involvement, no XPC.
///
/// The transport is plain `/usr/bin/ssh` driven by `Process`. We rely on
/// the operator already having `~/.ssh/config` and a key pair set up so
/// `ssh kali` works without a password — the app inherits the user's
/// agent + config because it runs in the user's session, not in a
/// sandbox. `BatchMode=yes` is forced so a misconfigured key never hangs
/// the UI on a password prompt.
///
/// We keep the process model dirt-simple on purpose: one `Process` per
/// attack invocation, two pipes (stdout, stderr), readability handlers
/// pushing decoded lines into an async stream the UI consumes. Attacks
/// that need a long-lived session (msfconsole, mitmproxy CLI) belong in
/// a tmux-driven path that doesn't exist yet — for now the catalog
/// avoids them.
public actor KaliClient {

    public static let shared = KaliClient()

    public struct Endpoint: Sendable, Equatable {
        public var host: String          // resolved by ssh config / Tailscale / DNS
        public var user: String?         // nil = whatever ssh_config dictates
        public init(host: String, user: String? = nil) {
            self.host = host; self.user = user
        }

        /// The string passed as the SSH target. `user@host` if user is set,
        /// otherwise just the host (lets ssh_config win).
        public var sshTarget: String {
            if let u = user { return "\(u)@\(host)" }
            return host
        }
    }

    public var endpoint: Endpoint = Endpoint(host: "kali")

    public func setEndpoint(_ e: Endpoint) { self.endpoint = e }

    // MARK: - Health probe

    public struct Health: Sendable, Equatable {
        public let reachable: Bool
        public let latencyMs: Int?
        public let kernel: String?
        public let banner: String?
    }

    /// One-shot reachability + tooling probe. ~3 s budget.
    public func ping() async -> Health {
        let target = endpoint.sshTarget
        let start = Date()
        let r = await runOneShot(
            command: "uname -srm; nmap --version 2>/dev/null | head -1",
            timeout: 5.0
        )
        let dt = Int(Date().timeIntervalSince(start) * 1000)
        guard r.exitCode == 0 else {
            return Health(reachable: false, latencyMs: nil, kernel: nil, banner: nil)
        }
        let lines = r.stdout.split(separator: "\n").map(String.init)
        return Health(
            reachable: true,
            latencyMs: dt,
            kernel: lines.first.map { $0.trimmingCharacters(in: .whitespaces) },
            banner: lines.dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) }
        )
        _ = target  // avoid 'unused' warning under strict mode
    }

    // MARK: - One-shot dispatch

    public struct RunResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let durationMs: Int
        public init(exitCode: Int32, stdout: String, stderr: String, durationMs: Int) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.durationMs = durationMs
        }
    }

    /// Run a remote command, collect both streams to completion.
    public func runOneShot(command: String,
                           timeout: TimeInterval = 60.0) async -> RunResult {
        let start = Date()
        let target = endpoint.sshTarget
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=15",
            target,
            command
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe
        do {
            try p.run()
        } catch {
            return RunResult(exitCode: -1, stdout: "",
                             stderr: "ssh launch failed: \(error.localizedDescription)",
                             durationMs: 0)
        }

        // Wait with timeout.
        let result = await Self.waitWithTimeout(process: p,
                                                outPipe: outPipe,
                                                errPipe: errPipe,
                                                timeout: timeout)
        let dt = Int(Date().timeIntervalSince(start) * 1000)
        return RunResult(exitCode: result.exit,
                         stdout: result.stdout,
                         stderr: result.stderr,
                         durationMs: dt)
    }

    private static func waitWithTimeout(process: Process,
                                        outPipe: Pipe,
                                        errPipe: Pipe,
                                        timeout: TimeInterval)
        async -> (exit: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { cont in
            let lock = NSLock()
            var finished = false
            let deadlineWork = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadlineWork)

            DispatchQueue.global().async {
                process.waitUntilExit()
                deadlineWork.cancel()
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                let out = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let err = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                cont.resume(returning: (
                    exit: process.terminationStatus,
                    stdout: String(data: out, encoding: .utf8) ?? "",
                    stderr: String(data: err, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    // MARK: - Streaming dispatch

    /// Run a remote command and emit its combined output line-by-line
    /// through an `AsyncStream`. The stream finishes when the process
    /// exits or the timeout elapses.
    public nonisolated func runStreaming(command: String,
                                         timeout: TimeInterval = 600.0)
        -> AsyncStream<StreamEvent> {

        AsyncStream { continuation in
            let target = self_endpoint_snapshot()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ServerAliveInterval=15",
                target,
                command
            ]
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            // Buffer-aware line splitter — pipes deliver arbitrary chunks,
            // we need clean lines so the UI can layout them as rows.
            let splitter = LineBuffer { line, isStderr in
                continuation.yield(.line(line, isStderr: isStderr))
            }

            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil; return }
                splitter.append(d, isStderr: false)
            }
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty { fh.readabilityHandler = nil; return }
                splitter.append(d, isStderr: true)
            }

            do {
                try p.run()
            } catch {
                continuation.yield(.line("ssh launch failed: \(error.localizedDescription)",
                                         isStderr: true))
                continuation.yield(.exit(-1))
                continuation.finish()
                return
            }

            // Timeout watchdog.
            let watchdog = DispatchWorkItem {
                if p.isRunning {
                    continuation.yield(.line("[timeout exceeded — terminating]",
                                              isStderr: true))
                    p.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            // Completion handler.
            DispatchQueue.global().async {
                p.waitUntilExit()
                watchdog.cancel()
                splitter.flush()
                continuation.yield(.exit(p.terminationStatus))
                continuation.finish()
            }

            // Cancellation.
            continuation.onTermination = { _ in
                if p.isRunning { p.terminate() }
            }
        }
    }

    /// Read endpoint snapshot from a non-isolated context. The endpoint
    /// rarely changes, and we accept stale reads on the streaming path.
    private nonisolated func self_endpoint_snapshot() -> String {
        // We can't `await` self.endpoint from a nonisolated function,
        // so we cache via UserDefaults at set-time instead. Default fallback
        // is "kali" which is the convention everywhere else in the app.
        UserDefaults.standard.string(forKey: "wm.kali.endpoint.host") ?? "kali"
    }

    public enum StreamEvent: Sendable {
        case line(String, isStderr: Bool)
        case exit(Int32)
    }

    /// Wrap a command so the remote shell installs the requested apt
    /// package on demand. The wrapper:
    ///   1. checks `which <tool>` — if found, runs the command as-is;
    ///   2. otherwise emits a banner line, then runs
    ///      `sudo -n apt-get -y install <pkg>` quietly, and runs the
    ///      command. `sudo -n` keeps it non-interactive so a missing
    ///      sudoers entry surfaces as an error instead of hanging.
    /// The banner line uses `>&2` so the UI marks it as the stderr
    /// stream and tints it. Composes safely with the existing pipelines
    /// because we wrap the user command in a subshell.
    public static func wrapWithAutoInstall(_ command: String,
                                           tool: String,
                                           aptPackage: String?) -> String {
        guard let pkg = aptPackage, !pkg.isEmpty else { return command }
        // safeCmd is appended raw, NOT inside single quotes — leave its
        // quotes alone. Only the install banner / apt-get arg get
        // single-quote break-out since those sit inside single quotes.
        let safeCmd = command
        let safePkg = pkg.replacingOccurrences(of: "'", with: "'\\''")
        let safeTool = tool.replacingOccurrences(of: "'", with: "'\\''")
        return """
        if ! command -v '\(safeTool)' >/dev/null 2>&1; then \
          echo '[auto-install] \(safeTool) missing — running: sudo apt-get install \(safePkg)' >&2; \
          sudo -n apt-get -y -q install '\(safePkg)' >/dev/null 2>&1 || \
            { echo '[auto-install] FAILED — sudo or network unavailable. Fix manually then retry.' >&2; exit 127; }; \
          echo '[auto-install] OK — \(safeTool) installed.' >&2; \
        fi; \
        \(safeCmd)
        """
    }

    /// Lock-free-ish chunk → line buffer. Append decoded chunks; emits
    /// complete lines through the callback.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var bufferOut = ""
        private var bufferErr = ""
        private let onLine: @Sendable (_ line: String, _ isStderr: Bool) -> Void

        init(onLine: @escaping @Sendable (_ line: String, _ isStderr: Bool) -> Void) {
            self.onLine = onLine
        }

        func append(_ data: Data, isStderr: Bool) {
            guard let s = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            if isStderr { bufferErr += s } else { bufferOut += s }
            // Move any complete lines out.
            func drain(_ buf: inout String, isErr: Bool) {
                while let nl = buf.firstIndex(of: "\n") {
                    let line = String(buf[..<nl])
                    buf.removeSubrange(buf.startIndex...nl)
                    onLine(line, isErr)
                }
            }
            drain(&bufferOut, isErr: false)
            drain(&bufferErr, isErr: true)
            lock.unlock()
        }

        func flush() {
            lock.lock()
            if !bufferOut.isEmpty { onLine(bufferOut, false); bufferOut = "" }
            if !bufferErr.isEmpty { onLine(bufferErr, true); bufferErr = "" }
            lock.unlock()
        }
    }
}

/// Persist the endpoint host so `runStreaming`'s nonisolated body can
/// read it without awaiting actor state. Called from `setEndpoint`.
@MainActor
public func wm_kali_persist_endpoint_host(_ host: String) {
    UserDefaults.standard.set(host, forKey: "wm.kali.endpoint.host")
}
