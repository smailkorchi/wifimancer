import Foundation

actor PacketFailureRecorder {
    private var messages: [String] = []
    func record(_ message: String) { messages.append(message) }
    var count: Int { messages.count }
}

@main
struct PacketActorSafetyTests {
    static let unexpectedFailure: @Sendable (String) -> Void = { preconditionFailure($0) }
    static let ownMAC = MACAddress("02:00:00:00:00:0a")!
    static let gatewayMAC = MACAddress("02:00:00:00:00:01")!
    static let selectedMAC = MACAddress("02:00:00:00:00:14")!
    static let trustedMAC = MACAddress("02:00:00:00:00:1e")!
    static let selected = ARPSpoofer.Target(ip: "192.168.1.20", mac: selectedMAC)
    static let context = NetworkContext(interface: "offline", selfIPv4: "192.168.1.10",
                                        selfIPv6: [], selfMAC: ownMAC,
                                        gatewayIPv4: "192.168.1.1", gatewayMAC: gatewayMAC,
                                        subnetCIDR: "192.168.1.0/24", ssid: "fixture",
                                        bssid: "02:00:00:00:01:01", ipv6Active: false,
                                        dnsServers: [])

    static func frameMAC(_ index: Int32, offset: Int32) -> [UInt8] {
        (0..<6).map { UInt8(offline_frame_byte(index, offset + Int32($0))) }
    }

    static func verifyRestoration(from index: Int32, currentMAC: MACAddress = selectedMAC) {
        precondition(offline_frame_count() == index + 10, "Five repairs in both directions")
        for frame in stride(from: index, to: index + 10, by: 2) {
            precondition(frameMAC(frame, offset: 0) == currentMAC.bytes)
            precondition(frameMAC(frame, offset: 22) == gatewayMAC.bytes)
            precondition(frameMAC(frame + 1, offset: 0) == gatewayMAC.bytes)
            precondition(frameMAC(frame + 1, offset: 22) == currentMAC.bytes)
        }
        precondition(offline_broadcast_count() == 0)
    }

    static func enqueue(_ mac: MACAddress, ip: String, askedIP: String) {
        mac.bytes.withUnsafeBufferPointer { bytes in
            ip.withCString { ip in
                askedIP.withCString { askedIP in offline_enqueue(bytes.baseAddress, ip, askedIP) }
            }
        }
    }

    static func settle() async throws {
        try await Task.sleep(nanoseconds: 25_000_000)
    }

