import Foundation

/// 「按下 `e` / ⏎ 之後要編輯哪一個東西」的判定半邊，從 `TaskStore.startEditing()` 抽出來。
///
/// 抽出來的理由不是整潔,是這道守門曾經寫死 `view == .list`：catalog 對 `.inlineEdit`
/// 宣告 `.listGridSelection`,指令盤也照著把它列在象限頁,只有這裡把象限頁擋掉,
/// 於是 `e` 在象限頁靜靜地沒反應。判定留在 `TaskStore`（SwiftUI 的 ObservableObject）
/// 裡就沒有測試搆得到它;搬到這裡之後,catalog 與守門的一致性有 `InlineEditGateTests` 擋著。
///
/// 對 store 的實際寫入(`editingIndex = i`、`startEditingNote()`)仍留在 App 層 ——
/// 同 `KeyboardGuardChain` 的分工:核心只判斷,App 只執行。
public enum InlineEditGate {

    /// 判定結果。`none` 是明確的「什麼都不做」,不是錯誤。
    public enum Route: Equatable, Sendable {
        /// 對第 `index` 筆任務開行內編輯。
        case task(index: Int)
        /// 交給筆記頁自己的編輯流程。
        case note
        case none
    }

    /// - Parameters:
    ///   - page: 目前頁面(`AppView.palettePage`)。
    ///   - cursor: 任務游標;`nil` 代表沒有選取。
    ///   - lines: 目前的任務清單,用來檢查游標範圍與完成狀態。
    public static func route(page: CommandPalettePage, cursor: Int?, lines: [TaskLine]) -> Route {
        if page == .notes { return .note }
        // 可用頁面刻意跟 catalog 的 `.inlineEdit` 宣告對齊,不要在這裡自己加減頁面。
        guard page == .list || page == .grid,
              let i = cursor, lines.indices.contains(i), !lines[i].isDone else { return .none }
        return .task(index: i)
    }
}
