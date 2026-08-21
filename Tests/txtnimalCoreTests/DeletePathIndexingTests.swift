import XCTest
@testable import txtnimalCore

/// 刪除路徑上的兩段索引換算,原本埋在 `TaskStore` 裡沒有測試。
///
/// 這兩段的共同點是「算錯不會當掉,只會安靜地作用在錯的那一筆」：
/// `Trash.fileIndex` 算錯 → 永久刪掉的是**別人**;
/// `CursorPlacement.afterRemoving` 算錯 → 游標跳到別的地方,下一顆 `d` 就刪錯人。
final class DeletePathIndexingTests: XCTestCase {

    // MARK: - 垃圾桶：看得見的第 N 列 → 檔案裡的第幾行

    func testVisibleIndexEqualsFileIndexWhenThereAreNoBlankLines() {
        let lines = [TaskLine("a"), TaskLine("b"), TaskLine("c")]
        XCTAssertEqual(Trash.fileIndex(forVisible: 0, in: lines), 0)
        XCTAssertEqual(Trash.fileIndex(forVisible: 2, in: lines), 2)
    }

    func testLeadingBlankLinesShiftEveryVisibleRow() {
        let lines = [TaskLine(""), TaskLine("a"), TaskLine("b")]
        XCTAssertEqual(Trash.fileIndex(forVisible: 0, in: lines), 1)
        XCTAssertEqual(Trash.fileIndex(forVisible: 1, in: lines), 2)
    }

    func testInterleavedBlankLinesAreSkipped() {
        let lines = [TaskLine("a"), TaskLine(""), TaskLine("b"), TaskLine(""), TaskLine("c")]
        XCTAssertEqual(Trash.fileIndex(forVisible: 0, in: lines), 0)
        XCTAssertEqual(Trash.fileIndex(forVisible: 1, in: lines), 2)
        XCTAssertEqual(Trash.fileIndex(forVisible: 2, in: lines), 4)
    }

    /// 越界一律 nil,呼叫端才 `guard let` 得掉。回 0 或 clamp 都會刪錯人。
    func testOutOfRangeVisibleIndexIsNil() {
        let lines = [TaskLine("a"), TaskLine("")]
        XCTAssertNil(Trash.fileIndex(forVisible: 1, in: lines))
        XCTAssertNil(Trash.fileIndex(forVisible: 99, in: lines))
        XCTAssertNil(Trash.fileIndex(forVisible: -1, in: lines))
    }

    func testEmptyAndAllBlankInputsAreNil() {
        XCTAssertNil(Trash.fileIndex(forVisible: 0, in: []))
        XCTAssertNil(Trash.fileIndex(forVisible: 0, in: [TaskLine(""), TaskLine("")]))
    }

    /// `trashTasks`(UI 那份)與這個換算必須看同一份非空行,否則第 N 列對不上第 N 筆。
    func testAgreesWithTheVisibleListItProjects() {
        let lines = [TaskLine(""), TaskLine("a"), TaskLine(""), TaskLine("b")]
        let visible = lines.filter { !$0.isBlank }
        for i in visible.indices {
            let fileIndex = Trash.fileIndex(forVisible: i, in: lines)
            XCTAssertNotNil(fileIndex, "\(i)")
            XCTAssertEqual(lines[fileIndex!].raw, visible[i].raw, "\(i)")
        }
    }

    // MARK: - 刪除後游標落點

    /// 刪掉中間那筆:游標留在原來的**位置**,也就是接住下面那一筆。
    func testCursorStaysAtTheSamePositionAndCatchesTheRowBelow() {
        XCTAssertEqual(CursorPlacement.afterRemoving(1, from: [0, 1, 2]), 1)
    }

    /// 刪掉最後一筆:沒有下面那一筆可以接,往上退一格。
    func testRemovingTheLastRowMovesTheCursorUp() {
        XCTAssertEqual(CursorPlacement.afterRemoving(2, from: [0, 1, 2]), 1)
    }

    func testRemovingTheOnlyRowLeavesNoCursor() {
        XCTAssertNil(CursorPlacement.afterRemoving(0, from: [0]))
        XCTAssertNil(CursorPlacement.afterRemoving(0, from: []))
    }

    /// 象限頁的走訪順序不是 0,1,2… —— 落點要照**顯示順序**算,不是照檔案索引算。
    func testNonSequentialOrderIsHonoured() {
        // 檔案索引 0 顯示在第 2 位;移除後留在第 2 位,也就是原本的檔案索引 1(位移後為 0)。
        XCTAssertEqual(CursorPlacement.afterRemoving(0, from: [2, 0, 1]), 0)
        // 檔案索引 2 顯示在第 1 位;移除後留在第 1 位,也就是檔案索引 0。
        XCTAssertEqual(CursorPlacement.afterRemoving(2, from: [2, 0, 1]), 0)
    }

    /// 移除之後,比它大的檔案索引全部往前挪一格 —— 漏掉這步游標就指到隔壁那筆。
    func testIndicesAboveTheRemovedRowShiftDownByOne() {
        XCTAssertEqual(CursorPlacement.afterRemoving(0, from: [0, 5]), 4)
    }

    /// 刪的那筆本來就不在目前的顯示順序裡(被篩選蓋掉):落在第一筆,不回 nil。
    func testRemovingSomethingOutsideTheVisibleOrderFallsBackToTheFirstRow() {
        XCTAssertEqual(CursorPlacement.afterRemoving(9, from: [3, 4]), 3)
    }
}
