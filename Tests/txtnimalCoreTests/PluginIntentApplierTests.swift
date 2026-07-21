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

    func testStaleIntentFailsWithoutMutation() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("One id:task-one"))
        let intent = ValidatedPluginIntent(pluginID: "app.txtnimal.test", command: .rescheduleOverdue,
                                           taskIDs: [], due: nil, expectedRevision: "rev", documentRevision: "old")
        XCTAssertThrowsError(try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-21")) { error in
            XCTAssertEqual(error as? PluginIntentApplyError, .staleDocument)
        }
    }
}
