import XCTest
import JavaScriptCore
@testable import txtnimalCore

final class HabitTrackerPluginTests: XCTestCase {
    private let today = "2026-07-24"

    private func loadSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let jsURL = repoRoot.appendingPathComponent("PluginFixtures/habit-tracker/main.js")
        return try String(contentsOf: jsURL, encoding: .utf8)
    }

    private func snapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "Dummy", due: nil, completed: false, lists: [], tags: [],
                               revision: "r1"),
        ])
    }

    private func run(kv: [String: String]) throws -> PluginPageDocument {
        try ReportPluginRunner().run(source: try loadSource(), reportType: "habit-tracker",
                                     snapshot: snapshot(), todayYMD: today, metadata: [:], kv: kv)
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

    private func decodeDates(_ value: String) throws -> [String] {
        try JSONDecoder().decode([String].self, from: Data(value.utf8))
    }

    private func manifest() -> PluginManifest {
        PluginManifest(id: "app.txtnimal.habit-tracker", name: "Habit Tracker", version: "0.1.0",
                       apiVersion: 1, entry: "main.js", capabilities: [.storageKV, .uiPage],
                       pages: [PluginPageDeclaration(id: "habit-tracker", title: "Habit Tracker", entryFunction: "run")])
    }

    func testCurrentStreakIncludingToday() throws {
        let doc = try run(kv: ["checkins:water": "[\"2026-07-22\",\"2026-07-23\",\"2026-07-24\"]"])
        XCTAssertEqual(node(in: doc, id: "habit-water-current")?.value, "3")
    }

    func testTodayNotCheckedDoesNotReset() throws {
        let doc = try run(kv: ["checkins:water": "[\"2026-07-22\",\"2026-07-23\"]"])
        XCTAssertEqual(node(in: doc, id: "habit-water-current")?.value, "2")
    }

    func testLongestStreak() throws {
        let doc = try run(kv: ["checkins:water": "[\"2026-07-01\",\"2026-07-02\",\"2026-07-03\",\"2026-07-04\",\"2026-07-05\",\"2026-07-20\",\"2026-07-21\"]"])
        XCTAssertEqual(node(in: doc, id: "habit-water-longest")?.value, "5")
    }

    func testCheckInButtonAppendsToday() throws {
        let doc = try run(kv: ["checkins:water": "[\"2026-07-22\",\"2026-07-23\"]"])
        let button = try XCTUnwrap(node(in: doc, id: "habit-water-button"))
        XCTAssertEqual(button.title, "打卡")
        XCTAssertEqual(button.action?.type, .kvSet)
        XCTAssertEqual(button.action?.command, PluginAction.kvSetCommand)
        XCTAssertEqual(button.action?.key, "checkins:water")
        let value = try XCTUnwrap(button.action?.value)
        let dates = try decodeDates(value)
        XCTAssertTrue(dates.contains("2026-07-24"))
    }

    func testUncheckButtonRemovesToday() throws {
        let doc = try run(kv: ["checkins:water": "[\"2026-07-22\",\"2026-07-23\",\"2026-07-24\"]"])
        let button = try XCTUnwrap(node(in: doc, id: "habit-water-button"))
        XCTAssertEqual(button.title, "取消今日打卡")
        let value = try XCTUnwrap(button.action?.value)
        let dates = try decodeDates(value)
        XCTAssertFalse(dates.contains("2026-07-24"))
    }

    func testDeterministicRender() throws {
        let kv = ["checkins:water": "[\"2026-07-22\",\"2026-07-23\"]"]
        let first = try run(kv: kv)
        let second = try run(kv: kv)
        XCTAssertEqual(first, second)
    }

    func testEmptyStateWhenKVAbsent() throws {
        let source = try loadSource()
        guard let context = JSContext() else {
            XCTFail("JSContext unavailable")
            return
        }

        var scriptException: String?
        context.exceptionHandler = { _, value in
            scriptException = value?.toString() ?? "unknown JavaScript exception"
        }
        context.evaluateScript(source)
        XCTAssertNil(scriptException)
        let inputJSON = "{\"todayYMD\":\"2026-07-24\"}"
        context.setObject(inputJSON, forKeyedSubscript: "__habitInput" as NSString)
        guard let result = context.evaluateScript("run(JSON.parse(__habitInput))") else {
            XCTFail("run returned nothing")
            return
        }
        XCTAssertNil(scriptException)
        guard let object = result.toObject(), JSONSerialization.isValidJSONObject(object) else {
            XCTFail("result was not a JSON object")
            return
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let doc = try JSONDecoder().decode(PluginPageDocument.self, from: data)
        let emptyState = try XCTUnwrap(node(in: doc, id: "habit-kv-empty"))
        XCTAssertEqual(emptyState.type, .emptyState)
        XCTAssertTrue(emptyState.title?.contains("storage.kv") == true)
    }

    func testReadyButEmptyRendersZeroStreak() throws {
        let doc = try run(kv: [:])
        XCTAssertEqual(node(in: doc, id: "habit-water-current")?.value, "0")
        XCTAssertEqual(node(in: doc, id: "habit-water-button")?.title, "打卡")
    }

    func testMalformedKVFallsBackToEmptyArray() throws {
        let doc = try run(kv: ["checkins:water": "{oops"])
        XCTAssertEqual(node(in: doc, id: "habit-water-current")?.value, "0")
        XCTAssertEqual(node(in: doc, id: "habit-water-button")?.title, "打卡")
    }

    func testNonArrayKVFallsBackToEmptyArray() throws {
        let doc = try run(kv: ["checkins:water": "\"2026-07-24\""])
        XCTAssertEqual(node(in: doc, id: "habit-water-current")?.value, "0")
        XCTAssertEqual(node(in: doc, id: "habit-water-button")?.title, "打卡")
    }

    func testRenderedPageValidatesAgainstManifest() throws {
        let doc = try run(kv: ["checkins:water": "[\"2026-07-22\",\"2026-07-23\",\"2026-07-24\"]"])
        XCTAssertNoThrow(try PluginValidator.validate(doc, manifest: manifest()))
    }
}
