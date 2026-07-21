import XCTest
import CryptoKit
@testable import txtnimalCore

final class PluginRevocationStoreTests: XCTestCase {
    func testRevocationListIsAuthenticAndRejectsRollback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = P256.Signing.PrivateKey()
        let store = try PluginRevocationStore(directory: dir, trustedKey: key.publicKey)
        let unsigned = PluginRevocationList.make(version: 2, revokedPluginIDs: ["app.txtnimal.bad"])
        let signed = PluginRevocationList(version: unsigned.version, revokedPluginIDs: unsigned.revokedPluginIDs, payloadSHA256: unsigned.payloadSHA256, signatureBase64: try key.signature(for: unsigned.canonicalPayload()).derRepresentation.base64EncodedString())
        try store.update(signed)
        XCTAssertEqual(try store.load()?.version, 2)
        XCTAssertThrowsError(try store.update(PluginRevocationList.make(version: 1, revokedPluginIDs: [])))
        let otherKey = P256.Signing.PrivateKey()
        let forged = PluginRevocationList(version: 3, revokedPluginIDs: [], payloadSHA256: PluginRevocationList.make(version: 3, revokedPluginIDs: []).payloadSHA256, signatureBase64: try otherKey.signature(for: Data("3\n".utf8)).derRepresentation.base64EncodedString())
        XCTAssertThrowsError(try store.update(forged))
    }
}
