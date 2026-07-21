import Foundation

public struct PluginSecurityPolicy: Equatable, Sendable {
    public let revokedPluginIDs: Set<String>
    public let minimumAPIVersion: Int
    public let requiredSignerTeamID: String?

    public init(revokedPluginIDs: Set<String> = [], minimumAPIVersion: Int = 1, requiredSignerTeamID: String? = nil) {
        self.revokedPluginIDs = revokedPluginIDs
        self.minimumAPIVersion = minimumAPIVersion
        self.requiredSignerTeamID = requiredSignerTeamID
    }

    public func validate(_ manifest: PluginManifest, signerTeamID: String? = nil) throws {
        guard manifest.apiVersion >= minimumAPIVersion,
              !revokedPluginIDs.contains(manifest.id),
              requiredSignerTeamID == nil || requiredSignerTeamID == signerTeamID else {
            throw PluginValidationError.invalidIdentifier
        }
    }
}
