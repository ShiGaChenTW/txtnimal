import Foundation
import XCTest
@testable import txtnimalCore

private final class AgentMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class HTTPAgentTransportTests: XCTestCase {
    override func tearDown() {
        AgentMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSuccessfulCompletionBuildsOpenAIRequestAndReturnsMessageContent() async throws {
        let expected = #"[{"taskID":"task-1","newDue":"2026-07-24"}]"#
        AgentMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://llm.example/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer top-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try self.bodyData(for: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "model-a")
            let responseFormat = try XCTUnwrap(object["response_format"] as? [String: Any])
            XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            XCTAssertEqual(messages.map { $0["role"] }, ["system", "user"])
            XCTAssertTrue(messages[0]["content"]?.contains("YYYY-MM-DD") == true)
            XCTAssertTrue(messages[1]["content"]?.contains("Schedule only these tasks") == true)
            XCTAssertTrue(messages[1]["content"]?.contains("Selected task") == true)
            XCTAssertTrue(messages[1]["content"]?.contains("2026-07-23") == true)

            return (try self.response(for: request, statusCode: 200),
                    try JSONSerialization.data(withJSONObject: [
                        "choices": [["message": ["content": expected]]]
                    ]))
        }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }

        let result = try await transport.complete(request: hostRequest())

        XCTAssertEqual(String(decoding: result, as: UTF8.self), expected)
    }

    func testNon2xxResponseThrowsRecognizableErrorWithoutIncludingBody() async {
        AgentMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 401), Data("top-secret echoed by server".utf8))
        }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }

        await assertTransportError(.httpStatus(401)) {
            try await transport.complete(request: self.hostRequest())
        }
    }

    func testMissingChoicesThrowsRecognizableError() async {
        AgentMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(#"{"id":"response-1"}"#.utf8))
        }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }

        await assertTransportError(.missingContent) {
            try await transport.complete(request: self.hostRequest())
        }
    }

    func testEmptyContentThrowsRecognizableError() async {
        AgentMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200),
             Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8))
        }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }

        await assertTransportError(.missingContent) {
            try await transport.complete(request: self.hostRequest())
        }
    }

    func testNonJSONContentThrowsRecognizableError() async {
        AgentMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200),
             Data(#"{"choices":[{"message":{"content":"not json"}}]}"#.utf8))
        }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }

        await assertTransportError(.invalidContent) {
            try await transport.complete(request: self.hostRequest())
        }
    }

    func testAPIKeyNeverAppearsInExecutionRecordOrPersistedLog() async throws {
        AgentMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 401), Data("top-secret echoed by server".utf8))
        }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }
        let runner = AgentRunner(transport: transport)
        let manifest = PluginManifest(id: "app.txtnimal.agent-test", name: "Agent Test", version: "1.0.0",
                                      apiVersion: 1, entry: "main.js", capabilities: [.agentQuery, .tasksUpdate])
        let query = PluginAction(type: .agentQuery, command: "agent.query", taskIDs: ["task-1"],
                                 expectedRevision: "task-rev", prompt: "Schedule",
                                 resultSchema: "reschedule.v1")

        do {
            _ = try await runner.execute(query: query, manifest: manifest, taskRevisions: [:])
            XCTFail("expected transport failure")
        } catch {
            guard case .transport = error as? AgentRunnerError else {
                return XCTFail("expected AgentRunnerError.transport, got \(error)")
            }
        }

        let records = await runner.executionRecords()
        let encodedRecords = try JSONEncoder().encode(records)
        XCTAssertFalse(String(decoding: encodedRecords, as: UTF8.self).contains("top-secret"))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("txtnimal-agent-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PluginExecutionLogStore(directory: directory)
        for record in records { try store.append(record) }
        let logData = try Data(contentsOf: directory.appendingPathComponent("execution-log.json"))
        XCTAssertFalse(String(decoding: logData, as: UTF8.self).contains("top-secret"))
    }

    func testRunnerClassifiesMalformedEndpointContentAsInvalidResponse() async {
        AgentMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200),
             Data(#"{"choices":[{"message":{"content":"not json"}}]}"#.utf8))
        }
        let (transport, session) = makeTransport()
        defer { session.invalidateAndCancel() }
        let runner = AgentRunner(transport: transport)
        let manifest = PluginManifest(id: "app.txtnimal.agent-test", name: "Agent Test", version: "1.0.0",
                                      apiVersion: 1, entry: "main.js", capabilities: [.agentQuery, .tasksUpdate])
        let query = PluginAction(type: .agentQuery, command: "agent.query", taskIDs: ["task-1"],
                                 expectedRevision: "task-rev", prompt: "Schedule",
                                 resultSchema: "reschedule.v1")

        do {
            _ = try await runner.execute(query: query, manifest: manifest, taskRevisions: [:])
            XCTFail("expected invalid response")
        } catch {
            XCTAssertEqual(error as? AgentRunnerError, .invalidResponse)
        }
    }

    private func makeTransport() -> (HTTPAgentTransport, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = InMemoryAgentCredentialStore(config: AgentEndpointConfig(
            baseURL: URL(string: "https://llm.example/v1")!, apiKey: "top-secret", model: "model-a"
        ))
        return (HTTPAgentTransport(credentialStore: credentials, session: session), session)
    }

    private func hostRequest() -> Data {
        Data(#"{"prompt":"Schedule only these tasks","taskIDs":["task-1"],"resultSchema":"reschedule.v1","tasks":[{"id":"task-1","title":"Selected task","due":"2026-07-23"}]}"#.utf8)
    }

    private func response(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode,
                                     httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
    }

    private func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw try XCTUnwrap(stream.streamError) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func assertTransportError<T>(_ expected: HTTPAgentTransportError,
                                         file: StaticString = #filePath, line: UInt = #line,
                                         operation: () async throws -> T) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HTTPAgentTransportError, expected, file: file, line: line)
            XCTAssertFalse(String(describing: error).contains("top-secret"), file: file, line: line)
        }
    }
}
