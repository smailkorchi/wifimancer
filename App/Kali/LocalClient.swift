import Foundation

/// Mirrors `KaliClient` but executes the command on the Mac itself.
///
/// Why we need it: the user's Kali sits on a different LAN than the
/// target devices the App scans (Mac LAN: 192.168.11.0/24, Kali:
/// 192.168.1.0/24). Tailscale links the two hosts but does not share
/// subnet routes by default — so a tool dispatched to Kali against an
/// IP on the Mac LAN times out. For tools that exist on both sides
/// (nmap, hydra, nikto, ffuf, whatweb, wpscan, smbclient,
/// searchsploit), running the recon-class probe on the Mac is faster
/// AND actually reaches the target. Tools that only exist on Kali
/// (responder, hashcat, eaphammer, hcxdumptool, reaver, …) still
/// dispatch via `KaliClient`.
public actor LocalClient {

    public static let shared = LocalClient()

    public init() {}

    /// Mirror of `KaliClient.wrapWithAutoInstall`. On the Mac we use
    /// Homebrew. We do NOT prefix with sudo because brew refuses to run
    /// as root. We also short-circuit with `command -v brew` — if brew
    /// isn't installed at all the message tells the user how to fix it.
    public static func wrapWithAutoInstall(_ command: String,
                                           tool: String,
                                           brewPackage: String?) -> String {
        guard let pkg = brewPackage, !pkg.isEmpty else { return command }
        // safeCmd is appended raw, NOT inside single quotes — so we
        // leave its single quotes alone. Only the install banner /
        // brew-install args get the standard `'\''` break-out, since
        // those literally sit inside single-quoted strings below.
        let safeCmd = command
        let safePkg = pkg.replacingOccurrences(of: "'", with: "'\\''")
        let safeTool = tool.replacingOccurrences(of: "'", with: "'\\''")
        return """
        if ! command -v '\(safeTool)' >/dev/null 2>&1; then \
          if ! command -v brew >/dev/null 2>&1; then \
            echo '[auto-install] Homebrew not found. Install: https://brew.sh' >&2; exit 127; \
          fi; \
          echo '[auto-install] \(safeTool) missing — running: brew install \(safePkg)' >&2; \
          brew install '\(safePkg)' >/dev/null 2>&1 || \
            { echo '[auto-install] FAILED — try manually: brew install \(safePkg)' >&2; exit 127; }; \
          echo '[auto-install] OK — \(safeTool) installed.' >&2; \
        fi; \
        \(safeCmd)
        """
    }

    public nonisolated func runStreaming(command: String,
                                         timeout: TimeInterval = 600.0)
        -> AsyncStream<KaliClient.StreamEvent> {

        AsyncStream { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-lc", command]   // login shell so PATH includes Homebrew
            let outPipe = Pipe()
            let errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe

            let splitter = LocalLineBuffer { line, isErr in
                continuation.yield(.line(line, isStderr: isErr))
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
                continuation.yield(.line("local launch failed: \(error.localizedDescription)",
                                         isStderr: true))
                continuation.yield(.exit(-1))
                continuation.finish()
                return
            }

            let watchdog = DispatchWorkItem {
                if p.isRunning {
                    continuation.yield(.line("[timeout exceeded — terminating]",
                                              isStderr: true))
                    p.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            DispatchQueue.global().async {
                p.waitUntilExit()
                watchdog.cancel()
                splitter.flush()
                continuation.yield(.exit(p.terminationStatus))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                if p.isRunning { p.terminate() }
            }
        }
    }
}

private final class LocalLineBuffer: @unchecked Sendable {
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
