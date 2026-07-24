import XCTest
@testable import txtnimalCore

final class RecurrenceTests: XCTestCase {

    // Fixed Gregorian/UTC calendar so all date math is deterministic regardless of the
    // runner's timezone — same approach as LogicTests.
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    // The spec's worked scenarios all use this completion date.
    let completion = "2026-07-24"

    // MARK: - RecurrenceRule.parse

    func testParseValidNonStrict() {
        XCTAssertEqual(RecurrenceRule.parse("1d"), RecurrenceRule(strict: false, count: 1, unit: .day))
        XCTAssertEqual(RecurrenceRule.parse("2w"), RecurrenceRule(strict: false, count: 2, unit: .week))
        XCTAssertEqual(RecurrenceRule.parse("3m"), RecurrenceRule(strict: false, count: 3, unit: .month))
        XCTAssertEqual(RecurrenceRule.parse("4y"), RecurrenceRule(strict: false, count: 4, unit: .year))
    }

    func testParseValidStrict() {
        XCTAssertEqual(RecurrenceRule.parse("+1d"), RecurrenceRule(strict: true, count: 1, unit: .day))
        XCTAssertEqual(RecurrenceRule.parse("+2w"), RecurrenceRule(strict: true, count: 2, unit: .week))
        XCTAssertEqual(RecurrenceRule.parse("+3m"), RecurrenceRule(strict: true, count: 3, unit: .month))
        XCTAssertEqual(RecurrenceRule.parse("+1y"), RecurrenceRule(strict: true, count: 1, unit: .year))
    }

    // Malformed forms return nil, so the token is preserved as unknown and never recurs.
    func testParseInvalidReturnsNil() {
        for bad in ["0d", "+0m", "3x", "w", "1", "1.5d", "", "+", "10", "d1", "1dd", "1 d", "-1d"] {
            XCTAssertNil(RecurrenceRule.parse(bad), "expected nil for \(bad)")
        }
    }

    // MARK: - nextDue: unit × strict/non-strict matrix

    // Non-strict recurs from the completion date, ignoring the original due entirely.
    func testNextDueNonStrictUsesCompletionDate() {
        let due: String? = "2026-07-20"
        XCTAssertEqual(next("1d", base: due), "2026-07-25")
        XCTAssertEqual(next("2w", base: due), "2026-08-07")   // completion + 14d
        XCTAssertEqual(next("3m", base: due), "2026-10-24")
        XCTAssertEqual(next("1y", base: due), "2027-07-24")
    }

    // Strict recurs from the original due, so lateness never shifts the cadence.
    func testNextDueStrictUsesOriginalDue() {
        let due: String? = "2026-07-21"
        XCTAssertEqual(next("+1w", base: due), "2026-07-28")  // original due + 7d
        XCTAssertEqual(next("+2d", base: due), "2026-07-23")
        XCTAssertEqual(next("+3m", base: due), "2026-10-21")
        XCTAssertEqual(next("+1y", base: due), "2027-07-21")
    }

    // Missing due degrades to the completion date for both strict and non-strict.
    func testNextDueMissingDueUsesCompletionDate() {
        XCTAssertEqual(next("1d", base: nil), "2026-07-25")
        XCTAssertEqual(next("+1d", base: nil), "2026-07-25")
        XCTAssertEqual(next("1w", base: nil), "2026-07-31")
        XCTAssertEqual(next("+1m", base: nil), "2026-08-24")
    }

    // MARK: - Month / year boundary clamp

    func testMonthEndClampsToLastDay() {
        // 2026-01-31 +1m has no 31st in February → clamp to 2026-02-28, not roll to March.
        XCTAssertEqual(next("+1m", base: "2026-01-31"), "2026-02-28")
    }

    func testYearBoundaryClampsLeapDay() {
        // 2028 is a leap year; +1y from Feb 29 lands on 2029-02-28 (no Feb 29 in 2029).
        XCTAssertEqual(next("+1y", base: "2028-02-29"), "2029-02-28")
    }

    func testNextDueUnparseableBaseReturnsNil() {
        XCTAssertNil(Recurrence.nextDue(base: "not-a-date", rule: RecurrenceRule(strict: true, count: 1, unit: .day),
                                        completionYMD: completion, calendar: cal))
    }

    // MARK: - recurringSuccessor: exact spec scenarios

    func testSuccessorNonStrict() {
        let line = TaskLine("倒垃圾 due:2026-07-20 rec:3d")
        XCTAssertEqual(line.recurringSuccessor(completionYMD: completion, calendar: cal)?.raw,
                       "倒垃圾 due:2026-07-27 rec:3d created:2026-07-24")
    }

    func testSuccessorStrict() {
        let line = TaskLine("週會 due:2026-07-21 rec:+1w")
        XCTAssertEqual(line.recurringSuccessor(completionYMD: completion, calendar: cal)?.raw,
                       "週會 due:2026-07-28 rec:+1w created:2026-07-24")
    }

    func testSuccessorMissingDue() {
        let line = TaskLine("喝水 rec:1d")
        XCTAssertEqual(line.recurringSuccessor(completionYMD: completion, calendar: cal)?.raw,
                       "喝水 due:2026-07-25 rec:1d created:2026-07-24")
    }

    func testSuccessorCarriesMetadata() {
        let line = TaskLine("健身 +health @gym q:2 rec:2d")
        let successor = line.recurringSuccessor(completionYMD: completion, calendar: cal)
        XCTAssertEqual(successor?.raw, "健身 +health @gym due:2026-07-26 q:2 rec:2d created:2026-07-24")
        XCTAssertEqual(successor?.title, "健身")
        XCTAssertEqual(successor?.projects, ["health"])
        XCTAssertEqual(successor?.contexts, ["gym"])
        XCTAssertEqual(successor?.quadrant, 2)
        XCTAssertFalse(successor?.isDone ?? true)
    }

