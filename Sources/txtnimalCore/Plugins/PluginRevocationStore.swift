import Foundation
import CryptoKit

public struct PluginRevocationList: Codable, Equatable, Sendable {
    public let version: Int
    public let revokedPluginIDs: Set<String>
    public let payloadSHA256: String
    public let signatureBase64: String?
    public init(version: Int, revokedPluginIDs: Set<String>, payloadSHA256: String, signatureBase64: String? = nil) { self.version = version; self.revokedPluginIDs = revokedPluginIDs; self.payloadSHA256 = payloadSHA256; self.signatureBase64 = signatureBase64 }
    public static func make(version: Int, revokedPluginIDs: Set<String>) -> PluginRevocationList {
        let payload = revokedPluginIDs.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return PluginRevocationList(version: version, revokedPluginIDs: revokedPluginIDs, payloadSHA256: hash)
    }
    public func canonicalPayload() -> Data { Data("\(version)\n\(revokedPluginIDs.sorted().joined(separator: "\n"))".utf8) }
    public func verifySignature(using trustedKey: P256.Signing.PublicKey) -> Bool {
        guard Self.make(version: version, revokedPluginIDs: revokedPluginIDs).payloadSHA256 == payloadSHA256,
              let signatureBase64, let signatureData = Data(base64Encoded: signatureBase64),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else { return false }
        return trustedKey.isValidSignature(signature, for: canonicalPayload())
    }
}

public final class PluginRevocationStore {
    public let url: URL
    private let trustedKey: P256.Signing.PublicKey
    public init(directory: URL, trustedKey: P256.Signing.PublicKey, fileManager: FileManager = .default) throws { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true); url = directory.appendingPathComponent("revocations.json"); self.trustedKey = trustedKey }
    public func load() throws -> PluginRevocationList? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(PluginRevocationList.self, from: Data(contentsOf: url))
        guard value.verifySignature(using: trustedKey) else { throw PluginExecutionError.transport("invalid revocation list signature") }; return value
    }
    public func update(_ value: PluginRevocationList) throws {
        guard value.verifySignature(using: trustedKey), value.version >= (try load()?.version ?? 0) else { throw PluginExecutionError.transport("revocation list rollback or invalid signature") }
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
