import XCTest
@testable import txtnimalCore

final class MethodologyPluginTests: XCTestCase {
    private let today = "2026-07-24"

    private func loadSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let jsURL = repoRoot.appendingPathComponent("PluginFixtures/methodology/main.js")
        return try String(contentsOf: jsURL, encoding: .utf8)
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

    private func textValues(in node: PluginPageNode?) -> [String] {
        guard let node else { return [] }
        var values: [String] = []
        func walk(_ current: PluginPageNode) {
            if current.type == .text, let value = current.value {
                values.append(value)
            }
            for child in current.children ?? [] { walk(child) }
        }
        walk(node)
        return values
    }

    func testUnknownViewFallsBackToGTD() throws {
        let snapshot = PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "收集想法", due: nil, completed: false,
                               lists: [], tags: [], revision: "r1"),
        ])
        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "",
                                               snapshot: snapshot, todayYMD: today, metadata: [:])
        XCTAssertEqual(doc.page.pageID, "gtd")
    }

    func testEisenhowerBucketsByQuadrantNotDue() throws {
        let snapshot = PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "安排會議", due: "2026-07-20", completed: false,
                               lists: [], tags: [], revision: "r1"),
        ])
        let metadata = [
            "t1": ReportPluginRunner.TaskMetadata(quadrant: 2)
        ]

        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "eisenhower",
                                               snapshot: snapshot, todayYMD: today, metadata: metadata)

        XCTAssertEqual(doc.page.pageID, "eisenhower")
        XCTAssertTrue(textValues(in: node(in: doc, id: "eisenhower-q2")).contains("• 安排會議（截止 2026-07-20）"))
        XCTAssertFalse(textValues(in: node(in: doc, id: "eisenhower-q1")).contains("• 安排會議（截止 2026-07-20）"))
    }

    func testEisenhowerIncompleteTaskWithoutQuadrantLandsInPool() throws {
        let snapshot = PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "已排程", due: nil, completed: false,
                               lists: [], tags: [], revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "尚未歸位", due: nil, completed: false,
                               lists: [], tags: [], revision: "r2"),
        ])
        let metadata = [
            "t1": ReportPluginRunner.TaskMetadata(quadrant: 1)
        ]

        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "eisenhower",
                                               snapshot: snapshot, todayYMD: today, metadata: metadata)

        XCTAssertTrue(textValues(in: node(in: doc, id: "eisenhower-pool")).contains("• 尚未歸位"))
    }

    func testEisenhowerDegradesWhenNoTaskCarriesQuadrant() throws {
        let snapshot = PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "只看截止", due: "2026-07-18", completed: false,
                               lists: [], tags: [], revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "另一筆", due: nil, completed: false,
                               lists: [], tags: [], revision: "r2"),
        ])

        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "eisenhower",
                                               snapshot: snapshot, todayYMD: today, metadata: [:])

        XCTAssertEqual(doc.page.children?.count, 1)
        XCTAssertEqual(node(in: doc, id: "eisenhower-missing-q")?.title, "需要象限(q)資料")
        XCTAssertNil(node(in: doc, id: "eisenhower-q2"))
    }

    func testPARAGroupsByFirstMatchOrder() throws {
        let snapshot = PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "已完成專案", due: nil, completed: true,
                               lists: ["work"], tags: [], revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "健身", due: nil, completed: false,
                               lists: [], tags: ["area"], revision: "r2"),
            PluginTaskSnapshot(id: "t3", title: "參考資料", due: nil, completed: false,
                               lists: ["library"], tags: ["resource"], revision: "r3"),
            PluginTaskSnapshot(id: "t4", title: "客戶提案", due: nil, completed: false,
                               lists: ["client"], tags: [], revision: "r4"),
            PluginTaskSnapshot(id: "t5", title: "待整理", due: nil, completed: false,
                               lists: [], tags: [], revision: "r5"),
        ])

        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "para",
                                               snapshot: snapshot, todayYMD: today, metadata: [:])

        XCTAssertEqual(doc.page.pageID, "para")
        XCTAssertTrue(textValues(in: node(in: doc, id: "para-archive")).contains("• 已完成專案"))
        XCTAssertFalse(textValues(in: node(in: doc, id: "para-projects")).contains("• 已完成專案"))
        XCTAssertTrue(textValues(in: node(in: doc, id: "para-areas")).contains("• 健身"))
        XCTAssertTrue(textValues(in: node(in: doc, id: "para-resources")).contains("• 參考資料"))
        XCTAssertTrue(textValues(in: node(in: doc, id: "para-projects")).contains("• 客戶提案"))
        XCTAssertTrue(textValues(in: node(in: doc, id: "para-inbox")).contains("• 待整理"))
    }

    func testGTDGroupsByTagAndListAndOmitsCompleted() throws {
        let snapshot = PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "等老闆回覆", due: nil, completed: false,
                               lists: [], tags: ["waiting", "boss"], revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "打電話", due: nil, completed: false,
                               lists: [], tags: ["phone"], revision: "r2"),
            PluginTaskSnapshot(id: "t3", title: "拆解路線圖", due: nil, completed: false,
                               lists: ["roadmap"], tags: [], revision: "r3"),
            PluginTaskSnapshot(id: "t4", title: "已完成電話", due: nil, completed: true,
                               lists: [], tags: ["phone"], revision: "r4"),
            PluginTaskSnapshot(id: "t5", title: "收件匣任務", due: nil, completed: false,
                               lists: [], tags: [], revision: "r5"),
        ])

        let doc = try ReportPluginRunner().run(source: try loadSource(), reportType: "gtd",
                                               snapshot: snapshot, todayYMD: today, metadata: [:])
        let allText = textValues(in: doc.page)

        XCTAssertTrue(textValues(in: node(in: doc, id: "gtd-waiting")).contains("• 等老闆回覆"))
        XCTAssertFalse(textValues(in: node(in: doc, id: "gtd-next")).contains("• 等老闆回覆"))
        XCTAssertTrue(textValues(in: node(in: doc, id: "gtd-next")).contains("• 打電話"))
        XCTAssertTrue(textValues(in: node(in: doc, id: "gtd-project-0")).contains("• 拆解路線圖"))
        XCTAssertTrue(textValues(in: node(in: doc, id: "gtd-inbox")).contains("• 收件匣任務"))
        XCTAssertFalse(allText.contains("• 已完成電話"))
    }

    func testDeterministicOutput() throws {
        let snapshot = PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "等回覆", due: nil, completed: false,
                               lists: [], tags: ["waiting"], revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "專案甲", due: nil, completed: false,
                               lists: ["alpha"], tags: [], revision: "r2"),
            PluginTaskSnapshot(id: "t3", title: "封存項目", due: nil, completed: true,
                               lists: ["beta"], tags: [], revision: "r3"),
        ])
        let source = try loadSource()

        let first = try ReportPluginRunner().run(source: source, reportType: "para",
                                                 snapshot: snapshot, todayYMD: today, metadata: [:])
        let second = try ReportPluginRunner().run(source: source, reportType: "para",
                                                  snapshot: snapshot, todayYMD: today, metadata: [:])

        XCTAssertEqual(first, second)
    }
}
