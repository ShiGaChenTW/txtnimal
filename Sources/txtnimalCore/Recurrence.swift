import Foundation

public struct RecurrenceRule: Equatable {
    public enum Unit: Equatable {
        case day
        case week
        case month
        case year
    }

    public let strict: Bool
    public let count: Int
    public let unit: Unit

    public init(strict: Bool, count: Int, unit: Unit) {
        self.strict = strict
        self.count = count
        self.unit = unit
    }

    public static func parse(_ token: String) -> RecurrenceRule? {
        var body = token[...]
        let strict = body.first == "+"
        if strict { body.removeFirst() }

        let digits = body.prefix { $0 >= "0" && $0 <= "9" }
        guard !digits.isEmpty, let count = Int(digits), count >= 1 else { return nil }

        let suffix = body.dropFirst(digits.count)
        guard suffix.count == 1, let last = suffix.first else { return nil }

        let unit: Unit
        switch last {
        case "d": unit = .day
        case "w": unit = .week
        case "m": unit = .month
        case "y": unit = .year
        default: return nil
        }

        return RecurrenceRule(strict: strict, count: count, unit: unit)
    }
}

public enum Recurrence {
    public static func nextDue(
        base: String?,
        rule: RecurrenceRule,
        completionYMD: String,
        calendar: Calendar = .current
    ) -> String? {
        let reference = rule.strict ? (base ?? completionYMD) : completionYMD
        guard let date = isoDate(reference, calendar: calendar) else { return nil }

        let component: Calendar.Component
        switch rule.unit {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        }

        guard let next = calendar.date(byAdding: component, value: rule.count, to: date) else { return nil }
        return DueDateParser.ymd(next, calendar)
    }

    private static func isoDate(_ ymd: String, calendar: Calendar) -> Date? {
        let parts = ymd.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return (back.year == year && back.month == month && back.day == day) ? date : nil
    }
}
