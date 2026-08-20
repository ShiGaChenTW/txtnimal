import XCTest
@testable import txtnimalCore

final class NoteCaptureTests: XCTestCase {

    func testListWrapSplitsOnSemicolonAndKeepsTags() {
        let draft = NoteCapture.parse("- milk; eggs; bread - #shop #home")
        XCTAssertEqual(draft?.kind, .list)
        XCTAssertEqual(draft?.tags, ["shop", "home"])
        XCTAssertEqual(draft?.body, "- milk\n- eggs\n- bread")
    }

    func testListWrapSplitsOnNewlinesAndDoesNotDoubleDash() {
        let draft = NoteCapture.parse("- - already dashed\nsecond -")
        XCTAssertEqual(draft?.kind, .list)
        XCTAssertEqual(draft?.body, "- already dashed\n- second")
    }

    func testQuoteWrapFromDoubleQuotes() {
        let draft = NoteCapture.parse("\"Stay hungry.\" #reading")
        XCTAssertEqual(draft?.kind, .quote)
        XCTAssertEqual(draft?.tags, ["reading"])
        XCTAssertEqual(draft?.body, "Stay hungry.")
    }

    func testQuoteWrapFromAnglePair() {
        let draft = NoteCapture.parse("> a longer quote <")
        XCTAssertEqual(draft?.kind, .quote)
        XCTAssertEqual(draft?.body, "a longer quote")
    }

    func testBlockWrap() {
        let draft = NoteCapture.parse("| func hello() {} | #code")
        XCTAssertEqual(draft?.kind, .block)
        XCTAssertEqual(draft?.tags, ["code"])
        XCTAssertEqual(draft?.body, "func hello() {}")
    }

    func testPlainTextWithoutWrapper() {
        let draft = NoteCapture.parse("just a thought #idea")
        XCTAssertEqual(draft?.kind, .plain)
        XCTAssertEqual(draft?.tags, ["idea"])
        XCTAssertEqual(draft?.body, "just a thought")
    }

    func testMarkdownPrefixListWithoutClosingWrapper() {
        let draft = NoteCapture.parse("- buy milk")
        XCTAssertEqual(draft?.kind, .list)
        XCTAssertEqual(draft?.body, "- buy milk")
    }

    func testEmptyInputAndTagOnlyAreRejected() {
        XCTAssertNil(NoteCapture.parse("   "))
        XCTAssertNil(NoteCapture.parse("#solo"))
        XCTAssertNil(NoteCapture.parse("- -"))
    }

    func testChineseListSeparatorsAndTags() {
        let draft = NoteCapture.parse("- 牛奶、雞蛋；麵包 - #購物")
        XCTAssertEqual(draft?.kind, .list)
        XCTAssertEqual(draft?.tags, ["購物"])
        XCTAssertEqual(draft?.body, "- 牛奶\n- 雞蛋\n- 麵包")
    }
}

final class NoteDocumentTests: XCTestCase {

    func testRoundTripPreservesKindTagsAndMultilineBody() {
        let notes = [
            Note(id: "n11111111", created: "2026-08-20", kind: .list, tags: ["shop"],
                 body: "- milk\n- eggs"),
            Note(id: "n22222222", created: "2026-08-20", kind: .quote, tags: ["reading", "quote"],
                 body: "Stay hungry.\nStay foolish."),
            Note(id: "n33333333", created: "2026-08-20", kind: .block, tags: [],
                 body: "func hello() {\n  print(\"hi\")\n}"),
            Note(id: "n44444444", created: "2026-08-20", kind: .plain, tags: ["idea"],
                 body: "just a thought"),
        ]
        let text = NoteDocument.serialize(notes)
        XCTAssertEqual(NoteDocument.parse(text), notes)
        XCTAssertTrue(text.contains("NOTE id:n11111111 created:2026-08-20 kind:list #shop"))
    }

    func testParseSkipsEmptyFileAndUnknownHeaderTokensSurviveByIgnoringThem() {
        XCTAssertEqual(NoteDocument.parse(""), [])
        XCTAssertEqual(NoteDocument.parse("   \n"), [])
        let parsed = NoteDocument.parse("NOTE id:nabc created:2026-08-20 kind:plain extra:keep #x\nhello\n")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].id, "nabc")
        XCTAssertEqual(parsed[0].tags, ["x"])
        XCTAssertEqual(parsed[0].body, "hello")
    }

    func testAllTagsSortedAndGroupedByTagThenUntagged() {
        let notes = [
            Note(id: "a", created: "2026-08-20", kind: .plain, tags: ["zeta", "alpha"], body: "one"),
            Note(id: "b", created: "2026-08-20", kind: .plain, tags: ["alpha"], body: "two"),
            Note(id: "c", created: "2026-08-20", kind: .plain, tags: [], body: "none"),
        ]
        XCTAssertEqual(NoteDocument.allTags(in: notes), ["alpha", "zeta"])
        let groups = NoteDocument.grouped(notes, tagFilter: nil)
        XCTAssertEqual(groups.map(\.tag), ["alpha", "zeta", ""])
        XCTAssertEqual(groups[0].notes.map(\.id), ["a", "b"])
        let filtered = NoteDocument.grouped(notes, tagFilter: "zeta")
        XCTAssertEqual(filtered.map(\.tag), ["zeta"])
        XCTAssertEqual(filtered[0].notes.map(\.id), ["a"])
    }
}
