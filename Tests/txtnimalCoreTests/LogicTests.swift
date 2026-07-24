import XCTest
@testable import txtnimalCore

final class LogicTests: XCTestCase {

    // Fixed calendar + date so everything is deterministic regardless of the runner's tz.
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    lazy var today: Date = cal.date(from: DateComponents(year: 2026, month: 7, day: 9))!

    // MARK: - DueDateParser

    func testISOPassThroughAndReject() {
        XCTAssertEqual(DueDateParser.parse("2026-08-01", today: today, calendar: cal), "2026-08-01")
        XCTAssertNil(DueDateParser.parse("2026-13-40", today: today, calendar: cal))
        XCTAssertNil(DueDateParser.parse("2026-02-30", today: today, calendar: cal))
    }

    func testTodayTomorrowOffsets() {
        XCTAssertEqual(DueDateParser.parse("today", today: today, calendar: cal), "2026-07-09")
        XCTAssertEqual(DueDateParser.parse("tomorrow", today: today, calendar: cal), "2026-07-10")
        XCTAssertEqual(DueDateParser.parse("3d", today: today, calendar: cal), "2026-07-12")
        XCTAssertEqual(DueDateParser.parse("2w", today: today, calendar: cal), "2026-07-23")
        XCTAssertEqual(DueDateParser.parse("0d", today: today, calendar: cal), "2026-07-09")
    }

    func testGibberishIsNil() {
        XCTAssertNil(DueDateParser.parse("someday", today: today, calendar: cal))
        XCTAssertNil(DueDateParser.parse("", today: today, calendar: cal))
    }

    // Property test: weekday result has the right weekday, is today-or-later, within a week.
    func testWeekdayProperties() {
        let cases: [(String, Int)] = [("fri", 6), ("sun", 1), ("wed", 4)]
        for (name, wd) in cases {
            let out = DueDateParser.parse(name, today: today, calendar: cal)!
            let date = cal.date(from: dc(out))!
            XCTAssertEqual(cal.component(.weekday, from: date), wd, "\(name)")
            let start = cal.startOfDay(for: today)
            let days = cal.dateComponents([.day], from: start, to: date).day!
            XCTAssertTrue((0...6).contains(days), "\(name) delta \(days)")
        }
    }

    private func dc(_ ymd: String) -> DateComponents {
        let p = ymd.split(separator: "-").map { Int($0)! }
        return DateComponents(year: p[0], month: p[1], day: p[2])
    }

    // MARK: - ListGrouping

    func testGroupingByDue() {
        let lines = TasksDocument.parse("""
        A due:2026-07-09
        B due:2026-07-20
        C due:2026-07-15
        D no date here
        E due:2026-07-01

        x F created:2026-07-01 done:2026-07-08
        """)
        let g = ListGrouping.group(lines, todayYMD: "2026-07-09")
        XCTAssertEqual(g.today, [0])              // A
        XCTAssertEqual(g.upcoming, [2, 1])        // C(07-15) before B(07-20), sorted by due
        XCTAssertEqual(g.overdue, [4])            // E(07-01)
        XCTAssertEqual(g.noDate, [3])             // D
        XCTAssertEqual(g.done, [6])               // F ; blank line (index 5) skipped
    }

    // MARK: - QuadrantBucketing

    func testQuadrantBoard() {
        let lines = TasksDocument.parse("""
        A q:1
        B q:3
        C
        D q:1
        x E done:2026-07-01 q:2
        """)
        let b = QuadrantBucketing.board(lines)
        XCTAssertEqual(b.q1, [0, 3])
        XCTAssertEqual(b.q2, [])
        XCTAssertEqual(b.q3, [1])
        XCTAssertEqual(b.unplaced, [2])   // C ; done E excluded even though it has q:2
    }

    // MARK: - Capture

    func testCaptureNormalizesDueAndStampsCreated() {
        let out = Capture.makeTaskLine(
            from: "Call bank due:tomorrow +personal",
            today: today, createdYMD: "2026-07-09", calendar: cal)
        XCTAssertEqual(out, "Call bank due:2026-07-10 +personal created:2026-07-09")
    }

