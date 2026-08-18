import XCTest
@testable import txtnimalCore

/// 左側 List 導覽欄的 done/total 計數。純資料函式,與 SwiftUI 版面無關 —— 版面本身
/// 靠 UAT 人眼驗收,但「數字算得對不對」不該只靠看。
final class ListTallyTests: XCTestCase {
    private func tally(_ text: String, lists: [String]) -> ListTallies {
        ListTallying.tally(TasksDocument.parse(text), lists: lists)
    }

    func testCountsDoneAndTotalPerList() {
        let t = tally("""
        a +work
        x b +work
        c +home
        """, lists: ["home", "work"])
        XCTAssertEqual(t["work"], ListTally(done: 1, total: 2))
        XCTAssertEqual(t["home"], ListTally(done: 0, total: 1))
    }

    /// `allProjects()` 會回傳只存在於 listDescriptions、零任務的 list。
    /// 那種 list 必須拿到一列 0/0,而不是從導覽欄消失。
    func testGivenListWithNoTasksTalliesZero() {
        let t = tally("a +work", lists: ["empty", "work"])
        XCTAssertEqual(t["empty"], ListTally(done: 0, total: 0))
    }

    /// 空白行是檔案裡的分隔行,不是任務 —— 與 `ListGrouping.group` 的判定一致。
    func testBlankLinesAreNotTasks() {
        let t = tally("""
        a +work

        x b +work
        """, lists: ["work"])
        XCTAssertEqual(t["work"], ListTally(done: 1, total: 2))
        XCTAssertEqual(t.all, ListTally(done: 1, total: 2))
    }

    /// 一筆任務掛兩個 list,兩邊都算 —— 導覽欄是篩選入口,點任一邊都該看得到它。
    func testTaskInTwoListsCountsInBoth() {
        let t = tally("x a +work +home", lists: ["home", "work"])
        XCTAssertEqual(t["work"], ListTally(done: 1, total: 1))
        XCTAssertEqual(t["home"], ListTally(done: 1, total: 1))
        XCTAssertEqual(t.all, ListTally(done: 1, total: 1), "同一筆任務在 All tasks 只能算一次")
    }

    /// `TaskLine.projects` 不去重(`+work +work` 回傳兩筆),計數端必須自己去重,
    /// 否則手滑打兩次 tag 的那行會讓 total 比實際任務數多。
    func testDuplicateProjectTokenCountsOnce() {
        let t = tally("a +work +work", lists: ["work"])
        XCTAssertEqual(t["work"], ListTally(done: 0, total: 1))
    }

    func testAllTasksCountsTasksWithoutAnyList() {
        let t = tally("""
        a
        x b
        c +work
        """, lists: ["work"])
        XCTAssertEqual(t.all, ListTally(done: 1, total: 3))
        XCTAssertEqual(t["work"], ListTally(done: 0, total: 1))
    }

    /// 只回報呼叫端問的名稱;檔案裡出現、但不在名單內的 +tag 不會憑空長出一列。
    func testProjectsOutsideGivenNamesAreNotReported() {
        let t = tally("a +ghost", lists: ["work"])
        XCTAssertNil(t.byList["ghost"])
        XCTAssertEqual(t.all, ListTally(done: 0, total: 1), "未列名的 list 仍算進 All tasks")
    }

    /// 未知名稱查詢回 0/0 而不是崩潰 —— 導覽欄在 store 更新的那一幀可能問到已消失的名稱。
    func testUnknownNameSubscriptsToZero() {
        XCTAssertEqual(tally("a +work", lists: ["work"])["nope"], ListTally(done: 0, total: 0))
    }
}
