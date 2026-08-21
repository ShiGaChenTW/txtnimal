import XCTest
@testable import txtnimalCore

final class PluginSnapshotTests: XCTestCase {
    func testPersistedIDSurvivesSnapshotAndEncoding() throws {
        var line = TaskLine("Write report id:task-123 +work")
        line.setStableID("task-123")
        let document = TaskDocumentSnapshot(lines: [line])
        let snapshot = try PluginSnapshotBuilder.build(from: document)
        XCTAssertEqual(snapshot.tasks.first?.id, "task-123")
        // Use sortedKeys so the comparison tests content stability, not incidental key ordering
        // (default JSONEncoder key order is not guaranteed stable between calls).
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(snapshot), try encoder.encode(snapshot))
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

    // MARK: - G-snap: 五個補齊欄位

    func testSnapshotCarriesAllFiveAddedFields() throws {
        let raw = #"Write report id:task-1 q:2 created:2026-07-01 rec:1w focus:true note:"call ops first" +work @home"#
        let document = TaskDocumentSnapshot(lines: TasksDocument.parse(raw))
        let task = try XCTUnwrap(try PluginSnapshotBuilder.build(from: document).tasks.first)
        XCTAssertEqual(task.quadrant, 2)
        XCTAssertEqual(task.created, "2026-07-01")
        XCTAssertEqual(task.recurrence, "1w")
        XCTAssertEqual(task.focus, true)
        XCTAssertEqual(task.note, "call ops first")
        // The pre-existing fields must be unaffected by the additions.
        XCTAssertEqual(task.title, "Write report")
        XCTAssertEqual(task.lists, ["work"])
        XCTAssertEqual(task.tags, ["home"])
    }

    func testSnapshotFieldsAreAbsentWhenTokensAreAbsent() throws {
        let document = TaskDocumentSnapshot(lines: TasksDocument.parse("Plain task id:task-2"))
        let task = try XCTUnwrap(try PluginSnapshotBuilder.build(from: document).tasks.first)
        XCTAssertNil(task.quadrant)
        XCTAssertNil(task.created)
        XCTAssertNil(task.recurrence)
        XCTAssertNil(task.note)
        XCTAssertFalse(task.focus, "focus is a Bool — absent token means false, never nil")
    }

    /// The five fields must survive JSON encoding under their contract keys. This is the
    /// wire the plugin host serializes, so a rename here is a breaking API change.
    func testAddedFieldsEncodeUnderContractKeys() throws {
        let raw = #"Task id:task-3 q:1 created:2026-08-01 rec:2d focus:true note:"n""#
        let document = TaskDocumentSnapshot(lines: TasksDocument.parse(raw))
        let snapshot = try PluginSnapshotBuilder.build(from: document)
        let data = try JSONEncoder().encode(try XCTUnwrap(snapshot.tasks.first))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["quadrant"] as? Int, 1)
        XCTAssertEqual(object["created"] as? String, "2026-08-01")
        XCTAssertEqual(object["recurrence"] as? String, "2d")
        XCTAssertEqual(object["note"] as? String, "n")
        XCTAssertEqual(object["focus"] as? Bool, true)
        // Additive only: every previously-shipped key is still present.
        for key in ["id", "title", "completed", "lists", "tags", "revision"] {
            XCTAssertNotNil(object[key], "existing key \(key) must not disappear")
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
