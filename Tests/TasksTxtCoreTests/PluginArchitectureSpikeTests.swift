import Foundation
import XCTest
@testable import TasksTxtCore

final class PluginArchitectureSpikeTests: XCTestCase {
    func testApprovedFixturesShareManifestAndActionGate() throws {
        let commandRoot = fixture("reschedule-tomorrow")
        let commandManifest = try PluginValidator.decodeManifest(Data(contentsOf: commandRoot.appendingPathComponent("manifest.json")))
        XCTAssertEqual(try PluginValidator.resolveEntry(commandManifest.entry, in: commandRoot).lastPathComponent, "main.js")
        let action = PluginAction(type: .hostCommand, command: "tasks.reschedule",
                                  taskIDs: ["task-123"], due: "2026-07-22", expectedRevision: "rev-1")
        let intent = try PluginValidator.validate(action: action, manifest: commandManifest)
        XCTAssertEqual(intent.command, .rescheduleTask)
        XCTAssertEqual(intent.taskIDs, ["task-123"])
        assertValidationError(.invalidAction) {
            try PluginValidator.validate(action: action, manifest: commandManifest,
                                         taskRevisions: ["task-123": "rev-2"])
        }

        let pageRoot = fixture("weekly-review")
        let pageManifest = try PluginValidator.decodeManifest(Data(contentsOf: pageRoot.appendingPathComponent("manifest.json")))
        let page = try PluginValidator.decodePage(Data(contentsOf: pageRoot.appendingPathComponent("weekly-review.json")), manifest: pageManifest)
        XCTAssertEqual(page.page.pageID, "weekly-review")
        XCTAssertEqual(page.page.children?.first?.children?.last?.action?.command, "tasks.rescheduleOverdue")
    }

    func testUnknownCapabilityAndNodeFailClosed() throws {
        let unknownCapability = manifestJSON(capabilities: ["tasks.read.everything"])
        XCTAssertThrowsError(try PluginValidator.decodeManifest(unknownCapability))

        let manifest = try PluginValidator.decodeManifest(manifestJSON(capabilities: ["tasks.update", "ui.page"], withPage: true))
        let unknownNode = Data("""
        {"schemaVersion":1,"page":{"type":"page","id":"root","pageID":"weekly-review","children":[{"type":"webView","id":"web"}]}}
        """.utf8)
        XCTAssertThrowsError(try PluginValidator.decodePage(unknownNode, manifest: manifest))

        let unknownProperty = Data("""
        {"schemaVersion":1,"page":{"type":"page","id":"root","pageID":"weekly-review","script":"alert(1)"}}
        """.utf8)
        XCTAssertThrowsError(try PluginValidator.decodePage(unknownProperty, manifest: manifest))

        let unknownManifestProperty = Data("""
        {"id":"app.txtnimal.test","name":"Test","version":"1.0.0","apiVersion":1,"entry":"main.js","capabilities":[],"commands":[],"pages":[],"network":true}
        """.utf8)
        XCTAssertThrowsError(try PluginValidator.decodeManifest(unknownManifestProperty))

        assertValidationError(.payloadTooLarge) {
            try PluginValidator.decodeManifest(manifestJSON(), limits: .init(maximumManifestBytes: 8))
        }
    }

