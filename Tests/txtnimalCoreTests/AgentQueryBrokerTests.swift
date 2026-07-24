import Foundation
import XCTest
@testable import txtnimalCore

/// Records whether the network was ever reached and returns a scripted response. Modeled on
/// `ChatMockURLProtocol` in AgentChatClientTests — no real network.
private final class BrokerMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var reached = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.reached = true
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

final class AgentQueryBrokerTests: XCTestCase {
    private let apiKey = "top-secret"
    private let host = "llm.private-endpoint.example"

    override func setUp() {
        super.setUp()
        BrokerMockURLProtocol.handler = nil
        BrokerMockURLProtocol.reached = false
    }

    override func tearDown() {
        BrokerMockURLProtocol.handler = nil
        BrokerMockURLProtocol.reached = false
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeBroker() -> (broker: AgentQueryBroker, session: URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrokerMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credentials = InMemoryAgentCredentialStore(config: AgentEndpointConfig(
            baseURL: URL(string: "https://\(host)/v1")!, apiKey: apiKey, model: "model-x"))
        let broker = AgentQueryBroker(credentialStore: credentials, session: session)
        return (broker, session)
    }

    private func manifest(_ capabilities: [PluginCapability]) -> PluginManifest {
        PluginManifest(id: "app.txtnimal.brain-dump", name: "Brain Dump", version: "1.0.0",
                       apiVersion: 1, entry: "main.js", capabilities: capabilities)
    }

    private func response(for request: URLRequest, statusCode: Int) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode,
                                      httpVersion: nil, headerFields: nil))
    }

    /// Every String reachable from a value via reflection, plus its `String(describing:)`.
    private func reflectedStrings(_ value: Any) -> [String] {
        var out = [String(describing: value)]
        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            out.append(contentsOf: reflectedStrings(child.value))
        }
        return out
    }

    // MARK: - Happy path

    func testBrokerReturnsResultAndHostSuppliesTheKey() async throws {
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }

        BrokerMockURLProtocol.handler = { request in
            // The HOST attached the bearer key — the plugin never had to.
            XCTAssertEqual(request.url?.absoluteString, "https://\(self.host)/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(self.apiKey)")
            return (try self.response(for: request, statusCode: 200),
                    Data(#"{"choices":[{"message":{"content":"[{\"title\":\"Buy milk\"}]"}}]}"#.utf8))
        }

        let result = try await broker.query(prompt: "Parse my brain dump into tasks",
                                            resultSchema: "tasks.v1",
                                            manifest: manifest([.agentQuery]))

        XCTAssertEqual(result.resultSchema, "tasks.v1")
        XCTAssertEqual(result.text, #"[{"title":"Buy milk"}]"#)
        XCTAssertTrue(BrokerMockURLProtocol.reached)
    }

    // MARK: - The result type carries NO config (the whole point)

    func testResultNeverExposesKeyOrEndpoint() async throws {
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }

        BrokerMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 200),
             Data(#"{"choices":[{"message":{"content":"done"}}]}"#.utf8))
        }

        let result = try await broker.query(prompt: "Summarize",
                                            resultSchema: "summary.v1",
                                            manifest: manifest([.agentQuery]))

        // Reflecting the result exposes only the schema id and the model text — never a secret.
        let leaked = reflectedStrings(result)
        XCTAssertFalse(leaked.contains { $0.contains(apiKey) }, "API key must never appear in the result")
        XCTAssertFalse(leaked.contains { $0.contains(host) }, "endpoint host must never appear in the result")
        // And the type's stored surface is exactly {resultSchema, text}.
        let labels = Mirror(reflecting: result).children.compactMap { $0.label }.sorted()
        XCTAssertEqual(labels, ["resultSchema", "text"])
    }

    // MARK: - Capability gate refuses BEFORE any network / credential access

    func testCapabilityAbsentIsRefusedWithoutTouchingNetwork() async {
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }
        BrokerMockURLProtocol.handler = { _ in
            XCTFail("network must not be reached when the capability is absent")
            throw URLError(.badServerResponse)
        }

        do {
            _ = try await broker.query(prompt: "Parse", resultSchema: "tasks.v1",
                                       manifest: manifest([.uiPage]))   // no .agentQuery
            XCTFail("expected missingCapability")
        } catch let error as AgentQueryBrokerError {
            XCTAssertEqual(error, .missingCapability)
        } catch {
            XCTFail("expected AgentQueryBrokerError.missingCapability, got \(error)")
        }
        XCTAssertFalse(BrokerMockURLProtocol.reached, "no request may be sent on the refusal path")
    }

    func testEmptyPromptIsRefusedWithoutNetwork() async {
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await broker.query(prompt: "   ", resultSchema: "tasks.v1",
                                       manifest: manifest([.agentQuery]))
            XCTFail("expected invalidRequest")
        } catch let error as AgentQueryBrokerError {
            XCTAssertEqual(error, .invalidRequest)
        } catch {
            XCTFail("expected invalidRequest, got \(error)")
        }
        XCTAssertFalse(BrokerMockURLProtocol.reached)
    }

    func testEmptyResultSchemaIsRefusedWithoutNetwork() async {
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await broker.query(prompt: "Parse", resultSchema: "  ",
                                       manifest: manifest([.agentQuery]))
            XCTFail("expected invalidRequest")
        } catch let error as AgentQueryBrokerError {
            XCTAssertEqual(error, .invalidRequest)
        } catch {
            XCTFail("expected invalidRequest, got \(error)")
        }
        XCTAssertFalse(BrokerMockURLProtocol.reached)
    }

    // MARK: - Failed / malformed LLM responses surface TYPED errors (no silent failure)

    func testNon2xxSurfacesTypedTransportError() async {
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }
        BrokerMockURLProtocol.handler = { request in
            (try self.response(for: request, statusCode: 500), Data("upstream boom".utf8))
        }

        do {
            _ = try await broker.query(prompt: "Parse", resultSchema: "tasks.v1",
                                       manifest: manifest([.agentQuery]))
            XCTFail("expected a transport error")
        } catch let error as AgentQueryBrokerError {
            guard case .transport = error else { return XCTFail("expected .transport, got \(error)") }
            // The key must never leak into an error message.
            XCTAssertFalse(error.localizedDescription.contains(apiKey))
        } catch {
            XCTFail("expected AgentQueryBrokerError.transport, got \(error)")
        }
    }

    func testMalformedResponseSurfacesTypedEmptyResult() async {
        let (broker, session) = makeBroker()
        defer { session.invalidateAndCancel() }
        BrokerMockURLProtocol.handler = { request in
            // 200 OK but no message content — must NOT be swallowed as an empty success.
            (try self.response(for: request, statusCode: 200), Data(#"{"choices":[]}"#.utf8))
        }

        do {
            _ = try await broker.query(prompt: "Parse", resultSchema: "tasks.v1",
                                       manifest: manifest([.agentQuery]))
            XCTFail("expected emptyResult")
        } catch let error as AgentQueryBrokerError {
            XCTAssertEqual(error, .emptyResult)
        } catch {
            XCTFail("expected emptyResult, got \(error)")
        }
    }

    // MARK: - Generic agentQuery action validator (mirrors validate(kvAction:))

    func testValidatorProducesAgentQueryWithCapability() throws {
        let action = PluginAction(type: .agentQuery, command: "agent.query",
                                  prompt: "Parse this", resultSchema: "tasks.v1")
        let validated = try PluginValidator.validate(agentQueryAction: action,
                                                     manifest: manifest([.agentQuery, .uiPage]))
        XCTAssertEqual(validated, ValidatedAgentQuery(pluginID: "app.txtnimal.brain-dump",
                                                      prompt: "Parse this", resultSchema: "tasks.v1"))
    }

    func testValidatorRejectsAgentQueryWithoutCapability() {
        let action = PluginAction(type: .agentQuery, command: "agent.query",
                                  prompt: "Parse this", resultSchema: "tasks.v1")
        XCTAssertThrowsError(try PluginValidator.validate(agentQueryAction: action,
                                                          manifest: manifest([.uiPage]))) {
            XCTAssertEqual($0 as? PluginValidationError, .missingCapability)
        }
    }

    func testValidatorRejectsAgentQuerySmugglingTaskFields() {
        // An agent.query must not smuggle task-mutation fields — those belong to the reviewed path.
        let action = PluginAction(type: .agentQuery, command: "agent.query", taskIDs: ["t1"],
                                  due: "2026-07-24", expectedRevision: "rev-1",
                                  prompt: "Parse this", resultSchema: "tasks.v1")
        XCTAssertThrowsError(try PluginValidator.validate(agentQueryAction: action,
                                                          manifest: manifest([.agentQuery]))) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }
    }

    // MARK: - Reviewed-mutation boundary preserved

    func testProposedTaskChangeGoesThroughReviewNotDirectWrite() throws {
        // A broker result is inert data. Turning a suggested reschedule into an actual change still
        // requires the reviewed path: validate(action:) yields a ValidatedPluginIntent (the review
        // item), and only PluginIntentApplier mutates task lines — the broker never touches them.
        let mutationManifest = PluginManifest(id: "app.txtnimal.smart-triage", name: "Smart Triage",
                                              version: "1.0.0", apiVersion: 1, entry: "main.js",
                                              capabilities: [.agentQuery, .tasksUpdate])
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("One id:task-1 due:2026-07-20"))
        let proposed = PluginAction(type: .hostCommand, command: PluginHostCommand.rescheduleTask.rawValue,
                                    taskIDs: ["task-1"], due: "2026-07-25",
                                    expectedRevision: snapshot.documentRevision,
                                    documentRevision: snapshot.documentRevision)

        let intent = try PluginValidator.validate(action: proposed, manifest: mutationManifest,
                                                  documentRevision: snapshot.documentRevision)
        XCTAssertEqual(intent.command, .rescheduleTask)
        XCTAssertEqual(intent.taskIDs, ["task-1"])

        // The review item, once applied through the ONLY writer, produces the new due date.
        let lines = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-24")
        XCTAssertEqual(lines.first?.due, "2026-07-25")

        // AgentQueryResult exposes no task-writing surface — only schema + text.
        let labels = Mirror(reflecting: AgentQueryResult(resultSchema: "tasks.v1", text: "x"))
            .children.compactMap { $0.label }.sorted()
        XCTAssertEqual(labels, ["resultSchema", "text"])
    }

    // MARK: - Read path: input.agentResult reaches run(input)

    private func singleTaskSnapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "任務", due: nil, completed: false,
                               lists: [], tags: [], revision: "r1"),
        ])
    }

    private let echoAgentResultSource = """
    function run(input) {
      return { schemaVersion: 1, page: { type: "page", id: "root", title: "echo", children: [
        { type: "statCard", id: "ar", title: "s", value: String(input.agentResult) }
      ] } };
    }
    """

    func testInputAgentResultReachesPluginRun() throws {
        let doc = try ReportPluginRunner().run(source: echoAgentResultSource, reportType: "triage",
                                               snapshot: singleTaskSnapshot(), todayYMD: "2026-07-24",
                                               agentResult: "hello")
        let card = doc.page.children?.first { $0.id == "ar" }
        XCTAssertEqual(card?.value, "hello")
    }

    func testInputAgentResultDefaultsToUndefined() throws {
        let doc = try ReportPluginRunner().run(source: echoAgentResultSource, reportType: "triage",
                                               snapshot: singleTaskSnapshot(), todayYMD: "2026-07-24")
        let card = doc.page.children?.first { $0.id == "ar" }
        XCTAssertEqual(card?.value, "undefined")
    }
}
