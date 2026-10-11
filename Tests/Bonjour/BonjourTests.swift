import Foundation

@main
struct BonjourTests {
    @MainActor
    static func main() {
        let time = Date(timeIntervalSince1970: 1_000)
        func identify(_ type: String, _ name: String, _ values: [String: String], at: Date? = nil) -> DeviceIdentification {
            MDNSAppEnricher.identification(serviceType: type, instanceName: name,
                txt: values.mapValues { Data($0.utf8) }, observedAt: at ?? time)
        }
        func observation(_ id: String, _ value: DeviceIdentification, ip: String = "192.168.1.3") -> MDNSAppEnricher.Observation {
            .init(identity: id, addresses: [ip], identification: value)
        }
        var checked = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checked += 1
        }

        let cast = identify("_googlecast._tcp.", "DU7000-opaque-id", ["fn": "Living Room TV", "md": "DU7000"])
        expect(cast.friendlyName == "Living Room TV" && cast.modelName == "DU7000", "Cast fn/md are explicit identity fields")
        expect(cast.deviceType == "MediaReceiver", "Cast alone does not prove television form factor")
        let airplay = identify("_airplay._tcp.", "Bedroom", ["model": "AppleTV14,1", "am": "ignored", "manufacturer": "Apple"])
        expect(airplay.modelName == "AppleTV14,1" && airplay.manufacturer == "Apple", "AirPlay model/manufacturer survive")
        let raop = identify("_raop._tcp.", "AABBCCDDEEFF@Kitchen", ["am": "AudioAccessory5,1"])
        expect(raop.friendlyName == "Kitchen" && raop.modelName == "AudioAccessory5,1", "RAOP transport MAC prefix is removed")
        expect(identify("_raop._tcp.", "Jane@Home", [:]).friendlyName == "Jane@Home", "Only a real RAOP MAC prefix is removed")
        let printer = identify("_ipps._tcp.", "Office", ["ty": "Fallback", "product": "(Generic)", "usb_MFG": "Brother", "usb_MDL": "HL-L2350DW"])
        expect(printer.manufacturer == "Brother" && printer.modelName == "HL-L2350DW" && printer.deviceType == "Printer", "Printer USB identity overrides generic product")
        expect(identify("_ipp._tcp.", "Office", ["product": "(LaserJet)"]).modelName == "LaserJet", "Printer product parentheses are removed")
        expect(identify("_ipp._tcp.", "Office", ["product": "()", "ty": "DeskJet"]).modelName == "DeskJet", "Empty product falls back to ty")
        expect(identify("_hap._tcp.", "Desk lamp", ["md": "LCA001"]).modelName == "LCA001", "HomeKit model is retained")
        expect(identify("_http._tcp.", "admin", [:]).deviceType == nil, "Generic HTTP is not a phone or computer")
        let malformed = MDNSAppEnricher.identification(serviceType: "_airplay._tcp.", instanceName: "  Room\nTV  ",
            txt: ["model": Data([0xff, 0xfe]), "manufacturer": Data(repeating: 65, count: 513)], observedAt: time)
        expect(malformed.modelName == nil && malformed.manufacturer == nil && malformed.friendlyName == "RoomTV", "Invalid/oversized TXT cannot pollute display")

        let generic = identify("_http._tcp.", "opaque-admin-name", [:], at: time.addingTimeInterval(10))
        let entries = [observation("cast", cast), observation("web", generic)]
        let merged = MDNSAppEnricher.records(from: entries, now: time.addingTimeInterval(20))["192.168.1.3"]!
        let reversed = MDNSAppEnricher.records(from: entries.reversed(), now: time.addingTimeInterval(20))["192.168.1.3"]!
        expect(merged == reversed && merged.prettyName == "Living Room TV", "Name precedence is independent of arrival order")
        expect(merged.modelIdentifier == "DU7000" && merged.serviceTypes == ["_googlecast._tcp.", "_http._tcp."], "Compatibility accessors include all services")
        expect(merged.observedAt == generic.observedAt && merged.identification.observedAt == generic.observedAt, "Freshness is actual latest resolution, never aggregate time")
        let again = MDNSAppEnricher.records(from: entries, now: time.addingTimeInterval(100))["192.168.1.3"]!
        expect(again.observedAt == merged.observedAt, "Rebuilding cache cannot extend observation age")
        let removed = MDNSAppEnricher.records(from: [observation("web", generic)], now: time.addingTimeInterval(20))["192.168.1.3"]!
        expect(removed.modelIdentifier == nil && removed.prettyName == "opaque-admin-name" && !removed.serviceTypes.contains("_googlecast._tcp."), "Removed service metadata is not retained by the aggregate")
        expect(MDNSAppEnricher.records(from: [], now: time).isEmpty, "Removing the last observation removes its IP record")
        let expired = MDNSAppEnricher.records(from: entries, now: time.addingTimeInterval(191))
        expect(expired.isEmpty, "Expired Bonjour metadata disappears after TTL")
        let partialExpiry = MDNSAppEnricher.records(from: entries, now: time.addingTimeInterval(185))["192.168.1.3"]!
        expect(partialExpiry.modelIdentifier == nil && partialExpiry.prettyName == "opaque-admin-name", "Expired rich metadata is not kept by a newer generic service")
        let moved = MDNSAppEnricher.records(from: [observation("cast", cast, ip: "192.168.1.4")], now: time)
        expect(moved["192.168.1.3"] == nil && moved["192.168.1.4"] != nil, "Re-resolved addresses replace old IP ownership")
        let tieA = observation("a", identify("_http._tcp.", "Alpha", [:]))
        let tieB = observation("b", identify("_http._tcp.", "Beta", [:]))
        expect(MDNSAppEnricher.records(from: [tieB, tieA], now: time)["192.168.1.3"]?.prettyName == "Alpha", "Equal priority uses stable service identity")
        expect(MDNSAppEnricher.trackedTypes.contains("_ipps._tcp.") && MDNSAppEnricher.trackedTypes.contains("_hap._tcp."), "Secure printers and HomeKit are browsed")
        let enricher = MDNSAppEnricher()
        enricher.stop()
        expect(enricher.byIP.isEmpty, "Stopping an unused enricher does not start networking")
        print("PASS: \(checked) offline Bonjour parsing, precedence, freshness and removal checks")
    }
}
