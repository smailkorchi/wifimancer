import Foundation
import dnssd

@main
struct ReverseNameTests {
    static func main() async {
        var checked = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checked += 1
        }
        func wire(_ labels: [String]) -> Data {
            var bytes: [UInt8] = []
            for label in labels { bytes.append(UInt8(label.utf8.count)); bytes.append(contentsOf: label.utf8) }
            bytes.append(0)
            return Data(bytes)
        }

        expect(ReverseNameDiscovery.ownerName(for: "192.168.1.18") == "18.1.168.192.in-addr.arpa.", "IPv4 PTR owner is exact")
        for invalid in ["", "1.2.3", "192.168.01.2", "192.168.1.256", "192.168.1.-2", "192.168.1.+2", "192.168.1.2\n", "127.0.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "::1"] {
            expect(ReverseNameDiscovery.ownerName(for: invalid) == nil, "Reject malformed/non-peer IPv4: \(invalid)")
        }
        let many = Set((1...100).map { "192.168.1.\($0)" })
        expect(ReverseNameDiscovery.boundedAddresses(many).count == 64, "Known peer bound is enforced")
        expect(ReverseNameDiscovery.boundedAddresses(many) == ReverseNameDiscovery.boundedAddresses(Set(many.reversed())), "Query bound is deterministic")

        expect(ReverseNameDiscovery.hostname(from: wire(["Android_630W1ZFC", "local"])) == "Android_630W1ZFC", "Android hostname preserves useful evidence")
        expect(ReverseNameDiscovery.hostname(from: wire(["MacBook-Pro", "LOCAL"])) == "MacBook-Pro", "Local suffix is case insensitive")
        expect(ReverseNameDiscovery.hostname(from: wire(["Chloé", "local"])) == "Chloé", "Valid UTF8 is retained")
        expect(ReverseNameDiscovery.hostname(from: wire(["localhost", "local"])) == nil, "Generic Samsung localhost is not a useful identity")
        for malformed in [Data(), Data([0]), wire(["local"]), wire(["Device", "example", "com"]), Data([0xc0, 0]), Data([64] + Array(repeating: 65, count: 64) + [0]), Data([3, 65, 66]), Data([1, 0xff, 0]), wire(["Bad\nName", "local"]), wire(["Bad.Name", "local"]), wire(["Device", "local"]) + Data([0]), Data(repeating: 65, count: 256)] {
            expect(ReverseNameDiscovery.hostname(from: malformed) == nil, "Malformed or non-local wire name is rejected")
        }
        let owner = "18.1.168.192.in-addr.arpa."
        let payload = wire(["Android", "local"])
        let time = Date(timeIntervalSince1970: 1_000)
        func identify(_ returnedOwner: String = "18.1.168.192.in-addr.arpa.", index: UInt32 = 4,
                      flags: DNSServiceFlags = UInt32(kDNSServiceFlagsAdd), type: UInt16 = UInt16(kDNSServiceType_PTR),
                      cls: UInt16 = UInt16(kDNSServiceClass_IN), ttl: UInt32 = 120) -> DeviceIdentification? {
            ReverseNameDiscovery.identification(owner: returnedOwner, expectedOwner: owner, data: payload,
                interfaceIndex: index, expectedInterface: 4, flags: flags, rrtype: type, rrclass: cls,
                ttl: ttl, observedAt: time)
        }
        let identity = identify()
        expect(identity?.friendlyName == "Android" && identity?.source == "mDNS hostname" && identity?.observedAt == time, "Resolution supplies current hostname evidence")
        expect(identity?.modelName == nil && identity?.deviceType == nil && identity?.manufacturer == nil && identity?.services == [], "Reverse lookup does not invent model, manufacturer or type")
        expect(identify(ttl: 1)?.expiresAt == time.addingTimeInterval(1), "One-second PTR TTL is preserved")
        expect(identify(ttl: 120)?.expiresAt == time.addingTimeInterval(120), "Normal PTR TTL is preserved")
        expect(identify(ttl: 181)?.expiresAt == time.addingTimeInterval(180)
            && identify(ttl: UInt32.max)?.expiresAt == time.addingTimeInterval(180), "Long PTR TTL cannot exceed the identity cache lifetime")
        expect(identify("19.1.168.192.in-addr.arpa.") == nil, "Another owner's reply is rejected")
        expect(identify(index: 5) == nil && identify(index: 0) == nil, "Other interfaces and unspecified interface are rejected")
        expect(identify(flags: 0) == nil && identify(ttl: 0) == nil, "Removal/expired replies are not accepted")
        expect(identify(type: UInt16(kDNSServiceType_A)) == nil && identify(cls: 3) == nil, "Only IN PTR records are accepted")

