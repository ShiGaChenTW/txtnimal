import Foundation

public enum PluginIntentApplyError: LocalizedError, Equatable, Sendable {
    case staleDocument
    case taskNotFound(String)
    case unsupportedCommand
    public var errorDescription: String? {
        switch self {
        case .staleDocument: return "document changed before plugin action was applied"
        case .taskNotFound(let id): return "task not found: \(id)"
        case .unsupportedCommand: return "unsupported plugin command"
        }
    }
}

public enum PluginIntentApplier {
    public static func apply(_ intent: ValidatedPluginIntent, to snapshot: TaskDocumentSnapshot,
                             todayYMD: String) throws -> [TaskLine] {
        guard intent.documentRevision == nil || intent.documentRevision == snapshot.documentRevision else {
            throw PluginIntentApplyError.staleDocument
        }
        var lines = snapshot.lines
        switch intent.command {
        case .createTask:
            guard let title = intent.title else { throw PluginIntentApplyError.unsupportedCommand }
            let safeTitle = title.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !safeTitle.isEmpty,
                  let today = fixedDate(from: todayYMD),
                  let raw = Capture.makeTaskLine(from: safeTitle, today: today,
                                                 createdYMD: todayYMD, calendar: fixedCalendar) else {
                throw PluginIntentApplyError.unsupportedCommand
            }
            var line = TaskLine(raw)
            line.setValue(todayYMD, forKey: "created")
            line.setDue(intent.due)
            lines.append(line)
        case .rescheduleTask:
            // Resolve by the same identity scheme the snapshot builder uses, so legacy rows
            // reschedule without stamping a synthetic id: token into the file. Map is computed
            // once against these lines; indices stay valid as we only mutate due in place.
            let identityMap = PluginSnapshotBuilder.identityMap(for: lines)
            for id in intent.taskIDs {
                guard let index = identityMap[id] else {
                    throw PluginIntentApplyError.taskNotFound(id)
                }
                lines[index].setDue(intent.due ?? todayYMD)
            }
        case .rescheduleOverdue:
            for index in lines.indices where !lines[index].isDone && (lines[index].due ?? todayYMD) < todayYMD {
                lines[index].setDue(todayYMD)
            }
        case .completeTask:
            let identityMap = PluginSnapshotBuilder.identityMap(for: lines)
            for id in intent.taskIDs {
                guard let index = identityMap[id] else { throw PluginIntentApplyError.taskNotFound(id) }
                lines[index].setDone(true, date: todayYMD)
            }
        case .deleteTask:
            let identityMap = PluginSnapshotBuilder.identityMap(for: lines)
            var indices: [Int] = []
            for id in intent.taskIDs {
                guard let index = identityMap[id] else { throw PluginIntentApplyError.taskNotFound(id) }
                indices.append(index)
            }
            // Remove high indices first so earlier removals don't shift later ones.
            for index in indices.sorted(by: >) { lines.remove(at: index) }
        case .retitleTask:
            guard let newTitle = intent.title,
                  let id = intent.taskIDs.first else { throw PluginIntentApplyError.unsupportedCommand }
            let identityMap = PluginSnapshotBuilder.identityMap(for: lines)
            guard let index = identityMap[id] else { throw PluginIntentApplyError.taskNotFound(id) }
            lines[index].setTitle(newTitle)
        }
        return lines
    }

    private static var fixedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func fixedDate(from ymd: String) -> Date? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return fixedCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
