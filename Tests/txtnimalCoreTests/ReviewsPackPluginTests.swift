import XCTest
@testable import txtnimalCore

final class ReviewsPackPluginTests: XCTestCase {
    private let today = "2026-07-24"

    private func loadSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let jsURL = repoRoot.appendingPathComponent("PluginFixtures/reviews-pack/main.js")
        return try String(contentsOf: jsURL, encoding: .utf8)
    }

    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "停滯甲", due: nil, completed: false, lists: [], tags: [],
                               revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "停滯乙", due: nil, completed: false, lists: [], tags: [],
                               revision: "r2"),
            PluginTaskSnapshot(id: "t3", title: "今日", due: "2026-07-24", completed: false, lists: [], tags: [],
                               revision: "r3"),
            PluginTaskSnapshot(id: "t4", title: "已完成", due: nil, completed: true, lists: [], tags: [],
                               revision: "r4"),
            PluginTaskSnapshot(id: "t5", title: "無created", due: nil, completed: false, lists: [], tags: [],
                               revision: "r5"),
        ])
    }

    private func metadata() -> [String: ReportPluginRunner.TaskMetadata] {
        [
            "t1": ReportPluginRunner.TaskMetadata(created: "2026-07-01"),
            "t2": ReportPluginRunner.TaskMetadata(created: "2026-06-20"),
            "t3": ReportPluginRunner.TaskMetadata(created: "2026-07-20"),
            "t4": ReportPluginRunner.TaskMetadata(created: "2026-06-01"),
        ]
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

    func testStalledCountsAgedIncompleteTasks() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "stalled",
                                               snapshot: snapshot(), todayYMD: today, metadata: metadata())
        XCTAssertEqual(node(in: doc, id: "stalled-stat-count")?.value, "2")
        XCTAssertNotNil(node(in: doc, id: "stalled-list"))
        XCTAssertTrue(node(in: doc, id: "stalled-list-t0")?.value?.contains("停滯乙") == true)
    }

    func testStalledDegradesWithoutCreated() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "stalled",
                                               snapshot: snapshot(), todayYMD: today, metadata: [:])
        XCTAssertNotNil(node(in: doc, id: "stalled-need-created"))
        XCTAssertNil(node(in: doc, id: "stalled-stat-count"))
    }

    func testUnknownViewFallsBackToWeekly() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "",
                                               snapshot: snapshot(), todayYMD: today, metadata: metadata())
        XCTAssertEqual(doc.page.pageID, "weekly")
    }

    func testDailyClassifiesDueToday() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "daily",
                                               snapshot: snapshot(), todayYMD: today, metadata: metadata())
        XCTAssertEqual(doc.page.pageID, "daily")
        XCTAssertEqual(node(in: doc, id: "daily-stat-today")?.value, "1")
    }

    func testDeterministicOutput() throws {
        let source = try loadSource()
        let first = try ReportPluginRunner().run(source: source, reportType: "stalled",
                                                 snapshot: snapshot(), todayYMD: today, metadata: metadata())
        let second = try ReportPluginRunner().run(source: source, reportType: "stalled",
                                                  snapshot: snapshot(), todayYMD: today, metadata: metadata())
        XCTAssertEqual(first, second)
    }
}
