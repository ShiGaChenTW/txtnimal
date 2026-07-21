import XCTest
@testable import txtnimalCore

final class PluginSnapshotTests: XCTestCase {
    func testPersistedIDSurvivesSnapshotAndEncoding() throws {
        var line = TaskLine("Write report id:task-123 +work")
        line.setStableID("task-123")
        let document = TaskDocumentSnapshot(lines: [line])
        let snapshot = try PluginSnapshotBuilder.build(from: document)
        XCTAssertEqual(snapshot.tasks.first?.id, "task-123")
        XCTAssertEqual(try JSONEncoder().encode(snapshot), try JSONEncoder().encode(snapshot))
    }

    func testLegacySnapshotDoesNotMutateSourceAndDuplicateLinesGetDistinctIDs() throws {
        let lines = TasksDocument.parse("legacy\nlegacy")
        let document = TaskDocumentSnapshot(lines: lines)
        let snapshot = try PluginSnapshotBuilder.build(from: document)
        XCTAssertEqual(document.lines.map(\.raw), ["legacy", "legacy"])
        XCTAssertEqual(snapshot.tasks.map(\.id), ["legacy-\(DocumentRevision.make(for: "legacy").prefix(16))", "legacy-\(DocumentRevision.make(for: "legacy").prefix(16))-1"])
    }

    func testDuplicatePersistedIDsFailClosed() {
        let lines = TasksDocument.parse("one id:same\ntwo id:same")
        XCTAssertThrowsError(try PluginSnapshotBuilder.build(from: TaskDocumentSnapshot(lines: lines))) { error in
            XCTAssertEqual(error as? PluginSnapshotError, .duplicatePersistedIdentity("same"))
        }
    }

    func testDocumentRevisionChangesOnlyWhenBytesChange() {
        let first = TaskDocumentSnapshot(lines: TasksDocument.parse("one\ntwo"))
        let same = TaskDocumentSnapshot(lines: TasksDocument.parse("one\ntwo"))
        let changed = TaskDocumentSnapshot(lines: TasksDocument.parse("one\nthree"))
        XCTAssertEqual(first.documentRevision, same.documentRevision)
        XCTAssertNotEqual(first.documentRevision, changed.documentRevision)
    }

    func testInvalidPersistedIDFailsClosed() {
        let line = TaskLine("bad id:../escape")
        XCTAssertTrue(try! PluginSnapshotBuilder.build(from: TaskDocumentSnapshot(lines: [line])).tasks[0].id.hasPrefix("legacy-"))
    }

    func testStaleDocumentRevisionRejectsAction() throws {
        let manifest = PluginManifest(id: "app.txtnimal.test", name: "Test", version: "1.0.0", apiVersion: 1,
                                      entry: "main.js", capabilities: [.tasksUpdate])
        let action = PluginAction(type: .hostCommand, command: "tasks.rescheduleOverdue",
                                  expectedRevision: "task-rev", documentRevision: "old-doc")
        XCTAssertThrowsError(try PluginValidator.validate(action: action, manifest: manifest,
                                                          documentRevision: "new-doc")) { error in
            XCTAssertEqual(error as? PluginValidationError, .staleDocument)
        }
        XCTAssertThrowsError(try PluginValidator.validate(action: action, manifest: manifest,
                                                          documentRevision: nil)) { error in
            XCTAssertEqual(error as? PluginValidationError, .staleDocument)
        }
    }

    func testLegacyIdentityCannotCollideWithPersistedIdentity() throws {
        let raw = "legacy"
        let base = "legacy-\(DocumentRevision.make(for: raw).prefix(16))"
        let lines = TasksDocument.parse("\(raw)\nother id:\(base)")
        XCTAssertThrowsError(try PluginSnapshotBuilder.build(from: TaskDocumentSnapshot(lines: lines))) { error in
            XCTAssertEqual(error as? PluginSnapshotError, .duplicatePersistedIdentity(base))
        }
    }
}
