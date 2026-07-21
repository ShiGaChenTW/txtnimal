import XCTest
import CryptoKit
@testable import txtnimalCore

final class PluginSignatureTests: XCTestCase {
    func testEntrySignatureMustMatchTrustedTeam() throws {
        let data = Data("entry".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let policy = PluginSecurityPolicy(requiredSignerTeamID: "TEAM")
        XCTAssertNoThrow(try policy.validateSignature(PluginSignature(teamID: "TEAM", entrySHA256: hash), entryData: data))
        XCTAssertThrowsError(try policy.validateSignature(PluginSignature(teamID: "OTHER", entrySHA256: hash), entryData: data))
        XCTAssertThrowsError(try policy.validateSignature(PluginSignature(teamID: "TEAM", entrySHA256: "bad"), entryData: data))
    }
}
