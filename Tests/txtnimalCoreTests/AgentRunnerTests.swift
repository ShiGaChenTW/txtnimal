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

final class AgentRunnerTests: XCTestCase {
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

    private func query() -> PluginAction {
        PluginAction(type: .agentQuery, command: "agent.query", taskIDs: ["task-1"],
                     expectedRevision: "task-rev", documentRevision: "doc-rev",
                     prompt: "Schedule the selected tasks", resultSchema: #"[{"taskID":"String","newDue":"yyyy-MM-dd"}]"#)
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
