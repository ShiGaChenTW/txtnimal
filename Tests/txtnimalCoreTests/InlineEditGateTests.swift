import XCTest
@testable import txtnimalCore

/// `TaskStore.startEditing()` 的判定半邊。這道守門曾經寫死只認清單頁，
/// 於是 `e` / ⏎ 在象限頁靜靜地沒反應（catalog 明明宣告 `.listGridSelection`，
/// 指令盤也照列）。判定搬進核心之後，那個回歸有測試擋著。
final class InlineEditGateTests: XCTestCase {

    private let open = [TaskLine("買牛奶"), TaskLine("寫報告")]
    private let done = [TaskLine("x 買牛奶")]

    // MARK: - 象限頁（這一條就是回歸圍籬）

    func testQuadrantPageStartsInlineEditJustLikeTheListPage() {
        XCTAssertEqual(InlineEditGate.route(page: .grid, cursor: 1, lines: open), .task(index: 1))
    }

    func testListPageStartsInlineEdit() {
        XCTAssertEqual(InlineEditGate.route(page: .list, cursor: 0, lines: open), .task(index: 0))
    }

    /// catalog 對 `.inlineEdit` 宣告的可用頁面，必須跟這道守門放行的頁面一致。
    /// 任何一邊改了而另一邊沒跟上，就是象限頁那次事故的重演。
    func testGateAgreesWithTheCatalogAvailabilityForInlineEdit() {
        let pages = CommandCatalog.builtIn(.inlineEdit).availability.pages
        XCTAssertEqual(pages, [.list, .grid])
        for page in CommandPalettePage.allCases where page != .notes {
            let routed = InlineEditGate.route(page: page, cursor: 0, lines: open) != .none
            XCTAssertEqual(routed, pages?.contains(page) ?? true, "\(page)")
        }
    }

    // MARK: - 筆記頁走另一條路

    func testNotesPageRoutesToTheNoteEditorRegardlessOfTaskCursor() {
        XCTAssertEqual(InlineEditGate.route(page: .notes, cursor: nil, lines: []), .note)
        XCTAssertEqual(InlineEditGate.route(page: .notes, cursor: 0, lines: open), .note)
    }

    // MARK: - 唯讀頁不得作用在看不見的游標上

    func testReadOnlyPagesDoNothing() {
        for page: CommandPalettePage in [.dash, .settings, .trash, .agent] {
            XCTAssertEqual(InlineEditGate.route(page: page, cursor: 0, lines: open), .none, "\(page)")
        }
    }

    // MARK: - 游標守門

    func testNoCursorDoesNothing() {
        XCTAssertEqual(InlineEditGate.route(page: .list, cursor: nil, lines: open), .none)
    }

    func testOutOfRangeCursorDoesNothing() {
        XCTAssertEqual(InlineEditGate.route(page: .grid, cursor: 9, lines: open), .none)
        XCTAssertEqual(InlineEditGate.route(page: .list, cursor: -1, lines: open), .none)
    }

    func testCompletedTaskIsNotInlineEditable() {
        XCTAssertEqual(InlineEditGate.route(page: .list, cursor: 0, lines: done), .none)
        XCTAssertEqual(InlineEditGate.route(page: .grid, cursor: 0, lines: done), .none)
    }

    func testEmptyListDoesNothing() {
        XCTAssertEqual(InlineEditGate.route(page: .list, cursor: 0, lines: []), .none)
    }
}