        let timeoutBackend = FakeDNS()
        let timed = ReverseNameDiscovery.Session(interfaceIndex: 4, addresses: Array(many), backend: timeoutBackend.backend, lifetime: 0.02)
        let timedResults = await withCheckedContinuation { timed.start($0) }
        expect(timedResults.isEmpty && timeoutBackend.counts == [64, 64, 64], "Timeout releases every bounded query on its dispatch queue")

        let failedBackend = FakeDNS(scheduleSucceeds: false)
        let failed = ReverseNameDiscovery.Session(interfaceIndex: 4, addresses: ["192.168.1.18"], backend: failedBackend.backend)
        _ = await withCheckedContinuation { failed.start($0) }
        expect(failedBackend.counts == [1, 1, 1], "Failed queue scheduling releases its reference exactly once")

        let earlyBackend = FakeDNS()
        let early = ReverseNameDiscovery.Session(interfaceIndex: 4, addresses: ["192.168.1.18"], backend: earlyBackend.backend)
        early.cancel()
        _ = await withCheckedContinuation { early.start($0) }
        expect(earlyBackend.counts == [0, 0, 0], "Cancellation before start creates no DNS references")

        let cancelledBackend = FakeDNS()
        let cancelled = ReverseNameDiscovery.Session(interfaceIndex: 4, addresses: ["192.168.1.18", "192.168.1.75"], backend: cancelledBackend.backend)
        let task = Task { await withCheckedContinuation { cancelled.start($0) } }
        for _ in 0..<100 {
            if cancelledBackend.counts[1] == 2 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        expect(cancelledBackend.counts[1] == 2, "Fixture actually started both queries before cancellation")
        cancelled.cancel()
        cancelled.cancel()
        let cancelledResults = await task.value
        expect(cancelledResults.isEmpty && cancelledBackend.counts == [2, 2, 2], "Repeated cancellation resumes once and frees each reference once")
        let invalidInterface = await ReverseNameDiscovery.discover(interface: "wifimancer-invalid-interface", allowedIPv4s: ["192.168.1.18"])
        expect(invalidInterface.isEmpty, "Invalid interface fails closed without starting queries")
        print("PASS: \(checked) offline reverse-name parsing, ownership, bounds and lifecycle checks")
    }
}

private final class FakeDNS: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduleSucceeds: Bool
    private var created = 0
    private var scheduled = 0
    private var released: Set<DNSServiceRef> = []
    private var queue: DispatchQueue?

    init(scheduleSucceeds: Bool = true) { self.scheduleSucceeds = scheduleSucceeds }
    var counts: [Int] { lock.withLock { [created, scheduled, released.count] } }
    var backend: ReverseNameDiscovery.Backend {
        .init(query: { [self] _, _, _ in
            lock.withLock { created += 1; return DNSServiceRef(bitPattern: created)! }
        }, schedule: { [self] _, queue in
            dispatchPrecondition(condition: .onQueue(queue))
            return lock.withLock { self.queue = queue; scheduled += 1; return scheduleSucceeds }
        }, release: { [self] reference in
            lock.withLock {
                dispatchPrecondition(condition: .onQueue(queue!))
                precondition(released.insert(reference).inserted, "Reference released twice")
            }
        })
    }
}
