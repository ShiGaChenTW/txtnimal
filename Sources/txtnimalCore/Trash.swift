import Foundation

/// Retention arithmetic for trash.txt.
///
/// The store itself only ever compares `deleted:` against a cutoff string — the same shape
/// `archiveCompleted(before:)` already uses. This type owns the one piece of real date maths
/// (today minus N days) so it is testable without a filesystem.
public enum Trash {
    /// Retention windows the settings picker offers, in days.
    public static let retentionOptions = [7, 15, 30]
    public static let defaultRetentionDays = 30

    /// Clamp an arbitrary (e.g. persisted) value onto a supported window.
    public static func normalizedRetentionDays(_ days: Int) -> Int {
        retentionOptions.contains(days) ? days : defaultRetentionDays
    }

    /// Lines stamped with a `deleted:` date STRICTLY older than this cutoff are expired.
    /// Cutoff is `todayYMD - retentionDays`, so a task deleted today survives exactly
    /// `retentionDays` further day boundaries before it is purged.
    public static func cutoffYMD(todayYMD: String, retentionDays: Int) -> String? {
        guard let today = date(from: todayYMD),
              let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: today) else { return nil }
        return ymd(from: cutoff)
    }

    /// A trash line is expired when it carries a `deleted:` date older than the cutoff.
    /// A line with no (or an unparseable) `deleted:` token is NEVER expired — we refuse to
    /// permanently destroy something we cannot date.
    public static func isExpired(_ line: TaskLine, cutoffYMD: String) -> Bool {
        guard !line.isBlank, let deleted = line.deletedDate, let parsed = date(from: deleted) else { return false }
        return ymd(from: parsed) < cutoffYMD   // normalize first — string compare only holds zero-padded
    }

    /// Whole days left before permanent deletion, floored at 0. `nil` when the line carries no
    /// usable `deleted:` stamp (the UI then shows nothing rather than a wrong countdown).
    public static func daysRemaining(_ line: TaskLine, todayYMD: String, retentionDays: Int) -> Int? {
        guard let deleted = line.deletedDate,
              let deletedDate = date(from: deleted),
              let today = date(from: todayYMD),
              let elapsed = calendar.dateComponents([.day], from: deletedDate, to: today).day else { return nil }
        return max(0, retentionDays - elapsed)
    }

    // MARK: - Fixed-calendar YMD helpers

    /// Gregorian/UTC so day arithmetic never shifts with the host locale or DST.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func date(from ymd: String) -> Date? {
        let parts = ymd.split(separator: "-")
        guard parts.count == 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func ymd(from date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
