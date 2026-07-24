import Foundation
import XCTest
@testable import txtnimalCore

final class ImportMappingTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 24))!
    }

    func testTodoTxtLineKeepsISODue() {
        let item = ImportedItem(title: "交報告", due: "2026-08-05", sourceId: "r1")

        let raw = ImportMapper.todoTxtLine(for: item, today: today, calendar: calendar)

        XCTAssertEqual(raw, "交報告 due:2026-08-05")
    }

    func testTodoTxtLineNormalizesShorthandDue() {
        let item = ImportedItem(title: "繳帳單", due: "3d", sourceId: "r2")

        let raw = ImportMapper.todoTxtLine(for: item, today: today, calendar: calendar)

        XCTAssertEqual(raw, "繳帳單 due:2026-07-27")
    }

    func testTodoTxtLineMapsListToProjectSlugPreservingCJK() {
        let item = ImportedItem(title: "回覆客戶", list: "  +工作 清單  ", sourceId: "r3")

        let raw = ImportMapper.todoTxtLine(for: item, today: today, calendar: calendar)

        XCTAssertEqual(raw, "回覆客戶 +工作_清單")
    }

    func testTodoTxtLineMapsEachTagToContextSlug() {
        let item = ImportedItem(title: "準備簡報", tags: [" urgent ", "@客戶 會議", "   "], sourceId: "r4")

        let raw = ImportMapper.todoTxtLine(for: item, today: today, calendar: calendar)

        XCTAssertEqual(raw, "準備簡報 @urgent @客戶_會議")
    }

    func testTodoTxtLineMapsNotesToQuotedNoteToken() {
        let item = ImportedItem(title: "買咖啡豆", notes: "  先問烘豆日期  ", sourceId: "r5")

        let raw = ImportMapper.todoTxtLine(for: item, today: today, calendar: calendar)

        XCTAssertEqual(raw, "買咖啡豆 note:\"先問烘豆日期\"")
    }

    func testTodoTxtLineSanitizesInjectedTitleTokens() {
        let item = ImportedItem(title: "x +proj @ctx Review due:2026-08-01 created:2026-01-01 安全標題",
                                sourceId: "r6")

        let raw = ImportMapper.todoTxtLine(for: item, today: today, calendar: calendar)

        XCTAssertEqual(raw, "Review 安全標題")
    }

    func testSlugStripsPrefixesAndCollapsesSeparators() {
        XCTAssertEqual(ImportMapper.slug("  +客戶  跟進  "), "客戶_跟進")
        XCTAssertEqual(ImportMapper.slug("@ops---review"), "ops_review")
        XCTAssertEqual(ImportMapper.slug("  ---  "), "")
    }

    func testCompletedItemsSkippedByDefault() async throws {
        let source = FakeRemindersSource(items: [
            ImportedItem(title: "保留", sourceId: "r1"),
            ImportedItem(title: "略過", completed: true, sourceId: "r2"),
        ])

        let proposals = try await RemindersImporter().plan(from: source, today: today, calendar: calendar)

        XCTAssertEqual(proposals, [
            ImportProposal(sourceId: "r1", rawLine: "保留", title: "保留", due: nil),
        ])
    }

    func testCompletedItemsIncludedWhenOptionEnabled() async throws {
        let source = FakeRemindersSource(items: [
            ImportedItem(title: "保留", sourceId: "r1"),
            ImportedItem(title: "完成項目", completed: true, sourceId: "r2"),
        ])

        let proposals = try await RemindersImporter().plan(from: source, today: today,
                                                           options: .init(includeCompleted: true),
                                                           calendar: calendar)

        XCTAssertEqual(proposals, [
            ImportProposal(sourceId: "r1", rawLine: "保留", title: "保留", due: nil),
            ImportProposal(sourceId: "r2", rawLine: "完成項目", title: "完成項目", due: nil),
        ])
    }

    func testImporterPlanReturnsReviewedCreateProposalsAndDoesNotWriteTasksFile() async throws {
        let source = FakeRemindersSource(items: [
            ImportedItem(title: "第一筆", due: "fri", list: "工作 清單", tags: ["重要"], notes: "先整理附件", sourceId: "r1"),
            ImportedItem(title: "x +proj", sourceId: "r-empty"),
            ImportedItem(title: "第二筆", due: "2026-08-01", sourceId: "r2"),
        ])
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "原始內容\n".write(to: tempURL, atomically: true, encoding: .utf8)

        let proposals = try await RemindersImporter().plan(from: source, today: today, calendar: calendar)
        let unchanged = try String(contentsOf: tempURL, encoding: .utf8)

        XCTAssertEqual(proposals, [
            ImportProposal(sourceId: "r1",
                           rawLine: "第一筆 due:2026-07-24 +工作_清單 @重要 note:\"先整理附件\"",
                           title: "第一筆",
                           due: "2026-07-24"),
            ImportProposal(sourceId: "r2",
                           rawLine: "第二筆 due:2026-08-01",
                           title: "第二筆",
                           due: "2026-08-01"),
        ])
        XCTAssertEqual(unchanged, "原始內容\n")
    }

    func testValidateImportSourcePassesWithCapability() throws {
        let manifest = PluginManifest(id: "app.txtnimal.importer", name: "Importer", version: "1.0.0",
                                      apiVersion: 1, entry: "main.js", capabilities: [.importRead])

        let validated = try PluginValidator.validate(importSource: " apple-reminders ", manifest: manifest)

        XCTAssertEqual(validated, ValidatedImportRequest(pluginID: "app.txtnimal.importer",
                                                         source: "apple-reminders"))
    }

    func testValidateImportSourceRejectsMissingCapability() {
        let manifest = PluginManifest(id: "app.txtnimal.importer", name: "Importer", version: "1.0.0",
                                      apiVersion: 1, entry: "main.js", capabilities: [.uiPage])

        XCTAssertThrowsError(try PluginValidator.validate(importSource: "apple-reminders", manifest: manifest)) {
            XCTAssertEqual($0 as? PluginValidationError, .missingCapability)
        }
    }

    func testValidateImportSourceRejectsUnknownSource() {
        let manifest = PluginManifest(id: "app.txtnimal.importer", name: "Importer", version: "1.0.0",
                                      apiVersion: 1, entry: "main.js", capabilities: [.importRead])

        XCTAssertThrowsError(try PluginValidator.validate(importSource: "todoist", manifest: manifest)) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }
    }
}

private struct FakeRemindersSource: RemindersSource {
    let items: [ImportedItem]

    func fetch() async throws -> [ImportedItem] {
        items
    }
}
