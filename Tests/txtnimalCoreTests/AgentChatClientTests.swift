import Foundation
import XCTest
@testable import txtnimalCore

private final class ChatMockURLProtocol: URLProtocol {
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

final class AgentChatClientTests: XCTestCase {
    override func tearDown() {
        ChatMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSuccessfulCompletionSendsFullConversationAndTaskTools() async throws {
        let messages = [
            AgentChatMessage(role: .system, content: "Read-only task context"),
            AgentChatMessage(role: .user, content: "What should I do first?"),
            AgentChatMessage(role: .assistant, content: "Start with the report."),
            AgentChatMessage(role: .user, content: "Why?"),
        ]
        ChatMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://llm.example/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer top-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try self.bodyData(for: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(object["model"] as? String, "model-a")
            XCTAssertNil(object["response_format"])
            let encodedMessages = try XCTUnwrap(object["messages"] as? [[String: String]])
            XCTAssertEqual(encodedMessages.map { $0["role"] }, ["system", "user", "assistant", "user"])
            XCTAssertEqual(encodedMessages.map { $0["content"] }, messages.map(\.content))
            let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
            XCTAssertEqual(tools.count, 5)
            let names = try tools.map {
                try XCTUnwrap(($0["function"] as? [String: Any])?["name"] as? String)
            }
            XCTAssertEqual(names, ["reschedule_tasks", "add_tasks", "complete_tasks", "delete_tasks", "retitle_tasks"])

            return (try self.response(for: request, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"Because it is due today."}}]}"#.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        let reply = try await client.send(messages: messages)

        XCTAssertEqual(reply, .text("Because it is due today."))
    }

