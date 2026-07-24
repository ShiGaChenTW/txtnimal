import Foundation
import XCTest
@testable import txtnimalCore

final class ExportPackPluginTests: XCTestCase {
    private let today = "2026-07-24"

    private func loadSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let jsURL = repoRoot.appendingPathComponent("PluginFixtures/export-pack/main.js")
        return try String(contentsOf: jsURL, encoding: .utf8)
    }

    private func loadManifest() throws -> PluginManifest {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repoRoot.appendingPathComponent("PluginFixtures/export-pack/manifest.json")
        return try PluginValidator.decodeManifest(Data(contentsOf: manifestURL))
    }

    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "rent-1", title: "繳房租", due: "2026-08-01", completed: false,
                               lists: ["home"], tags: ["money"], revision: "r1"),
            PluginTaskSnapshot(id: "milk-1", title: "買牛奶, 蛋; 麵包", due: "2026-07-25", completed: false,
                               lists: ["home", "errands"], tags: [], revision: "r2"),
            PluginTaskSnapshot(id: "week-1", title: "寫週報", due: "2026-07-25", completed: false,
                               lists: ["work"], tags: ["report"], revision: "r3"),
            PluginTaskSnapshot(id: "call-1", title: "打電話", due: "2026-07-20", completed: false,
                               lists: [], tags: [], revision: "r4"),
            PluginTaskSnapshot(id: "gym-1", title: "健身", due: "2026-07-24", completed: false,
                               lists: [], tags: [], revision: "r5"),
            PluginTaskSnapshot(id: "idea-1", title: "想點子", due: nil, completed: false,
                               lists: [], tags: [], revision: "r6"),
            PluginTaskSnapshot(id: "done-1", title: "已完成的事", due: "2026-07-10", completed: true,
                               lists: [], tags: ["done"], revision: "r7"),
        ])
    }

    private func renderDocument() throws -> PluginPageDocument {
        try ReportPluginRunner().run(source: try loadSource(), reportType: "",
                                     snapshot: snapshot(), todayYMD: today)
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

    private func expectedICS() -> String {
        [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "PRODID:-//txtnimal//export-pack//EN",
            "BEGIN:VEVENT",
            "UID:rent-1@txtnimal",
            "SUMMARY:繳房租",
            "DTSTART;VALUE=DATE:20260801",
            "DTEND;VALUE=DATE:20260802",
            "STATUS:CONFIRMED",
            "CATEGORIES:home,money",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "UID:milk-1@txtnimal",
            "SUMMARY:買牛奶\\, 蛋\\; 麵包",
            "DTSTART;VALUE=DATE:20260725",
            "DTEND;VALUE=DATE:20260726",
            "STATUS:CONFIRMED",
            "CATEGORIES:home,errands",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "UID:week-1@txtnimal",
            "SUMMARY:寫週報",
            "DTSTART;VALUE=DATE:20260725",
            "DTEND;VALUE=DATE:20260726",
            "STATUS:CONFIRMED",
            "CATEGORIES:work,report",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "UID:call-1@txtnimal",
            "SUMMARY:打電話",
            "DTSTART;VALUE=DATE:20260720",
            "DTEND;VALUE=DATE:20260721",
            "STATUS:CONFIRMED",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "UID:gym-1@txtnimal",
            "SUMMARY:健身",
            "DTSTART;VALUE=DATE:20260724",
            "DTEND;VALUE=DATE:20260725",
            "STATUS:CONFIRMED",
            "END:VEVENT",
            "BEGIN:VEVENT",
            "UID:done-1@txtnimal",
            "SUMMARY:已完成的事",
            "DTSTART;VALUE=DATE:20260710",
            "DTEND;VALUE=DATE:20260711",
            "STATUS:COMPLETED",
            "CATEGORIES:done",
            "END:VEVENT",
            "END:VCALENDAR",
        ].joined(separator: "\r\n")
    }

    private func expectedCSV() -> String {
        [
            "id,title,due,completed,lists,tags",
            "rent-1,繳房租,2026-08-01,false,home,money",
            "milk-1,\"買牛奶, 蛋; 麵包\",2026-07-25,false,home;errands,",
            "week-1,寫週報,2026-07-25,false,work,report",
            "call-1,打電話,2026-07-20,false,,",
            "gym-1,健身,2026-07-24,false,,",
            "idea-1,想點子,,false,,",
            "done-1,已完成的事,2026-07-10,true,,done",
        ].joined(separator: "\r\n")
    }

    private func expectedMarkdown() -> String {
        [
            "# 任務匯出",
            "產生時間:2026-07-24 · 共 7 筆",
            "",
            "## 逾期",
            "- [ ] 打電話 (due:2026-07-20)",
            "",
            "## 今天",
            "- [ ] 健身 (due:2026-07-24)",
            "",
            "## 即將",
            "- [ ] 繳房租 (due:2026-08-01) +home @money",
            "- [ ] 買牛奶, 蛋; 麵包 (due:2026-07-25) +home +errands",
            "- [ ] 寫週報 (due:2026-07-25) +work @report",
            "",
            "## 無期限",
            "- [ ] 想點子",
            "",
            "## 已完成",
            "- [x] 已完成的事 (due:2026-07-10) @done",
        ].joined(separator: "\n")
    }

    func testSummaryStats() throws {
        let doc = try renderDocument()

        XCTAssertEqual(doc.page.pageID, "export-pack")
        XCTAssertEqual(node(in: doc, id: "export-pack-stat-total")?.value, "7")
        XCTAssertEqual(node(in: doc, id: "export-pack-stat-ics")?.value, "6")
        XCTAssertEqual(node(in: doc, id: "export-pack-stat-skipped")?.value, "1")
    }

    func testIcsContent() throws {
        let doc = try renderDocument()
        let button = try XCTUnwrap(node(in: doc, id: "export-pack-ics-file"))
        let action = try XCTUnwrap(button.action)
        let ics = try XCTUnwrap(action.content)

        XCTAssertEqual(button.title, "行事曆存檔(.ics)")
        XCTAssertEqual(action.type, .exportWrite)
        XCTAssertEqual(action.command, "export.write")
        XCTAssertEqual(action.filename, "txtnimal.ics")
        XCTAssertEqual(action.mimeType, "text/calendar")
        XCTAssertEqual(action.destination, PluginExportDestination.file)
        XCTAssertEqual(ics, expectedICS())
        XCTAssertTrue(ics.contains("BEGIN:VCALENDAR"))
        XCTAssertTrue(ics.contains("VERSION:2.0"))
        XCTAssertTrue(ics.contains("CALSCALE:GREGORIAN"))
        XCTAssertTrue(ics.contains("PRODID:-//txtnimal//export-pack//EN"))
        XCTAssertTrue(ics.contains("UID:rent-1@txtnimal"))
        XCTAssertTrue(ics.contains("SUMMARY:繳房租"))
        XCTAssertTrue(ics.contains("DTSTART;VALUE=DATE:20260801"))
        XCTAssertTrue(ics.contains("DTEND;VALUE=DATE:20260802"))
        XCTAssertTrue(ics.contains("STATUS:CONFIRMED"))
        XCTAssertTrue(ics.contains("CATEGORIES:home,money"))
        XCTAssertTrue(ics.contains("SUMMARY:買牛奶\\, 蛋\\; 麵包"))
        XCTAssertTrue(ics.contains("UID:done-1@txtnimal\r\nSUMMARY:已完成的事\r\nDTSTART;VALUE=DATE:20260710\r\nDTEND;VALUE=DATE:20260711\r\nSTATUS:COMPLETED"))
        XCTAssertFalse(ics.contains("idea-1@txtnimal"))
        XCTAssertTrue(ics.contains("\r\n"))
    }

    func testCsvContent() throws {
        let doc = try renderDocument()
        let button = try XCTUnwrap(node(in: doc, id: "export-pack-csv-file"))
        let action = try XCTUnwrap(button.action)
        let csv = try XCTUnwrap(action.content)

        XCTAssertEqual(button.title, "試算表存檔(.csv)")
        XCTAssertEqual(action.filename, "txtnimal.csv")
        XCTAssertEqual(action.mimeType, "text/csv")
        XCTAssertEqual(action.destination, PluginExportDestination.file)
        XCTAssertEqual(csv, expectedCSV())
        XCTAssertTrue(csv.hasPrefix("id,title,due,completed,lists,tags\r\n"))
        XCTAssertTrue(csv.contains("week-1,寫週報,2026-07-25,false,work,report"))
        XCTAssertTrue(csv.contains("\"買牛奶, 蛋; 麵包\""))
        XCTAssertTrue(csv.contains("home;errands"))
        XCTAssertTrue(csv.contains("idea-1,想點子,,false,,"))
        XCTAssertTrue(csv.contains("done-1,已完成的事,2026-07-10,true,,done"))
    }

    func testMarkdownContent() throws {
        let doc = try renderDocument()
        let button = try XCTUnwrap(node(in: doc, id: "export-pack-md-file"))
        let action = try XCTUnwrap(button.action)
        let md = try XCTUnwrap(action.content)

        XCTAssertEqual(button.title, "報告存檔(.md)")
        XCTAssertEqual(action.filename, "txtnimal.md")
        XCTAssertEqual(action.mimeType, "text/markdown")
        XCTAssertEqual(action.destination, PluginExportDestination.file)
        XCTAssertEqual(md, expectedMarkdown())
        XCTAssertTrue(md.contains("共 7 筆"))
        XCTAssertTrue(md.contains("產生時間:2026-07-24"))
        XCTAssertTrue(md.contains("## 逾期"))
        XCTAssertTrue(md.contains("- [ ] 打電話 (due:2026-07-20)"))
        XCTAssertTrue(md.contains("## 今天"))
        XCTAssertTrue(md.contains("- [ ] 健身"))
        XCTAssertTrue(md.contains("## 無期限"))
        XCTAssertTrue(md.contains("- [ ] 想點子"))
        XCTAssertTrue(md.contains("## 已完成"))
        XCTAssertTrue(md.contains("- [x] 已完成的事"))
        XCTAssertTrue(md.contains("+home"))
        XCTAssertTrue(md.contains("@money"))
    }

    func testDeterministicOutput() throws {
        let source = try loadSource()
        let first = try ReportPluginRunner().run(source: source, reportType: "",
                                                 snapshot: snapshot(), todayYMD: today)
        let second = try ReportPluginRunner().run(source: source, reportType: "",
                                                  snapshot: snapshot(), todayYMD: today)
        XCTAssertEqual(first, second)
    }

    func testAllSixExportButtonsPresent() throws {
        let doc = try renderDocument()
        let manifest = try loadManifest()
        let ics = expectedICS()
        let csv = expectedCSV()
        let md = expectedMarkdown()
        let expected: [(id: String, title: String, filename: String, mimeType: String,
                        destination: PluginExportDestination, content: String)] = [
            ("export-pack-ics-file", "行事曆存檔(.ics)", "txtnimal.ics", "text/calendar", .file, ics),
            ("export-pack-ics-share", "行事曆分享(.ics)", "txtnimal.ics", "text/calendar", .share, ics),
            ("export-pack-csv-file", "試算表存檔(.csv)", "txtnimal.csv", "text/csv", .file, csv),
            ("export-pack-csv-share", "試算表分享(.csv)", "txtnimal.csv", "text/csv", .share, csv),
            ("export-pack-md-file", "報告存檔(.md)", "txtnimal.md", "text/markdown", .file, md),
            ("export-pack-md-share", "報告分享(.md)", "txtnimal.md", "text/markdown", .share, md),
        ]

        XCTAssertNoThrow(try PluginValidator.validate(doc, manifest: manifest))
        XCTAssertEqual(node(in: doc, id: "export-pack-dest-note")?.title,
                       "Slack / Notion 目的地由 host 尚未實作;目前支援存檔與分享")

        for entry in expected {
            let button = try XCTUnwrap(node(in: doc, id: entry.id), "missing button \(entry.id)")
            let action: PluginAction = try XCTUnwrap(button.action, "missing action for \(entry.id)")
            let content: String = try XCTUnwrap(action.content, "missing content for \(entry.id)")
            XCTAssertEqual(button.title, entry.title)
            XCTAssertEqual(action.type, .exportWrite)
            XCTAssertEqual(action.command, "export.write")
            XCTAssertEqual(action.filename, entry.filename)
            XCTAssertEqual(action.mimeType, entry.mimeType)
            XCTAssertEqual(action.destination, entry.destination)
            XCTAssertEqual(content, entry.content)
            XCTAssertFalse(content.isEmpty)
        }
    }
}
