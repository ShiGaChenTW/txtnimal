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
        case .rescheduleTask:
            for id in intent.taskIDs {
                guard let index = lines.firstIndex(where: { $0.stableID == id }) else {
                    throw PluginIntentApplyError.taskNotFound(id)
                }
                lines[index].setDue(intent.due ?? todayYMD)
            }
        case .rescheduleOverdue:
            for index in lines.indices where !lines[index].isDone && (lines[index].due ?? todayYMD) < todayYMD {
                lines[index].setDue(todayYMD)
            }
        }
        return lines
    }
}
