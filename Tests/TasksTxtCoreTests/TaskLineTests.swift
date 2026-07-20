import XCTest
@testable import TasksTxtCore

final class TaskLineTests: XCTestCase {

    // The invariant that matters most: read a file, write it back, get identical bytes.
    // Includes a blank line and a deliberate double-space before `created:`.
    let sample = """
    Finish landing page due:2026-07-04 note:"update colors and links" focus:true q:1
    Call design lead +freelance created:2026-06-15 q:2
    Daily marketing posts +marketing created:2026-05-28
    x Buy groceries +personal created:2026-06-12 done:2026-06-18

    Set up portfolio limits  created:2026-06-05
    """

    func testRoundTripByteIdentical() {
        let lines = TasksDocument.parse(sample)
        XCTAssertEqual(TasksDocument.serialize(lines), sample)
    }

    func testParseFields() {
        let t = TaskLine(#"Finish landing page due:2026-07-04 note:"update colors" focus:true q:1"#)
        XCTAssertEqual(t.title, "Finish landing page")
        XCTAssertEqual(t.due, "2026-07-04")
        XCTAssertEqual(t.quadrant, 1)
        XCTAssertTrue(t.isFocused)
        XCTAssertEqual(t.note, "update colors")
        XCTAssertFalse(t.isDone)
    }

    func testDoneParse() {
        let t = TaskLine("x Buy groceries +personal created:2026-06-12 done:2026-06-18")
        XCTAssertTrue(t.isDone)
        XCTAssertEqual(t.completedDate, "2026-06-18")
        XCTAssertEqual(t.projects, ["personal"])
    }

    func testNoteWithSpacesPreserved() {
        let t = TaskLine(#"Task note:"a b c" q:2"#)
        XCTAssertEqual(t.note, "a b c")
        XCTAssertEqual(t.quadrant, 2)
    }

    // Edits touch only the target token — everything else stays byte-identical.
    func testEditReplacesOnlyTargetToken() {
        var t = TaskLine("Call design lead +freelance created:2026-06-15 q:2")
        t.setQuadrant(1)
        XCTAssertEqual(t.raw, "Call design lead +freelance created:2026-06-15 q:1")
    }

    func testSetDueAppendsWhenAbsent() {
        var t = TaskLine("Call design lead +freelance")
        t.setDue("2026-07-15")
        XCTAssertEqual(t.raw, "Call design lead +freelance due:2026-07-15")
    }

    func testRemoveKeyPreservesRest() {
        var t = TaskLine("a due:2026-01-01 +proj q:3")
        t.removeKey("due")
        XCTAssertEqual(t.raw, "a +proj q:3")
    }

    func testRemoveFirstTokenDropsLeadingSpace() {
        var t = TaskLine("q:1 rest here")
        t.removeKey("q")
        XCTAssertEqual(t.raw, "rest here")
    }

    func testMarkDoneStampsAndClearsFocusAndQuadrant() {
        var t = TaskLine("Write report due:2026-07-01 focus:true q:1")
        t.setDone(true, date: "2026-07-09")
        XCTAssertTrue(t.raw.hasPrefix("x Write report"))
        XCTAssertTrue(t.raw.contains("done:2026-07-09"))
        XCTAssertFalse(t.isFocused)
        XCTAssertNil(t.quadrant)
        XCTAssertTrue(t.isDone)
    }

    func testUnmarkDoneRemovesXAndDoneDate() {
        var t = TaskLine("x Task created:2026-01-01 done:2026-01-02")
        t.setDone(false, date: "")
        XCTAssertEqual(t.raw, "Task created:2026-01-01")
    }

    // Single-focus invariant across the whole document.
    func testDocumentFocusIsSingleton() {
        let lines = TasksDocument.parse("a focus:true\nb\nc focus:true")
        let out = TasksDocument.setFocus(lines, onIndex: 1)
        XCTAssertEqual(out.map(\.isFocused), [false, true, false])
        XCTAssertEqual(out[1].raw, "b focus:true")
    }

    func testContextsParsedAndStrippedFromTitle() {
        let t = TaskLine("Email vendor @calls +work due:2026-07-10")
        XCTAssertEqual(t.contexts, ["calls"])
        XCTAssertEqual(t.projects, ["work"])
        XCTAssertEqual(t.title, "Email vendor")
    }

    func testSetTitleKeepsMetadata() {
        var t = TaskLine("x Call +work @calls due:2026-07-10 done:2026-07-10 lead")
        t.setTitle("Ring the bank")
        XCTAssertEqual(t.raw, "x Ring the bank +work @calls due:2026-07-10 done:2026-07-10")
        XCTAssertEqual(t.title, "Ring the bank")
    }

    func testAddTagAppendsAndDedupes() {
        var t = TaskLine("Call bank")
        t.addTag("personal")          // bare → +personal
        t.addTag("@calls")
        t.addTag("+personal")         // dupe, no-op
        XCTAssertEqual(t.raw, "Call bank +personal @calls")
    }

    // Unknown tokens survive edits untouched.
    func testUnknownTokensPreserved() {
        var t = TaskLine("Task @context pri:high weird:stuff q:4")
        t.setFocus(true)
        XCTAssertEqual(t.raw, "Task @context pri:high weird:stuff q:4 focus:true")
    }

    func testRoundTripPreservesCRLFAndMalformedNote() {
        let text = "one  odd:value\r\ntwo note:\"never closed\r\n"
        XCTAssertEqual(TasksDocument.serialize(TasksDocument.parse(text)), text)
    }

    func testDuplicateKnownKeysRemainLosslessWhenUntouched() {
        let text = "task due:2026-01-01 due:2026-02-02 q:1 q:4"
        let task = TaskLine(text)
        XCTAssertEqual(task.due, "2026-01-01")
        XCTAssertEqual(task.quadrant, 1)
        XCTAssertEqual(task.raw, text)
    }
}
