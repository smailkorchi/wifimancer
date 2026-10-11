import Foundation

@main
struct ModelTests {
    static func main() throws {
        let privateMAC = MACAddress("02:00:00:00:01:01")!
        let samsungMAC = MACAddress("b8:b4:09:00:00:01")!
        let privatePeer = Device(mac: privateMAC, ipv4: "192.168.1.124")
        precondition(privatePeer.kind == .unknown, "A private MAC does not identify a phone")
        precondition(privatePeer.classificationSource == "Unknown")
        for vendor in ["Apple, Inc.", "Sonos, Inc.", "Zhejiang Dahua Technology"] {
            let peer = Device(mac: privateMAC, ipv4: "192.168.1.124", vendor: vendor)
            precondition(peer.kind == .unknown, "A supplied OUI vendor is invalid for a private MAC")
            precondition(peer.displayName == "192.168.1.124")
        }
        for vendor in ["Samsung Electronics Co. Ltd", "Huawei Technologies", "Xiaomi", "Intel Corporate", "Sony Corporation"] {
            precondition(Device(mac: samsungMAC, vendor: vendor).kind == .unknown,
                         "A broad adapter manufacturer does not prove a device class")
        }

        let television = Device(mac: samsungMAC, hostname: "DU7000-fixture",
                                vendor: "Samsung Electronics Co. Ltd",
                                identification: DeviceIdentification(
                                    friendlyName: "75\" Crystal UHD", manufacturer: "Samsung",
                                    modelName: "UA75DU7000UXMV", modelDescription: "Samsung DTV DMR",
                                    deviceType: "urn:schemas-upnp-org:device:MediaRenderer:1", source: "SSDP / UPnP"))
        precondition(television.kind == .tv, "Reported Samsung TV model beats generic renderer type")
        precondition(television.classificationSource == "Reported model")
        precondition(television.displayName == "75\" Crystal UHD")
        precondition(Device(mac: samsungMAC, hostname: "DU7000-fixture").kind == .tv)
        precondition(Device(mac: samsungMAC, identification: DeviceIdentification(
            deviceType: "Samsung Smart TV")).kind == .tv)

        let renderer = Device(mac: privateMAC, identification: DeviceIdentification(
            deviceType: "urn:schemas-upnp-org:device:MediaRenderer:1", source: "SSDP / UPnP"))
        precondition(renderer.kind == .mediaReceiver, "A renderer may be a speaker, TV, or software receiver")
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            deviceType: "MediaReceiver")).kind == .mediaReceiver)
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            modelName: "iPad13,4", deviceType: "MediaReceiver")).kind == .ipad)
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            deviceType: "HomeKitAccessory")).kind == .iot)
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            modelName: "AppleTV14,1", deviceType: "HomeKitAccessory")).kind == .tv)
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            deviceType: "MobileDevice")).kind == .unknown)
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            deviceType: "MobileDevice", services: ["_apple-mobdev2._tcp."])).kind == .applish)
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            modelName: "iPhone16,1", deviceType: "MobileDevice", services: ["_apple-mobdev2._tcp."])).kind == .iphone)
        for service in ["_googlecast._tcp.", "_airplay._tcp.", "_raop._tcp."] {
            precondition(Device(mac: privateMAC, identification: DeviceIdentification(
                services: [service], source: "mDNS")).kind == .mediaReceiver)
        }
        let printer = Device(mac: privateMAC, hostname: "samsung-private",
                             identification: DeviceIdentification(services: ["_ipps._tcp."], source: "mDNS"))
        precondition(printer.kind == .printer)
        precondition(printer.classificationSource == "Advertised service")

        for (model, expected) in [("MacBookPro17,1", DeviceKind.laptop), ("iPhone16,1", .iphone),
                                  ("iPad13,4", .ipad), ("AppleTV14,1", .tv), ("Mac mini M2", .desktop)] {
            let device = Device(mac: privateMAC, deviceModel: model,
                                identification: DeviceIdentification(services: ["_airplay._tcp."], source: "mDNS"))
            precondition(device.kind == expected, "Hardware model outranks a generic receiver service")
            precondition(device.classificationSource == "Reported model")
        }
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            source: "Samsung TV")).kind == .unknown, "Provenance is not hardware evidence")
        let reportedModel = Device(mac: privateMAC, hostname: "opaque-id",
                                   identification: DeviceIdentification(modelName: "Readable model"))
        precondition(reportedModel.displayName == "Readable model")
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            modelName: "Crystal UHD", modelNumber: "DU7000")).displayModel == "Crystal UHD · DU7000")
        precondition(Device(mac: privateMAC, identification: DeviceIdentification(
            modelName: "Samsung DU7000", modelNumber: "du7000")).displayModel == "Samsung DU7000")
        precondition(Device(mac: privateMAC, hostname: "My Mac", deviceModel: "MacBookPro17,1").displayName == "My Mac")
        precondition(Device(mac: privateMAC, hostname: "Office iPhone").classificationSource == "Hostname estimate")
        precondition(Device(mac: samsungMAC, vendor: "Sonos, Inc.").classificationSource == "Vendor estimate")
        precondition(Device(mac: privateMAC, isGateway: true, identification: television.identification).kind == .router)
        precondition(Device(mac: privateMAC, isSelf: true, identification: television.identification).kind == .thisMac)

        let encoded = try JSONEncoder().encode(privatePeer)
        var oldObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        oldObject.removeValue(forKey: "identification")
        let oldJSON = try JSONSerialization.data(withJSONObject: oldObject)
        let decodedOld = try JSONDecoder().decode(Device.self, from: oldJSON)
        precondition(decodedOld == privatePeer, "Helper JSON without identification remains compatible")
        let roundTrip = try JSONDecoder().decode(Device.self, from: JSONEncoder().encode(television))
        precondition(roundTrip == television, "Reported identity survives JSON serialization")
        print("PASS: evidence-ranked device classification, honest unknowns, and backward-compatible identity JSON")
    }
}
