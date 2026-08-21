import Foundation

/// 刪除／封存一筆之後,游標要落在哪裡。
///
/// 從 `TaskStore.cursorAfterRemoving` 抽出來的判定半邊。抽出來的理由是它算錯不會有任何
/// 症狀:游標安靜地跳到別的地方,下一顆 `d` 就刪錯人。而它同時踩了兩個典型陷阱 ——
/// 移除後的索引位移(`> removed` 要減一)與落點夾擠(`min(position, count-1)`)——
/// 兩者都是 off-by-one 的常客,留在 ObservableObject 裡沒有任何測試搆得到。
public enum CursorPlacement {

    /// - Parameters:
    ///   - removed: 被移除的那一筆的**檔案**索引。
    ///   - order: 移除前的顯示走訪順序(清單是分組攤平,象限是四象限攤平),元素為檔案索引。
    /// - Returns: 移除後的新檔案索引;沒有東西可選時 `nil`。
    ///
    /// 落點規則是「留在原來的位置」:接住原本在下面那一筆,除非刪的就是最後一筆,
    /// 那就往上退一格。`removed` 不在 `order` 裡(被篩選蓋掉)時落在第一筆。
    public static func afterRemoving(_ removed: Int, from order: [Int]) -> Int? {
        let remaining = order.filter { $0 != removed }.map { $0 > removed ? $0 - 1 : $0 }
        guard !remaining.isEmpty else { return nil }
        let position = order.firstIndex(of: removed) ?? 0
        return remaining[min(position, remaining.count - 1)]
    }
}
