import Foundation

/// Reads a saved Wi-Fi password from the macOS user/system Keychain.
///
/// macOS stores Wi-Fi PSKs as generic-password Keychain items keyed by
/// SSID. The first time a process tries to read one, the OS pops a
/// "<App> wants to access password X — Allow / Deny / Always Allow"
/// dialog. We shell out to `/usr/bin/security` because that binary is
/// stable and trusted; replicating the SecKeychain API in Swift is
/// possible but adds risk for no benefit on a UI surface that already
/// runs in the user's session.
///
/// The user's keychain holds passwords for networks they joined
/// themselves; the system keychain holds entries created by the
/// "Remember this network" flow on a prior macOS install. We try both.
public actor WiFiPasswordReader {

    public enum Failure: Error, LocalizedError {
        case notFound
        case denied              // user clicked Deny in the auth dialog
        case keychainLocked
        case other(String)

        public var errorDescription: String? {
            switch self {
            case .notFound:       "No saved password for this network."
            case .denied:         "Keychain access denied."
            case .keychainLocked: "Keychain is locked."
            case .other(let s):   s
            }
        }
    }

    public static let shared = WiFiPasswordReader()

    public init() {}

    /// Look up the saved PSK for `ssid`. Returns the cleartext password
    /// or throws a `Failure`. Call from a Task — this blocks on the
    /// keychain dialog if one appears.
    public func password(for ssid: String) async throws -> String {
        // First try the user keychain (default behaviour of `security`).
        if let p = try? runSecurity(ssid: ssid, system: false), !p.isEmpty {
            return p
        }
        // Fall back to the system keychain. Reading the system keychain
        // requires admin auth; the OS pops the appropriate prompt.
        if let p = try? runSecurity(ssid: ssid, system: true), !p.isEmpty {
            return p
        }
        throw Failure.notFound
    }

    private func runSecurity(ssid: String, system: Bool) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        var args = ["find-generic-password", "-ga", ssid, "-w"]
        if system {
            args.append("/Library/Keychains/System.keychain")
        }
        p.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        try p.run()
        p.waitUntilExit()

        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stdout = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if p.terminationStatus == 0, !stdout.isEmpty {
            return stdout
        }
        // Map common error strings.
        let s = (stdout + stderr).lowercased()
        if s.contains("user interaction is not allowed") { throw Failure.keychainLocked }
        if s.contains("user canceled") || s.contains("not allowed") {
            throw Failure.denied
        }
        if s.contains("could not be found") || s.contains("specified item could not be found") {
            throw Failure.notFound
        }
        throw Failure.other(stderr.isEmpty ? "exit \(p.terminationStatus)" : stderr)
    }
}
