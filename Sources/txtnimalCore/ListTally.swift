import Foundation

/// 一列 List 導覽的完成度。`done` 一定 ≤ `total`。
public struct ListTally: Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int = 0, total: Int = 0) {
        self.done = done
        self.total = total
    }

    /// 顯示成 "3/12" —— 導覽欄唯一的數字格式,別處要顯示同一組數字時也走這裡。
    public var label: String { "\(done)/\(total)" }
}

/// 左側 List 導覽欄一次算完的計數。
public struct ListTallies: Equatable {
    /// 「All tasks」列:全部非空白行,每筆只算一次(即使掛了多個 list)。
    public var all: ListTally
    /// 呼叫端給的每個名稱都保證有一筆;沒被問到的 +tag 不會出現在這裡。
    public var byList: [String: ListTally]

    public init(all: ListTally = ListTally(), byList: [String: ListTally] = [:]) {
        self.all = all
        self.byList = byList
    }

    /// 未知名稱回 0/0 而不是 nil —— 導覽欄在 store 更新的那一幀可能問到剛消失的名稱。
    public subscript(_ name: String) -> ListTally { byList[name] ?? ListTally() }
}

public enum ListTallying {
    /// 單趟掃過 `lines` 算出所有 list 的 done/total。
    ///
    /// `lists` 由呼叫端給(App 端是 `TaskStore.allProjects()`),因為只存在於 List metadata、
    /// 零任務的清單也必須拿到一列 0/0,那種清單在 `lines` 裡根本找不到。
    ///
    /// 刻意**不套用** `tagFilter` / `searchQuery`:導覽欄是切換篩選的入口,若計數也跟著篩,
    /// 選中某個 list 會讓其他每一列都變成 0/0,導覽功能就沒了。
    public static func tally(_ lines: [TaskLine], lists: [String]) -> ListTallies {
        var byList = [String: ListTally](minimumCapacity: lists.count)
        for name in lists { byList[name] = ListTally() }

        var all = ListTally()
        for t in lines where !t.isBlank {
            let isDone = t.isDone
            all.total += 1
            if isDone { all.done += 1 }
            // Set:`TaskLine.projects` 不去重,`+work +work` 那行只能算一次。
            for name in Set(t.projects) {
                guard var tally = byList[name] else { continue }
                tally.total += 1
                if isDone { tally.done += 1 }
                byList[name] = tally
            }
        }
        return ListTallies(all: all, byList: byList)
    }
}
