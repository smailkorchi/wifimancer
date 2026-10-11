@main
private struct ClientAuthenticationTests {
    static func signatureHash(_ url: URL) throws -> String {
        var code: SecStaticCode?
        precondition(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
        var info: CFDictionary?
        precondition(SecCodeCopySigningInformation(code!, [], &info) == errSecSuccess)
        let hash = (info! as NSDictionary)[kSecCodeInfoUnique] as! Data
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func main() throws {
        let installed = HelperClientAuthorization.installedApp
        let installedHash = try signatureHash(installed)
        let valid = "cdhash H\"\(installedHash)\""
        let policy = HelperClientAuthorization.parse(valid)!
        precondition(policy.installedAppIsValid())
        precondition(HelperClientAuthorization.parse(valid + "\n") != nil)
        for malformed in ["identifier \"com.wifimancer.app\"", valid + " or true", "true",
                          "designated => " + valid, valid + "\n\n", valid + "\ntrue",
                          "cdhash H\"\(String(repeating: "0", count: 39))\"", valid + "\0"] {
            precondition(HelperClientAuthorization.parse(malformed) == nil)
        }
        let wrongHash = installedHash == String(repeating: "0", count: 40)
            ? String(repeating: "1", count: 40) : String(repeating: "0", count: 40)
        precondition(HelperClientAuthorization.parse("cdhash H\"\(wrongHash)\"")?.installedAppIsValid() == false)
        precondition(!policy.permits(pid: getpid(), uid: getuid(), consoleUID: 0))
        precondition(!policy.permits(pid: getpid(), uid: 502, consoleUID: 501))
        precondition(!policy.permits(pid: 0, uid: 501, consoleUID: 501))
        // A separately signed program running as the same user must fail.
        precondition(!policy.permits(pid: getpid(), uid: getuid(), consoleUID: getuid()))
        print("Client authentication passed: exact CDHash, installed signature, malformed/identifier-only rules, wrong binary, wrong user, and non-app caller rejected")
    }
}
