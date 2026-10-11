import Foundation
import Security
import SystemConfiguration

/// The administrator-approved local install pins one exact app build. A bundle
/// identifier alone cannot authenticate an ad-hoc signed privileged client.
private struct HelperClientAuthorization {
    static let installedApp = URL(fileURLWithPath: "/Applications/Wifi Mancer.app", isDirectory: true)
    static let requirementPath = "/Library/PrivilegedHelperTools/com.wifimancer.client-requirement"

    let requirementText: String
    let requirement: SecRequirement

    static func load() -> Self? {
        for path in ["/Library", "/Library/PrivilegedHelperTools"] {
            var info = stat()
            guard lstat(path, &info) == 0,
                  info.st_uid == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o022 == 0 else { return nil }
        }
        let descriptor = open(requirementPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size < 256 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count == info.st_size,
              let text = String(bytes: bytes.prefix(count), encoding: .utf8),
              let policy = parse(text), policy.installedAppIsValid() else { return nil }
        return policy
    }

    static func parse(_ text: String) -> Self? {
        // Keep the administrator pin exact: no identifier-only rule or OR clause.
        guard text.range(of: #"\Acdhash H"[0-9a-f]{40}"\n?\z"#,
                         options: .regularExpression) != nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .newlines)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(trimmed as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        return Self(requirementText: trimmed, requirement: requirement)
    }

    func installedAppIsValid() -> Bool {
        guard Self.installedApp.resolvingSymlinksInPath().path == Self.installedApp.path else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Self.installedApp as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
    }

    func permits(_ connection: NSXPCConnection) -> Bool {
        var consoleUID: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil else { return false }
        return permits(pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier,
                       consoleUID: consoleUID)
    }

    func permits(pid: pid_t, uid: uid_t, consoleUID: uid_t) -> Bool {
        guard consoleUID != 0, consoleUID != uid_t.max, uid == consoleUID,
              pid > 0, installedAppIsValid() else { return false }
        var caller: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)]
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &caller) == errSecSuccess,
              let caller, SecCodeCheckValidity(caller, [], requirement) == errSecSuccess else { return false }
        var staticCaller: SecStaticCode?
        var path: CFURL?
        guard SecCodeCopyStaticCode(caller, [], &staticCaller) == errSecSuccess,
              let staticCaller,
              SecCodeCopyPath(staticCaller, [], &path) == errSecSuccess,
              let path, (path as URL).standardizedFileURL.path == Self.installedApp.path else { return false }
        return true
    }
}

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service = HelperService()
    private let authorization = HelperClientAuthorization.load()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard let authorization, authorization.permits(conn) else {
            Log.xpc.error("Rejected unauthenticated helper client pid=\(conn.processIdentifier) uid=\(conn.effectiveUserIdentifier)")
            return false
        }
        // Foundation uses the connection's internal audit identity and checks
        // every message. This also closes the PID-reuse/exec race of a PID check.
        conn.setCodeSigningRequirement(authorization.requirementText)
        let iface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedInterface = iface
        conn.exportedObject = service
        conn.remoteObjectInterface = NSXPCInterface(with: HelperEventReceiver.self)
        conn.invalidationHandler = { Log.xpc.info("client invalidated") }
        conn.interruptionHandler  = { Log.xpc.info("client interrupted") }
        conn.resume()
        return true
    }
}

Log.root.info("WifiMancerHelper starting (uid=\(getuid()))")

let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
let delegate = HelperListenerDelegate()
listener.delegate = delegate
listener.resume()

RunLoop.current.run()
