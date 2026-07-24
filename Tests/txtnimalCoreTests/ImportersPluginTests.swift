import Foundation
import XCTest
@testable import txtnimalCore

final class ImportersPluginTests: XCTestCase {
    private let today = "2026-07-24"

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadSource() throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/importers/main.js"),
                   encoding: .utf8)
    }

    private func loadManifest() throws -> PluginManifest {
        let manifestURL = repoRoot().appendingPathComponent("PluginFixtures/importers/manifest.json")
        return try PluginValidator.decodeManifest(Data(contentsOf: manifestURL))
    }

    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "importers-doc-rev", tasks: [
            PluginTaskSnapshot(id: "water-1", title: "喝水", due: nil, completed: false,
                               lists: ["生活"], tags: [], revision: "rev-1")
        ])
    }

    private func renderDocument() throws -> PluginPageDocument {
        try ReportPluginRunner().run(source: try loadSource(), reportType: "importers",
                                     snapshot: snapshot(), todayYMD: today)
    }

    private func node(in document: PluginPageDocument, id: String) -> PluginPageNode? {
        func search(_ node: PluginPageNode) -> PluginPageNode? {
            if node.id == id { return node }
            for child in node.children ?? [] {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(document.page)
    }

    func testReminderButtonCarriesImportReadReminders() throws {
        let document = try renderDocument()
        let button = try XCTUnwrap(node(in: document, id: "importers-reminders"))

        XCTAssertEqual(button.type, .button)
        XCTAssertEqual(button.title, "從 Reminders 匯入")
        XCTAssertEqual(button.action?.type, .importRead)
        XCTAssertEqual(button.action?.command, PluginAction.importReadCommand)
        XCTAssertEqual(button.action?.source, "reminders")
    }

    func testImportActionGatePassesWithCapability() throws {
        let document = try renderDocument()
        let manifest = try loadManifest()
        let action = try XCTUnwrap(node(in: document, id: "importers-reminders")?.action)

        let validated = try PluginValidator.validate(importAction: action, manifest: manifest)

        XCTAssertEqual(validated.source, "reminders")
        XCTAssertEqual(validated.pluginID, "app.txtnimal.importers")
    }

    func testImportActionGateRefusedWithoutCapability() throws {
        let document = try renderDocument()
        let action = try XCTUnwrap(node(in: document, id: "importers-reminders")?.action)
        let manifest = PluginManifest(id: "app.txtnimal.importers", name: "Importers", version: "0.1.0",
                                      apiVersion: 1, entry: "main.js", capabilities: [.uiPage],
                                      pages: [PluginPageDeclaration(id: "importers", title: "Importers",
                                                                    entryFunction: "run")])

        XCTAssertThrowsError(try PluginValidator.validate(importAction: action, manifest: manifest)) {
            XCTAssertEqual($0 as? PluginValidationError, .missingCapability)
        }
    }

    func testRenderedPageValidatesAgainstManifestAndIsDeterministic() throws {
        let source = try loadSource()
        let manifest = try loadManifest()
        let first = try ReportPluginRunner().run(source: source, reportType: "importers",
                                                 snapshot: snapshot(), todayYMD: today)
        let second = try ReportPluginRunner().run(source: source, reportType: "importers",
                                                  snapshot: snapshot(), todayYMD: today)

        XCTAssertNoThrow(try PluginValidator.validate(first, manifest: manifest))
        XCTAssertEqual(first, second)
    }
}