    static func main() async throws {
        let unsafeTargets = [
            ARPSpoofer.Target(ip: context.selfIPv4, mac: trustedMAC),
            ARPSpoofer.Target(ip: "192.168.1.30", mac: ownMAC),
            ARPSpoofer.Target(ip: context.gatewayIPv4, mac: trustedMAC),
            ARPSpoofer.Target(ip: "192.168.1.30", mac: gatewayMAC),
            ARPSpoofer.Target(ip: "192.168.1.30", mac: MACAddress("00:00:00:00:00:00")!),
            ARPSpoofer.Target(ip: "192.168.1.30", mac: MACAddress("01:00:00:00:00:01")!),
            ARPSpoofer.Target(ip: "invalid", mac: trustedMAC),
            ARPSpoofer.Target(ip: "192.168.1.10\0suffix", mac: trustedMAC),
            ARPSpoofer.Target(ip: "224.0.0.1", mac: trustedMAC),
            ARPSpoofer.Target(ip: "192.168.2.30", mac: trustedMAC),
            ARPSpoofer.Target(ip: "192.168.1.0", mac: trustedMAC),
            ARPSpoofer.Target(ip: "192.168.1.255", mac: trustedMAC)
        ]
        precondition(ARPSpoofer.validatedTargets(unsafeTargets + [selected], context: context) == [selected])
        precondition(ARPSpoofer.validatedTargets([selected,
                     .init(ip: selected.ip, mac: trustedMAC)], context: context).isEmpty)
        precondition(ARPSpoofer.validatedTargets([selected,
                     .init(ip: "192.168.1.21", mac: selectedMAC)], context: context).isEmpty)

        offline_reset()
        let spoofer = ARPSpoofer(context: context, onFailure: unexpectedFailure)
        try await spoofer.start(targets: unsafeTargets + [selected], mode: .instant, bindings: [selected])
        try await settle()
        await spoofer.pause(seconds: 60)
        precondition(offline_frame_count() >= 2)
        for frame in 0..<offline_frame_count() {
            let destination = frameMAC(frame, offset: 0)
            precondition(destination == selectedMAC.bytes || destination == gatewayMAC.bytes)
            precondition(frameMAC(frame, offset: 22) == ownMAC.bytes)
        }
        let beforeRemoval = offline_frame_count()
        try await spoofer.update(targets: [], bindings: [selected])
        verifyRestoration(from: beforeRemoval)
        let afterRemoval = offline_frame_count()
        await spoofer.stop()
        precondition(offline_frame_count() == afterRemoval, "No duplicate repairs for removed peers")
        precondition(offline_open_count() == offline_close_count())

        offline_reset()
        try await spoofer.start(targets: [], mode: .instant, bindings: [selected])
        try await Task.sleep(nanoseconds: 250_000_000)
        await spoofer.stop()
        precondition(offline_frame_count() == 0, "Empty sessions must send no gateway broadcasts")

        offline_reset()
        try await spoofer.start(targets: [selected], mode: .instant, bindings: [selected])
        await spoofer.pause(seconds: 60)
        let beforeStop = offline_frame_count()
        await spoofer.stop()
        verifyRestoration(from: beforeStop)
        await spoofer.stop()
        precondition(offline_frame_count() == beforeStop + 10)
        try await spoofer.start(targets: [selected], mode: .instant, bindings: [selected])
        await spoofer.pause(seconds: 60)
        let beforeRestartStop = offline_frame_count()
        await spoofer.stop()
        verifyRestoration(from: beforeRestartStop)
        let stoppedCount = offline_frame_count()
        try await settle()
        precondition(offline_frame_count() == stoppedCount, "Cancelled loops cannot write through a reopened handle")

        offline_reset()
        try await spoofer.start(targets: [selected], mode: .instant, bindings: [selected])
        await spoofer.pause(seconds: 60)
        var nextLAN = context
        nextLAN.selfIPv4 = "192.168.1.11"
        let beforeChange = offline_frame_count()
        await spoofer.setContext(nextLAN)
        do {
            try await spoofer.update(targets: [selected], bindings: [selected])
            preconditionFailure("Changed network must reject stale update")
        } catch {}
        try await settle()
        precondition(offline_frame_count() == beforeChange, "A changed LAN gets no stale poison or repair")
        precondition(offline_open_count() == offline_close_count())
        await spoofer.setContext(context)
        try await spoofer.start(targets: [], mode: .instant, bindings: [selected])
        await spoofer.stop()

        offline_reset()
        let responder = ARPResponder(context: context, onFailure: unexpectedFailure)
        enqueue(ownMAC, ip: context.selfIPv4, askedIP: context.gatewayIPv4)
        enqueue(trustedMAC, ip: "192.168.1.30", askedIP: context.gatewayIPv4)
        enqueue(trustedMAC, ip: "192.168.1.30", askedIP: selected.ip)
        enqueue(selectedMAC, ip: selected.ip, askedIP: context.gatewayIPv4)
        enqueue(gatewayMAC, ip: context.gatewayIPv4, askedIP: selected.ip)
        try await responder.start(targets: unsafeTargets + [selected])
        try await settle()
        await responder.stop()
        precondition(offline_frame_count() == 2 && offline_broadcast_count() == 0)
        precondition(offline_open_count() == offline_close_count())

        offline_reset()
        enqueue(selectedMAC, ip: selected.ip, askedIP: context.gatewayIPv4)
        try await responder.start(targets: [])
        try await settle()
        await responder.stop()
        precondition(offline_frame_count() == 0)

        offline_reset()
        enqueue(selectedMAC, ip: selected.ip, askedIP: context.gatewayIPv4)
        try await responder.start(targets: [])
        await responder.setContext(nextLAN)
        do {
            try await responder.update(targets: [selected])
            preconditionFailure("Changed network must reject stale responder update")
        } catch {}
        try await settle()
        await responder.stop()
        precondition(offline_frame_count() == 0 && offline_open_count() == offline_close_count())

        offline_reset()
        var unknownGateway = context
        unknownGateway.gatewayMAC = nil
        let unavailableSpoofer = ARPSpoofer(context: unknownGateway, onFailure: unexpectedFailure)
        let unavailableResponder = ARPResponder(context: unknownGateway, onFailure: unexpectedFailure)
        do {
            try await unavailableSpoofer.start(targets: [selected], mode: .instant, bindings: [selected])
            preconditionFailure("Unknown restoration identity must fail closed")
        } catch {}
        do {
            try await unavailableResponder.start(targets: [selected])
            preconditionFailure("Unknown gateway requester identity must fail closed")
        } catch {}
        precondition(offline_open_count() == 0 && offline_frame_count() == 0)

        // Learning metadata or transient redaction is not a LAN change.
        offline_reset()
        var unknownMetadata = context
        unknownMetadata.ssid = nil; unknownMetadata.bssid = nil
        precondition(ARPSpoofer.sameLAN(unknownMetadata, context))
        var redactedMetadata = context
        redactedMetadata.ssid = "<redacted>"; redactedMetadata.bssid = nil
        redactedMetadata.gatewayMAC = nil
        precondition(ARPSpoofer.sameLAN(context, redactedMetadata))
        await spoofer.setContext(unknownMetadata)
        try await spoofer.start(targets: [selected], mode: .instant, bindings: [selected])
        await spoofer.pause(seconds: 60)
        let beforeLearning = offline_frame_count()
        await spoofer.setContext(context)
        await spoofer.setContext(redactedMetadata)
        try await spoofer.update(targets: [], bindings: [selected])
        verifyRestoration(from: beforeLearning)
        precondition(offline_open_count() == 1 && offline_close_count() == 0)
        await spoofer.stop()

        // A changed LAN closes without emitting even legitimate old repairs.
        offline_reset()
        await spoofer.setContext(context)
        try await spoofer.start(targets: [selected], mode: .instant, bindings: [selected])
        await spoofer.pause(seconds: 60)
        let beforeInvalidate = offline_frame_count()
        await spoofer.stop(restore: false)
        precondition(offline_frame_count() == beforeInvalidate)
        precondition(offline_open_count() == offline_close_count())

        // A trusted successor inherits the cut IP. The old MAC must never be
        // announced into the gateway cache by target removal or stop.
        offline_reset()
        let successor = ARPSpoofer.Target(ip: selected.ip, mac: trustedMAC)
        try await spoofer.start(targets: [selected], mode: .instant, bindings: [selected])
        await spoofer.pause(seconds: 60)
        let beforeReassignment = offline_frame_count()
        try await spoofer.update(targets: [], bindings: [successor])
        verifyRestoration(from: beforeReassignment, currentMAC: trustedMAC)
        await spoofer.stop()

        offline_reset()
        try await spoofer.start(targets: [selected], mode: .instant, bindings: [selected])
        await spoofer.pause(seconds: 60)
        let beforeReassignedStop = offline_frame_count()
        await spoofer.stop(bindings: [successor])
        verifyRestoration(from: beforeReassignedStop, currentMAC: trustedMAC)

        for uncertainBindings in [[ARPSpoofer.Target](), [selected, successor]] {
            offline_reset()
            try await spoofer.start(targets: [selected], mode: .instant, bindings: [selected])
            await spoofer.pause(seconds: 60)
            let beforeUncertain = offline_frame_count()
            try await spoofer.update(targets: [], bindings: uncertainBindings)
            precondition(offline_frame_count() == beforeUncertain, "Absent/conflicting evidence suppresses stale repair")
            await spoofer.stop()
        }

        // Runtime faults halt once. The controller then closes the dormant
        // spoofer handle after stopping the responder, with repairs if safe.
        offline_reset()
        let injectionFailures = PacketFailureRecorder()
        let brokenSpoofer = ARPSpoofer(context: context) { message in
            Task { await injectionFailures.record(message) }
        }
        offline_set_inject_result(-1)
        try await brokenSpoofer.start(targets: [selected], mode: .instant, bindings: [selected])
        try await settle()
        let faultCount = offline_frame_count()
        try await settle()
        precondition(offline_frame_count() == faultCount && faultCount == 1)
        let injectionFailureCount = await injectionFailures.count
        precondition(injectionFailureCount == 1)
        do {
            try await brokenSpoofer.update(targets: [selected], bindings: [selected])
            preconditionFailure("A failed packet loop cannot accept updates")
        } catch {}
        offline_set_inject_result(60)
        await brokenSpoofer.stop()
        verifyRestoration(from: faultCount)
        precondition(offline_open_count() == offline_close_count())

        for captureFailure in [true, false] {
            offline_reset()
            let failures = PacketFailureRecorder()
            let brokenResponder = ARPResponder(context: context) { message in
                Task { await failures.record(message) }
            }
            if captureFailure { offline_set_read_failure(1) }
            else {
                enqueue(selectedMAC, ip: selected.ip, askedIP: context.gatewayIPv4)
                offline_set_inject_result(-1)
            }
            try await brokenResponder.start(targets: [selected])
            try await settle()
            let afterFault = offline_frame_count()
            try await settle()
            precondition(offline_frame_count() == afterFault)
            let failureCount = await failures.count
            precondition(failureCount == 1)
            precondition(offline_open_count() == offline_close_count())
            await brokenResponder.stop()
        }

        offline_reset()
        offline_set_nonblock_failure(1)
        do {
            try await responder.start(targets: [selected])
            preconditionFailure("A blocking responder handle cannot be accepted")
        } catch {}
        precondition(offline_open_count() == offline_close_count())
        print("Packet actor safety passed: selected identities, no broadcasts, current-owner repairs, metadata learning, LAN invalidation, restart, and single capture/injection failure callback")
    }
}
