import Foundation
import Combine

/// App-side Bonjour metadata. Services retain their own observations so
/// removals, address changes and network resets cannot leave permanent IP hints.
@MainActor
final class MDNSAppEnricher: NSObject, ObservableObject {
    struct Record: Equatable {
        var identification: DeviceIdentification
        var observedAt: Date
        var modelIdentifier: String? { identification.modelName }
        var prettyName: String? { identification.friendlyName }
        var serviceTypes: Set<String> { Set(identification.services) }
    }

    struct Observation {
        var identity: String
        var addresses: [String]
        var identification: DeviceIdentification
    }

    static let trackedTypes: [String] = [
        "_device-info._tcp.", "_airplay._tcp.", "_raop._tcp.",
        "_companion-link._tcp.", "_smb._tcp.", "_afpovertcp._tcp.",
        "_ssh._tcp.", "_sftp-ssh._tcp.", "_http._tcp.", "_https._tcp.",
        "_rfb._tcp.", "_rtsp._tcp.", "_googlecast._tcp.",
        "_printer._tcp.", "_ipp._tcp.", "_ipps._tcp.",
        "_homekit._tcp.", "_hap._tcp.", "_apple-mobdev2._tcp.",
        "_workstation._tcp.", "_spotify-connect._tcp.", "_eppc._tcp.",
        "_net-assistant._udp."
    ]
    static let observationTTL: TimeInterval = 180

    @Published private(set) var byIP: [String: Record] = [:]

    private struct TrackedService {
        var service: NetService
        var observation: Observation?
        var resolving = false
        var monitoring = false
    }
    private var browsers: [NetServiceBrowser] = []
    private var tracked: [String: TrackedService] = [:]
    private var refreshTimer: Timer?
    private var generation = 0

