import Foundation

enum MediaAudioCommand {
    static func make(script: URL?, target: String, file: URL, protocolName: String) -> String {
        guard let script else {
            return "printf '%s\\n' '[err] Bundled audio runner is missing.' >&2; exit 1"
        }
        return "exec python3 \(quote(script.path)) --target \(quote(target)) --file \(quote(file.path)) --protocol \(quote(protocolName))"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
