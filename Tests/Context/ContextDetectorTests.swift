@main
struct ContextDetectorTests {
    static func main() {
        let native = ContextDetector.detect()!
        precondition(Sysinfo.commands.isEmpty, "Native association must spawn no process")
        precondition(CWWiFiClient.requestedInterface == "fixture0")
        precondition(native.ssid == "Owned" && native.bssid == "02:00:00:00:02:01")
        precondition(native.interface == "fixture0" && native.selfIPv4 == "192.168.1.10"
                     && native.gatewayIPv4 == "192.168.1.1" && native.gatewayMAC != nil)
        CWWiFiClient.currentSSID = nil; CWWiFiClient.currentBSSID = nil
        Sysinfo.summary = "SSID : Other owned AP\nBSSID : 02:00:00:00:02:02\n"
        let fallback = ContextDetector.detect()!
        precondition(Sysinfo.commands == [["/usr/sbin/ipconfig", "getsummary", "fixture0"]],
                     "Unavailable native identities allow only one read of the known interface")
        precondition(Sysinfo.timeouts == [0.5], "Metadata fallback must not stall the session actor for five seconds")
        precondition(fallback.ssid == "Other owned AP" && fallback.bssid == "02:00:00:00:02:02")
        precondition(!NetworkSessionIdentity(context: native).matches(fallback), "Changed AP identity must invalidate binding")
        Sysinfo.commands = []
        Sysinfo.summary = "SSID : <redacted>\nBSSID : 02:00:00:00:00:00\n"
        let redacted = ContextDetector.detect()!
        precondition(redacted.ssid == nil && redacted.bssid == nil)
        precondition(Sysinfo.commands.count == 1, "No route lookup or verbose mutation")
        Sysinfo.summary = "SSID : \nBSSID : invalid\n"
        let unavailable = ContextDetector.detect()!
        precondition(unavailable.ssid == nil && unavailable.bssid == nil, "No cached old association")
        CWWiFiClient.currentSSID = "Old"; CWWiFiClient.currentBSSID = nil
        Sysinfo.summary = "SSID : New\nBSSID : 02:00:00:00:02:03\n"
        let switched = ContextDetector.detect()!
        precondition(switched.ssid == "New" && switched.bssid == "02:00:00:00:02:03", "Never mix old SSID with new AP")
        Sysinfo.summary = "SSID : New\nBSSID : invalid\n"
        let partialSwitch = ContextDetector.detect()!
        precondition(partialSwitch.ssid == "New" && partialSwitch.bssid == nil)
        CWWiFiClient.currentSSID = nil; CWWiFiClient.currentBSSID = "02:00:00:00:02:01"
        let partialNewSSID = ContextDetector.detect()!
        precondition(partialNewSSID.ssid == "New" && partialNewSSID.bssid == nil,
                     "Never combine a new summary SSID with a native BSSID from another observation")
        CWWiFiClient.currentSSID = "Old"; CWWiFiClient.currentBSSID = nil
        Sysinfo.summary = "BSSID : 02:00:00:00:02:03\n"
        let partialNewBSSID = ContextDetector.detect()!
        precondition(partialNewBSSID.ssid == nil && partialNewBSSID.bssid == "02:00:00:00:02:03",
                     "Never combine a new summary BSSID with a native SSID from another observation")
        CWWiFiClient.currentSSID = "Current"; CWWiFiClient.currentBSSID = "01:00:00:00:00:01"
        Sysinfo.summary = ""
        precondition(ContextDetector.detect()?.bssid == nil, "Multicast BSSID refused")
        Sysinfo.summary = "? (192.168.1.1) at c0:b1:1:0:0:1 on fixture0 ifscope [ethernet]"
        precondition(ContextDetector.arpLookup(ipv4: "192.168.1.1", iface: "fixture0")?.description == "c0:b1:01:00:00:01")
        precondition(MACAddress("c0:b1:1:0:0:1") == nil, "General MAC parsing remains strict")
        precondition(ContextDetector.arpLookup(ipv4: "192.168.1.1", iface: "other0") == nil, "Reject another interface's ARP entry")
        precondition(ContextDetector.arpLookup(ipv4: "192.168.1.2", iface: "fixture0") == nil, "Reject another IP's ARP entry")
        for invalid in ["c0:b1::0:0:1", "c0:b1:001:0:0:1", "c0:b1:gg:0:0:1", "c0:b1:+1:0:0:1", "01:00:00:00:00:01", "00:00:00:00:00:00", "(incomplete)"] {
            Sysinfo.summary = "? (192.168.1.1) at \(invalid) on fixture0 ifscope [ethernet]"
            precondition(ContextDetector.arpLookup(ipv4: "192.168.1.1", iface: "fixture0") == nil)
        }
        precondition(Sysinfo.timeouts.allSatisfy { $0 == 0.5 }, "Every read-only fallback is bounded")
        print("Context detector passed: bounded native/read-only paths, interface-bound association, changed AP, redaction, no mixed identities and macOS ARP formatting")
    }
}
