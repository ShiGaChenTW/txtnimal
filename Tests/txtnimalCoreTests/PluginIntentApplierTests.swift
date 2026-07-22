import XCTest
@testable import txtnimalCore

final class PluginIntentApplierTests: XCTestCase {
    func testRescheduleTaskMutatesOnlyStableTarget() throws {
        let lines = TasksDocument.parse("One id:task-one due:2026-07-20\nTwo id:task-two due:2026-07-20")
        let snapshot = TaskDocumentSnapshot(lines: lines)
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .rescheduleTask,
                                           taskIDs: ["task-one"], due: "2026-07-22", expectedRevision: "rev", documentRevision: snapshot.documentRevision)
        let result = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-21")
        XCTAssertEqual(result.map(\.due), ["2026-07-22", "2026-07-20"])
    }

    func testRescheduleResolvesLegacyRowWithoutStampingID() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("Legacy task due:2026-07-20"))
        // The builder assigns a deterministic legacy id; reschedule must resolve it by identity
        // rather than requiring a persisted id: token.
        let legacyID = try PluginSnapshotBuilder.build(from: snapshot).tasks[0].id
        XCTAssertTrue(legacyID.hasPrefix("legacy-"))
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .rescheduleTask,
                                           taskIDs: [legacyID], due: "2026-07-25", expectedRevision: "rev",
                                           documentRevision: snapshot.documentRevision)

        let result = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-21")

        XCTAssertEqual(result[0].due, "2026-07-25")
        XCTAssertNil(result[0].stableID)                   // no id: token stamped into the file
        XCTAssertFalse(result[0].raw.contains("id:"))
    }

    func testStaleIntentFailsWithoutMutation() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("One id:task-one"))
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .rescheduleOverdue,
                                           taskIDs: [], due: nil, expectedRevision: "rev", documentRevision: "old")
        XCTAssertThrowsError(try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-21")) { error in
            XCTAssertEqual(error as? PluginIntentApplyError, .staleDocument)
        }
    }

    func testCreateTaskAppendsStampedLineWithoutChangingExistingTasks() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("Existing id:task-one due:2026-07-20"))
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .createTask,
                                           taskIDs: [], title: "Write launch notes", due: "2026-07-24",
                                           expectedRevision: nil, documentRevision: snapshot.documentRevision)

        let result = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-23")

        XCTAssertEqual(result.count, snapshot.lines.count + 1)
        XCTAssertEqual(result.first, snapshot.lines.first)
        XCTAssertEqual(result.last?.title, "Write launch notes")
        XCTAssertEqual(result.last?.due, "2026-07-24")
        XCTAssertEqual(result.last?.created, "2026-07-23")
    }

    func testCompleteTaskMarksTargetsDoneOnly() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("One id:task-one\nTwo id:task-two"))
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .completeTask,
                                           taskIDs: ["task-one"], title: nil, due: nil,
                                           expectedRevision: nil, documentRevision: snapshot.documentRevision)
        let result = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-23")
        XCTAssertTrue(result[0].isDone)
        XCTAssertFalse(result[1].isDone)
    }

    func testDeleteTaskRemovesTargetedRows() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("One id:task-one\nTwo id:task-two\nThree id:task-three"))
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .deleteTask,
                                           taskIDs: ["task-one", "task-three"], title: nil, due: nil,
                                           expectedRevision: nil, documentRevision: snapshot.documentRevision)
        let result = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-23")
        XCTAssertEqual(result.map(\.title), ["Two"])
    }

    func testRetitleTaskChangesTitleKeepingMetadata() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("Old id:task-one due:2026-07-20"))
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .retitleTask,
                                           taskIDs: ["task-one"], title: "New title", due: nil,
                                           expectedRevision: nil, documentRevision: snapshot.documentRevision)
        let result = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-23")
        XCTAssertEqual(result[0].title, "New title")
        XCTAssertEqual(result[0].due, "2026-07-20")
        XCTAssertEqual(result[0].stableID, "task-one")
    }

    func testCreateTaskSanitizesLineBreaksAndOverridesEmbeddedDates() throws {
        let snapshot = TaskDocumentSnapshot(lines: [])
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .createTask,
                                           taskIDs: [], title: "Review due:2020-01-01\ncreated:2020-01-01",
                                           due: nil, expectedRevision: nil,
                                           documentRevision: snapshot.documentRevision)

        let result = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-23")

        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].due)
        XCTAssertEqual(result[0].created, "2026-07-23")
        XCTAssertFalse(result[0].raw.contains("\n"))
    }
}
