import Foundation

/// Display metadata belongs to a current IP owner, never to an IP alone.
struct DeviceIdentityCache {
    struct Binding: Equatable {
        let mac: MACAddress
        let since: Date
    }

    private(set) var bindings: [String: Binding] = [:]
    private(set) var conflictingIPv4s: Set<String> = []
    private var reported: [String: DeviceIdentification] = [:]
    private var hostnames: [String: DeviceIdentification] = [:]
    static let lifetime: TimeInterval = 180

    mutating func reset() {
        bindings.removeAll()
        conflictingIPv4s.removeAll()
        reported.removeAll()
        hostnames.removeAll()
    }

    @discardableResult
    mutating func update(_ devices: [Device], at now: Date = .now) -> Bool {
        let owners = Dictionary(grouping: devices.filter { $0.ipv4 != nil }, by: { $0.ipv4! })
            .mapValues { Set($0.map(\.mac)) }
        let old = bindings
        conflictingIPv4s = Set(owners.filter { $0.value.count > 1 }.keys)
        bindings = owners.reduce(into: [:]) { result, entry in
            guard entry.value.count == 1, let mac = entry.value.first else { return }
            result[entry.key] = old[entry.key]?.mac == mac ? old[entry.key] : Binding(mac: mac, since: now)
        }
        reported = reported.filter { ip, identity in
            old[ip] == bindings[ip] && bindings[ip] != nil
                && now.timeIntervalSince(identity.observedAt) < Self.lifetime
        }
        hostnames = hostnames.filter { ip, identity in
            old[ip] == bindings[ip] && bindings[ip] != nil
                && identity.expiresAt.map { now < $0 } != false
                && now.timeIntervalSince(identity.observedAt) < Self.lifetime
        }
        return bindings != old
    }

    mutating func acceptHostnames(_ records: [String: DeviceIdentification],
                                 requestedBindings: [String: Binding]) {
        for (ip, identity) in records {
            guard let binding = bindings[ip], requestedBindings[ip] == binding,
                  identity.observedAt >= binding.since else { continue }
            hostnames[ip] = identity
        }
    }

    mutating func accept(_ records: [String: DeviceIdentification],
                         requestedBindings: [String: Binding]) {
        for (ip, identity) in records {
            guard let binding = bindings[ip], requestedBindings[ip] == binding,
                  identity.observedAt >= binding.since else { continue }
            reported[ip] = identity
        }
    }

    func enriched(_ device: Device, bonjour: DeviceIdentification?, at now: Date = .now) -> Device {
        var result = device
        // The legacy helper's IP-only Bonjour cache has no ownership or age
        // evidence. Only the scoped observations below may name this owner.
        result.hostname = hostname(for: device, at: now)?.friendlyName
        result.deviceModel = nil
        result.identification = identity(for: device, bonjour: bonjour, at: now)
        return result
    }

    private func hostname(for device: Device, at now: Date) -> DeviceIdentification? {
        guard let ip = device.ipv4, let binding = bindings[ip], binding.mac == device.mac,
              let identity = hostnames[ip], identity.observedAt >= binding.since,
              identity.expiresAt.map({ now < $0 }) != false,
              now.timeIntervalSince(identity.observedAt) < Self.lifetime else { return nil }
        return identity
    }

    func identity(for device: Device, bonjour: DeviceIdentification?, at now: Date = .now) -> DeviceIdentification? {
        guard let ip = device.ipv4, let binding = bindings[ip], binding.mac == device.mac else { return nil }
        func fresh(_ identity: DeviceIdentification?) -> DeviceIdentification? {
            guard let identity, identity.observedAt >= binding.since,
                  now.timeIntervalSince(identity.observedAt) < Self.lifetime else { return nil }
            return identity
        }
        let upnp = fresh(reported[ip])
        let mdns = fresh(bonjour)
        guard let primary = upnp ?? mdns ?? hostname(for: device, at: now) else { return nil }
        guard let mdns, upnp != nil else { return primary }
        return DeviceIdentification(
            friendlyName: primary.friendlyName ?? mdns.friendlyName,
            manufacturer: primary.manufacturer ?? mdns.manufacturer,
            modelName: primary.modelName ?? mdns.modelName,
            modelNumber: primary.modelNumber ?? mdns.modelNumber,
            modelDescription: primary.modelDescription ?? mdns.modelDescription,
            deviceType: primary.deviceType ?? mdns.deviceType,
            services: Array(Set(primary.services + mdns.services)).sorted(),
            source: "UPnP + Bonjour", observedAt: min(primary.observedAt, mdns.observedAt))
    }
}
