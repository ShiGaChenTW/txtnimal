import XCTest
@testable import txtnimalCore

final class ReportPluginRunnerTests: XCTestCase {
    private let today = "2026-07-23"

    /// Loads the ACTUAL shipped fixture from disk, resolved relative to this test
    /// file: repoRoot/Tests/txtnimalCoreTests/ThisFile.swift -> repoRoot.
    private func loadSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // txtnimalCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let jsURL = repoRoot.appendingPathComponent("PluginFixtures/task-report/main.js")
        return try String(contentsOf: jsURL, encoding: .utf8)
    }

    // Known mix: 1 overdue, 1 due today, 1 upcoming, 1 completed, 1 no-due.
    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "逾期任務", due: "2026-07-22", completed: false,
                               lists: ["工作"], tags: ["urgent"], revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "今日任務", due: "2026-07-23", completed: false,
                               lists: ["工作"], tags: ["client"], revision: "r2"),
            PluginTaskSnapshot(id: "t3", title: "未來任務", due: "2026-07-30", completed: false,
                               lists: ["生活"], tags: [], revision: "r3"),
            PluginTaskSnapshot(id: "t4", title: "已完成任務", due: "2026-07-20", completed: true,
                               lists: ["工作"], tags: ["urgent"], revision: "r4"),
            PluginTaskSnapshot(id: "t5", title: "無日期任務", due: nil, completed: false,
                               lists: [], tags: ["someday"], revision: "r5"),
        ])
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

    func testWeeklyReturnsValidDocumentWithComputedCounts() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "weekly",
                                               snapshot: snapshot(), todayYMD: today)
        XCTAssertEqual(doc.schemaVersion, 1)
        XCTAssertEqual(doc.page.type, .page)
        XCTAssertEqual(doc.page.title, "任務週報")
        XCTAssertEqual(node(in: doc, id: "weekly-stat-overdue")?.value, "1")
        XCTAssertEqual(node(in: doc, id: "weekly-stat-today")?.value, "1")
        XCTAssertEqual(node(in: doc, id: "weekly-stat-upcoming")?.value, "1")
        XCTAssertEqual(node(in: doc, id: "weekly-stat-completed")?.value, "1")
    }

    func testStandupSplitsDoneTodayAndBlockers() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "standup",
                                               snapshot: snapshot(), todayYMD: today)
        XCTAssertEqual(doc.page.title, "站會日報")
        XCTAssertEqual(node(in: doc, id: "standup-stat-yesterday")?.value, "1") // completed
        XCTAssertEqual(node(in: doc, id: "standup-stat-today")?.value, "1")     // due today
        XCTAssertEqual(node(in: doc, id: "standup-stat-blockers")?.value, "1")  // overdue
    }

    func testProgressComputesTotalsAndCompletion() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "progress",
                                               snapshot: snapshot(), todayYMD: today)
        XCTAssertEqual(doc.page.title, "進度摘要")
        XCTAssertEqual(node(in: doc, id: "progress-stat-total")?.value, "5")
        XCTAssertEqual(node(in: doc, id: "progress-stat-done")?.value, "1")
        XCTAssertEqual(node(in: doc, id: "progress-stat-rate")?.value, "20%")
    }

    func testCategoryEmitsBarChartFromTagCounts() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "category",
                                               snapshot: snapshot(), todayYMD: today)
        XCTAssertEqual(doc.page.title, "分類統計")
        let chart = node(in: doc, id: "category-tags-chart")
        XCTAssertEqual(chart?.type, .barChart)
        // urgent=2 (max), client=1, someday=1 -> normalized "1,0.5,0.5"
        XCTAssertEqual(chart?.value, "1,0.5,0.5")
    }

    func testReportTypeChangesOutput() throws {
        let source = try loadSource()
        var titles = Set<String>()
        for reportType in ["weekly", "progress", "category", "standup"] {
            let doc = try ReportPluginRunner().run(source: source, reportType: reportType,
                                                   snapshot: snapshot(), todayYMD: today)
            if let title = doc.page.title { titles.insert(title) }
        }
        XCTAssertEqual(titles.count, 4, "each reportType must produce a distinct page")
    }

    func testNewFieldsSerializeToJS() throws {
        let echo = """
        function run(input) {
          var a = input.tasks[0], b = input.tasks[1];
          return { schemaVersion: 1, page: { type: "page", id: "root", title: "echo", children: [
            { type: "statCard", id: "a-created", title: "c", value: String(a.created) },
            { type: "statCard", id: "a-done",    title: "d", value: String(a.done) },
            { type: "statCard", id: "a-q",       title: "q", value: String(a.q) },
            { type: "statCard", id: "b-created", title: "c", value: String(b.created) }
          ] } };
        }
        """
        let snap = PluginDocumentSnapshot(documentRevision: "rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "有中繼", due: nil, completed: false, lists: [], tags: [],
                               revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "無中繼", due: nil, completed: false, lists: [], tags: [],
                               revision: "r2"),
        ])
        let meta = ["t1": ReportPluginRunner.TaskMetadata(created: "2026-07-01", done: "2026-07-05", quadrant: 3)]
        let doc = try ReportPluginRunner().run(source: echo, reportType: "weekly",
                                               snapshot: snap, todayYMD: today, metadata: meta)
        XCTAssertEqual(node(in: doc, id: "a-created")?.value, "2026-07-01")
        XCTAssertEqual(node(in: doc, id: "a-done")?.value, "2026-07-05")
        XCTAssertEqual(node(in: doc, id: "a-q")?.value, "3")
        XCTAssertEqual(node(in: doc, id: "b-created")?.value, "undefined")
    }

    func testMissingRunFunctionThrows() {
        XCTAssertThrowsError(
            try ReportPluginRunner().run(source: "function notRun() { return {}; }",
                                         reportType: "weekly", snapshot: snapshot(), todayYMD: today)
        )
    }
}
