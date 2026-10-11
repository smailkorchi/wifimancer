import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Darwin

/// Read-only UPnP identity discovery for peers already observed on the current LAN.
enum UPnPDiscovery {
    static let maximumDescriptorBytes = 128 * 1024

    static func discover(sourceIPv4: String, allowedIPv4s: Set<String>) async -> [String: DeviceIdentification] {
        guard canonicalIPv4(sourceIPv4) != nil, !allowedIPv4s.isEmpty, !Task.isCancelled else { return [:] }
        let allowed = Set(allowedIPv4s.filter { canonicalIPv4($0) != nil && $0 != sourceIPv4 })
        let receiver = Task.detached(priority: .utility) { locations(sourceIPv4: sourceIPv4, allowedIPv4s: allowed) }
        let candidates = await withTaskCancellationHandler {
            await receiver.value
        } onCancel: {
            receiver.cancel()
        }
        guard !Task.isCancelled else { return [:] }
        return await withTaskGroup(of: (String, DeviceIdentification?).self) { group in
            for (ip, urls) in candidates {
                group.addTask {
                    var descriptions: [DeviceIdentification] = []
                    for url in urls {
                        guard !Task.isCancelled else { return (ip, nil) }
                        let loader = UPnPDescriptorLoader()
                        if let data = await loader.load(url), let identification = parseDescriptor(data) {
                            descriptions.append(identification)
                        }
                    }
                    return (ip, combine(descriptions))
                }
            }
            var found: [String: DeviceIdentification] = [:]
            for await (ip, identification) in group {
                if let identification { found[ip] = identification }
            }
            return found
        }
    }

    static func combine(_ descriptions: [DeviceIdentification]) -> DeviceIdentification? {
        // A model identifier is more specific than a generic renderer role.
        let ordered = descriptions.sorted {
            func rank(_ identity: DeviceIdentification) -> Int {
                let model = identity.modelName ?? ""
                return model.isEmpty ? 0 : (model.contains(where: \.isNumber) ? 2 : 1)
            }
            return rank($0) == rank($1)
                ? ($0.modelName ?? "") < ($1.modelName ?? "") : rank($0) > rank($1)
        }
        guard var result = ordered.first else { return nil }
        for identity in ordered.dropFirst() {
            result.friendlyName = result.friendlyName ?? identity.friendlyName
            result.manufacturer = result.manufacturer ?? identity.manufacturer
            result.modelName = result.modelName ?? identity.modelName
            result.modelNumber = result.modelNumber ?? identity.modelNumber
            result.modelDescription = result.modelDescription ?? identity.modelDescription
            result.deviceType = result.deviceType ?? identity.deviceType
        }
        result.services = Array(Set(descriptions.flatMap(\.services))).sorted()
        result.observedAt = descriptions.map(\.observedAt).min()!
        return result
    }

    /// A LOCATION must refer directly to the numeric address that sent the reply.
    static func validatedLocation(_ value: String, senderIPv4: String, allowedIPv4s: Set<String>) -> URL? {
        guard allowedIPv4s.contains(senderIPv4), canonicalIPv4(senderIPv4) != nil,
              value.utf8.count <= 2048,
              let parts = URLComponents(string: value),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.host == senderIPv4, parts.percentEncodedHost == senderIPv4,
              parts.port == nil || (1...65535).contains(parts.port!),
              let url = parts.url else { return nil }
        return url
    }

    static func location(in response: Data, senderIPv4: String, allowedIPv4s: Set<String>) -> URL? {
        guard response.count < 8192, let text = String(data: response, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " "), status.count >= 2,
              ["HTTP/1.1", "HTTP/1.0"].contains(String(status[0])), status[1] == "200" else { return nil }
        let locations = lines.dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"), line[..<colon].lowercased() == "location" else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard locations.count == 1 else { return nil }
        return validatedLocation(locations[0], senderIPv4: senderIPv4, allowedIPv4s: allowedIPv4s)
    }

