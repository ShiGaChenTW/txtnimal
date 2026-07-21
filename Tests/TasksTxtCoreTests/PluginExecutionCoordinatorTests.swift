import XCTest
@testable import TasksTxtCore

private struct TestTransport: PluginExecutionTransport {
    let response: Data
    func execute(pluginID: String, request: Data) async throws -> Data { response }
}

final class PluginExecutionCoordinatorTests: XCTestCase {
    func testCoordinatorValidatesTransportResponseAndRecordsSuccess() async throws {
        let manifest = PluginManifest(id: "app.txtnimal.test", name: "Test", version: "1.0.0", apiVersion: 1,
                                      entry: "main.js", capabilities: [.tasksUpdate])
        let action = PluginAction(type: .hostCommand, command: "tasks.rescheduleOverdue", expectedRevision: "doc")
        let response = try JSONEncoder().encode(action)
        let coordinator = PluginExecutionCoordinator(transport: TestTransport(response: response))
        let intent = try await coordinator.execute(manifest: manifest, request: Data(), documentRevision: "doc")
        XCTAssertEqual(intent.command, .rescheduleOverdue)
        let records = await coordinator.executionRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testCoordinatorRejectsDuplicateResponseKeys() async throws {
        let manifest = PluginManifest(id: "app.txtnimal.test", name: "Test", version: "1.0.0", apiVersion: 1,
                                      entry: "main.js", capabilities: [.tasksUpdate])
        let response = Data(#"{"type":"hostCommand","command":"tasks.rescheduleOverdue","command":"tasks.rescheduleOverdue","expectedRevision":"doc"}"#.utf8)
        let coordinator = PluginExecutionCoordinator(transport: TestTransport(response: response))
        do {
            _ = try await coordinator.execute(manifest: manifest, request: Data(), documentRevision: "doc")
            XCTFail("expected duplicate key rejection")
        } catch { XCTAssertTrue(error is PluginJSONError) }
        let records = await coordinator.executionRecords()
        XCTAssertEqual(records.count, 1)
    }
}
