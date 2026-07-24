import Foundation

public enum ImportMapper {
    /// Converts raw list/tag text into a todo.txt-safe token body.
    /// Leading `+`, `@`, and whitespace are stripped; runs of separators collapse to `_`;
    /// Unicode letters and digits are preserved, so CJK text remains intact.
    public static func slug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.drop { $0 == "+" || $0 == "@" || CharacterSet.whitespacesAndNewlines.contains($0) }
        let allowed = CharacterSet.letters.union(.decimalDigits)
        var out = ""
        var lastWasUnderscore = false

        for scalar in scalars {
            if allowed.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasUnderscore = false
                continue
            }

            guard !out.isEmpty, !lastWasUnderscore else { continue }
            out.append("_")
            lastWasUnderscore = true
        }

        while out.last == "_" { out.removeLast() }
        return out
    }

    public static func todoTxtLine(for item: ImportedItem, today: Date, calendar: Calendar = .current) -> String {
        var line = TaskLine(TaskLine.sanitizedTitle(item.title))

        if let due = normalizedDue(item.due, today: today, calendar: calendar) {
            line.setDue(due)
        }

        let listSlug = item.list.map(slug) ?? ""
        if !listSlug.isEmpty {
            line.addTag("+" + listSlug)
        }

        for tag in item.tags {
            let tagSlug = slug(tag)
            if !tagSlug.isEmpty {
                line.addTag("@" + tagSlug)
            }
        }

        if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            line.setNote(notes)
        }

        return line.raw
    }

    private static func normalizedDue(_ raw: String?, today: Date, calendar: Calendar) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if isISODate(value, calendar: calendar) {
            return value
        }
        return DueDateParser.parse(value, today: today, calendar: calendar)
    }

    private static func isISODate(_ value: String, calendar: Calendar) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}
