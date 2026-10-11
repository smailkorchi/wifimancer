import Foundation
import Darwin
import SystemConfiguration

enum Sysinfo {

    // MARK: native detection (no fork, no PATH, no sandbox surface)

    /// Read the system's primary interface + IPv4 default gateway via
    /// SCDynamicStore. This bypasses Process/launchPath entirely — macOS 26
    /// LaunchDaemons get a stripped sandbox where shelling out to
    /// `/sbin/route`, `/sbin/ifconfig`, `/usr/sbin/ipconfig` produces empty
    /// output silently, which is why detect() was returning nil and the app
    /// was scanning nothing.
    static func nativePrimary() -> (iface: String, gateway: String)? {
        guard let store = SCDynamicStoreCreate(nil, "WifiMancerHelper" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let iface = dict["PrimaryInterface"] as? String,
              let gw = dict["Router"] as? String else { return nil }
        return (iface, gw)
    }

    /// getifaddrs() — IPv4/IPv6/MAC/netmask for one interface. Robust under
    /// any sandbox: it's a single syscall, no subprocess.
    static func nativeIfaceInfo(_ iface: String)
        -> (ipv4: String, cidrPrefix: Int, ipv6: [String], mac: String)? {
        var ifapPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifapPtr) == 0 else { return nil }
        defer { freeifaddrs(ifapPtr) }

        var ipv4: String?
        var prefix: Int?
        var ipv6List: [String] = []
        var macStr: String?

        var p = ifapPtr
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let ifa = cur.pointee
            guard String(cString: ifa.ifa_name) == iface,
                  let addrPtr = ifa.ifa_addr else { continue }
            let fam = Int32(addrPtr.pointee.sa_family)

            if fam == AF_INET {
                // Read the netmask FIRST so we can decide whether this is our
                // real interface address or an IP-claim alias.
                //
                // Why this matters: the IPClaimer cut-layer adds victim IPs
                // as `/32` host-route aliases on en0 (mask=255.255.255.255).
                // getifaddrs returns ALL of them in arbitrary order alongside
                // our real IP. If we let an alias win as selfIPv4, the context
                // detector sees selfIPv4 flip from 192.168.1.7 → alias on the
                // next refresh, fires a spurious "context changed" event,
                // tears down the spoofer, and the cut self-disengages within
                // 7 seconds of starting. Real interface IPs have a /24-/30
                // subnet mask; aliases are always /32. Skip /32 aliases.
                var thisPrefix: Int? = nil
                if let mskPtr = ifa.ifa_netmask {
                    mskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { msk in
                        let m = msk.pointee.sin_addr.s_addr
                        thisPrefix = m.nonzeroBitCount
                    }
                }
                if thisPrefix == 32 { continue }   // skip alias

                var addrBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                addrPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var sa = sin.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &sa, &addrBuf, socklen_t(INET_ADDRSTRLEN))
                }
                ipv4 = String(cString: addrBuf)
                prefix = thisPrefix
            } else if fam == AF_INET6 {
                var addrBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                addrPtr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var sa = sin6.pointee.sin6_addr
                    _ = inet_ntop(AF_INET6, &sa, &addrBuf, socklen_t(INET6_ADDRSTRLEN))
                }
                let s = String(cString: addrBuf)
                if !s.isEmpty { ipv6List.append(s) }
            } else if fam == AF_LINK {
                addrPtr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr in
                    let dl = dlPtr.pointee
                    guard dl.sdl_alen == 6 else { return }
                    let nlen = Int(dl.sdl_nlen)
                    // sdl_data is a tuple of CChars; advance past the name.
                    withUnsafePointer(to: dl.sdl_data) { tuplePtr in
                        let raw = UnsafeRawPointer(tuplePtr).advanced(by: nlen)
                        let bytes = raw.assumingMemoryBound(to: UInt8.self)
                        let parts = (0..<6).map { String(format: "%02x", bytes[$0]) }
                        macStr = parts.joined(separator: ":")
                    }
                }
            }
        }

        guard let ip = ipv4, let pre = prefix, let mac = macStr else { return nil }
        return (ip, pre, ipv6List, mac)
    }

    /// SCDynamicStore-based DNS list. Replaces `/usr/sbin/scutil --dns` shell-out.
    static func nativeDNSServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "WifiMancerHelper" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String] else { return [] }
        return servers
    }

    /// Read the kernel's IPv4 ARP table natively via sysctl(PF_ROUTE) and
    /// return the MAC for the requested IP. This is what `arp -an` does
    /// internally but without the subprocess. Returns nil if the IP is not
    /// in the cache (kernel hasn't talked to it yet).
    ///
    /// This is the fix for the recurring "gwMac=nil" pattern: the previous
    /// shell-out (`/usr/sbin/arp -n <ip>`) returns empty inside macOS 26
    /// LaunchDaemons, so the gateway MAC was nil for the entire spoof loop
    /// until a scan happened to observe a gateway ARP REPLY. Native sysctl
    /// works under any sandbox.
    static func nativeArpLookup(_ ipv4: String) -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, Int32(RTF_LLINFO)]
        var len = 0
        if sysctl(&mib, UInt32(mib.count), nil, &len, nil, 0) < 0 { return nil }
        guard len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        if sysctl(&mib, UInt32(mib.count), &buf, &len, nil, 0) < 0 { return nil }

        var targetAddr = in_addr()
        guard inet_pton(AF_INET, ipv4, &targetAddr) == 1 else { return nil }

        return buf.withUnsafeBufferPointer { bp -> String? in
            guard let base = bp.baseAddress else { return nil }
            var off = 0
            while off + MemoryLayout<rt_msghdr2>.size <= len {
                let rtm = base.advanced(by: off)
                    .withMemoryRebound(to: rt_msghdr2.self, capacity: 1) { $0.pointee }
                let msgLen = Int(rtm.rtm_msglen)
                guard msgLen > 0, off + msgLen <= len else { break }

                // sockaddr_in (destination) immediately follows the rtm header.
                let sinPtr = base.advanced(by: off + MemoryLayout<rt_msghdr2>.size)
                    .withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let sinLen = Int(sinPtr.sin_len)

                // sockaddr_dl (link-layer) follows sockaddr_in, padded to
                // 4-byte alignment.
                let dlOffset = MemoryLayout<rt_msghdr2>.size + ((sinLen + 3) & ~3)
                if dlOffset + MemoryLayout<sockaddr_dl>.size <= msgLen {
                    let dl = base.advanced(by: off + dlOffset)
                        .withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
                    if sinPtr.sin_addr.s_addr == targetAddr.s_addr, dl.sdl_alen == 6 {
                        let nlen = Int(dl.sdl_nlen)
                        let macStr = withUnsafePointer(to: dl.sdl_data) { tuplePtr -> String in
                            let raw = UnsafeRawPointer(tuplePtr).advanced(by: nlen)
                            let macBytes = raw.assumingMemoryBound(to: UInt8.self)
                            return (0..<6).map { String(format: "%02x", macBytes[$0]) }
                                .joined(separator: ":")
                        }
                        return macStr
                    }
                }
                off += msgLen
            }
            return nil
        }
    }

    /// Compute the network-address/prefix CIDR string from an IPv4 + prefix length.
    static func cidr(ipv4: String, prefix: Int) -> String {
        let parts = ipv4.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return "\(ipv4)/\(prefix)" }
        let ipNum = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        let mask: UInt32 = prefix == 0 ? 0 : 0xFFFF_FFFF << (32 - prefix)
        let net = ipNum & mask
        return "\((net >> 24) & 0xff).\((net >> 16) & 0xff).\((net >> 8) & 0xff).\(net & 0xff)/\(prefix)"
    }

    static func runShell(_ argv: [String], timeout: TimeInterval = 5) -> String {
        let p = Process()
        p.launchPath = argv[0]
        p.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            p.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func defaultInterface() -> String? {
        let out = runShell(["/sbin/route", "get", "default"])
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func defaultGateway() -> String? {
        let out = runShell(["/sbin/route", "get", "default"])
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") {
                return t.replacingOccurrences(of: "gateway:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func ipv4(of iface: String) -> String? {
        let out = runShell(["/usr/sbin/ipconfig", "getifaddr", iface])
        return out.isEmpty ? nil : out
    }

    static func ipv6(of iface: String) -> [String] {
        let out = runShell(["/sbin/ifconfig", iface])
        var v6: [String] = []
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("inet6 ") {
                let parts = t.split(separator: " ")
                if parts.count >= 2 {
                    v6.append(String(parts[1]).components(separatedBy: "%").first ?? String(parts[1]))
                }
            }
        }
        return v6
    }

    static func mac(of iface: String) -> String? {
        let out = runShell(["/sbin/ifconfig", iface])
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("ether ") {
                return String(t.dropFirst("ether ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func subnetCIDR(of iface: String) -> String? {
        let out = runShell(["/sbin/ifconfig", iface])
        var ip: String?, mask: UInt32?
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("inet ") && !t.hasPrefix("inet6") {
                let parts = t.split(separator: " ")
                if parts.count >= 4 {
                    ip = String(parts[1])
                    if let m = UInt32(String(parts[3]).dropFirst(2), radix: 16) {
                        mask = m
                    }
                }
            }
        }
        guard let ip, let mask else { return nil }
        let bits = String(mask, radix: 2).filter { $0 == "1" }.count
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return nil }
        let ipNum = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
        let net = ipNum & mask
        let n = [(net >> 24) & 0xff, (net >> 16) & 0xff, (net >> 8) & 0xff, net & 0xff]
        return "\(n[0]).\(n[1]).\(n[2]).\(n[3])/\(bits)"
    }

    static func dnsServers() -> [String] {
        let out = runShell(["/usr/sbin/scutil", "--dns"])
        var seen = Set<String>()
        var result: [String] = []
        for line in out.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("nameserver[") {
                if let r = t.range(of: ":") {
                    let v = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !v.isEmpty && !seen.contains(v) {
                        seen.insert(v); result.append(v)
                    }
                }
            }
        }
        return result
    }
}
