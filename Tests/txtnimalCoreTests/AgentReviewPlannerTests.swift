import XCTest
@testable import txtnimalCore

final class AgentReviewPlannerTests: XCTestCase {
    func testCreateIntentProducesOneReviewItemPerIntent() {
        let intents = [
            ValidatedPluginIntent(pluginID: "app.txtnimal.brain-dump", command: .createTask,
                                  taskIDs: [], title: "交季報", due: "2026-07-25",
                                  expectedRevision: nil, documentRevision: "doc-rev"),
            ValidatedPluginIntent(pluginID: "app.txtnimal.brain-dump", command: .createTask,
                                  taskIDs: [], title: "準備投影片 +工作 @urgent", due: nil,
                                  expectedRevision: nil, documentRevision: "doc-rev"),
        ]

        let items = AgentReviewPlanner.makeItems(intents: intents, currentTasks: [],
                                                 defaultDueYMD: "2026-07-24")

        XCTAssertEqual(items.map(\.id), ["new-1", "new-2"])
        XCTAssertEqual(items.map(\.title), ["交季報", "準備投影片 +工作 @urgent"])
        XCTAssertEqual(items.map(\.oldDue), [nil, nil])
        XCTAssertEqual(items.map(\.newDue), ["2026-07-25", "無期限"])
        XCTAssertEqual(items.map(\.intent), intents)
    }

    func testRemoveItemDropsPairedIntentByConstruction() {
        let intents = [
            ValidatedPluginIntent(pluginID: "app.txtnimal.brain-dump", command: .createTask,
                                  taskIDs: [], title: "交季報", due: "2026-07-25",
                                  expectedRevision: nil, documentRevision: "doc-rev"),
            ValidatedPluginIntent(pluginID: "app.txtnimal.brain-dump", command: .createTask,
                                  taskIDs: [], title: "準備投影片", due: nil,
                                  expectedRevision: nil, documentRevision: "doc-rev"),
            ValidatedPluginIntent(pluginID: "app.txtnimal.brain-dump", command: .createTask,
                                  taskIDs: [], title: "繳電費", due: nil,
                                  expectedRevision: nil, documentRevision: "doc-rev"),
        ]

        let items = AgentReviewPlanner.makeItems(intents: intents, currentTasks: [],
                                                 defaultDueYMD: "2026-07-24")
        let remaining = AgentReviewPlanner.removeItem(id: "new-2", from: items)

        XCTAssertEqual(remaining.map(\.id), ["new-1", "new-3"])
        XCTAssertEqual(remaining.map(\.title), ["交季報", "繳電費"])
        XCTAssertEqual(remaining.map(\.intent.title), ["交季報", "繳電費"])
    }
}
