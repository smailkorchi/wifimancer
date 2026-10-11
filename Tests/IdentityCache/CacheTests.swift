import Foundation

@main struct CacheTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = Device(mac: MACAddress("00:11:22:33:44:55")!, ipv4: "192.168.1.3")
        let replacement = Device(mac: MACAddress("00:11:22:33:44:66")!, ipv4: first.ipv4)
        let identity = DeviceIdentification(friendlyName: "Living room TV", modelName: "UA75DU7000UXMV",
                                            source: "UPnP", observedAt: now.addingTimeInterval(1))
        var cache = DeviceIdentityCache()
        precondition(cache.update([first], at: now))
        let bindings = cache.bindings
        cache.accept([first.ipv4!: identity], requestedBindings: bindings)
        precondition(cache.identity(for: first, bonjour: nil, at: now.addingTimeInterval(2))?.friendlyName == "Living room TV")
        precondition(!cache.update([first], at: now.addingTimeInterval(3)))
        precondition(cache.identity(for: first, bonjour: nil, at: now.addingTimeInterval(182)) == nil)

        // A simultaneous claimant cannot inherit another MAC's description.
        cache.update([first, replacement], at: now.addingTimeInterval(4))
        precondition(cache.conflictingIPv4s == [first.ipv4!])
        precondition(cache.identity(for: first, bonjour: identity, at: now.addingTimeInterval(5)) == nil)
        precondition(cache.identity(for: replacement, bonjour: identity, at: now.addingTimeInterval(5)) == nil)
        cache.update([replacement], at: now.addingTimeInterval(6))
        cache.accept([first.ipv4!: identity], requestedBindings: bindings)
        precondition(cache.identity(for: replacement, bonjour: identity, at: now.addingTimeInterval(7)) == nil)

        // Only a resolve made after the new owner appeared can enrich it.
        var fresh = identity
        fresh.friendlyName = "Replacement receiver"
        fresh.observedAt = now.addingTimeInterval(8)
        precondition(cache.identity(for: replacement, bonjour: fresh, at: now.addingTimeInterval(9))?.friendlyName == fresh.friendlyName)
        cache.reset()
        precondition(cache.bindings.isEmpty && cache.conflictingIPv4s.isEmpty)
        precondition(cache.identity(for: replacement, bonjour: fresh, at: now.addingTimeInterval(10)) == nil)
        cache.update([first], at: now.addingTimeInterval(11))
        cache.accept([first.ipv4!: identity], requestedBindings: bindings)
        precondition(cache.identity(for: first, bonjour: fresh, at: now.addingTimeInterval(12)) == nil)
        var staleHelperDevice = first
        staleHelperDevice.hostname = "Previous owner's iPhone"
        staleHelperDevice.deviceModel = "iPhone16,1"
        let unverified = cache.enriched(staleHelperDevice, bonjour: nil, at: now.addingTimeInterval(12))
        precondition(unverified.hostname == nil && unverified.deviceModel == nil && unverified.kind == .unknown)
        let currentBindings = cache.bindings
        let hostname = DeviceIdentification(friendlyName: "Android-3", source: "mDNS hostname",
                                            observedAt: now.addingTimeInterval(13))
        cache.acceptHostnames([first.ipv4!: hostname], requestedBindings: currentBindings)
        let named = cache.enriched(first, bonjour: nil, at: now.addingTimeInterval(14))
        precondition(named.displayName == "Android-3" && named.hostname == "Android-3")
        precondition(named.kind == .unknown, "An Android hostname does not prove phone form factor")
        precondition(named.identification?.source == "mDNS hostname")
        var shortLived = hostname
        shortLived.expiresAt = now.addingTimeInterval(15)
        cache.acceptHostnames([first.ipv4!: shortLived], requestedBindings: currentBindings)
        precondition(cache.enriched(first, bonjour: nil, at: now.addingTimeInterval(14)).hostname == "Android-3")
        precondition(cache.enriched(first, bonjour: nil, at: now.addingTimeInterval(15)).hostname == nil)
        cache.acceptHostnames([first.ipv4!: hostname], requestedBindings: currentBindings)
        precondition(cache.enriched(first, bonjour: nil, at: now.addingTimeInterval(194)).hostname == nil)
        var richer = identity
        richer.observedAt = now.addingTimeInterval(15)
        cache.accept([first.ipv4!: richer], requestedBindings: currentBindings)
        precondition(cache.enriched(first, bonjour: nil, at: now.addingTimeInterval(16)).displayName == "Living room TV")
        cache.update([replacement], at: now.addingTimeInterval(17))
        cache.acceptHostnames([replacement.ipv4!: hostname], requestedBindings: currentBindings)
        precondition(cache.enriched(replacement, bonjour: nil, at: now.addingTimeInterval(18)).hostname == nil)
        cache.reset()
        precondition(cache.enriched(first, bonjour: nil, at: now.addingTimeInterval(19)).hostname == nil)
        print("PASS identity ownership, conflicts, expiry and network reset")
    }
}
