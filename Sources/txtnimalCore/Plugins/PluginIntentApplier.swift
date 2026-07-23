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
        try applyBatch([intent], to: snapshot, todayYMD: todayYMD)
    }

    /// Apply a batch of intents against a single pre-batch snapshot. Identity is resolved ONCE from
    /// the original lines, so content-derived legacy IDs don't drift as earlier mutations change the
    /// document. In-place edits (reschedule/complete/retitle) run against stable indices; deletions
    /// are collected and removed last (highest index first) so they don't shift those indices.
    public static func applyBatch(_ intents: [ValidatedPluginIntent], to snapshot: TaskDocumentSnapshot,
                                  todayYMD: String) throws -> [TaskLine] {
        for intent in intents where !(intent.documentRevision == nil || intent.documentRevision == snapshot.documentRevision) {
            throw PluginIntentApplyError.staleDocument
        }
        var lines = snapshot.lines
        let identityMap = PluginSnapshotBuilder.identityMap(for: lines)
        var deleteIndices = Set<Int>()

        func index(for id: String) throws -> Int {
            guard let index = identityMap[id] else { throw PluginIntentApplyError.taskNotFound(id) }
            return index
        }

        for intent in intents {
            switch intent.command {
            case .createTask:
                guard let title = intent.title else { throw PluginIntentApplyError.unsupportedCommand }
                let safeTitle = TaskLine.sanitizedTitle(title).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !safeTitle.isEmpty,
                      let today = fixedDate(from: todayYMD),
                      let raw = Capture.makeTaskLine(from: safeTitle, today: today,
                                                     createdYMD: todayYMD, calendar: fixedCalendar) else {
                    throw PluginIntentApplyError.unsupportedCommand
                }
                var line = TaskLine(raw)
                line.setValue(todayYMD, forKey: "created")
                line.setDue(intent.due)
                lines.append(line)   // append doesn't shift existing indices
            case .rescheduleTask:
                for id in intent.taskIDs { lines[try index(for: id)].setDue(intent.due ?? todayYMD) }
            case .rescheduleOverdue:
                for i in lines.indices where !lines[i].isDone && (lines[i].due ?? todayYMD) < todayYMD {
                    lines[i].setDue(todayYMD)
                }
            case .completeTask:
                for id in intent.taskIDs { lines[try index(for: id)].setDone(true, date: todayYMD) }
            case .deleteTask:
                for id in intent.taskIDs { deleteIndices.insert(try index(for: id)) }
            case .retitleTask:
                guard let newTitle = intent.title, let id = intent.taskIDs.first else {
                    throw PluginIntentApplyError.unsupportedCommand
                }
                let safe = TaskLine.sanitizedTitle(newTitle)
                guard !safe.isEmpty else { throw PluginIntentApplyError.unsupportedCommand }
                lines[try index(for: id)].setTitle(safe)
            }
        }
        for i in deleteIndices.sorted(by: >) { lines.remove(at: i) }
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
