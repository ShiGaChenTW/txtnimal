import Foundation
import XCTest
@testable import txtnimalCore

private final class NlReportBrokerMockURLProtocol: URLProtocol {
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

final class NlReportPluginTests: XCTestCase {
    private let today = "2026-07-24"
    private let apiKey = "top-secret-report-key"
    private let host = "report.private-endpoint.example"

    override func setUp() {
        super.setUp()
        NlReportBrokerMockURLProtocol.handler = nil
    }

    override func tearDown() {
        NlReportBrokerMockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: - Fixtures loaded from the real repo path (drive the actual main.js)

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/nl-report/main.js"),
                   encoding: .utf8)
    }

    private func loadManifest() throws -> PluginManifest {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/nl-report/manifest.json"))
        return try PluginValidator.decodeManifest(data)
    }

    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "nl-report-doc-rev", tasks: [
            PluginTaskSnapshot(id: "report-1", title: "整理提案", due: "2026-07-25", completed: false,
                               lists: ["工作"], tags: ["deep"], revision: "rev-1"),
            PluginTaskSnapshot(id: "report-2", title: "回覆客戶", due: "2026-07-24", completed: true,
                               lists: ["工作"], tags: ["urgent"], revision: "rev-2"),
            PluginTaskSnapshot(id: "report-3", title: "預約健檢", due: nil, completed: false,
                               lists: ["生活"], tags: [], revision: "rev-3"),
        ])
    }

    private func emptySnapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "nl-report-doc-rev", tasks: [])
    }

    private func run(reportType: String = "weekly",
                     snapshot: PluginDocumentSnapshot? = nil,
                     agentResult: String?) throws -> PluginPageDocument {
        try ReportPluginRunner().run(source: try loadSource(), reportType: reportType,
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
        configuration.protocolClasses = [NlReportBrokerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = InMemoryAgentCredentialStore(config: AgentEndpointConfig(
            baseURL: URL(string: "https://\(host)/v1")!, apiKey: apiKey, model: "model-x"))
        return (AgentQueryBroker(credentialStore: credentials, session: session), session)
    }

    private func httpResponse(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode,
                                      httpVersion: nil, headerFields: nil))
    }

    // A representative report body carrying markdown structure and non-ASCII content.
    private let sampleReport = """
    # 本週週報

    ## 已完成
    - 回覆客戶

    ## 待跟進
    - 整理提案(2026-07-25 到期)
    - 預約健檢
    """

    // MARK: - First render: agent.query button (no agentResult yet)

    func testFirstRenderWithTasksShowsAgentQueryButton() throws {
        let document = try run(reportType: "weekly", agentResult: nil)

        let button = try XCTUnwrap(node(in: document, id: "nl-report-generate"))
        XCTAssertEqual(button.type, .button)
        XCTAssertNotNil(button.title)
        XCTAssertEqual(button.action?.type, .agentQuery)
        XCTAssertEqual(button.action?.command, PluginCapability.agentQuery.rawValue)
        XCTAssertEqual(button.action?.resultSchema, "nl-report.markdown.v1")
        // Prompt reuses the builtin ReportGenerator "weekly" system-prompt semantics …
        XCTAssertTrue(button.action?.prompt?.contains("週報整理助手") == true)
        // … and carries the task summary drawn from input.
        XCTAssertTrue(button.action?.prompt?.contains("整理提案") == true)
        XCTAssertTrue(button.action?.prompt?.contains("回覆客戶") == true)
        // First render has no export button yet.
        XCTAssertNil(node(in: document, id: "nl-report-export"))
    }

    func testEmptyTaskListFirstRenderShowsEmptyStateAndNoQuery() throws {
        let document = try run(snapshot: emptySnapshot(), agentResult: nil)

        XCTAssertNotNil(node(in: document, id: "nl-report-empty-state"))
        XCTAssertTrue(allNodes(in: document).allSatisfy { $0.action?.type != .agentQuery })
        XCTAssertTrue(allNodes(in: document).allSatisfy { $0.type != .button })
    }

    // MARK: - Second render: report page + export.write button (agentResult present)

    func testReportResultRendersMarkdownPageWithExportButton() throws {
        let document = try run(reportType: "weekly", agentResult: sampleReport)

        // The report markdown is rendered verbatim as a page text node.
        let body = try XCTUnwrap(node(in: document, id: "nl-report-body"))
        XCTAssertEqual(body.type, .text)
        XCTAssertEqual(body.value, sampleReport)

        // The export button carries the exact report content as a text/markdown file.
        let export = try XCTUnwrap(node(in: document, id: "nl-report-export"))
        XCTAssertEqual(export.type, .button)
        XCTAssertNotNil(export.title)
        XCTAssertEqual(export.action?.type, .exportWrite)
        XCTAssertEqual(export.action?.command, PluginAction.exportWriteCommand)
        XCTAssertEqual(export.action?.mimeType, "text/markdown")
        XCTAssertEqual(export.action?.content, sampleReport)
        XCTAssertEqual(export.action?.filename, "nl-report-weekly-2026-07-24.md")
        XCTAssertEqual(export.action?.destination, .file)
    }

    func testExportActionValidatesAsAWritableArtifact() throws {
        let manifest = try loadManifest()
        let document = try run(reportType: "progress", agentResult: sampleReport)
        let export = try XCTUnwrap(node(in: document, id: "nl-report-export"))

        let validated = try PluginValidator.validate(exportAction: try XCTUnwrap(export.action), manifest: manifest)
        XCTAssertEqual(validated.pluginID, manifest.id)
        XCTAssertEqual(validated.destination, .file)
        XCTAssertEqual(validated.artifact.mimeType, "text/markdown")
        XCTAssertEqual(validated.artifact.content, sampleReport)
        XCTAssertEqual(validated.artifact.filename, "nl-report-progress-2026-07-24.md")
    }

    func testReportPageValidatesAgainstManifestAndIsDeterministic() throws {
        let manifest = try loadManifest()

        let first = try run(reportType: "weekly", agentResult: sampleReport)
        let second = try run(reportType: "weekly", agentResult: sampleReport)

        XCTAssertEqual(first, second)
        XCTAssertNoThrow(try PluginValidator.validate(first, manifest: manifest))
    }

    // MARK: - Read-only guarantees (no task mutation, ever)

    func testReportPageCarriesNoTaskMutationActions() throws {
        let document = try run(reportType: "standup", agentResult: sampleReport)
        let actions = allNodes(in: document).compactMap(\.action)

        // The only action on the report page is the export write.
        XCTAssertEqual(actions.map(\.type), [.exportWrite])
        XCTAssertTrue(actions.allSatisfy {
            $0.type != .hostCommand && $0.type != .kvSet && $0.type != .agentQuery
        })
        // No action smuggles task IDs / mutation fields.
        XCTAssertTrue(actions.allSatisfy { ($0.taskIDs ?? []).isEmpty })
    }

    func testManifestDeclaresNoTaskWriteCapabilities() throws {
        let manifest = try loadManifest()
        let caps = Set(manifest.capabilities)
        XCTAssertEqual(caps, [.agentQuery, .tasksAllRead, .uiPage, .exportWrite])
        let writeCaps: Set<PluginCapability> = [.tasksCreate, .tasksUpdate, .tasksComplete, .tasksDelete]
        XCTAssertTrue(caps.isDisjoint(with: writeCaps))
    }

    // MARK: - Four report types reuse builtin semantics; filename encodes type + date

    func testEachReportTypeReusesBuiltinPromptAndFilename() throws {
        let expected: [(type: String, marker: String)] = [
            ("weekly", "週報整理助手"),
            ("progress", "進度摘要助手"),
            ("category", "任務分類分析助手"),
            ("standup", "站會日報助手"),
        ]
        for entry in expected {
            let request = try run(reportType: entry.type, agentResult: nil)
            let button = try XCTUnwrap(node(in: request, id: "nl-report-generate"),
                                       "missing generate button for \(entry.type)")
            XCTAssertTrue(button.action?.prompt?.contains(entry.marker) == true,
                          "prompt for \(entry.type) should reuse builtin system prompt")

            let report = try run(reportType: entry.type, agentResult: sampleReport)
            let export = try XCTUnwrap(node(in: report, id: "nl-report-export"))
            XCTAssertEqual(export.action?.filename, "nl-report-\(entry.type)-\(today).md")
        }
    }

    func testUnknownReportTypeFallsBackToWeekly() throws {
        let report = try run(reportType: "totally-unknown", agentResult: sampleReport)
        let export = try XCTUnwrap(node(in: report, id: "nl-report-export"))
        XCTAssertEqual(export.action?.filename, "nl-report-weekly-2026-07-24.md")
    }

    // MARK: - Degenerate agentResult

    func testBlankAgentResultShowsEmptyReportStateAndNoExport() throws {
        let document = try run(reportType: "weekly", agentResult: "   \n  ")
        XCTAssertNotNil(node(in: document, id: "nl-report-empty-result-state"))
        XCTAssertNil(node(in: document, id: "nl-report-export"))
        XCTAssertTrue(allNodes(in: document).allSatisfy { $0.type != .button })
    }

    // MARK: - Truncation note when over the query limit

    func testOverLimitTaskCountShowsTruncationNoteInReport() throws {
        var tasks = [PluginTaskSnapshot]()
        for index in 0..<130 {
            tasks.append(PluginTaskSnapshot(id: "bulk-\(index)", title: "任務\(index)", due: nil,
                                            completed: false, lists: [], tags: [], revision: "r\(index)"))
        }
        let bigSnapshot = PluginDocumentSnapshot(documentRevision: "bulk-rev", tasks: tasks)
        let document = try run(reportType: "weekly", snapshot: bigSnapshot, agentResult: sampleReport)

        let note = try XCTUnwrap(node(in: document, id: "nl-report-content-limit"))
        XCTAssertTrue((note.value ?? "").contains("僅涵蓋前 100 筆"))
    }

    // MARK: - End-to-end via the real host broker (key never leaks to the plugin)

    func testBrokerResultRendersReportWithoutLeakingAPIKey() async throws {
        let manifest = try loadManifest()
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }

        // Broker returns a markdown report; the plugin must never see the raw key/host.
        let brokerMarkdown = "# 週報\\n\\n## 已完成\\n- 回覆客戶\\n\\n## 待跟進\\n- 整理提案"
        NlReportBrokerMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.apiKey)")
            return (try self.httpResponse(for: request, statusCode: 200),
                    Data("{\"choices\":[{\"message\":{\"content\":\"\(brokerMarkdown)\"}}]}".utf8))
        }

        let queryResult = try await broker.query(
            prompt: "請產生本週週報",
            resultSchema: "nl-report.markdown.v1",
            manifest: manifest
        )
        let document = try run(reportType: "weekly", agentResult: queryResult.text)

        let body = try XCTUnwrap(node(in: document, id: "nl-report-body"))
        XCTAssertTrue((body.value ?? "").contains("回覆客戶"))

        let export = try XCTUnwrap(node(in: document, id: "nl-report-export"))
        XCTAssertEqual(export.action?.content, queryResult.text)
        XCTAssertEqual(export.action?.mimeType, "text/markdown")

        // The rendered page + broker result must not leak the API key or endpoint host.
        let serializedPage = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
        let leakedStrings = reflectedStrings(queryResult) + reflectedStrings(document) + [serializedPage]
        XCTAssertFalse(queryResult.text.contains(apiKey))
        XCTAssertFalse(leakedStrings.contains { $0.contains(apiKey) })
        XCTAssertFalse(leakedStrings.contains { $0.contains(host) })

        // The full page still validates as a well-formed, read-only export page.
        XCTAssertNoThrow(try PluginValidator.validate(document, manifest: manifest))
        XCTAssertEqual(allNodes(in: document).compactMap(\.action).map(\.type), [.exportWrite])
    }
}
