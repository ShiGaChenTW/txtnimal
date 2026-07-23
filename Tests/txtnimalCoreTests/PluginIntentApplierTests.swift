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

    func testApplyBatchReschedulesDuplicateLegacyTasksIndependently() throws {
        // Two identical legacy rows (no persisted id) — the pre-fix per-intent loop drifted and
        // failed the second one. applyBatch resolves identity once, so both land correctly.
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("Todo\nTodo"))
        let built = try PluginSnapshotBuilder.build(from: snapshot)
        let intents = [
            ValidatedPluginIntent(pluginID: "t", command: .rescheduleTask, taskIDs: [built.tasks[0].id],
                                  title: nil, due: "2026-07-25", expectedRevision: "r", documentRevision: snapshot.documentRevision),
            ValidatedPluginIntent(pluginID: "t", command: .rescheduleTask, taskIDs: [built.tasks[1].id],
                                  title: nil, due: "2026-07-26", expectedRevision: "r", documentRevision: snapshot.documentRevision),
        ]
        let result = try PluginIntentApplier.applyBatch(intents, to: snapshot, todayYMD: "2026-07-20")
        XCTAssertEqual(result.map { $0.due }, ["2026-07-25", "2026-07-26"])
    }

    func testRetitleSanitizesInjectedControlTokens() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("Original id:task-one due:2026-07-20"))
        let intent = ValidatedPluginIntent(pluginID: "t", command: .retitleTask, taskIDs: ["task-one"],
                                           title: "x Pwned due:2099-12-31 id:other\nsecond line", due: nil,
                                           expectedRevision: nil, documentRevision: snapshot.documentRevision)
        let result = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-23")
        XCTAssertEqual(result.count, 1)                 // no extra line injected via newline
        XCTAssertFalse(result[0].isDone)                // leading "x" neutralized
        XCTAssertEqual(result[0].due, "2026-07-20")     // due: token not injected
        XCTAssertEqual(result[0].stableID, "task-one")  // id: token not injected
        XCTAssertFalse(result[0].raw.contains("\n"))
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
