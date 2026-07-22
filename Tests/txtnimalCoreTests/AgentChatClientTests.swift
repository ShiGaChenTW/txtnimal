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

    func testSuccessfulCompletionSendsFullConversationWithoutResponseFormat() async throws {
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

            return (try self.response(for: request, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"Because it is due today."}}]}"#.utf8))
        }
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }

        let reply = try await client.send(messages: messages)

        XCTAssertEqual(reply, "Because it is due today.")
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
