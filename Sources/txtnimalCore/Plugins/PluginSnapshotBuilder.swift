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
        var legacyOccurrences: [String: Int] = [:]
        let tasks = try document.lines.enumerated().compactMap { _, line -> PluginTaskSnapshot? in
            guard !line.isBlank else { return nil }
            let id: String
            if let persisted = line.stableID, isValidPersistedID(persisted) {
                id = persisted
                guard seen.insert(id).inserted else { throw PluginSnapshotError.duplicatePersistedIdentity(id) }
            } else {
                let base = "legacy-\(DocumentRevision.make(for: line.raw).prefix(16))"
                let occurrence = legacyOccurrences[base, default: 0]
                legacyOccurrences[base] = occurrence + 1
                id = occurrence == 0 ? base : "\(base)-\(occurrence)"
                guard seen.insert(id).inserted else {
                    throw PluginSnapshotError.duplicatePersistedIdentity(id)
                }
            }
            return PluginTaskSnapshot(id: id, title: line.title, due: line.due,
                                      completed: line.isDone, lists: line.projects, tags: line.contexts,
                                      revision: DocumentRevision.make(for: line.raw))
        }
        return PluginDocumentSnapshot(documentRevision: document.documentRevision, tasks: tasks)
    }

    private static func isValidPersistedID(_ id: String) -> Bool {
        guard id.count >= 4, id.count <= 80 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return id.unicodeScalars.allSatisfy(allowed.contains)
    }
}
