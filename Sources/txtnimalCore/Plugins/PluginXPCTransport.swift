import Foundation

/// Transport contract for the production Broker. The concrete NSXPC adapter
/// lives in the macOS app target; Core only defines the versioned boundary.
public struct PluginBrokerRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let pluginID: String
    public let payload: Data
    public init(pluginID: String, payload: Data, version: Int = 1) {
        self.version = version; self.pluginID = pluginID; self.payload = payload
    }
}

public struct PluginBrokerResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let payload: Data?
    public let error: String?
    public init(payload: Data? = nil, error: String? = nil, version: Int = 1) {
        self.version = version; self.payload = payload; self.error = error
    }
}
