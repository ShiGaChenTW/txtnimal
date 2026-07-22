import Foundation

public struct TaskHandle: Hashable, Codable {
    public let generation: UInt64
    public let index: Int
    public init(generation: UInt64, index: Int) { self.generation = generation; self.index = index }
}
public enum TaskCommand: Equatable {
    case toggleDone(TaskHandle)
    case toggleFocus(TaskHandle)
    case setQuadrant(TaskHandle, Int?)
    case setDue(TaskHandle, String?)
    case setTag(TaskHandle, String, Bool)
    case delete(TaskHandle)
    case rescheduleOverdue
}

public enum TaskWorkspaceError: LocalizedError, Equatable {
    case staleHandle
    case missingTask
    public var errorDescription: String? {
        self == .staleHandle ? "任務已在外部變更，請重新操作" : "找不到任務"
    }
}

public enum TaskWorkspace {
    public static func apply(_ command: TaskCommand, to snapshot: TaskDocumentSnapshot, todayYMD: String) throws -> [TaskLine] {
        var lines = snapshot.lines
        func index(_ handle: TaskHandle) throws -> Int {
            guard handle.generation == snapshot.generation else { throw TaskWorkspaceError.staleHandle }
            guard lines.indices.contains(handle.index) else { throw TaskWorkspaceError.missingTask }
            return handle.index
        }
        switch command {
        case .toggleDone(let handle):
            let i = try index(handle); lines[i].setDone(!lines[i].isDone, date: todayYMD)
        case .toggleFocus(let handle):
            let i = try index(handle)
            lines = TasksDocument.setFocus(lines, onIndex: lines[i].isFocused ? nil : i)
        case .setQuadrant(let handle, let q):
            let i = try index(handle); guard !lines[i].isDone else { return lines }; lines[i].setQuadrant(q)
        case .setDue(let handle, let due):
            let i = try index(handle); guard !lines[i].isDone else { return lines }; lines[i].setDue(due)
        case .setTag(let handle, let tag, let enabled):
            let i = try index(handle); guard !lines[i].isDone else { return lines }
            if enabled { lines[i].addTag(tag) } else { lines[i].removeTag(tag) }
        case .delete(let handle):
            lines.remove(at: try index(handle))
        case .rescheduleOverdue:
            for i in lines.indices where !lines[i].isDone && (lines[i].due ?? todayYMD) < todayYMD { lines[i].setDue(todayYMD) }
        }
        return lines
    }
}
