import Foundation

/// Turns one line typed into the quick-capture panel into a finished task line.
///
/// Reuses the same tokenizer, so `+project` / `note:"…"` / any metadata the user
/// types is preserved. A shorthand `due:` value (`fri`, `3d`, …) is normalized to
/// an ISO date; an unparseable one is left as typed. `created:` is stamped if absent.
public enum Capture {
    public static func makeTaskLine(
        from input: String,
        today: Date,
        createdYMD: String,
        calendar: Calendar = .current
    ) -> String? {
        var t = TaskLine(input.trimmingCharacters(in: .whitespaces))
        if t.isBlank { return nil }
        if let raw = t.due, let norm = DueDateParser.parse(raw, today: today, calendar: calendar) {
            t.setDue(norm)
        }
        if t.created == nil { t.setValue(createdYMD, forKey: "created") }
        return t.raw
    }
}
