import EventKit
import Foundation
import txtnimalCore

struct EventKitRemindersSource: RemindersSource {
    enum SourceError: LocalizedError {
        case accessDenied

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "未取得提醒事項存取權限，請到系統設定授權。"
            }
        }
    }

    func fetch() async throws -> [ImportedItem] {
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToReminders()
        } else {
            granted = try await store.requestAccess(to: .reminder)
        }

        guard granted else { throw SourceError.accessDenied }

        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil,
                                                              ending: nil,
                                                              calendars: nil)
        let reminders = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[EKReminder], Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        return reminders.map { reminder in
            ImportedItem(
                title: reminder.title ?? "",
                due: dueString(from: reminder.dueDateComponents),
                list: reminder.calendar.title,
                tags: [],
                notes: reminder.notes,
                completed: reminder.isCompleted,
                sourceId: reminder.calendarItemIdentifier
            )
        }
    }

    private func dueString(from components: DateComponents?) -> String? {
        guard let components,
              let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.timeZone = utc

        var normalized = DateComponents()
        normalized.calendar = calendar
        normalized.timeZone = calendar.timeZone
        normalized.year = year
        normalized.month = month
        normalized.day = day

        guard let date = calendar.date(from: normalized) else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
