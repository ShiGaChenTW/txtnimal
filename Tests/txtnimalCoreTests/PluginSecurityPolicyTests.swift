import XCTest
@testable import txtnimalCore

final class PluginSecurityPolicyTests: XCTestCase {
    func testRevokedAndWrongSignerFailClosed() {
        let manifest = PluginManifest(id: "app.txtnimal.test", name: "Test", version: "1.0.0", apiVersion: 1, entry: "main.js", capabilities: [])
        XCTAssertThrowsError(try PluginSecurityPolicy(revokedPluginIDs: [manifest.id]).validate(manifest))
        XCTAssertThrowsError(try PluginSecurityPolicy(requiredSignerTeamID: "TEAM").validate(manifest, signerTeamID: "OTHER"))
        XCTAssertNoThrow(try PluginSecurityPolicy(requiredSignerTeamID: "TEAM").validate(manifest, signerTeamID: "TEAM"))
    }
}
