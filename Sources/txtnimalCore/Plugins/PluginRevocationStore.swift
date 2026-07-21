import Foundation
import CryptoKit

public struct PluginRevocationList: Codable, Equatable, Sendable {
    public let version: Int
    public let revokedPluginIDs: Set<String>
    public let payloadSHA256: String
    public init(version: Int, revokedPluginIDs: Set<String>, payloadSHA256: String) { self.version = version; self.revokedPluginIDs = revokedPluginIDs; self.payloadSHA256 = payloadSHA256 }
    public static func make(version: Int, revokedPluginIDs: Set<String>) -> PluginRevocationList {
        let payload = revokedPluginIDs.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return PluginRevocationList(version: version, revokedPluginIDs: revokedPluginIDs, payloadSHA256: hash)
    }
    public func isAuthentic() -> Bool { Self.make(version: version, revokedPluginIDs: revokedPluginIDs).payloadSHA256 == payloadSHA256 }
}

public final class PluginRevocationStore {
    public let url: URL
    public init(directory: URL, fileManager: FileManager = .default) throws { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true); url = directory.appendingPathComponent("revocations.json") }
    public func load() throws -> PluginRevocationList? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(PluginRevocationList.self, from: Data(contentsOf: url))
        guard value.isAuthentic() else { throw PluginExecutionError.transport("invalid revocation list") }; return value
    }
    public func update(_ value: PluginRevocationList) throws {
        guard value.isAuthentic(), value.version >= (try load()?.version ?? 0) else { throw PluginExecutionError.transport("revocation list rollback or invalid signature") }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
