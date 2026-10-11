import Foundation

public struct MACAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]   // 6 bytes
    public init?(_ s: String) {
        let parts = s.lowercased().split(whereSeparator: { ":-".contains($0) })
        guard parts.count == 6 else { return nil }
        var b: [UInt8] = []
        for p in parts {
            guard p.count == 2, let v = UInt8(p, radix: 16) else { return nil }
            b.append(v)
        }
        self.bytes = b
    }
    public init(bytes: [UInt8]) {
        precondition(bytes.count == 6); self.bytes = bytes
    }
    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
    public var oui: String {
        bytes.prefix(3).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
    public var isLocallyAdministered: Bool { (bytes[0] & 0x02) != 0 }
    public var isMulticast: Bool            { (bytes[0] & 0x01) != 0 }
}

public struct Device: Identifiable, Hashable, Codable, Sendable {
    public var id: String { mac.description }
    public var mac: MACAddress
    public var ipv4: String?
    public var ipv6: [String]
    public var hostname: String?
    public var vendor: String?
    public var deviceModel: String?       // resolved from mDNS / DHCP fingerprint
    public var identification: DeviceIdentification?
    public var firstSeen: Date
    public var lastSeen: Date
    public var isAllowlisted: Bool
    public var isGateway: Bool
    public var isSelf: Bool
    public var bandwidthBps: Double       // EWMA smoothed
    public var threatScore: Int           // 0..100
    public var blockedSince: Date?

    public init(
        mac: MACAddress, ipv4: String? = nil, ipv6: [String] = [],
        hostname: String? = nil, vendor: String? = nil, deviceModel: String? = nil,
        firstSeen: Date = .now, lastSeen: Date = .now,
        isAllowlisted: Bool = false, isGateway: Bool = false, isSelf: Bool = false,
        bandwidthBps: Double = 0, threatScore: Int = 0, blockedSince: Date? = nil,
        identification: DeviceIdentification? = nil
    ) {
        self.mac = mac; self.ipv4 = ipv4; self.ipv6 = ipv6
        self.hostname = hostname; self.vendor = vendor; self.deviceModel = deviceModel
        self.firstSeen = firstSeen; self.lastSeen = lastSeen
        self.isAllowlisted = isAllowlisted
        self.isGateway = isGateway; self.isSelf = isSelf
        self.bandwidthBps = bandwidthBps; self.threatScore = threatScore
        self.blockedSince = blockedSince
        self.identification = identification
    }

    public var displayName: String {
        if let n = identification?.friendlyName, !n.isEmpty { return n }
        if identification?.modelName?.isEmpty == false || identification?.modelNumber?.isEmpty == false,
           let model = displayModel { return model }
        if let h = hostname, !h.isEmpty { return h }
        if let m = displayModel { return m }
        if !mac.isLocallyAdministered, let v = vendor, !v.isEmpty { return v }
        return ipv4 ?? mac.description
    }

    public var displayModel: String? {
        let name = identification?.modelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = identification?.modelNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [name, number].compactMap { $0 }.filter { !$0.isEmpty }
        if parts.count == 2, parts[0].localizedCaseInsensitiveContains(parts[1]) { return parts[0] }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        guard let deviceModel, !deviceModel.isEmpty else { return nil }
        return deviceModel
    }

    public var bandwidthPretty: String {
        let bps = bandwidthBps * 8
        if bps > 1_000_000 { return String(format: "%.1f Mbps", bps / 1_000_000) }
        if bps > 1_000     { return String(format: "%.0f Kbps", bps / 1_000) }
        return String(format: "%.0f bps", bps)
    }

    public var kind: DeviceKind { classification.kind }

    /// Describes the actual signal, not a claim that every icon is certain.
    public var classificationSource: String { classification.source }

