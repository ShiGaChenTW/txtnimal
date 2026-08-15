/// Bounded linear history of full task-document text snapshots.
///
/// Snapshots are the complete `tasks.txt` bytes at a point in time. The stack
/// keeps the last `capacity` snapshots; a new push after undo discards the
/// redo branch. No AppKit/SwiftUI dependency — verified by `swift test`.
public struct UndoStack: Equatable {
    public static let defaultCapacity = 50

    public let capacity: Int
    private var snapshots: [String] = []
    /// Index of the current snapshot, or `-1` when empty.
    private var index: Int = -1

    public init(capacity: Int = UndoStack.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { snapshots.isEmpty }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index >= 0 && index < snapshots.count - 1 }

    public mutating func push(_ snapshot: String) {
        if index >= 0 && index < snapshots.count - 1 {
            snapshots.removeSubrange((index + 1)...)
        }
        snapshots.append(snapshot)
        if snapshots.count > capacity {
            snapshots.removeFirst(snapshots.count - capacity)
        }
        index = snapshots.count - 1
    }

    public mutating func undo() -> String? {
        guard canUndo else { return nil }
        index -= 1
        return snapshots[index]
    }

    public mutating func redo() -> String? {
        guard canRedo else { return nil }
        index += 1
        return snapshots[index]
    }

    public mutating func clear() {
        snapshots.removeAll(keepingCapacity: false)
        index = -1
    }
}
