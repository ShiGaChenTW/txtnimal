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

final class ReportGeneratorTests: XCTestCase {
    override func tearDown() {
        ChatMockURLProtocol.handler = nil
        super.tearDown()
    }

    func testSelectedTasksAreSerializedIntoUserMessageAndRequestOmitsToolsAndResponseFormat() async throws {
        let tasks = [
            ReportTask(id: "task-1", title: "整理本週待辦", due: "2026-07-24", completed: false),
            ReportTask(id: "task-2", title: "寄出進度摘要", due: nil, completed: true),
        ]
        ChatMockURLProtocol.handler = { request in
            let body = try self.bodyData(for: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertNil(object["tools"])
            XCTAssertNil(object["response_format"])
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            let userMessage = try XCTUnwrap(messages.first { $0["role"] == "user" }?["content"])
            XCTAssertTrue(userMessage.contains("task-1"))
            XCTAssertTrue(userMessage.contains("整理本週待辦"))
            XCTAssertTrue(userMessage.contains("\"completed\":true"))
            return (try self.response(for: request, statusCode: 200),
                    Data(###"{"choices":[{"message":{"content":"# 報表\n\n內容"}}]}"###.utf8))
        }
        let (generator, session) = makeGenerator()
        defer { session.invalidateAndCancel() }

        _ = try await generator.generate(template: .builtIn[0], tweak: "", tasks: tasks)
    }

    func testTweakIsAppendedToSystemMessage() async throws {
        let tweak = "請強調風險與下週優先順序"
        ChatMockURLProtocol.handler = { request in
            let body = try self.bodyData(for: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            let systemMessage = try XCTUnwrap(messages.first { $0["role"] == "system" }?["content"])
            XCTAssertTrue(systemMessage.contains("額外要求：\(tweak)"))
            XCTAssertTrue(systemMessage.hasSuffix("額外要求：\(tweak)"))
            return (try self.response(for: request, statusCode: 200),
                    Data(###"{"choices":[{"message":{"content":"# 報表"}}]}"###.utf8))
        }
        let (generator, session) = makeGenerator()
        defer { session.invalidateAndCancel() }

        _ = try await generator.generate(template: .builtIn[1], tweak: tweak, tasks: [])
    }

    func testEmptyTweakDoesNotAppendMarkerAndReturnsMockedContent() async throws {
        let expected = "## 站會日報\n- 已完成：整理任務"
        ChatMockURLProtocol.handler = { request in
            let body = try self.bodyData(for: request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
            let systemMessage = try XCTUnwrap(messages.first { $0["role"] == "system" }?["content"])
            XCTAssertFalse(systemMessage.contains("額外要求："))
            return (try self.response(for: request, statusCode: 200),
                    Data(###"{"choices":[{"message":{"content":"## 站會日報\n- 已完成：整理任務"}}]}"###.utf8))
        }
        let (generator, session) = makeGenerator()
        defer { session.invalidateAndCancel() }

        let content = try await generator.generate(
            template: .builtIn[3],
            tweak: "   ",
            tasks: [ReportTask(id: "task-3", title: "整理任務", due: nil, completed: true)]
        )

        XCTAssertEqual(content, expected)
    }

    private func makeGenerator() -> (ReportGenerator, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = InMemoryAgentCredentialStore(config: AgentEndpointConfig(
            baseURL: URL(string: "https://llm.example/v1")!, apiKey: "top-secret", model: "model-a"
        ))
        return (ReportGenerator(credentialStore: credentials, session: session), session)
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
}