    private var classification: (kind: DeviceKind, source: String) {
        if isGateway { return (.router, "Network gateway") }
        if isSelf { return (.thisMac, "This Mac") }
        let reportedType = identification?.deviceType?.lowercased() ?? ""
        let genericRenderer = reportedType.contains("mediarenderer") || reportedType == "mediareceiver"
        let genericAccessory = reportedType == "homekitaccessory"
        let genericMobile = reportedType == "mobiledevice"
        if !genericRenderer, !genericAccessory, !genericMobile, let kind = Self.reportedKind(reportedType) {
            return (kind, "Reported device type")
        }
        let models = [identification?.modelName, identification?.modelNumber,
                      identification?.modelDescription, deviceModel]
        for case let model? in models {
            if let kind = Self.reportedKind(model.lowercased()) {
                return (kind, "Reported model")
            }
        }
        let services = identification?.services.map { $0.lowercased() } ?? []
        if services.contains(where: { $0.hasPrefix("_ipp.") || $0.hasPrefix("_ipps.")
            || $0.hasPrefix("_printer.") || $0.contains(":service:printer:") }) {
            return (.printer, "Advertised service")
        }
        if genericMobile, services.contains(where: { $0.hasPrefix("_apple-mobdev2.") }) {
            return (.applish, "Advertised service")
        }
        if genericRenderer { return (.mediaReceiver, "Reported device type") }
        if services.contains(where: { $0.hasPrefix("_airplay.") || $0.hasPrefix("_raop.")
            || $0.hasPrefix("_googlecast.") || $0.contains(":service:avtransport:") }) {
            return (.mediaReceiver, "Advertised service")
        }
        if genericAccessory { return (.iot, "Reported device type") }
        if let name = identification?.friendlyName, let kind = Self.hostnameKind(name.lowercased()) {
            return (kind, "Reported name estimate")
        }
        if let kind = Self.hostnameKind((hostname ?? "").lowercased()) {
            return (kind, "Hostname estimate")
        }

        // OUI identifies an adapter manufacturer, often spanning many classes.
        // Keep only narrow vendor estimates; never infer a phone from a private MAC.
        guard !mac.isLocallyAdministered else { return (.unknown, "Unknown") }
        let v = (vendor ?? "").lowercased()
        let estimate: DeviceKind?
        if v.contains("apple") { estimate = .applish }
        else if v.contains("sonos") || v.contains("bose") { estimate = .speaker }
        else if v.contains("hikvision") || v.contains("dahua") || v.contains("reolink")
            || v.contains("amcrest") || v.contains("axis comm") { estimate = .camera }
        else if v.contains("brother") || v.contains("epson") || v.contains("lexmark") { estimate = .printer }
        else if v.contains("philips lighting") || v.contains("signify") { estimate = .light }
        else if v.contains("tuya") || v.contains("espressif") || v.contains("shelly") { estimate = .iot }
        else { estimate = nil }
        if let estimate { return (estimate, "Vendor estimate") }
        return (.unknown, "Unknown")
    }

    private static func reportedKind(_ value: String) -> DeviceKind? {
        let compact = value.filter { $0.isLetter || $0.isNumber }
        if compact.hasPrefix("iphone") { return .iphone }
        if compact.hasPrefix("ipad") { return .ipad }
        if compact.hasPrefix("macbook") { return .laptop }
        if compact.hasPrefix("imac") || compact.hasPrefix("macmini") || compact.hasPrefix("macpro") { return .desktop }
        if compact.hasPrefix("appletv") { return .tv }
        if compact.hasPrefix("homepod") { return .speaker }
        if compact.hasPrefix("airpods") || compact.hasPrefix("ipod") { return .audio }
        if compact.hasPrefix("watch") || compact.hasPrefix("applewatch") { return .watch }
        // Samsung model identifiers distinguish a TV from the manufacturer's phones.
        if value.range(of: #"^(?:samsung[\s-]*)?(?:(?:ua|ue|un|qn|qe|qa)\d{2}[a-z]\d?[a-z0-9]*|(?:du|cu|au|bu)\d{4})$"#,
                       options: .regularExpression) != nil { return .tv }
        if compact == "tv" || compact.contains("smarttv") || compact.contains("television")
            || value.contains(" tv") || value.contains("dtv") || value.contains(":tv:") { return .tv }
        if compact.contains("printer") { return .printer }
        if compact.contains("camera") { return .camera }
        if compact.contains("speaker") || compact.contains("audiorenderer") { return .speaker }
        if compact.contains("internetgatewaydevice") { return .router }
        if compact == "phone" || compact == "smartphone" { return .phone }
        if compact == "laptop" || compact == "notebook" { return .laptop }
        if compact == "desktop" { return .desktop }
        return nil
    }

