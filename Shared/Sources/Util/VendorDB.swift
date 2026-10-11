import Foundation

/// IEEE OUI lookup. Loads compact CSV from `Resources/Data/oui.csv`.
/// Format: `AABBCC,Vendor Name`
public final class VendorDB {

    public static let shared = VendorDB()

    private let map: [String: String]

    private init() {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "csv"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            self.map = [:]; return
        }
        var m: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: ",", maxSplits: 1)
            guard parts.count == 2 else { continue }
            m[String(parts[0]).uppercased()] = String(parts[1])
        }
        self.map = m
    }

    public func vendor(for mac: MACAddress) -> String? {
        guard !mac.isLocallyAdministered, !mac.isMulticast else { return nil }
        let oui = mac.bytes.prefix(3).map { String(format: "%02X", $0) }.joined()
        return map[oui]
    }
}
