import Foundation

/// Turns one line typed into the quick-capture panel into a finished task line.
///
/// Reuses the same tokenizer, so `+project` / `note:"…"` / any metadata the user
/// types is preserved. A shorthand `due:` value (`fri`, `3d`, …) is normalized to
/// an ISO date; an unparseable one is left as typed. `created:` and `id:` are stamped
/// if absent — a task is born with an identity, the same way a `Note` is.
public enum Capture {
    public static func makeTaskLine(
        from input: String,
        today: Date,
        createdYMD: String,
        calendar: Calendar = .current,
        makeID: () -> String = TaskLine.makeID
    ) -> String? {
        var t = TaskLine(input.trimmingCharacters(in: .whitespaces))
        if t.isBlank { return nil }
        if let raw = t.due, let norm = DueDateParser.parse(raw, today: today, calendar: calendar) {
            t.setDue(norm)
        }
        if t.created == nil { t.setValue(createdYMD, forKey: "created") }
        // Identity at creation, not on first reference: a task the user just typed already
        // has an id before it reaches disk. The save path still backfills, but only for lines
        // that arrived some other way (legacy files, external edits).
        if (t.stableID ?? "").isEmpty { t.setStableID(makeID()) }
        return t.raw
    }
}
