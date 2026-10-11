import Foundation
import os

enum Log {
    static let root = Logger(subsystem: "com.wifimancer.helper", category: "core")
    static let arp  = Logger(subsystem: "com.wifimancer.helper", category: "arp")
    static let ndp  = Logger(subsystem: "com.wifimancer.helper", category: "ndp")
    static let scan = Logger(subsystem: "com.wifimancer.helper", category: "scan")
    static let wifi = Logger(subsystem: "com.wifimancer.helper", category: "wifi")
    static let xpc  = Logger(subsystem: "com.wifimancer.helper", category: "xpc")
}
