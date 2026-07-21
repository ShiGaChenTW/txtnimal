import XCTest
@testable import txtnimalCore

final class PluginRevocationStoreTests: XCTestCase {
    func testRevocationListIsAuthenticAndRejectsRollback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PluginRevocationStore(directory: dir)
        try store.update(PluginRevocationList.make(version: 2, revokedPluginIDs: ["app.txtnimal.bad"]))
        XCTAssertEqual(try store.load()?.version, 2)
        XCTAssertThrowsError(try store.update(PluginRevocationList.make(version: 1, revokedPluginIDs: [])))
    }
}
