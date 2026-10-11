import Foundation

/// Identity reported by a device's discovery services, separate from its
/// network adapter's OUI vendor. Missing fields remain unknown.
public struct DeviceIdentification: Codable, Hashable, Sendable {
    public var friendlyName: String?
    public var manufacturer: String?
    public var modelName: String?
    public var modelNumber: String?
    public var modelDescription: String?
    public var deviceType: String?
    public var services: [String]
    public var source: String
    public var observedAt: Date
    public var expiresAt: Date?

    public init(friendlyName: String? = nil, manufacturer: String? = nil,
                modelName: String? = nil, modelNumber: String? = nil,
                modelDescription: String? = nil, deviceType: String? = nil,
                services: [String] = [], source: String = "unknown", observedAt: Date = .now,
                expiresAt: Date? = nil) {
        self.friendlyName = friendlyName; self.manufacturer = manufacturer
        self.modelName = modelName; self.modelNumber = modelNumber
        self.modelDescription = modelDescription; self.deviceType = deviceType
        self.services = services; self.source = source; self.observedAt = observedAt
        self.expiresAt = expiresAt
    }
}
