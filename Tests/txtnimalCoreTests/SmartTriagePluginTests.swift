import Foundation
import XCTest
@testable import txtnimalCore

private final class SmartTriageBrokerMockURLProtocol: URLProtocol {
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

final class SmartTriagePluginTests: XCTestCase {
    private let today = "2026-07-24"
    private let apiKey = "top-secret-triage-key"
    private let host = "triage.private-endpoint.example"

    override func setUp() {
        super.setUp()
        SmartTriageBrokerMockURLProtocol.handler = nil
    }

    override func tearDown() {
        SmartTriageBrokerMockURLProtocol.handler = nil
        super.tearDown()
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/smart-triage/main.js"),
                   encoding: .utf8)
    }

    private func loadManifest() throws -> PluginManifest {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/smart-triage/manifest.json"))
        return try PluginValidator.decodeManifest(data)
    }

    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "triage-doc-rev", tasks: [
            PluginTaskSnapshot(id: "triage-1", title: "整理提案", due: "2026-07-25", completed: false,
                               lists: ["工作"], tags: ["deep"], revision: "rev-1"),
            PluginTaskSnapshot(id: "triage-2", title: "回覆客戶", due: "2026-07-24", completed: false,
                               lists: ["工作"], tags: ["urgent"], revision: "rev-2"),
            PluginTaskSnapshot(id: "triage-3", title: "預約健檢", due: nil, completed: false,
                               lists: ["生活"], tags: [], revision: "rev-3"),
            PluginTaskSnapshot(id: "triage-4", title: "整理報帳", due: "2026-07-30", completed: false,
                               lists: ["行政"], tags: ["finance"], revision: "rev-4"),
        ])
    }

    private func emptySnapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "triage-doc-rev", tasks: [])
    }

    private func run(snapshot: PluginDocumentSnapshot? = nil,
                     agentResult: String?) throws -> PluginPageDocument {
        try ReportPluginRunner().run(source: try loadSource(), reportType: "smart-triage",
                                     snapshot: snapshot ?? self.snapshot(), todayYMD: today,
                                     agentResult: agentResult)
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

    private func descendantTextValues(of node: PluginPageNode) -> [String] {
        var values = [String]()
        if node.type == .text || node.type == .emptyState || node.type == .statCard {
            if let value = node.value { values.append(value) }
            if let title = node.title { values.append(title) }
        }
        for child in node.children ?? [] {
            values.append(contentsOf: descendantTextValues(of: child))
        }
        return values
    }

    private func textValues(in document: PluginPageDocument, sectionID: String) -> [String] {
        guard let section = node(in: document, id: sectionID) else { return [] }
        return descendantTextValues(of: section)
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
        configuration.protocolClasses = [SmartTriageBrokerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = InMemoryAgentCredentialStore(config: AgentEndpointConfig(
            baseURL: URL(string: "https://\(host)/v1")!, apiKey: apiKey, model: "model-x"))
        return (AgentQueryBroker(credentialStore: credentials, session: session), session)
    }

    private func httpResponse(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode,
                                      httpVersion: nil, headerFields: nil))
    }

    func testFirstRenderWithTasksShowsAgentQueryButton() throws {
        let document = try run(agentResult: nil)

        let button = try XCTUnwrap(node(in: document, id: "smart-triage-query"))
        XCTAssertEqual(button.type, .button)
        XCTAssertEqual(button.action?.type, .agentQuery)
        XCTAssertEqual(button.action?.command, PluginCapability.agentQuery.rawValue)
        XCTAssertEqual(button.action?.resultSchema, "triage.ranking.v1")
        XCTAssertTrue(button.action?.prompt?.contains("整理提案") == true)
        XCTAssertTrue(button.action?.prompt?.contains("回覆客戶") == true)
    }

    func testEmptyTaskListFirstRenderShowsEmptyStateAndNoQuery() throws {
        let document = try run(snapshot: emptySnapshot(), agentResult: nil)

        XCTAssertNotNil(node(in: document, id: "smart-triage-empty-state"))
        XCTAssertTrue(allNodes(in: document).allSatisfy { $0.action?.type != .agentQuery })
    }

    func testKnownRankingRendersFocusAndFullOrder() throws {
        let result = """
        {"ranking":[
          {"taskID":"triage-2","rank":2,"reason":"今天到期，外部依賴最高","bucket":"now","title":"假的標題"},
          {"taskID":"triage-1","rank":1,"reason":"先整理脈絡再推進","bucket":"now","title":"也是假標題"},
          {"taskID":"triage-4","rank":3,"reason":"月底前要送出","title":"亂寫"}
        ]}
        """
        let document = try run(agentResult: result)
        let focusValues = textValues(in: document, sectionID: "smart-triage-focus")
        let rankedValues = textValues(in: document, sectionID: "smart-triage-ranked")
        let serializedPage = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

        XCTAssertTrue(focusValues.contains { $0.contains("整理提案") && $0.contains("先整理脈絡再推進") })
        XCTAssertTrue(focusValues.contains { $0.contains("回覆客戶") && $0.contains("今天到期，外部依賴最高") })
        XCTAssertEqual(rankedValues.filter { $0.contains("#") }, [
            "#1 ｜ 整理提案 ｜ 到期：2026-07-25 ｜ 理由：先整理脈絡再推進",
            "#2 ｜ 回覆客戶 ｜ 到期：2026-07-24 ｜ 理由：今天到期，外部依賴最高",
            "#3 ｜ 整理報帳 ｜ 到期：2026-07-30 ｜ 理由：月底前要送出"
        ])
        XCTAssertTrue(serializedPage.contains("整理提案"))
        XCTAssertFalse(serializedPage.contains("假的標題"))
    }

    func testPartialRankingPutsUnrankedTasksInUnrankedSection() throws {
        let result = """
        {"tasks":[
          {"taskID":"triage-2","rank":1,"reason":"先回覆外部訊息"},
          {"taskID":"triage-3","reason":"沒有足夠資訊"}
        ]}
        """
        let document = try run(agentResult: result)
        let unrankedValues = textValues(in: document, sectionID: "smart-triage-unranked")

        XCTAssertTrue(unrankedValues.contains { $0.contains("整理提案") })
        XCTAssertTrue(unrankedValues.contains { $0.contains("預約健檢") })
        XCTAssertTrue(unrankedValues.contains { $0.contains("整理報帳") })
        XCTAssertFalse(unrankedValues.contains { $0.contains("回覆客戶") })
    }

    func testUnknownTaskIDInRankingIsDropped() throws {
        let result = """
        [
          {"taskID":"ghost-task","rank":1,"reason":"不存在"},
          {"taskID":"triage-1","rank":2,"reason":"真實任務"}
        ]
        """
        let document = try run(agentResult: result)
        let rankedValues = textValues(in: document, sectionID: "smart-triage-ranked")
        let serializedPage = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)

        XCTAssertEqual(rankedValues.filter { $0.contains("#") }, [
            "#2 ｜ 整理提案 ｜ 到期：2026-07-25 ｜ 理由：真實任務"
        ])
        XCTAssertFalse(serializedPage.contains("ghost-task"))
    }

    func testInvalidOrEmptyAgentResultShowsEmptyState() throws {
        for raw in ["not json", "[]", "{}"] {
            let document = try run(agentResult: raw)
            XCTAssertNotNil(node(in: document, id: "smart-triage-invalid-empty"),
                            "missing empty state for \(raw)")
        }
    }

    func testRenderedRankingPageHasNoButtonsOrMutationActions() throws {
        let result = """
        [{"taskID":"triage-1","rank":1,"reason":"先做這個","bucket":"now"}]
        """
        let document = try run(agentResult: result)
        let nodes = allNodes(in: document)

        XCTAssertTrue(nodes.filter { $0.type == .button }.isEmpty)
        XCTAssertTrue(nodes.compactMap(\.action).allSatisfy {
            $0.type != .hostCommand && $0.type != .kvSet && $0.type != .exportWrite
        })
    }

    func testRenderedPageValidatesAgainstManifestAndIsDeterministic() throws {
        let manifest = try loadManifest()
        let result = """
        [{"taskID":"triage-1","rank":1,"reason":"先做這個"},{"taskID":"triage-2","rank":2,"reason":"接著做"}]
        """

        let first = try run(agentResult: result)
        let second = try run(agentResult: result)

        XCTAssertEqual(first, second)
        XCTAssertNoThrow(try PluginValidator.validate(first, manifest: manifest))
    }

    func testBrokerResultRendersRankingWithoutLeakingAPIKey() async throws {
        let manifest = try loadManifest()
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }

        SmartTriageBrokerMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.apiKey)")
            return (try self.httpResponse(for: request, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"[{\"taskID\":\"triage-2\",\"rank\":1,\"reason\":\"今天到期\",\"bucket\":\"now\"},{\"taskID\":\"triage-1\",\"rank\":2,\"reason\":\"補齊脈絡\"}]"}}]}"#.utf8))
        }

        let queryResult = try await broker.query(
            prompt: "請排序目前任務",
            resultSchema: "triage.ranking.v1",
            manifest: manifest
        )
        let document = try run(agentResult: queryResult.text)
        let serializedPage = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let leakedStrings = reflectedStrings(queryResult) + reflectedStrings(document) + [serializedPage]

        XCTAssertTrue(serializedPage.contains("回覆客戶"))
        XCTAssertFalse(queryResult.text.contains(apiKey))
        XCTAssertFalse(leakedStrings.contains { $0.contains(apiKey) })
        XCTAssertFalse(leakedStrings.contains { $0.contains(host) })
        XCTAssertTrue(allNodes(in: document).filter { $0.type == .button }.isEmpty)
        XCTAssertTrue(allNodes(in: document).compactMap(\.action).allSatisfy {
            $0.type != .hostCommand && $0.type != .kvSet && $0.type != .exportWrite
        })
    }
}