    private static func hostnameKind(_ h: String) -> DeviceKind? {
        if let known = reportedKind(h) { return known }
        if h.contains("iphone")                                 { return .iphone }
        if h.contains("ipad")                                   { return .ipad }
        if h.contains("ipod") || h.contains("airpods") || h.contains("beats") { return .audio }
        if h.contains("watch")                                  { return .watch }
        if h.contains("macbook")                                { return .laptop }
        if h.contains("imac") || h.contains("macmini") || h.contains("macpro") { return .desktop }
        if h.contains("appletv") || h.contains("apple-tv") || h.contains("roku")
            || h.contains("firestick") || h.contains("shield-tv")
            || h.hasSuffix("-tv") || h.hasSuffix("tv")          { return .tv }
        if h.contains("chromecast") { return .mediaReceiver }
        if h.range(of: #"^(?:du|cu|au|bu)\d{4}(?:-|$)"#, options: .regularExpression) != nil { return .tv }
        if h.contains("echo") || h.contains("alexa") || h.contains("homepod")
            || h.contains("nest-mini") || h.contains("nest-hub") || h.contains("googlehome")
            || h.contains("sonos") || h.contains("bose")        { return .speaker }
        if h.contains("camera") || h.contains("cam-") || h.hasSuffix("cam")
            || h.contains("doorbell") || h.contains("ring-")    { return .camera }
        if h.contains("printer") || h.contains("brother") || h.contains("epson")
            || h.contains("canon") || h.contains("hp-") || h.contains("officejet") { return .printer }
        if h.contains("playstation") || h.contains("ps5") || h.contains("ps4")
            || h.contains("xbox") || h.contains("switch") || h.contains("nintendo") { return .gamingConsole }
        if h.contains("raspberry") || h.contains("rpi") || h.contains("pi-")
            || h.contains("esp") || h.contains("arduino")       { return .iot }
        if h.contains("bulb") || h.contains("lifx") || h.contains("hue")
            || h.contains("kasa") || h.contains("tplink-bulb")  { return .light }
        if h.contains("thermostat") || h.contains("sensor")     { return .sensor }
        return nil
    }
}

public enum DeviceKind: String, Codable, Hashable, Sendable {
    case router, thisMac, laptop, desktop, applish
    case phone, iphone, ipad, watch, audio
    case tv, speaker, camera, printer, gamingConsole, mediaReceiver
    case iot, light, sensor
    case unknown

    /// SF Symbol rendered inside the device circle. Chosen so a phone, TV,
    /// camera, etc. are distinguishable at a glance without reading the label.
    public var sfSymbol: String {
        switch self {
        case .router:        return "wifi.router.fill"
        case .thisMac:       return "macbook"
        case .laptop:        return "laptopcomputer"
        case .desktop:       return "desktopcomputer"
        case .applish:       return "apple.logo"
        case .phone:         return "iphone"
        case .iphone:        return "iphone"
        case .ipad:          return "ipad"
        case .watch:         return "applewatch"
        case .audio:         return "airpodspro"
        case .tv:            return "tv"
        case .mediaReceiver: return "play.rectangle"
        case .speaker:       return "hifispeaker.fill"
        case .camera:        return "video.fill"
        case .printer:       return "printer.fill"
        case .gamingConsole: return "gamecontroller.fill"
        case .iot:           return "sensor.fill"
        case .light:         return "lightbulb.fill"
        case .sensor:        return "thermometer.medium"
        case .unknown:       return "network"
        }
    }
}

/// Minimal struct sent over XPC when arming the spoofer. Contains everything
/// the helper needs to construct ARP frames without consulting its in-memory
/// lastDevices cache. The previous wire format ([MACAddress.description])
/// forced the helper to look up each MAC's IPv4 from a cache that gets reset
/// every time launchd respawns the daemon — leading to the
/// "startSpoof: requested=N lastDevices=0 v4Targets=0" silent-no-cut bug.
public struct SpoofTarget: Codable, Sendable, Hashable {
    public let mac: MACAddress
    public let ipv4: String
    public let ipv6: [String]
    public init(mac: MACAddress, ipv4: String, ipv6: [String] = []) {
        self.mac = mac; self.ipv4 = ipv4; self.ipv6 = ipv6
    }
}
