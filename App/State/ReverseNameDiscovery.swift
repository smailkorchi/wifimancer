import Foundation
import Darwin
import dnssd

/// Reverse mDNS only asks known peers on the current interface for their hostname.
/// A reply supplies a name, never proof of its model or device category.
enum ReverseNameDiscovery {
    static let peerLimit = 64
    static let timeout: TimeInterval = 3

    static func discover(interface: String, allowedIPv4s: Set<String>) async -> [String: DeviceIdentification] {
        let index = if_nametoindex(interface)
        guard index != 0 else { return [:] }
        let session = Session(interfaceIndex: index, addresses: boundedAddresses(allowedIPv4s))
        return await withTaskCancellationHandler {
            await withCheckedContinuation { session.start($0) }
        } onCancel: {
            session.cancel()
        }
    }

    static func boundedAddresses(_ addresses: Set<String>) -> [String] {
        addresses.filter { ownerName(for: $0) != nil }.sorted().prefix(peerLimit).map { $0 }
    }

    static func ownerName(for address: String) -> String? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard let value = UInt8(part), String(value) == part else { return nil }
            octets.append(value)
        }
        guard (1...223).contains(octets[0]), octets[0] != 127 else { return nil }
        return octets.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa."
    }

    /// DNS-SD exposes standalone rdata, so compressed pointers have no valid
    /// packet base. Rejecting them also prevents pointer cycles and out-of-bounds reads.
    static func hostname(from data: Data) -> String? {
        guard !data.isEmpty, data.count <= 255 else { return nil }
        let bytes = [UInt8](data)
        var labels: [String] = []
        var offset = 0
        while offset < bytes.count {
            let length = Int(bytes[offset])
            offset += 1
            if length == 0 {
                guard offset == bytes.count, labels.count >= 2,
                      labels.last?.lowercased() == "local" else { return nil }
                let name = labels.dropLast().joined(separator: ".")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty || name.caseInsensitiveCompare("localhost") == .orderedSame ? nil : name
            }
            guard length <= 63, offset + length < bytes.count,
                  let label = String(bytes: bytes[offset..<(offset + length)], encoding: .utf8),
                  !label.isEmpty,
                  label.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) })
            else { return nil }
            labels.append(label)
            offset += length
        }
        return nil
    }

    static func identification(owner: String, expectedOwner: String, data: Data,
                               interfaceIndex: UInt32, expectedInterface: UInt32,
                               flags: DNSServiceFlags, rrtype: UInt16, rrclass: UInt16,
                               ttl: UInt32, observedAt: Date = .now) -> DeviceIdentification? {
        guard owner.caseInsensitiveCompare(expectedOwner) == .orderedSame,
              interfaceIndex == expectedInterface,
              flags & UInt32(kDNSServiceFlagsAdd) != 0, ttl > 0,
              rrtype == UInt16(kDNSServiceType_PTR), rrclass == UInt16(kDNSServiceClass_IN),
              let name = hostname(from: data) else { return nil }
        var identity = DeviceIdentification(friendlyName: name, source: "mDNS hostname", observedAt: observedAt)
        identity.expiresAt = observedAt.addingTimeInterval(TimeInterval(min(ttl, 180)))
        return identity
    }

    /// Kept injectable so lifetime and cancellation tests never issue LAN queries.
    struct Backend: @unchecked Sendable {
        var query: (String, UInt32, UnsafeMutableRawPointer) -> DNSServiceRef?
        var schedule: (DNSServiceRef, DispatchQueue) -> Bool
        var release: (DNSServiceRef) -> Void

        static let system = Backend(query: { owner, index, context in
            var reference: DNSServiceRef?
            let error = DNSServiceQueryRecord(&reference, UInt32(kDNSServiceFlagsForceMulticast), index,
                owner, UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN), { reference, flags, index, error, owner, type, cls, length, bytes, ttl, context in
                    guard error == kDNSServiceErr_NoError, let reference, let context,
                          let owner, let bytes, length > 0, length <= 255,
                          strnlen(owner, 1_009) < 1_009 else { return }
                    Unmanaged<Session>.fromOpaque(context).takeUnretainedValue().received(
                        reference, owner: String(cString: owner), data: Data(bytes: bytes, count: Int(length)),
                        interfaceIndex: index, flags: flags, rrtype: type, rrclass: cls, ttl: ttl)
                }, context)
            return error == kDNSServiceErr_NoError ? reference : nil
        }, schedule: { DNSServiceSetDispatchQueue($0, $1) == kDNSServiceErr_NoError },
        release: { DNSServiceRefDeallocate($0) })
    }

    /// All mutable state, callbacks and reference releases share this queue.
    final class Session: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.wifimancer.reverse-name")
        private let interfaceIndex: UInt32
        private let addresses: [String]
        private let backend: Backend
        private let lifetime: TimeInterval
        private var queries: [DNSServiceRef: (address: String, owner: String)] = [:]
        private var results: [String: DeviceIdentification] = [:]
        private var continuation: CheckedContinuation<[String: DeviceIdentification], Never>?
        private var timer: DispatchSourceTimer?
        private var finished = false

        init(interfaceIndex: UInt32, addresses: [String], backend: Backend = .system,
             lifetime: TimeInterval = ReverseNameDiscovery.timeout) {
            self.interfaceIndex = interfaceIndex
            self.addresses = ReverseNameDiscovery.boundedAddresses(Set(addresses))
            self.backend = backend
            self.lifetime = lifetime
        }

        func start(_ continuation: CheckedContinuation<[String: DeviceIdentification], Never>) {
            queue.async {
                guard !self.finished else { continuation.resume(returning: [:]); return }
                self.continuation = continuation
                guard self.interfaceIndex != 0 else { self.finish(); return }
                for address in self.addresses {
                    guard let owner = ReverseNameDiscovery.ownerName(for: address),
                          let reference = self.backend.query(owner, self.interfaceIndex, Unmanaged.passUnretained(self).toOpaque())
                    else { continue }
                    self.queries[reference] = (address, owner)
                    if !self.backend.schedule(reference, self.queue) {
                        self.queries.removeValue(forKey: reference)
                        self.backend.release(reference)
                    }
                }
                guard !self.queries.isEmpty else { self.finish(); return }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.setEventHandler { self.finish() }
                timer.schedule(deadline: .now() + self.lifetime)
                self.timer = timer
                timer.resume()
            }
        }

        func cancel() { queue.async { self.finish(cancelled: true) } }

        fileprivate func received(_ reference: DNSServiceRef, owner: String, data: Data,
                                  interfaceIndex: UInt32, flags: DNSServiceFlags,
                                  rrtype: UInt16, rrclass: UInt16, ttl: UInt32) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !finished, let query = queries[reference] else { return }
            if owner.caseInsensitiveCompare(query.owner) == .orderedSame,
               interfaceIndex == self.interfaceIndex, rrtype == UInt16(kDNSServiceType_PTR),
               rrclass == UInt16(kDNSServiceClass_IN),
               (flags & UInt32(kDNSServiceFlagsAdd) == 0 || ttl == 0) {
                results.removeValue(forKey: query.address)
                return
            }
            guard let value = ReverseNameDiscovery.identification(owner: owner, expectedOwner: query.owner,
                    data: data, interfaceIndex: interfaceIndex, expectedInterface: self.interfaceIndex,
                    flags: flags, rrtype: rrtype, rrclass: rrclass, ttl: ttl) else { return }
            results[query.address] = value
        }

        private func finish(cancelled: Bool = false) {
            dispatchPrecondition(condition: .onQueue(queue))
            guard !finished else { return }
            finished = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            for reference in queries.keys { backend.release(reference) }
            queries.removeAll()
            let continuation = continuation
            self.continuation = nil
            continuation?.resume(returning: cancelled ? [:] : results)
        }
    }
}
