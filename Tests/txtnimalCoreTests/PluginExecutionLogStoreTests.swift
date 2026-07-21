import XCTest
@testable import txtnimalCore

final class PluginExecutionLogStoreTests: XCTestCase {
    func testLogPersistsAndCapsRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PluginExecutionLogStore(directory: directory)
        for index in 0..<120 {
            try store.append(PluginExecutionRecord(pluginID: "app.txtnimal.test", command: "cmd-\(index)", succeeded: index.isMultiple(of: 2)))
        }
        let records = try store.load()
        XCTAssertEqual(records.count, 100)
        XCTAssertEqual(records.first?.command, "cmd-20")
        try store.clear()
        XCTAssertTrue(try store.load().isEmpty)
    }
}
