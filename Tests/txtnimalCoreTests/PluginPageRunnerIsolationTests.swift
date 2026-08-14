import XCTest
@testable import txtnimalCore

private final class RecordingPageTransport: PluginExecutionTransport, @unchecked Sendable {
    private(set) var callCount = 0
    func execute(pluginID: String, request: Data) async throws -> Data {
        callCount += 1
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
