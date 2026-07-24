import Foundation

public enum PluginSnapshotError: LocalizedError, Equatable, Sendable {
    case duplicatePersistedIdentity(String)
    case invalidPersistedIdentity(String)

    public var errorDescription: String? {
        switch self {
        case .duplicatePersistedIdentity(let id): return "duplicate task identity: \(id)"
        case .invalidPersistedIdentity(let id): return "invalid task identity: \(id)"
        }
    }
}

public enum PluginSnapshotBuilder {
    public static func build(from document: TaskDocumentSnapshot) throws -> PluginDocumentSnapshot {
        var seen = Set<String>()
        let tasks = try orderedIdentities(for: document.lines).map { entry -> PluginTaskSnapshot in
            guard seen.insert(entry.id).inserted else {
                throw PluginSnapshotError.duplicatePersistedIdentity(entry.id)
            }
            let line = document.lines[entry.index]
            return PluginTaskSnapshot(id: entry.id, title: line.title, due: line.due,
                                      completed: line.isDone, lists: line.projects, tags: line.contexts,
                                      revision: DocumentRevision.make(for: line.raw))
        }
        return PluginDocumentSnapshot(documentRevision: document.documentRevision, tasks: tasks)
    }

    /// Maps each non-blank line's plugin identity → its index in `lines`, using the exact scheme
    /// `build` assigns. Lets the applier resolve legacy (unpersisted) IDs without stamping them
    /// into the file — so rescheduling an ID-less row changes only its due, not its tokens.
    public static func identityMap(for lines: [TaskLine]) -> [String: Int] {
        var map: [String: Int] = [:]
        for entry in orderedIdentities(for: lines) where map[entry.id] == nil {
            map[entry.id] = entry.index
        }
        return map
    }

    /// Single source of the id-assignment logic shared by `build` and `identityMap`.
    private static func orderedIdentities(for lines: [TaskLine]) -> [(index: Int, id: String)] {
        var result: [(index: Int, id: String)] = []
        var legacyOccurrences: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            guard !line.isBlank else { continue }
            let id: String
            if let persisted = line.stableID, isValidPersistedID(persisted) {
                id = persisted
            } else {
                let base = "legacy-\(DocumentRevision.make(for: line.raw).prefix(16))"
                let occurrence = legacyOccurrences[base, default: 0]
                legacyOccurrences[base] = occurrence + 1
                id = occurrence == 0 ? base : "\(base)-\(occurrence)"
            }
            result.append((index, id))
        }
        return result
    }

    private static func isValidPersistedID(_ id: String) -> Bool {
        guard id.count >= 4, id.count <= 80 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return id.unicodeScalars.allSatisfy(allowed.contains)
    }
}
