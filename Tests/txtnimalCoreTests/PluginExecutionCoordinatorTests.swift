import XCTest
@testable import txtnimalCore

private struct TestTransport: PluginExecutionTransport {
    let response: Data
    func execute(pluginID: String, request: Data) async throws -> Data { response }
}

private struct DelayedTransport: PluginExecutionTransport {
    let delayNanoseconds: UInt64
    let response: Data
    func execute(pluginID: String, request: Data) async throws -> Data {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return response
    }
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
        XCTAssertEqual(records.first?.status, .pending)
        await coordinator.recordPersistSucceeded()
        let applied = await coordinator.executionRecords()
        XCTAssertEqual(applied.first?.status, .applied)
    }

    func testCoordinatorStaysPendingUntilHostPersistSucceeds() async throws {
        let manifest = PluginManifest(id: "app.txtnimal.test", name: "Test", version: "1.0.0", apiVersion: 1,
                                      entry: "main.js", capabilities: [.tasksUpdate])
        let action = PluginAction(type: .hostCommand, command: "tasks.rescheduleOverdue", expectedRevision: "doc")
        let coordinator = PluginExecutionCoordinator(transport: TestTransport(response: try JSONEncoder().encode(action)))
        _ = try await coordinator.execute(manifest: manifest, request: Data(), documentRevision: "doc")
        let pending = await coordinator.executionRecords()
        XCTAssertEqual(pending.map(\.status), [.pending])
        await coordinator.recordPersistSucceeded()
        let applied = await coordinator.executionRecords()
        XCTAssertEqual(applied.map(\.status), [.applied])
        XCTAssertNil(applied.first?.error)
    }

    func testCoordinatorMarksFailedWhenHostPersistFails() async throws {
        let manifest = PluginManifest(id: "app.txtnimal.test", name: "Test", version: "1.0.0", apiVersion: 1,
                                      entry: "main.js", capabilities: [.tasksUpdate])
        let action = PluginAction(type: .hostCommand, command: "tasks.rescheduleOverdue", expectedRevision: "doc")
        let coordinator = PluginExecutionCoordinator(transport: TestTransport(response: try JSONEncoder().encode(action)))
        _ = try await coordinator.execute(manifest: manifest, request: Data(), documentRevision: "doc")
        await coordinator.recordPersistFailed(TaskDocumentStoreError.writeFailed("/tmp/tasks.txt"))
        let records = await coordinator.executionRecords()
        XCTAssertEqual(records.map(\.status), [.failed])
        XCTAssertEqual(records.first?.error, TaskDocumentStoreError.writeFailed("/tmp/tasks.txt").errorDescription)
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
        XCTAssertEqual(records.first?.status, .failed)
    }

    func testTransportTimesOutWithInjectedDeadline() async throws {
        let transport = LimitedPluginExecutionTransport(
            base: DelayedTransport(delayNanoseconds: 200_000_000, response: Data()),
            timeoutNanoseconds: 10_000_000)
        do {
            _ = try await transport.execute(pluginID: "app.txtnimal.test", request: Data())
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? PluginExecutionError, .timedOut)
        }
    }

    func testTransportRejectsOversizedResponseBeforeReturningIt() async throws {
        let transport = LimitedPluginExecutionTransport(
            base: TestTransport(response: Data(repeating: 0, count: 12)),
            timeoutNanoseconds: 1_000_000_000,
            limits: PluginLimits(maximumPayloadBytes: 8))
        do {
            _ = try await transport.execute(pluginID: "app.txtnimal.test", request: Data())
            XCTFail("expected payload limit")
        } catch {
            XCTAssertEqual(error as? PluginExecutionError, .responseTooLarge(12))
        }
    }
}
