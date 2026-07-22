import XCTest
@testable import txtnimalCore

final class PluginExecutionLogStoreTests: XCTestCase {
    func testLegacySucceededRecordDecodesIntoStatus() throws {
        let data = Data(#"{"pluginID":"app.txtnimal.test","command":"cmd","succeeded":true,"timestamp":0}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record = try decoder.decode(PluginExecutionRecord.self, from: data)
        XCTAssertEqual(record.status, .applied)
        XCTAssertTrue(record.succeeded)
    }

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