    func testDuplicateJSONKeysFailClosed() {
        let duplicate = Data(#"{"id":"app.txtnimal.test","id":"second","name":"Test","version":"1.0.0","apiVersion":1,"entry":"main.js","capabilities":[],"commands":[],"pages":[]}"#.utf8)
        XCTAssertThrowsError(try PluginValidator.decodeManifest(duplicate))
    }

    func testVersionPayloadDepthNodeAndQueryLimitsFailClosed() throws {
        let manifest = try PluginValidator.decodeManifest(manifestJSON(capabilities: ["tasks.update", "ui.page"], withPage: true))
        let root = PluginPageNode(type: .page, id: "root", pageID: "weekly-review")
        XCTAssertThrowsError(try PluginValidator.validate(PluginPageDocument(schemaVersion: 2, page: root), manifest: manifest))

        let payload = Data(repeating: 0x20, count: 17)
        XCTAssertThrowsError(try PluginValidator.decodePage(payload, manifest: manifest,
                                                            limits: .init(maximumPayloadBytes: 16)))

        let deep = PluginPageNode(type: .page, id: "root", pageID: "weekly-review", children: [
            PluginPageNode(type: .section, id: "one", children: [
                PluginPageNode(type: .section, id: "two")
            ])
        ])
        XCTAssertThrowsError(try PluginValidator.validate(PluginPageDocument(schemaVersion: 1, page: deep),
                                                          manifest: manifest, limits: .init(maximumDepth: 2)))

        let many = PluginPageNode(type: .page, id: "root", pageID: "weekly-review", children: [
            PluginPageNode(type: .text, id: "a"), PluginPageNode(type: .text, id: "b")
        ])
        XCTAssertThrowsError(try PluginValidator.validate(PluginPageDocument(schemaVersion: 1, page: many),
                                                          manifest: manifest, limits: .init(maximumNodes: 2)))

        let query = PluginPageNode(type: .page, id: "root", pageID: "weekly-review", children: [
            PluginPageNode(type: .taskList, id: "tasks", query: .init(limit: 101))
        ])
        XCTAssertThrowsError(try PluginValidator.validate(PluginPageDocument(schemaVersion: 1, page: query),
                                                          manifest: manifest))

        let negativeQuery = PluginPageNode(type: .page, id: "root", pageID: "weekly-review", children: [
            PluginPageNode(type: .taskList, id: "tasks", query: .init(limit: -1))
        ])
        assertValidationError(.queryLimitExceeded) {
            try PluginValidator.validate(.init(schemaVersion: 1, page: negativeQuery), manifest: manifest)
        }
    }

    func testCapabilityRevisionAndDuplicateIDsAreRejected() throws {
        let readOnly = try PluginValidator.decodeManifest(manifestJSON(capabilities: ["tasks.selected.read"]))
        let validShape = PluginAction(type: .hostCommand, command: "tasks.reschedule",
                                      taskIDs: ["task-1"], due: "2026-07-22", expectedRevision: "rev")
        XCTAssertThrowsError(try PluginValidator.validate(action: validShape, manifest: readOnly))

        let writable = try PluginValidator.decodeManifest(manifestJSON(capabilities: ["tasks.update"]))
        let staleShape = PluginAction(type: .hostCommand, command: "tasks.reschedule",
                                      taskIDs: ["task-1"], due: "2026-07-22")
        XCTAssertThrowsError(try PluginValidator.validate(action: staleShape, manifest: writable))

        let invalidDate = PluginAction(type: .hostCommand, command: "tasks.reschedule",
                                       taskIDs: ["task-1"], due: "2026-02-30", expectedRevision: "rev")
        assertValidationError(.invalidAction) {
            try PluginValidator.validate(action: invalidDate, manifest: writable,
                                         taskRevisions: ["task-1": "rev"])
        }

        let duplicateTasks = PluginAction(type: .hostCommand, command: "tasks.reschedule",
                                          taskIDs: ["task-1", "task-1"], due: "2026-07-22",
                                          expectedRevision: "rev")
        assertValidationError(.invalidAction) {
            try PluginValidator.validate(action: duplicateTasks, manifest: writable,
                                         taskRevisions: ["task-1": "rev"])
        }

        let duplicate = Data("""
        {"id":"app.txtnimal.test","name":"Test","version":"1.0.0","apiVersion":1,"entry":"main.js","capabilities":[],"commands":[{"id":"same","title":"A"},{"id":"same","title":"B"}],"pages":[]}
        """.utf8)
        XCTAssertThrowsError(try PluginValidator.decodeManifest(duplicate))

        let manifest = try PluginValidator.decodeManifest(manifestJSON(capabilities: ["ui.page"], withPage: true))
        let nestedPage = PluginPageNode(type: .page, id: "root", pageID: "weekly-review", children: [
            PluginPageNode(type: .page, id: "nested", pageID: "weekly-review")
        ])
        XCTAssertThrowsError(try PluginValidator.validate(.init(schemaVersion: 1, page: nestedPage), manifest: manifest))

        let hiddenAction = PluginPageNode(type: .page, id: "root", pageID: "weekly-review", children: [
            PluginPageNode(type: .text, id: "hidden", value: "text",
                           action: .init(type: .hostCommand, command: "tasks.rescheduleOverdue",
                                         expectedRevision: "rev"))
        ])
        assertValidationError(.invalidNode) {
            try PluginValidator.validate(.init(schemaVersion: 1, page: hiddenAction), manifest: manifest)
        }
    }

    func testAbsoluteTraversalAndSymlinkEntryEscapeAreRejected() throws {
        for entry in ["/tmp/main.js", "../main.js", "scripts/../../main.js"] {
            XCTAssertThrowsError(try PluginValidator.decodeManifest(manifestJSON(entry: entry)))
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".js")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("main.js"), withDestinationURL: outside)
        XCTAssertThrowsError(try PluginValidator.resolveEntry("main.js", in: root))

        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.js"),
                                                withIntermediateDirectories: true)
        assertValidationError(.invalidEntryPath) {
            try PluginValidator.resolveEntry("directory.js", in: root)
        }
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("PluginFixtures").appendingPathComponent(name)
    }

    private func manifestJSON(entry: String = "main.js", capabilities: [String] = [], withPage: Bool = false) -> Data {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        let pages = withPage ? "[{\"id\":\"weekly-review\",\"title\":\"Weekly Review\",\"entryFunction\":\"render\"}]" : "[]"
        return Data("""
        {"id":"app.txtnimal.test","name":"Test","version":"1.0.0","apiVersion":1,"entry":"\(entry)","capabilities":[\(caps)],"commands":[],"pages":\(pages)}
        """.utf8)
    }

    private func assertValidationError<T>(_ expected: PluginValidationError, file: StaticString = #filePath,
                                          line: UInt = #line, _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? PluginValidationError, expected, file: file, line: line)
        }
    }
}
