import Foundation

/// ⌘1 main list, grouped by `due` relative to today. Values are indices into the
/// source array so the UI can edit/reorder the underlying line by position.
///
/// Display buckets; the app presents them as Today → Overdue → Upcoming → No-date → Done.
public struct TaskGroups: Equatable {
    public var today: [Int] = []
    public var upcoming: [Int] = []
    public var overdue: [Int] = []
    public var noDate: [Int] = []
    public var done: [Int] = []
    public init() {}
}

public enum ListGrouping {
    /// `todayYMD` must be a canonical `YYYY-MM-DD` string. Due dates are compared
    /// lexicographically, which is chronological for zero-padded ISO dates.
    public static func group(_ lines: [TaskLine], todayYMD: String) -> TaskGroups {
        var g = TaskGroups()
        for (i, t) in lines.enumerated() {
            if t.isBlank { continue }
            if t.isDone { g.done.append(i); continue }
            guard let due = t.due else { g.noDate.append(i); continue }
            if due == todayYMD { g.today.append(i) }
            else if due > todayYMD { g.upcoming.append(i) }
            else { g.overdue.append(i) }
        }
        // Upcoming sorts by due ascending; ties keep file order (stable via index).
        g.upcoming.sort { a, b in
            let da = lines[a].due ?? "", db = lines[b].due ?? ""
            return da == db ? a < b : da < db
        }
        return g
    }
}

/// ⌘4 quadrant board. `q:1`…`q:4` place a task manually; everything else (not done,
/// not blank) waits in `unplaced`. Time is never consulted here.
public struct QuadrantBoard: Equatable {
    public var q1: [Int] = []
    public var q2: [Int] = []
    public var q3: [Int] = []
    public var q4: [Int] = []
    public var unplaced: [Int] = []
    public init() {}
}

public enum QuadrantBucketing {
    public static func board(_ lines: [TaskLine]) -> QuadrantBoard {
        var b = QuadrantBoard()
        for (i, t) in lines.enumerated() {
            if t.isBlank || t.isDone { continue }
            switch t.quadrant {
            case 1: b.q1.append(i)
            case 2: b.q2.append(i)
            case 3: b.q3.append(i)
            case 4: b.q4.append(i)
            default: b.unplaced.append(i)
            }
        }
        return b
    }
}
