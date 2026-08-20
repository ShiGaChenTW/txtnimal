import Foundation

/// How a note is presented. Chosen at capture time from wrapping symbols, then stored.
public enum NoteKind: String, Equatable, Sendable, CaseIterable {
    case plain
    case list
    case quote
    case block
}

/// One independent note. Not a task-line `note:"…"` token and not scratch.txt.
public struct Note: Equatable, Identifiable, Sendable {
    public var id: String
    public var created: String
    public var kind: NoteKind
    public var tags: [String]
    public var body: String

    public init(id: String, created: String, kind: NoteKind, tags: [String], body: String) {
        self.id = id
        self.created = created
        self.kind = kind
        self.tags = Self.normalizedTags(tags)
        self.body = body
    }

    public var title: String {
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { return String(trimmed.dropFirst(2)) }
        return trimmed
    }

    public func hasTag(_ tag: String) -> Bool {
        tags.contains(tag)
    }

    public static func makeID() -> String {
        let hex = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "n" + hex
    }

    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags {
            let clean = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            out.append(clean)
        }
        return out
    }
}

/// Result of parsing one capture string before it is persisted.
public struct NoteDraft: Equatable, Sendable {
    public var kind: NoteKind
    public var tags: [String]
    public var body: String

    public init(kind: NoteKind, tags: [String], body: String) {
        self.kind = kind
        self.tags = Note.normalizedTags(tags)
        self.body = body
    }
}
