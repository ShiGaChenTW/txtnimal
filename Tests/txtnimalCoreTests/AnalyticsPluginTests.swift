import XCTest
@testable import txtnimalCore

final class AnalyticsPluginTests: XCTestCase {
    private let today = "2026-07-24"

    private func loadSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let jsURL = repoRoot.appendingPathComponent("PluginFixtures/analytics/main.js")
        return try String(contentsOf: jsURL, encoding: .utf8)
    }

    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "整理週報", due: nil, completed: true,
                               lists: ["work"], tags: ["urgent"], revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "回覆客戶", due: nil, completed: true,
                               lists: ["work"], tags: ["waiting"], revision: "r2"),
            PluginTaskSnapshot(id: "t3", title: "採買用品", due: nil, completed: false,
                               lists: ["home"], tags: ["urgent"], revision: "r3"),
            PluginTaskSnapshot(id: "t4", title: "整理收件匣", due: nil, completed: false,
                               lists: [], tags: [], revision: "r4"),
        ])
    }

    private func metadata() -> [String: ReportPluginRunner.TaskMetadata] {
        [
            "t1": ReportPluginRunner.TaskMetadata(done: "2026-07-22"),
            "t2": ReportPluginRunner.TaskMetadata(done: "2026-07-15"),
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

    func testOverviewAndListMetricsAreComputed() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "analytics",
                                               snapshot: snapshot(), todayYMD: today, metadata: metadata())
        XCTAssertEqual(doc.page.pageID, "analytics")
        XCTAssertEqual(doc.page.title, "分析儀表板")
        XCTAssertEqual(node(in: doc, id: "analytics-stat-rate")?.value, "50%")
        XCTAssertEqual(node(in: doc, id: "analytics-list-0")?.value, "2/2（100%）")
        XCTAssertEqual(node(in: doc, id: "analytics-list-1")?.value, "0/1（0%）")
        XCTAssertEqual(node(in: doc, id: "analytics-lists-chart")?.value, "1,0.5")
    }

    func testTrendCountsCompletionInCurrentWeekBucket() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "analytics",
                                               snapshot: snapshot(), todayYMD: today, metadata: metadata())
        let chart = try XCTUnwrap(node(in: doc, id: "analytics-trend-chart"))
        let values = chart.value?.split(separator: ",").compactMap { Double($0) } ?? []
        XCTAssertEqual(values.count, 8)
        XCTAssertGreaterThan(values.last ?? 0, 0)
        XCTAssertEqual(node(in: doc, id: "analytics-stat-velocity")?.value, "0.25")
    }

    func testTrendDegradesWithoutCompletionDates() throws {
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "analytics",
                                               snapshot: snapshot(), todayYMD: today, metadata: [:])
        XCTAssertNotNil(node(in: doc, id: "analytics-trend-empty"))
        XCTAssertEqual(node(in: doc, id: "analytics-stat-velocity")?.value, "—")
    }

    func testDeterministicOutput() throws {
        let source = try loadSource()
        let first = try ReportPluginRunner().run(source: source, reportType: "analytics",
                                                 snapshot: snapshot(), todayYMD: today, metadata: metadata())
        let second = try ReportPluginRunner().run(source: source, reportType: "analytics",
                                                  snapshot: snapshot(), todayYMD: today, metadata: metadata())
        XCTAssertEqual(first, second)
    }
}