    func testSuccessorMonthEndClamp() {
        let line = TaskLine("繳費 due:2026-01-31 rec:+1m")
        XCTAssertEqual(line.recurringSuccessor(completionYMD: completion, calendar: cal)?.raw,
                       "繳費 due:2026-02-28 rec:+1m created:2026-07-24")
    }

    // The successor is a brand-new open task: focus:/done:/id: (known control tokens) are
    // dropped and created:/due: are stamped fresh. Non-metadata words the app treats as part of
    // the title — including unknown key:value tokens like a todo.txt priority — ride along in the
    // title, exactly as they do on the original line, so nothing the user typed is silently lost.
    func testSuccessorDropsFocusAndIdButKeepsTitleWords() {
        let line = TaskLine("巡檢 due:2026-07-20 rec:1d focus:true id:abc123 pri:high")
        let successor = line.recurringSuccessor(completionYMD: completion, calendar: cal)
        XCTAssertEqual(successor?.raw, "巡檢 pri:high due:2026-07-25 rec:1d created:2026-07-24")
        XCTAssertFalse(successor?.isFocused ?? true)
        XCTAssertNil(successor?.stableID)
        XCTAssertFalse(successor?.isDone ?? true)
    }

    func testInvalidRecProducesNoSuccessor() {
        XCTAssertNil(TaskLine("報告 due:2026-07-20 rec:3x").recurringSuccessor(completionYMD: completion, calendar: cal))
        XCTAssertNil(TaskLine("報告 due:2026-07-20 rec:0d").recurringSuccessor(completionYMD: completion, calendar: cal))
    }

    func testNoRecProducesNoSuccessor() {
        XCTAssertNil(TaskLine("普通任務 due:2026-07-20").recurringSuccessor(completionYMD: completion, calendar: cal))
    }

    // MARK: - Completion transition through TaskWorkspace (atomic + idempotent)

    private func snapshot(_ text: String, generation: UInt64 = 0) -> TaskDocumentSnapshot {
        TaskDocumentSnapshot(lines: TasksDocument.parse(text), generation: generation)
    }

    // Completing an open rec: task appends exactly one open successor in the same result array,
    // and the original is stamped done — one atomic save writes both.
    func testToggleDoneGeneratesOneSuccessor() throws {
        let snap = snapshot("倒垃圾 due:2026-07-20 rec:3d")
        let out = try TaskWorkspace.apply(.toggleDone(TaskHandle(generation: 0, index: 0)),
                                          to: snap, todayYMD: completion, calendar: cal)
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].isDone)
        XCTAssertTrue(out[0].raw.contains("done:2026-07-24"))
        XCTAssertFalse(out[1].isDone)
        XCTAssertEqual(out[1].raw, "倒垃圾 due:2026-07-27 rec:3d created:2026-07-24")
    }

    func testToggleDoneNoRecAppendsNothing() throws {
        let snap = snapshot("普通任務 due:2026-07-20")
        let out = try TaskWorkspace.apply(.toggleDone(TaskHandle(generation: 0, index: 0)),
                                          to: snap, todayYMD: completion, calendar: cal)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].isDone)
    }

    func testToggleDoneInvalidRecAppendsNothing() throws {
        let snap = snapshot("報告 due:2026-07-20 rec:3x")
        let out = try TaskWorkspace.apply(.toggleDone(TaskHandle(generation: 0, index: 0)),
                                          to: snap, todayYMD: completion, calendar: cal)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].isDone)
    }

    // Idempotency + no-reclaim: un-completing a done rec: task neither generates nor removes.
    func testUncompleteDoesNotReclaimOrGenerate() throws {
        let snap = snapshot("x 倒垃圾 due:2026-07-20 rec:3d done:2026-07-24 created:2026-07-01")
        let out = try TaskWorkspace.apply(.toggleDone(TaskHandle(generation: 0, index: 0)),
                                          to: snap, todayYMD: completion, calendar: cal)
        XCTAssertEqual(out.count, 1)
        XCTAssertFalse(out[0].isDone)
    }

    // Re-saving an already-completed rec: task never re-runs the transition (only .toggleDone
    // generates, and a plain re-save does not toggle) — proven here by toggling a done task and
    // confirming no successor is produced.
    func testResaveOfDoneTaskDoesNotRegenerate() throws {
        var snap = snapshot("倒垃圾 due:2026-07-20 rec:3d")
        // First completion generates the successor.
        let afterComplete = try TaskWorkspace.apply(.toggleDone(TaskHandle(generation: 0, index: 0)),
                                                    to: snap, todayYMD: completion, calendar: cal)
        XCTAssertEqual(afterComplete.count, 2)
        // A subsequent unrelated edit (setDue on the new open successor) must not spawn more tasks.
        snap = TaskDocumentSnapshot(lines: afterComplete, generation: 0)
        let afterEdit = try TaskWorkspace.apply(.setDue(TaskHandle(generation: 0, index: 1), "2026-07-30"),
                                                to: snap, todayYMD: completion, calendar: cal)
        XCTAssertEqual(afterEdit.count, 2)
    }

    // MARK: - helper

    private func next(_ token: String, base: String?) -> String? {
        guard let rule = RecurrenceRule.parse(token) else { return nil }
        return Recurrence.nextDue(base: base, rule: rule, completionYMD: completion, calendar: cal)
    }
}
