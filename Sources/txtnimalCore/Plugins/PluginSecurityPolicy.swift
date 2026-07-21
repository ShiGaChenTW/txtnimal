import Foundation
import CryptoKit

public struct PluginSignature: Codable, Equatable, Sendable {
    public let teamID: String
    public let entrySHA256: String
    public init(teamID: String, entrySHA256: String) { self.teamID = teamID; self.entrySHA256 = entrySHA256 }
}

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

    public func validateSignature(_ signature: PluginSignature, entryData: Data) throws {
        guard requiredSignerTeamID == nil || requiredSignerTeamID == signature.teamID else {
            throw PluginValidationError.invalidIdentifier
        }
        let digest = SHA256.hash(data: entryData).map { String(format: "%02x", $0) }.joined()
        guard digest == signature.entrySHA256 else { throw PluginValidationError.invalidEntryPath }
    }
}
