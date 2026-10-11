import Foundation

@main
struct UPnPTests {
    static func main() async throws {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
        func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name + ".xml")) }
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
        }
        let samsung = UPnPDiscovery.parseDescriptor(try fixture("samsung"))
        expect(samsung?.friendlyName == "75\" Crystal UHD", "Samsung friendly name")
        expect(samsung?.modelName == "UA75DU7000UXMV", "Samsung exact advertised model")
        expect(samsung?.manufacturer == "Samsung Electronics", "Samsung manufacturer")
        expect(samsung?.services.count == 2, "Samsung services")
        expect(samsung?.source == "UPnP", "Identification provenance")
        let generic = UPnPDiscovery.parseDescriptor(try fixture("generic-renderer"))
        expect(generic?.deviceType == "urn:schemas-upnp-org:device:MediaRenderer:1", "Keep advertised generic type")
        expect(generic?.modelName == nil, "Do not invent a generic renderer model")
        var renderer = generic!
        renderer.modelName = "Samsung DTV DMR"
        let combined = UPnPDiscovery.combine([renderer, samsung!])
        expect(combined?.modelName == "UA75DU7000UXMV", "Specific reported model wins over a renderer role")
        expect(Set(combined!.services) == Set(renderer.services + samsung!.services), "Merge all advertised capabilities")
        expect(UPnPDiscovery.combine([samsung!, renderer]) == combined, "Description arrival order must not change identity")
        let router = UPnPDiscovery.parseDescriptor(try fixture("router-nested"))
        expect(router?.friendlyName == "Home Router", "Embedded device must not replace root name")
        expect(router?.manufacturer == "Example Networks", "Embedded vendor must not replace root vendor")
        expect(router?.modelName == "Router 20", "Embedded model must not replace root model")
        expect(router?.services.count == 2, "Include nested service capabilities")
        let ip = "192.168.1.3"
        let allowed: Set<String> = [ip]
        expect(UPnPDiscovery.validatedLocation("http://192.168.1.3:9197/dmr", senderIPv4: ip, allowedIPv4s: allowed) != nil, "Valid local LOCATION")
        for invalid in ["http://example.com/dmr", "http://192.168.1.4/dmr", "file:///etc/passwd", "http://user:pass@192.168.1.3/dmr", "http://127.0.0.1/dmr", "http://%31%39%32.168.1.3/dmr", "http://192.168.1.3:0/dmr", "http://192.168.1.3/dmr#fragment"] {
            expect(UPnPDiscovery.validatedLocation(invalid, senderIPv4: ip, allowedIPv4s: allowed) == nil, "Reject unsafe LOCATION: \(invalid)")
        }
        expect(UPnPDiscovery.validatedLocation("http://192.168.1.3/dmr", senderIPv4: ip, allowedIPv4s: []) == nil, "Unknown peers excluded")
        func reply(_ header: String) -> Data { Data("HTTP/1.1 200 OK\r\n\(header)\r\n\r\n".utf8) }
        expect(UPnPDiscovery.location(in: reply("LOCATION: http://192.168.1.3/dmr"), senderIPv4: ip, allowedIPv4s: allowed) != nil, "SSDP LOCATION parse")
        expect(UPnPDiscovery.location(in: reply("LOCATION: http://192.168.1.3/dmr\r\nLOCATION: http://192.168.1.3/other"), senderIPv4: ip, allowedIPv4s: allowed) == nil, "Ambiguous LOCATION rejected")
        expect(UPnPDiscovery.parseDescriptor(Data("<root><device>".utf8)) == nil, "Malformed XML rejected")
        expect(UPnPDiscovery.parseDescriptor(Data(repeating: 32, count: UPnPDiscovery.maximumDescriptorBytes + 1)) == nil, "Oversized XML rejected")
        expect(UPnPDiscovery.parseDescriptor(Data("<!DOCTYPE root [<!ENTITY name SYSTEM 'file:///etc/passwd'>]><root><device><friendlyName>&name;</friendlyName></device></root>".utf8)) == nil, "Entities rejected")
        expect(UPnPDiscovery.parseDescriptor(Data("<root><deviceList><device><friendlyName>Wrong root</friendlyName></device></deviceList></root>".utf8)) == nil, "Root device required")
        let long = "<root><device><friendlyName>" + String(repeating: "a", count: 2000) + "</friendlyName></device></root>"
        expect(UPnPDiscovery.parseDescriptor(Data(long.utf8))?.friendlyName?.count == 256, "Untrusted fields truncated")
        expect(UPnPDiscovery.parseDescriptor(Data("<root><device><friendlyName><![CDATA[TV & Sound]]></friendlyName></device></root>".utf8))?.friendlyName == "TV & Sound", "CDATA identity fields")
        let deep = "<root><device>" + String(repeating: "<x>", count: 40) + String(repeating: "</x>", count: 40) + "</device></root>"
        expect(UPnPDiscovery.parseDescriptor(Data(deep.utf8)) == nil, "Excessive nesting rejected")
        func loader() -> UPnPDescriptorLoader {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureURLProtocol.self]
            return UPnPDescriptorLoader(configuration: configuration)
        }
        let good = await loader().load(URL(string: "http://192.168.1.3/good")!)
        expect(good == Data("fixture".utf8), "Bounded loader accepts a normal response")
        let oversized = await loader().load(URL(string: "http://192.168.1.3/oversized")!)
        expect(oversized == nil, "Streaming download cap enforced without Content-Length")
        let rejected = await loader().load(URL(string: "http://192.168.1.3/rejected")!)
        expect(rejected == nil, "HTTP errors do not become device identities")
        let redirect = await loader().load(URL(string: "http://192.168.1.3/redirect")!)
        expect(redirect == nil, "Redirects refused")
        expect(!FixtureURLProtocol.requestLog.externalHostSeen, "No external redirect request")
        let cancelLoader = loader()
        let pending = Task { await cancelLoader.load(URL(string: "http://192.168.1.3/pending")!) }
        try await Task.sleep(nanoseconds: 20_000_000)
        pending.cancel()
        let cancelled = await pending.value
        expect(cancelled == nil, "Cancelling discovery cancels its descriptor download")
        print("UPnP parser, URL safety, bounded download and cancellation tests passed (no network access)")
    }
}

/// Every URL is intercepted; tests never open a LAN or internet connection.
private final class FixtureURLProtocol: URLProtocol {
    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var sawExternalHost = false
        var externalHostSeen: Bool { lock.lock(); defer { lock.unlock() }; return sawExternalHost }
        func record(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            if url.host != "192.168.1.3" { sawExternalHost = true }
        }
    }
    static let requestLog = RequestLog()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { fatalError("Missing fixture URL") }
        Self.requestLog.record(url)
        let path = url.path
        if path == "/pending" { return }
        if path == "/redirect" {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "http://example.invalid/outside"])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "http://example.invalid/outside")!), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: path == "/rejected" ? 403 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = path == "/oversized" ? Data(repeating: 65, count: UPnPDiscovery.maximumDescriptorBytes + 1) : Data("fixture".utf8)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
