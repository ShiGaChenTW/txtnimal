import Foundation
import XCTest
@testable import txtnimalCore

private struct ImmediateAgentTransport: AgentTransport {
    let response: Data
    func complete(request: Data) async throws -> Data { response }
}

private actor ControlledAgentTransport: AgentTransport {
    private let response: Data
    private var continuation: CheckedContinuation<Data, Error>?
    private var started = false
    private var cancellationRequested = false

    init(response: Data) { self.response = response }

    func complete(request: Data) async throws -> Data {
        started = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                if cancellationRequested {
                    $0.resume(throwing: CancellationError())
                } else {
                    continuation = $0
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume() {
        continuation?.resume(returning: response)
        continuation = nil
    }

    private func cancel() {
        cancellationRequested = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private actor RecordingAgentTransport: AgentTransport {
    private let response: Data
    private var recordedRequest: Data?

    init(response: Data) { self.response = response }

    func complete(request: Data) async throws -> Data {
        recordedRequest = request
        return response
    }

    func request() -> Data? { recordedRequest }
}

final class AgentRunnerTests: XCTestCase {
    func testRequestContainsOnlySelectedTaskMinimalFields() async throws {
        let response = Data(#"[{"taskID":"task-1","newDue":"2026-07-24"}]"#.utf8)
        let transport = RecordingAgentTransport(response: response)
        let runner = AgentRunner(transport: transport)
        let selected = PluginTaskSnapshot(id: "task-1", title: "Selected task", due: "2026-07-23",
                                          completed: true, lists: ["private-list"], tags: ["private-tag"],
                                          revision: "private-revision")
        let unselected = PluginTaskSnapshot(id: "task-2", title: "Unselected task", due: "2026-07-25",
                                            revision: "other-revision")

        _ = try await runner.execute(query: query(), manifest: manifest(), tasks: [selected, unselected],
                                     taskRevisions: ["task-1": "task-rev"],
                                     documentRevision: "doc-rev")

        let recordedRequest = await transport.request()
        let requestData = try XCTUnwrap(recordedRequest)
        let request = try JSONDecoder().decode(AgentTransportRequest.self, from: requestData)
        XCTAssertEqual(request.tasks, [
            AgentTransportTask(id: "task-1", title: "Selected task", due: "2026-07-23")
        ])
        let payload = String(decoding: requestData, as: UTF8.self)
        for excludedValue in ["task-2", "Unselected task", "private-list", "private-tag",
                              "private-revision", "completed", "lists", "tags", "revision"] {
            XCTAssertFalse(payload.contains(excludedValue), "request leaked \(excludedValue)")
        }
    }

    func testLegacyTransportRequestDefaultsTasksToEmpty() throws {
        let data = Data(#"{"prompt":"prompt","taskIDs":["task-1"],"resultSchema":"reschedule.v1"}"#.utf8)

        let request = try JSONDecoder().decode(AgentTransportRequest.self, from: data)

        XCTAssertEqual(request.tasks, [])
    }

    func testTransportTaskEncodesMissingDueExplicitlyAsNull() throws {
        let request = AgentTransportRequest(prompt: "prompt", taskIDs: ["task-1"],
                                            resultSchema: "reschedule.v1",
                                            tasks: [.init(id: "task-1", title: "No due task", due: nil)])

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])

        XCTAssertTrue(tasks[0].keys.contains("due"))
        XCTAssertTrue(tasks[0]["due"] is NSNull)
    }

    func testSuccessfulResultMapsThroughValidatorAndTransitionsToApplied() async throws {
        let response = Data(#"[{"taskID":"task-1","newDue":"2026-07-23"}]"#.utf8)
        let transport = ControlledAgentTransport(response: response)
        let runner = AgentRunner(transport: transport)
        let execution = Task {
            try await runner.execute(query: query(), manifest: manifest(),
                                     taskRevisions: ["task-1": "task-rev"],
                                     documentRevision: "doc-rev")
        }

        await transport.waitUntilStarted()
        let pendingRecords = await runner.executionRecords()
        XCTAssertEqual(pendingRecords.map(\.status), [.pending])
        await transport.resume()

        let intents = try await execution.value
        XCTAssertEqual(intents, [
            ValidatedPluginIntent(pluginID: "app.txtnimal.agent-test", command: .rescheduleTask,
                                  taskIDs: ["task-1"], due: "2026-07-23",
                                  expectedRevision: "task-rev", documentRevision: "doc-rev")
        ])
        let appliedRecords = await runner.executionRecords()
        XCTAssertEqual(appliedRecords.map(\.status), [.applied])
    }

    func testUnknownResultSchemaIsRejectedAndRecordsFailure() async {
        let response = Data(#"[{"taskID":"task-1","newDue":"2026-07-23"}]"#.utf8)

        for schema in ["tag.v1", "reschedule.v2"] {
            let runner = AgentRunner(transport: ImmediateAgentTransport(response: response))

            await assertAgentError(.unsupportedResultSchema) {
                try await runner.execute(query: query(resultSchema: schema), manifest: manifest(),
                                         taskRevisions: ["task-1": "task-rev"],
                                         documentRevision: "doc-rev")
            }
            let failedRecords = await runner.executionRecords()
            XCTAssertEqual(failedRecords.map(\.status), [.failed])
        }
    }

    func testEmptyResultSchemaIsRejectedDuringQueryValidation() async {
        let runner = AgentRunner(transport: ImmediateAgentTransport(response: Data()))

        do {
            _ = try await runner.execute(query: query(resultSchema: ""), manifest: manifest(),
                                         taskRevisions: ["task-1": "task-rev"],
                                         documentRevision: "doc-rev")
            XCTFail("expected empty result schema to be rejected")
        } catch {
            XCTAssertEqual(error as? PluginValidationError, .invalidAction)
        }
        let failedRecords = await runner.executionRecords()
        XCTAssertEqual(failedRecords.map(\.status), [.failed])
    }

    func testRescheduleDispatcherMapsStructuredResultToHostActions() throws {
        let response = Data(#"[{"taskID":"task-1","newDue":"2026-07-23"}]"#.utf8)

        let actions = try AgentResultDispatcher.actions(resultSchema: "reschedule.v1", response: response,
                                                        query: query(), limits: .init())

        XCTAssertEqual(actions, [
            PluginAction(type: .hostCommand, command: PluginHostCommand.rescheduleTask.rawValue,
                         taskIDs: ["task-1"], due: "2026-07-23", expectedRevision: "task-rev",
                         documentRevision: "doc-rev")
        ])
    }

    func testDispatcherRejectsUnknownResultSchema() {
        XCTAssertThrowsError(try AgentResultDispatcher.actions(resultSchema: "tag.v1", response: Data(),
                                                               query: query(), limits: .init())) { error in
            XCTAssertEqual(error as? AgentRunnerError, .unsupportedResultSchema)
        }
    }

    func testTimeoutIsDistinctAndRecordsFailure() async {
        let transport = ControlledAgentTransport(response: Data())
        let runner = AgentRunner(transport: transport, timeoutNanoseconds: 1_000_000)

        await assertAgentError(.timedOut) {
            try await runner.execute(query: query(), manifest: manifest(),
                                     taskRevisions: ["task-1": "task-rev"],
                                     documentRevision: "doc-rev")
        }
        let failedRecords = await runner.executionRecords()
        XCTAssertEqual(failedRecords.map(\.status), [.failed])
    }

    func testCancellationIsDistinctAndRecordsCancellation() async {
        let transport = ControlledAgentTransport(response: Data())
        let runner = AgentRunner(transport: transport)
        let execution = Task {
            try await runner.execute(query: query(), manifest: manifest(),
                                     taskRevisions: ["task-1": "task-rev"],
                                     documentRevision: "doc-rev")
        }
        await transport.waitUntilStarted()
        execution.cancel()

        await assertAgentError(.cancelled) { try await execution.value }
        let cancelledRecords = await runner.executionRecords()
        XCTAssertEqual(cancelledRecords.map(\.status), [.cancelled])
    }

    func testOversizedResponseIsRejected() async {
        let runner = AgentRunner(transport: ImmediateAgentTransport(response: Data(repeating: 0x20, count: 9)),
                                 limits: .init(maximumPayloadBytes: 8))
        await assertAgentError(.payloadTooLarge) {
            try await runner.execute(query: query(), manifest: manifest(),
                                     taskRevisions: ["task-1": "task-rev"],
                                     documentRevision: "doc-rev")
        }
    }

    func testMalformedStructuredResultIsRejected() async {
        let runner = AgentRunner(transport: ImmediateAgentTransport(response: Data(#"{"not":"an array"}"#.utf8)))
        await assertAgentError(.invalidResponse) {
            try await runner.execute(query: query(), manifest: manifest(),
                                     taskRevisions: ["task-1": "task-rev"],
                                     documentRevision: "doc-rev")
        }
    }

    func testMappedResultIsRejectedWhenTaskRevisionChanged() async {
        let response = Data(#"[{"taskID":"task-1","newDue":"2026-07-23"}]"#.utf8)
        let runner = AgentRunner(transport: ImmediateAgentTransport(response: response))

        do {
            _ = try await runner.execute(query: query(), manifest: manifest(),
                                         taskRevisions: ["task-1": "new-rev"],
                                         documentRevision: "doc-rev")
            XCTFail("expected stale task revision to be rejected")
        } catch {
            XCTAssertEqual(error as? PluginValidationError, .invalidAction)
        }
    }

    func testAgentQueryCapabilityIsRequiredBeforeTransportRuns() async {
        let response = Data(#"[{"taskID":"task-1","newDue":"2026-07-23"}]"#.utf8)
        let runner = AgentRunner(transport: ImmediateAgentTransport(response: response))
        let unauthorized = PluginManifest(id: "app.txtnimal.agent-test", name: "Agent Test", version: "1.0.0",
                                          apiVersion: 1, entry: "main.js", capabilities: [.tasksUpdate])

        do {
            _ = try await runner.execute(query: query(), manifest: unauthorized,
                                         taskRevisions: ["task-1": "task-rev"],
                                         documentRevision: "doc-rev")
            XCTFail("expected agent.query capability gate")
        } catch {
            XCTAssertEqual(error as? PluginValidationError, .missingCapability)
        }
    }

    private func manifest() -> PluginManifest {
        PluginManifest(id: "app.txtnimal.agent-test", name: "Agent Test", version: "1.0.0", apiVersion: 1,
                       entry: "main.js", capabilities: [.agentQuery, .tasksUpdate])
    }

    private func query(resultSchema: String = "reschedule.v1") -> PluginAction {
        PluginAction(type: .agentQuery, command: "agent.query", taskIDs: ["task-1"],
                     expectedRevision: "task-rev", documentRevision: "doc-rev",
                     prompt: "Schedule the selected tasks", resultSchema: resultSchema)
    }

    private func assertAgentError<T>(_ expected: AgentRunnerError, file: StaticString = #filePath,
                                     line: UInt = #line, operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AgentRunnerError, expected, file: file, line: line)
        }
    }
}
