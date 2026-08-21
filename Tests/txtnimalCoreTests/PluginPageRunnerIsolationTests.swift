import XCTest
@testable import txtnimalCore

private final class RecordingPageTransport: PluginExecutionTransport, @unchecked Sendable {
    private(set) var callCount = 0
    private(set) var lastRequest: Data?
    func execute(pluginID: String, request: Data) async throws -> Data {
        callCount += 1
        lastRequest = request
        return try JSONEncoder().encode(PluginPageDocument(
            schemaVersion: 1,
            page: PluginPageNode(type: .page, id: "root", pageID: "installed-page",
                                 children: [PluginPageNode(type: .text, id: "message", value: "isolated")])) )
    }
}

final class PluginPageRunnerIsolationTests: XCTestCase {
    func testInstalledEntryUsesTransportAndReturnsDecodedPage() async throws {
        let manifest = PluginManifest(
            id: "app.txtnimal.installed-page", name: "Installed", version: "1.0.0", apiVersion: 1,
            entry: "main.js", capabilities: [.uiPage],
            pages: [PluginPageDeclaration(id: "installed-page", title: "Installed", entryFunction: "run")])
        let entry = PluginRegistryEntry(manifest: manifest, source: .installed,
                                        packageRootURL: URL(fileURLWithPath: "/tmp/installed"), enabled: true)
        let transport = RecordingPageTransport()
        let document = try await GenericPluginPageRunner().run(
            entry: entry,
            source: "function run(input) { while (true) {} }",
            snapshot: PluginDocumentSnapshot(documentRevision: "rev", tasks: []),
            todayYMD: "2026-08-15",
            transport: transport,
            timeoutNanoseconds: 1_000_000_000)

        XCTAssertEqual(document.page.pageID, "installed-page")
        XCTAssertEqual(transport.callCount, 1)
    }

    /// G-snap: the isolated (installed) path serializes its own task payload, separate from
    /// the in-process runner. Both must carry the five snapshot fields or plugins behave
    /// differently depending on how they were installed.
    func testInstalledEntryPayloadCarriesSnapshotFields() async throws {
        let manifest = PluginManifest(
            id: "app.txtnimal.installed-page", name: "Installed", version: "1.0.0", apiVersion: 1,
            entry: "main.js", capabilities: [.uiPage],
            pages: [PluginPageDeclaration(id: "installed-page", title: "Installed", entryFunction: "run")])
        let entry = PluginRegistryEntry(manifest: manifest, source: .installed,
                                        packageRootURL: URL(fileURLWithPath: "/tmp/installed"), enabled: true)
        let transport = RecordingPageTransport()
        let snapshot = PluginDocumentSnapshot(documentRevision: "rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "全欄位", due: "2026-08-20", completed: false,
                               lists: ["work"], tags: ["home"], quadrant: 3, created: "2026-07-01",
                               note: "備註", recurrence: "2d", focus: true, revision: "r1"),
        ])
        _ = try await GenericPluginPageRunner().run(
            entry: entry, source: "function run(input) { return {}; }",
            snapshot: snapshot, todayYMD: "2026-08-15", transport: transport)

        let request = try XCTUnwrap(transport.lastRequest)
        let envelope = try XCTUnwrap(try JSONSerialization.jsonObject(with: request) as? [String: Any])
        let inputJSON = try XCTUnwrap(envelope["inputJSON"] as? String)
        let input = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(inputJSON.utf8)) as? [String: Any])
        let task = try XCTUnwrap((input["tasks"] as? [[String: Any]])?.first)
        XCTAssertEqual(task["q"] as? Int, 3)
        XCTAssertEqual(task["created"] as? String, "2026-07-01")
        XCTAssertEqual(task["note"] as? String, "備註")
        XCTAssertEqual(task["rec"] as? String, "2d")
        XCTAssertEqual(task["focus"] as? Bool, true)
    }

    func testBundledEntryDoesNotCallTransport() async throws {
        let manifest = PluginManifest(
            id: "app.txtnimal.bundled-page", name: "Bundled", version: "1.0.0", apiVersion: 1,
            entry: "main.js", capabilities: [.uiPage],
            pages: [PluginPageDeclaration(id: "bundled-page", title: "Bundled", entryFunction: "run")])
        let entry = PluginRegistryEntry(manifest: manifest, source: .bundled,
                                        packageRootURL: URL(fileURLWithPath: "/tmp/bundled"), enabled: true)
        let transport = RecordingPageTransport()
        let source = "function run(input) { return {schemaVersion:1,page:{type:'page',id:'root',pageID:'bundled-page',children:[]}}; }"
        let document = try await GenericPluginPageRunner().run(
            entry: entry,
            source: source,
            snapshot: PluginDocumentSnapshot(documentRevision: "rev", tasks: []),
            todayYMD: "2026-08-15",
            transport: transport)

        XCTAssertEqual(document.page.pageID, "bundled-page")
        XCTAssertEqual(transport.callCount, 0)
    }
}
