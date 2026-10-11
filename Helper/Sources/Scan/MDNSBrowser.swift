import Foundation

/// Continuous Bonjour / mDNS service browser.
///
/// Implementation note: an earlier version drove `/usr/bin/dns-sd` as a
/// subprocess, which fails because the CLI block-buffers stdout when its
/// destination isn't a TTY (verified — 12-second test windows surfaced
/// zero output). The current implementation talks directly to
/// `mDNSResponder` through the `<dns_sd.h>` C API via the `wm_mdns_*`
/// shim in `Helper/CSources/wm_mdns.c`. That gives us TXT records pushed
/// inline on a serial dispatch queue with no buffering pathology.
///
/// The high-value field is the `model=` TXT key on `_airplay._tcp` and
/// `_device-info._tcp`, which carries Apple's hardware identifier
/// (e.g. `MacBookPro17,1`). The browser surfaces it as
/// `Discovery.appleModelIdentifier`; the upper layer hands that to
/// `AppleModelResolver` to get the marketing name.
public actor MDNSBrowser {

    public struct Discovery: Sendable, Hashable {
        public let serviceType: String
        public let instanceName: String
        public let hostTarget: String
        public let port: Int
        public let txt: [String: String]

        public var prettyName: String {
            instanceName.replacingOccurrences(of: "\\032", with: " ")
        }

        public var appleModelIdentifier: String? {
            txt["model"] ?? txt["am"]
        }
    }

    public static let defaultServiceTypes: [String] = [
        "_device-info._tcp",
        "_airplay._tcp",
        "_raop._tcp",
        "_companion-link._tcp",
        "_smb._tcp",
        "_afpovertcp._tcp",
        "_ssh._tcp",
        "_sftp-ssh._tcp",
        "_http._tcp",
        "_https._tcp",
        "_rfb._tcp",
        "_rtsp._tcp",
        "_googlecast._tcp",
        "_printer._tcp",
        "_ipp._tcp",
        "_homekit._tcp",
        "_apple-mobdev2._tcp",
        "_workstation._tcp",
        "_spotify-connect._tcp"
    ]

    public typealias Sink = @Sendable (Discovery) async -> Void

    /// Heap-allocated sink trampoline. We hand its `Unmanaged.toOpaque()`
    /// pointer to the C side and let it ride along through every callback;
    /// `stop()` reverses the retain.
    fileprivate final class SinkBox: @unchecked Sendable {
        let sink: Sink
        init(_ s: @escaping Sink) { self.sink = s }
    }

    private struct Subscription {
        let handle: UnsafeMutableRawPointer
        let boxPtr: UnsafeMutableRawPointer
    }

    private var subs: [Subscription] = []

    public init() {}

    public func start(serviceTypes: [String] = defaultServiceTypes,
                      sink: @escaping Sink) {
        for type in serviceTypes {
            let box = SinkBox(sink)
            let raw = Unmanaged.passRetained(box).toOpaque()
            type.withCString { tptr in
                if let h = wm_mdns_open(tptr, mdns_event_thunk, raw, nil) {
                    subs.append(Subscription(handle: h, boxPtr: raw))
                } else {
                    Unmanaged<SinkBox>.fromOpaque(raw).release()
                }
            }
        }
    }

    public func stop() {
        for s in subs {
            wm_mdns_close(s.handle)
            Unmanaged<SinkBox>.fromOpaque(s.boxPtr).release()
        }
        subs.removeAll()
    }

    public var subscriptionCount: Int { subs.count }
}

// MARK: - C callback thunks (file-scope, no captures so they coerce to
// C function pointers).

/// Accumulator the TXT-iter thunk fills as it walks one record.
private final class TXTAcc {
    var dict: [String: String] = [:]
}

private let mdns_event_thunk: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UInt16,
    UInt16,
    UnsafePointer<UInt8>?,
    UnsafeMutableRawPointer?
) -> Void = { typePtr, namePtr, hostPtr, port, txtLen, txtData, userPtr in
    guard let userPtr, let typePtr, let namePtr else { return }
    let box = Unmanaged<MDNSBrowser.SinkBox>.fromOpaque(userPtr).takeUnretainedValue()

    let serviceType = String(cString: typePtr)
    let instanceName = String(cString: namePtr)
    let hostTarget = hostPtr.map { String(cString: $0) } ?? ""

    let acc = TXTAcc()
    let accRaw = Unmanaged.passRetained(acc).toOpaque()
    wm_mdns_txt_iterate(txtLen, txtData, mdns_txt_thunk, accRaw)
    let txtDict = acc.dict
    Unmanaged<TXTAcc>.fromOpaque(accRaw).release()

    let discovery = MDNSBrowser.Discovery(
        serviceType: serviceType,
        instanceName: instanceName,
        hostTarget: hostTarget,
        port: Int(port),
        txt: txtDict
    )
    Task { await box.sink(discovery) }
}

private let mdns_txt_thunk: @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { keyPtr, valPtr, userPtr in
    guard let keyPtr, let valPtr, let userPtr else { return }
    let acc = Unmanaged<TXTAcc>.fromOpaque(userPtr).takeUnretainedValue()
    acc.dict[String(cString: keyPtr)] = String(cString: valPtr)
}