    static func parseDescriptor(_ data: Data) -> DeviceIdentification? {
        // UPnP descriptions use UTF-8. Reject DTDs entirely, including internal
        // entities; disabling external resolution alone does not prevent expansion.
        guard !data.isEmpty, data.count <= maximumDescriptorBytes, !data.contains(0),
              let xml = String(data: data, encoding: .utf8),
              xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return nil }
        let delegate = DescriptorParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.sawRootDevice else { return nil }
        let fields = delegate.fields
        guard !fields.isEmpty || !delegate.services.isEmpty else { return nil }
        return DeviceIdentification(
            friendlyName: fields["friendlyName"], manufacturer: fields["manufacturer"],
            modelName: fields["modelName"], modelNumber: fields["modelNumber"],
            modelDescription: fields["modelDescription"], deviceType: fields["deviceType"],
            services: delegate.services.sorted(), source: "UPnP", observedAt: Date()
        )
    }

    private static func canonicalIPv4(_ value: String) -> in_addr? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        let host = UInt32(bigEndian: address.s_addr)
        guard host != 0, host != UInt32.max, host >> 24 != 127, host >> 24 < 224 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil,
              String(cString: buffer) == value else { return nil }
        return address
    }

    private static func locations(sourceIPv4: String, allowedIPv4s: Set<String>) -> [String: [URL]] {
        guard var localAddress = canonicalIPv4(sourceIPv4), !allowedIPv4s.isEmpty else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        local.sin_addr = localAddress
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return [:] }
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        var ttl: UInt8 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &localAddress, socklen_t(MemoryLayout<in_addr>.size)) == 0,
              setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size)) == 0 else { return [:] }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1900).bigEndian
        // Some Wi-Fi paths suppress multicast discovery replies. The same
        // read-only SSDP query can be sent directly to already-observed peers.
        let destinations = ["239.255.255.250"] + allowedIPv4s.sorted().prefix(32)
        for host in destinations {
            guard !Task.isCancelled else { return [:] }
            inet_pton(AF_INET, host, &destination.sin_addr)
            let message = Data("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: ssdp:all\r\n\r\n".utf8)
            _ = message.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2.0
        var found: [String: [URL]] = [:]
        var buffer = [UInt8](repeating: 0, count: 8192)
        var packets = 0
        while ProcessInfo.processInfo.systemUptime < deadline, packets < 96, !Task.isCancelled {
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }
                break
            }
            packets += 1
            guard sender.sin_family == sa_family_t(AF_INET), length >= MemoryLayout<sockaddr_in>.size else { continue }
            var address = sender.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &text, socklen_t(text.count)) != nil else { continue }
            let ip = String(cString: text)
            guard let url = location(in: Data(buffer.prefix(count)), senderIPv4: ip, allowedIPv4s: allowedIPv4s),
                  found[ip] != nil || found.count < 16 else { continue }
            var urls = found[ip] ?? []
            if urls.count < 2, !urls.contains(url) { urls.append(url) }
            found[ip] = urls
        }
        return found
    }
}

private final class DescriptorParser: NSObject, XMLParserDelegate {
    var sawRootDevice = false
    var fields: [String: String] = [:]
    var services: Set<String> = []
    private var elements: [String] = []
    private var text: [String] = []
    private let identityFields: Set<String> = ["friendlyName", "manufacturer", "modelName", "modelNumber", "modelDescription", "deviceType"]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard elements.count < 32 else { parser.abortParsing(); return }
        elements.append(elementName)
        text.append("")
        if elements == ["root", "device"] { sawRootDevice = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !text.isEmpty else { return }
        let index = text.count - 1
        text[index].append(contentsOf: string.prefix(max(0, 512 - text[index].count)))
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let value = text.last else { return }
        let clean = value.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        if elements.count == 3, elements.prefix(2) == ["root", "device"], identityFields.contains(elementName), !clean.isEmpty, fields[elementName] == nil {
            fields[elementName] = String(clean.prefix(elementName == "modelDescription" ? 512 : 256))
        }
        if elements.prefix(2) == ["root", "device"], elements.suffix(3) == ["serviceList", "service", "serviceType"], !clean.isEmpty, services.count < 64 {
            services.insert(String(clean.prefix(256)))
        }
        elements.removeLast()
        text.removeLast()
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
}

/// Streaming accumulation prevents an untrusted peer from supplying an unbounded response.
final class UPnPDescriptorLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var continuation: CheckedContinuation<Data?, Never>?
    private var session: URLSession?
    private var bytes = Data()
    private var completed = false

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    func load(_ url: URL) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !completed else { lock.unlock(); continuation.resume(returning: nil); return }
                self.continuation = continuation
                let config = configuration
                config.timeoutIntervalForRequest = 3
                config.timeoutIntervalForResource = 3
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.connectionProxyDictionary = [:]
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: url)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.finish(nil)
        }
    }

    private func finish(_ data: Data?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(returning: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              response.expectedContentLength <= Int64(UPnPDiscovery.maximumDescriptorBytes) else {
            completionHandler(.cancel)
            finish(nil)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard bytes.count + data.count <= UPnPDiscovery.maximumDescriptorBytes else { lock.unlock(); finish(nil); return }
        bytes.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result = error == nil ? bytes : nil
        lock.unlock()
        finish(result)
    }
}
