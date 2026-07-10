import Foundation

/// Turns the keyboard-flow date shorthands into a canonical `YYYY-MM-DD` string.
///
/// Accepts: `2026-07-15` (ISO), `today`, `tomorrow`/`tmr`, weekday names
/// (`mon`…`sun`, today-inclusive nearest upcoming), and offsets `Nd`/`Nw`
/// (e.g. `3d`, `2w`). Returns `nil` for anything it can't confidently read —
/// the caller then leaves the user's raw text alone.
///
/// `today` is injected so the logic is deterministic and testable.
public enum DueDateParser {

    public static func parse(_ input: String, today: Date, calendar: Calendar = .current) -> String? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { return nil }

        if let d = isoDate(s, calendar: calendar) { return ymd(d, calendar) }

        switch s {
        case "today", "tod": return ymd(today, calendar)
        case "tomorrow", "tmr", "tom": return ymd(add(today, days: 1, calendar), calendar)
        default: break
        }

        if let target = weekday(s) { return ymd(nextWeekday(target, from: today, calendar: calendar), calendar) }
        if let days = offset(s) { return ymd(add(today, days: days, calendar), calendar) }
        return nil
    }

    // MARK: - helpers

    static func ymd(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func add(_ date: Date, days: Int, _ cal: Calendar) -> Date {
        cal.date(byAdding: .day, value: days, to: date) ?? date
    }

    /// Strict ISO parse — rejects impossible dates like `2026-13-40` or `2026-02-30`.
    private static func isoDate(_ s: String, calendar: Calendar) -> Date? {
        let p = s.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        guard let date = calendar.date(from: c) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return (back.year == y && back.month == m && back.day == d) ? date : nil
    }

    /// Gregorian weekday numbers: Sun=1 … Sat=7.
    private static func weekday(_ s: String) -> Int? {
        switch s {
        case "sun", "sunday": return 1
        case "mon", "monday": return 2
        case "tue", "tues", "tuesday": return 3
        case "wed", "weds", "wednesday": return 4
        case "thu", "thur", "thurs", "thursday": return 5
        case "fri", "friday": return 6
        case "sat", "saturday": return 7
        default: return nil
        }
    }

    private static func nextWeekday(_ target: Int, from: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: from)
        let cur = calendar.component(.weekday, from: start)
        let delta = (target - cur + 7) % 7 // 0 == today
        return calendar.date(byAdding: .day, value: delta, to: start) ?? start
    }

    /// `3d` → 3 days, `2w` → 14 days.
    private static func offset(_ s: String) -> Int? {
        guard let last = s.last, last == "d" || last == "w" else { return nil }
        guard let n = Int(s.dropLast()), n >= 0 else { return nil }
        return last == "w" ? n * 7 : n
    }
}