    func testParsesRescheduleToolCall() async throws {
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(#"""
            {
              "choices":[{"message":{"content":"I suggest moving these.","tool_calls":[
                {"id":"call-1","type":"function","function":{"name":"reschedule_tasks","arguments":"{\"updates\":[{\"taskID\":\"task-1\",\"newDue\":\"2026-07-25\"},{\"taskID\":\"task-2\",\"newDue\":\"2026-07-26\"}]}"}}
              ]}}]
            }
            """#.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        let reply = try await client.send(messages: [.init(role: .user, content: "Move them")])

        XCTAssertEqual(reply, .actions([
            .reschedule(taskID: "task-1", newDue: "2026-07-25"),
            .reschedule(taskID: "task-2", newDue: "2026-07-26"),
        ], assistantNote: "I suggest moving these."))
    }

    func testParsesCompleteDeleteRetitleToolCalls() async throws {
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(#"""
            {
              "choices":[{"message":{"content":null,"tool_calls":[
                {"id":"c1","type":"function","function":{"name":"complete_tasks","arguments":"{\"taskIDs\":[\"task-1\"]}"}},
                {"id":"c2","type":"function","function":{"name":"delete_tasks","arguments":"{\"taskIDs\":[\"task-2\"]}"}},
                {"id":"c3","type":"function","function":{"name":"retitle_tasks","arguments":"{\"updates\":[{\"taskID\":\"task-3\",\"newTitle\":\"Renamed\"}]}"}}
              ]}}]
            }
            """#.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        let reply = try await client.send(messages: [.init(role: .user, content: "Tidy up")])

        XCTAssertEqual(reply, .actions([
            .complete(taskID: "task-1"),
            .delete(taskID: "task-2"),
            .retitle(taskID: "task-3", newTitle: "Renamed"),
        ], assistantNote: nil))
    }

    func testStreamYieldsTextDeltasThenCompletedText() async throws {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n"
                + "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n"
                + "data: [DONE]\n\n"
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(sse.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        var deltas: [String] = []
        var final: AgentChatReply?
        for try await event in client.stream(messages: [.init(role: .user, content: "Hi")]) {
            switch event {
            case .textDelta(let piece): deltas.append(piece)
            case .completed(let reply): final = reply
            }
        }
        XCTAssertEqual(deltas, ["Hel", "lo"])
        XCTAssertEqual(final, .text("Hello"))
    }

    func testStreamAssemblesFragmentedToolCallDeltasIntoActions() async throws {
        // name arrives in the first chunk; arguments are split across two chunks by index.
        let sse = "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"reschedule_tasks\",\"arguments\":\"{\\\"updates\\\":[{\\\"taskID\\\":\\\"task-1\\\",\"}}]}}]}\n\n"
                + "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"newDue\\\":\\\"2026-07-25\\\"}]}\"}}]}}]}\n\n"
                + "data: [DONE]\n\n"
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(sse.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        var final: AgentChatReply?
        for try await event in client.stream(messages: [.init(role: .user, content: "Move")]) {
            if case .completed(let reply) = event { final = reply }
        }
        XCTAssertEqual(final, .actions([.reschedule(taskID: "task-1", newDue: "2026-07-25")], assistantNote: nil))
    }

    func testStreamCombinesMultiLineDataEventIntoOneJSON() async throws {
        // A single SSE event whose JSON is split across two data: lines must be joined, not
        // decoded per line (each line alone is invalid JSON).
        let sse = "data: {\"choices\":[{\"delta\":\n"
                + "data: {\"content\":\"Hi\"}}]}\n\n"
                + "data: [DONE]\n\n"
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(sse.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        var final: AgentChatReply?
        for try await event in client.stream(messages: [.init(role: .user, content: "Hi")]) {
            if case .completed(let reply) = event { final = reply }
        }
        XCTAssertEqual(final, .text("Hi"))
    }

    func testStreamIgnoresNonJSONKeepaliveEvents() async throws {
        // A `data: ping` keepalive must not poison the following real event.
        let sse = "data: ping\n\n"
                + "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n"
                + "data: [DONE]\n\n"
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(sse.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        var final: AgentChatReply?
        for try await event in client.stream(messages: [.init(role: .user, content: "Hi")]) {
            if case .completed(let reply) = event { final = reply }
        }
        XCTAssertEqual(final, .text("Hi"))
    }

    func testParsesAddAndMixedToolCalls() async throws {
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(#"""
            {
              "choices":[{"message":{"content":null,"tool_calls":[
                {"id":"call-1","type":"function","function":{"name":"reschedule_tasks","arguments":"{\"updates\":[{\"taskID\":\"task-1\",\"newDue\":\"2026-07-25\"}]}"}},
                {"id":"call-2","type":"function","function":{"name":"add_tasks","arguments":"{\"tasks\":[{\"title\":\"Write launch notes\",\"due\":\"2026-07-26\"},{\"title\":\"Book room\"}]}"}}
              ]}}]
            }
            """#.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        let reply = try await client.send(messages: [.init(role: .user, content: "Plan launch")])

        XCTAssertEqual(reply, .actions([
            .reschedule(taskID: "task-1", newDue: "2026-07-25"),
            .create(title: "Write launch notes", due: "2026-07-26"),
            .create(title: "Book room", due: nil),
        ], assistantNote: nil))
    }

    func testBadArgumentsAndUnknownToolsFallBackToText() async throws {
        let responses = [
            #"{"choices":[{"message":{"content":"I could not prepare that change.","tool_calls":[{"type":"function","function":{"name":"add_tasks","arguments":"not-json"}}]}}]}"#,
            #"{"choices":[{"message":{"content":null,"tool_calls":[{"type":"function","function":{"name":"delete_tasks","arguments":"{}"}}]}}]}"#,
        ]
        var index = 0
        ChatMockURLProtocol.handler = { request in
            defer { index += 1 }
            return (try self.response(for: request, statusCode: 200), Data(responses[index].utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        let first = try await client.send(messages: [.init(role: .user, content: "First")])
        let second = try await client.send(messages: [.init(role: .user, content: "Second")])
        XCTAssertEqual(first, .text("I could not prepare that change."))
        XCTAssertEqual(second, .text("The agent returned an unsupported task action."))
    }

    func testEndpointRejectingToolsRetriesAsTextWithoutTools() async throws {
        var requestCount = 0
        ChatMockURLProtocol.handler = { request in
            requestCount += 1
            let body = try self.bodyData(for: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            if requestCount == 1 {
                XCTAssertNotNil(object["tools"])
                return (try self.response(for: request, statusCode: 400), Data())
            }
            XCTAssertNil(object["tools"])
            return (try self.response(for: request, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"Text-only endpoint reply."}}]}"#.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        let reply = try await client.send(messages: [.init(role: .user, content: "Hello")])

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(reply, .text("Text-only endpoint reply."))
    }

    func testNon2xxThrowsRecognizableRedactedError() async {
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 401), Data("top-secret echoed by server".utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        await assertChatError(.httpStatus(401)) {
            _ = try await client.send(messages: [.init(role: .user, content: "Hello")])
        }
    }

    func testMissingChoicesThrowsRecognizableError() async {
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200), Data(#"{"id":"response-1"}"#.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        await assertChatError(.missingContent) {
            _ = try await client.send(messages: [.init(role: .user, content: "Hello")])
        }
    }

    func testEmptyContentThrowsRecognizableError() async {
        ChatMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200),
             Data(#"{"choices":[{"message":{"content":"  \n "}}]}"#.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        await assertChatError(.missingContent) {
            _ = try await client.send(messages: [.init(role: .user, content: "Hello")])
        }
    }

    func testInsecureRemoteEndpointIsRejectedBeforeNetwork() async {
        ChatMockURLProtocol.handler = { _ in
            XCTFail("network must not be reached")
            throw URLError(.badURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credentials = InMemoryAgentCredentialStore(config: AgentEndpointConfig(
            baseURL: URL(string: "http://api.remote.example/v1")!, apiKey: "top-secret", model: "model-a"
        ))
        let client = AgentChatClient(credentialStore: credentials, session: session)

        await assertChatError(.insecureEndpoint) {
            _ = try await client.send(messages: [.init(role: .user, content: "Hello")])
        }
    }

    private func makeClient() -> (AgentChatClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = InMemoryAgentCredentialStore(config: AgentEndpointConfig(
            baseURL: URL(string: "https://llm.example/v1")!, apiKey: "top-secret", model: "model-a"
        ))
        return (AgentChatClient(credentialStore: credentials, session: session), session)
    }

    private func bodyData(for request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func response(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode,
                                     httpVersion: nil, headerFields: nil))
    }

    private func assertChatError(
        _ expected: HTTPAgentTransportError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? HTTPAgentTransportError, expected)
            XCTAssertFalse(error.localizedDescription.contains("top-secret"))
        }
    }
}