    func start() {
        guard browsers.isEmpty else { return }
        for type in Self.trackedTypes {
            let browser = NetServiceBrowser()
            browser.includesPeerToPeer = true
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        let startedGeneration = generation
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == startedGeneration else { return }
                self.refresh(clearObservations: false)
            }
        }
    }

    func stop() {
        generation += 1
        refreshTimer?.invalidate()
        refreshTimer = nil
        for browser in browsers { browser.stop(); browser.delegate = nil }
        browsers.removeAll()
        for entry in tracked.values { release(entry.service) }
        tracked.removeAll()
        byIP.removeAll()
    }

    func reset() { stop(); start() }

    /// A new resolver object also invalidates queued callbacks from the previous
    /// resolution. AppStore requests this when an IP gets a different owner.
    func refresh() { refresh(clearObservations: true) }

    /// Keep valid peers visible while re-resolving changed address owners.
    func refresh(invalidatingIPv4s addresses: Set<String>) {
        for key in Array(tracked.keys) {
            guard let observation = tracked[key]?.observation,
                  !addresses.isDisjoint(with: observation.addresses) else { continue }
            tracked[key]?.observation = nil
        }
        refresh(clearObservations: false)
    }

    private func refresh(clearObservations: Bool) {
        if clearObservations {
            for key in Array(tracked.keys) { tracked[key]?.observation = nil }
        }
        rebuild()
        for key in Array(tracked.keys) {
            guard let entry = tracked[key] else { continue }
            let replacement = NetService(domain: entry.service.domain,
                                         type: entry.service.type, name: entry.service.name)
            replacement.includesPeerToPeer = true
            release(entry.service)
            tracked[key] = TrackedService(service: replacement, observation: entry.observation)
            resolve(key)
        }
    }

    private static func key(for service: NetService) -> String {
        "\(service.domain.lowercased())\u{0}\(service.type.lowercased())\u{0}\(service.name.lowercased())"
    }

    private func release(_ service: NetService) {
        service.stopMonitoring()
        service.stop()
        service.delegate = nil
    }

    private func resolve(_ key: String) {
        guard var entry = tracked[key], !entry.resolving else { return }
        entry.resolving = true
        tracked[key] = entry
        entry.service.delegate = self
        entry.service.resolve(withTimeout: 4)
    }

    private func isCurrent(_ service: NetService) -> Bool {
        tracked[Self.key(for: service)]?.service === service
    }

    private func rebuild() {
        byIP = Self.records(from: tracked.values.compactMap(\.observation), now: Date())
    }

    private func ingest(_ service: NetService, resolvedAt: Date, txtData: Data? = nil) {
        let key = Self.key(for: service)
        guard var entry = tracked[key], entry.service === service else { return }
        let addresses = (service.addresses ?? []).compactMap(Self.ipv4Address)
        let txt = (txtData ?? service.txtRecordData()).map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        entry.observation = Observation(identity: key, addresses: addresses,
            identification: Self.identification(serviceType: service.type, instanceName: service.name,
                                                txt: txt, observedAt: resolvedAt))
        tracked[key] = entry
        rebuild()
    }

    private static func ipv4Address(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        var address = sockaddr_in()
        _ = withUnsafeMutableBytes(of: &address) { data.copyBytes(to: $0) }
        guard address.sin_family == sa_family_t(AF_INET) else { return nil }
        var ip = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let value = String(cString: buffer)
        guard !value.hasPrefix("127."), !value.hasPrefix("169.254."), value != "0.0.0.0" else { return nil }
        return value
    }

    // Pure parsing/aggregation also drives the offline Bonjour fixtures.
    static func identification(serviceType: String, instanceName: String,
                               txt: [String: Data], observedAt: Date) -> DeviceIdentification {
        let type = serviceType.lowercased()
        var values: [String: String] = [:]
        for key in txt.keys.sorted() {
            guard let data = txt[key], data.count <= 512,
                  let value = String(data: data, encoding: .utf8), let clean = cleaned(value) else { continue }
            values[key.lowercased()] = clean
        }
        var name = cleaned(instanceName)
        var model: String?
        var manufacturer = values["manufacturer"]
        var deviceType: String?
        switch type {
        case "_googlecast._tcp.":
            name = values["fn"] ?? name
            model = values["md"]
            deviceType = "MediaReceiver"
        case "_airplay._tcp.", "_raop._tcp.":
            name = values["name"] ?? values["fn"] ?? name
            if type == "_raop._tcp.", let current = name, let separator = current.firstIndex(of: "@"),
               current[..<separator].count == 12, current[..<separator].allSatisfy(\.isHexDigit) {
                name = cleaned(String(current[current.index(after: separator)...]))
            }
            model = values["model"] ?? values["am"]
            deviceType = "MediaReceiver"
        case "_printer._tcp.", "_ipp._tcp.", "_ipps._tcp.":
            manufacturer = values["usb_mfg"] ?? manufacturer
            model = values["usb_mdl"] ?? values["product"].flatMap {
                cleaned($0.trimmingCharacters(in: CharacterSet(charactersIn: "()")))
            } ?? values["ty"]
            deviceType = "Printer"
        case "_hap._tcp.", "_homekit._tcp.":
            model = values["md"] ?? values["model"]
            deviceType = "HomeKitAccessory"
        case "_apple-mobdev2._tcp.":
            model = values["model"] ?? values["am"]
            deviceType = "MobileDevice"
        case "_spotify-connect._tcp.":
            model = values["model"]
            deviceType = "MediaReceiver"
        default:
            model = values["model"] ?? values["am"]
        }
        return DeviceIdentification(friendlyName: name, manufacturer: manufacturer,
                                    modelName: model.flatMap(cleaned), deviceType: deviceType,
                                    services: [type], source: "Bonjour", observedAt: observedAt)
    }

    private static func cleaned(_ value: String) -> String? {
        let clean = value.components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : String(clean.prefix(256))
    }

    private static func priority(_ observation: Observation) -> Int {
        switch observation.identification.services.first {
        case "_googlecast._tcp.", "_ipp._tcp.", "_ipps._tcp.", "_printer._tcp.": return 100
        case "_device-info._tcp.": return 95
        case "_airplay._tcp.": return 90
        case "_raop._tcp.", "_hap._tcp.", "_homekit._tcp.": return 80
        case "_workstation._tcp.", "_smb._tcp.", "_afpovertcp._tcp.": return 50
        default: return 10
        }
    }

    static func records(from observations: [Observation], now: Date) -> [String: Record] {
        var groups: [String: [Observation]] = [:]
        for observation in observations where now.timeIntervalSince(observation.identification.observedAt) <= observationTTL {
            for ip in Set(observation.addresses) { groups[ip, default: []].append(observation) }
        }
        return groups.mapValues { observations in
            let ordered = observations.sorted {
                let lhs = priority($0), rhs = priority($1)
                return lhs == rhs ? $0.identity < $1.identity : lhs > rhs
            }
            let latest = ordered.map(\.identification.observedAt).max()!
            var identification = DeviceIdentification(source: "Bonjour", observedAt: latest)
            for observation in ordered {
                let value = observation.identification
                identification.friendlyName = identification.friendlyName ?? value.friendlyName
                identification.manufacturer = identification.manufacturer ?? value.manufacturer
                identification.modelName = identification.modelName ?? value.modelName
                identification.modelNumber = identification.modelNumber ?? value.modelNumber
                identification.modelDescription = identification.modelDescription ?? value.modelDescription
                identification.deviceType = identification.deviceType ?? value.deviceType
                identification.services.append(contentsOf: value.services)
            }
            identification.services = Array(Set(identification.services)).sorted()
            return Record(identification: identification, observedAt: latest)
        }
    }
}

extension MDNSAppEnricher: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        Task { @MainActor in
            guard self.browsers.contains(where: { $0 === browser }) else { return }
            let key = Self.key(for: service)
            guard self.tracked[key] == nil else { return }
            self.tracked[key] = TrackedService(service: service)
            self.resolve(key)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            guard self.isCurrent(sender) else { return }
            let key = Self.key(for: sender)
            self.tracked[key]?.resolving = false
            self.ingest(sender, resolvedAt: Date())
            if self.tracked[key]?.monitoring == false {
                self.tracked[key]?.monitoring = true
                sender.startMonitoring()
            }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        Task { @MainActor in
            guard self.isCurrent(sender) else { return }
            self.tracked[Self.key(for: sender)]?.resolving = false
            self.rebuild()
        }
    }

    nonisolated func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        Task { @MainActor in
            guard self.isCurrent(sender), let resolvedAt = self.tracked[Self.key(for: sender)]?.observation?.identification.observedAt else { return }
            self.ingest(sender, resolvedAt: resolvedAt, txtData: data)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor in
            guard self.browsers.contains(where: { $0 === browser }) else { return }
            if let entry = self.tracked.removeValue(forKey: Self.key(for: service)) { self.release(entry.service) }
            self.rebuild()
        }
    }
}
