import XCTest
import CryptoKit
@testable import txtnimalCore

final class PluginSignatureTests: XCTestCase {
    func testEntrySignatureMustMatchTrustedTeam() throws {
        let data = Data("entry".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let policy = PluginSecurityPolicy()
        XCTAssertNoThrow(try policy.validateSignature(PluginSignature(teamID: "TEAM", entrySHA256: hash), entryData: data))
        XCTAssertThrowsError(try PluginSecurityPolicy(requiredSignerTeamID: "TEAM").validateSignature(PluginSignature(teamID: "OTHER", entrySHA256: hash), entryData: data))
        XCTAssertThrowsError(try policy.validateSignature(PluginSignature(teamID: "TEAM", entrySHA256: "bad"), entryData: data))
    }

    func testP256SignatureMustVerifyDigest() throws {
        let data = Data("entry".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = P256.Signing.PrivateKey()
        let signature = try key.signature(for: Data(digest.utf8))
        let value = PluginSignature(teamID: "TEAM", entrySHA256: digest,
                                    publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                                    signatureBase64: signature.derRepresentation.base64EncodedString())
        XCTAssertNoThrow(try PluginSecurityPolicy(requiredSignerTeamID: "TEAM").validateSignature(value, entryData: data))
    }
}