    // Quick capture accepts a rec: token and writes it through verbatim while still
    // normalizing due: and stamping created:.
    func testCaptureAcceptsRecToken() {
        XCTAssertEqual(
            Capture.makeTaskLine(from: "澆花 due:fri rec:1w", today: today, createdYMD: "2026-07-09", calendar: cal),
            "澆花 due:2026-07-10 rec:1w created:2026-07-09")
    }

    func testCaptureKeepsUnparseableDueAndPlainLine() {
        XCTAssertEqual(
            Capture.makeTaskLine(from: "Just a task", today: today, createdYMD: "2026-07-09", calendar: cal),
            "Just a task created:2026-07-09")
        XCTAssertEqual(
            Capture.makeTaskLine(from: "Do it due:someday", today: today, createdYMD: "2026-07-09", calendar: cal),
            "Do it due:someday created:2026-07-09")
        XCTAssertNil(Capture.makeTaskLine(from: "   ", today: today, createdYMD: "2026-07-09", calendar: cal))
    }

    func testCaptureAssistExtractsOnlyRecognizedTokens() {
        let tokens = CaptureAssist.tokens(
            from: "寄報價單 due:fri +business @mac due:someday +",
            today: today,
            calendar: cal
        )

        XCTAssertEqual(tokens, [
            CaptureAssist.Token(kind: .due, raw: "due:fri", displayValue: "2026-07-10"),
            CaptureAssist.Token(kind: .project, raw: "+business", displayValue: "business"),
            CaptureAssist.Token(kind: .context, raw: "@mac", displayValue: "mac"),
        ])
    }

    func testCaptureAssistSuggestsOnlyHighConfidenceChineseDates() {
        XCTAssertEqual(
            CaptureAssist.dueSuggestion(from: "明天下午打電話給銀行"),
            CaptureAssist.DueSuggestion(matchedText: "明天", dueValue: "tomorrow", label: "明天")
        )
        XCTAssertEqual(
            CaptureAssist.dueSuggestion(from: "後天寄出發票"),
            CaptureAssist.DueSuggestion(matchedText: "後天", dueValue: "2d", label: "後天")
        )
        XCTAssertEqual(
            CaptureAssist.dueSuggestion(from: "星期五寄報價單"),
            CaptureAssist.DueSuggestion(matchedText: "星期五", dueValue: "fri", label: "星期五")
        )
        XCTAssertNil(CaptureAssist.dueSuggestion(from: "下週處理這件事"))
        XCTAssertNil(CaptureAssist.dueSuggestion(from: "明天處理 due:fri"))
    }

    func testCaptureAssistAppliesAndRemovesSuggestionsAndTokens() {
        let suggestion = CaptureAssist.DueSuggestion(matchedText: "明天", dueValue: "tomorrow", label: "明天")
        XCTAssertEqual(
            CaptureAssist.applying(suggestion, to: "明天下午 打電話給銀行"),
            "下午 打電話給銀行 due:tomorrow"
        )
        XCTAssertEqual(
            CaptureAssist.removingToken("+business", from: "寄報價單 +business @mac"),
            "寄報價單 @mac"
        )
    }

    func testCaptureAssistFindsCompletionAtCursor() {
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "寄報價單 +bus", cursorUTF16Offset: 9),
            CaptureAssist.CompletionQuery(kind: .project, fragment: "bus", tokenRange: NSRange(location: 5, length: 4))
        )
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "call @ma later", cursorUTF16Offset: 8),
            CaptureAssist.CompletionQuery(kind: .context, fragment: "ma", tokenRange: NSRange(location: 5, length: 3))
        )
        XCTAssertEqual(
            CaptureAssist.completionQuery(from: "安排 due:tom", cursorUTF16Offset: 10),
            CaptureAssist.CompletionQuery(kind: .due, fragment: "tom", tokenRange: NSRange(location: 3, length: 7))
        )
        XCTAssertNil(CaptureAssist.completionQuery(from: "email+a", cursorUTF16Offset: 7))
    }

    func testCaptureAssistAppliesCompletionWithoutDroppingSuffix() {
        let query = CaptureAssist.CompletionQuery(
            kind: .context,
            fragment: "ma",
            tokenRange: NSRange(location: 5, length: 3)
        )
        XCTAssertEqual(
            CaptureAssist.applyingCompletion("mac", query: query, to: "call @ma later"),
            CaptureAssist.CompletionResult(text: "call @mac later", cursorUTF16Offset: 9)
        )
    }
}
