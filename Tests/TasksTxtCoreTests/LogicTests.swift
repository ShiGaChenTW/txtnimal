import XCTest
@testable import TasksTxtCore

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

    func testCaptureKeepsUnparseableDueAndPlainLine() {
        XCTAssertEqual(
            Capture.makeTaskLine(from: "Just a task", today: today, createdYMD: "2026-07-09", calendar: cal),
            "Just a task created:2026-07-09")
        XCTAssertEqual(
            Capture.makeTaskLine(from: "Do it due:someday", today: today, createdYMD: "2026-07-09", calendar: cal),
            "Do it due:someday created:2026-07-09")
        XCTAssertNil(Capture.makeTaskLine(from: "   ", today: today, createdYMD: "2026-07-09", calendar: cal))
    }
}
