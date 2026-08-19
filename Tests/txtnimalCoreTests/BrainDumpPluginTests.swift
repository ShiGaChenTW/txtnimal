import Foundation
import XCTest
@testable import txtnimalCore

private final class BrainDumpBrokerMockURLProtocol: URLProtocol {
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

final class BrainDumpPluginTests: XCTestCase {
    private let today = "2026-07-24"
    private let apiKey = "top-secret-brain-key"
    private let host = "llm.private-endpoint.example"

    override func setUp() {
        super.setUp()
        BrainDumpBrokerMockURLProtocol.handler = nil
    }

    override func tearDown() {
        BrainDumpBrokerMockURLProtocol.handler = nil
        super.tearDown()
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/brain-dump/main.js"),
                   encoding: .utf8)
    }

    private func loadManifest() throws -> PluginManifest {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/brain-dump/manifest.json"))
        return try PluginValidator.decodeManifest(data)
    }

    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "braindump-1", title: "既有任務", due: nil, completed: false,
                               lists: [], tags: [], revision: "rev-1"),
        ])
    }

    private func run(agentResult: String?) throws -> PluginPageDocument {
        try ReportPluginRunner().run(source: try loadSource(), reportType: "brain-dump",
                                     snapshot: snapshot(), todayYMD: today, agentResult: agentResult)
    }

    private func allNodes(in document: PluginPageDocument) -> [PluginPageNode] {
        func walk(_ node: PluginPageNode) -> [PluginPageNode] {
            [node] + (node.children ?? []).flatMap(walk)
        }
        return walk(document.page)
    }

    private func node(in document: PluginPageDocument, id: String) -> PluginPageNode? {
        allNodes(in: document).first { $0.id == id }
    }

    private func createButtons(in document: PluginPageDocument) -> [PluginPageNode] {
        allNodes(in: document).filter {
            $0.type == .button && $0.action?.type == .hostCommand && $0.action?.command == PluginHostCommand.createTask.rawValue
        }
    }

    private func reflectedStrings(_ value: Any) -> [String] {
        var out = [String(describing: value)]
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            out.append(contentsOf: reflectedStrings(child.value))
        }
        return out
    }

    private func makeBroker() -> (AgentQueryBroker, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrainDumpBrokerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = InMemoryAgentCredentialStore(config: AgentEndpointConfig(
            baseURL: URL(string: "https://\(host)/v1")!, apiKey: apiKey, model: "model-x"))
        return (AgentQueryBroker(credentialStore: credentials, session: session), session)
    }

    private func httpResponse(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode,
                                      httpVersion: nil, headerFields: nil))
    }

    func testFirstRenderShowsTextFieldAndAgentQueryButton() throws {
        let document = try run(agentResult: nil)

        let textField = try XCTUnwrap(node(in: document, id: "braindump-text"))
        let button = try XCTUnwrap(node(in: document, id: "brain-query"))

        XCTAssertEqual(textField.type, .textField)
        XCTAssertEqual(button.action?.type, .agentQuery)
        XCTAssertEqual(button.action?.command, PluginCapability.agentQuery.rawValue)
        XCTAssertEqual(button.action?.resultSchema, "braindump.tasks.v1")
        XCTAssertTrue(button.action?.prompt?.contains("{{input}}") == true)
    }

    func testKnownAgentResultRendersTwoCreateButtons() throws {
        let result = #"[{"title":"交季報","due":"2026-07-25"},{"title":"準備投影片","lists":["工作"],"tags":["urgent"]},{"title":"  "}]"#
        let document = try run(agentResult: result)
        let buttons = createButtons(in: document)

        XCTAssertEqual(buttons.count, 2)
        XCTAssertEqual(buttons[0].action?.due, "2026-07-25")
        XCTAssertEqual(buttons[1].action?.title, "準備投影片")
        XCTAssertEqual(buttons[1].action?.lists, ["工作"])
        XCTAssertEqual(buttons[1].action?.tags, ["urgent"])
    }

    func testRenderedCreateButtonsValidateIntoCreateTaskIntents() throws {
        let manifest = try loadManifest()
        let result = #"[{"title":"交季報","due":"2026-07-25"},{"title":"準備投影片","lists":["工作"],"tags":["urgent"]}]"#
        let document = try run(agentResult: result)

        let intents = try createButtons(in: document).map {
            try PluginValidator.validate(action: try XCTUnwrap($0.action), manifest: manifest)
        }

        XCTAssertEqual(intents.map(\.command), [.createTask, .createTask])
        XCTAssertEqual(intents.map(\.taskIDs), [[], []])
        XCTAssertEqual(intents[1].title, "準備投影片")
        XCTAssertEqual(intents[1].lists, ["工作"])
        XCTAssertEqual(intents[1].tags, ["urgent"])
    }

    func testCapsDraftsAtOneHundred() throws {
        let items = (1...150).map { #"{"title":"任務\#($0)"}"# }.joined(separator: ",")
        let document = try run(agentResult: "[\(items)]")
        XCTAssertEqual(createButtons(in: document).count, 100)
    }

    func testInvalidOrEmptyAgentResultShowsEmptyState() throws {
        for raw in ["not json", "[]", "{}"] {
            let document = try run(agentResult: raw)
            XCTAssertNotNil(node(in: document, id: "brain-empty"), "missing empty state for \(raw)")
            XCTAssertTrue(createButtons(in: document).isEmpty)
        }
    }

    func testRenderedPageValidatesAgainstManifestAndIsDeterministic() throws {
        let manifest = try loadManifest()
        let result = #"[{"title":"交季報","due":"2026-07-25"},{"title":"準備投影片","lists":["工作"],"tags":["urgent"]}]"#

        let first = try run(agentResult: result)
        let second = try run(agentResult: result)

        XCTAssertEqual(first, second)
        XCTAssertNoThrow(try PluginValidator.validate(first, manifest: manifest))
    }

    func testBrokerResultFeedsReviewedCreatePathWithoutLeakingAPIKey() async throws {
        let manifest = try loadManifest()
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }

        BrainDumpBrokerMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.apiKey)")
            return (try self.httpResponse(for: request, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"[{\"title\":\"交季報\",\"due\":\"2026-07-25\"},{\"title\":\"準備投影片\",\"lists\":[\"工作\"],\"tags\":[\"urgent\"]}]"}}]}"#.utf8))
        }

        let queryResult = try await broker.query(
            prompt: "請拆解這段會議筆記",
            resultSchema: "braindump.tasks.v1",
            manifest: manifest
        )
        let document = try run(agentResult: queryResult.text)
        let intents = try createButtons(in: document).map {
            try PluginValidator.validate(action: try XCTUnwrap($0.action), manifest: manifest)
        }

        XCTAssertEqual(intents.map(\.command), [.createTask, .createTask])

        let snapshot = TaskDocumentSnapshot(lines: [], scratch: "", archiveLines: [],
                                            generation: 1, tasksText: "")
        let applied = try PluginIntentApplier.applyBatch(intents, to: snapshot, todayYMD: today).lines

        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(applied[0].title, "交季報")
        XCTAssertEqual(applied[0].due, "2026-07-25")
        XCTAssertEqual(applied[1].title, "準備投影片")
        XCTAssertTrue(applied[1].raw.contains("+工作"))
        XCTAssertTrue(applied[1].raw.contains("@urgent"))

        let serializedPage = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let leakedStrings = reflectedStrings(queryResult) + reflectedStrings(document) + reflectedStrings(intents) + [serializedPage]
        XCTAssertFalse(queryResult.text.contains(apiKey))
        XCTAssertFalse(leakedStrings.contains { $0.contains(apiKey) })
        XCTAssertFalse(leakedStrings.contains { $0.contains(host) })
    }
}
