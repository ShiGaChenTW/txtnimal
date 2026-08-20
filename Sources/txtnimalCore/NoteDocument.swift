import Foundation

/// Plain-text persistence for independent notes, living next to tasks.txt as `notes.txt`.
///
/// Each record starts with a `NOTE` header line; the body runs until the next header.
/// Unknown header tokens are preserved so hand-edits survive a round trip.
public enum NoteDocument {
    public static func parse(_ text: String) -> [Note] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        var notes: [Note] = []
        var current: Header?
        var bodyLines: [String] = []

        func flush() {
            guard let header = current else { return }
            let body = trimBody(bodyLines.joined(separator: "\n"))
            if header.id.isEmpty && body.isEmpty { return }
            notes.append(Note(
                id: header.id.isEmpty ? Note.makeID() : header.id,
                created: header.created,
                kind: header.kind,
                tags: header.tags,
                body: body
            ))
            current = nil
            bodyLines = []
        }

        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            if let header = parseHeader(line) {
                flush()
                current = header
            } else if current != nil {
                bodyLines.append(line)
            }
        }
        flush()
        return notes
    }

    public static func serialize(_ notes: [Note]) -> String {
        guard !notes.isEmpty else { return "" }
        return notes.map(serializeOne).joined(separator: "\n\n") + "\n"
    }

    public static func allTags(in notes: [Note]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for note in notes {
            for tag in note.tags where seen.insert(tag).inserted {
                out.append(tag)
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func grouped(_ notes: [Note], tagFilter: String?) -> [(tag: String, notes: [Note])] {
        if let tagFilter {
            return [(tag: tagFilter, notes: notes.filter { $0.hasTag(tagFilter) })]
        }
        var buckets: [String: [Note]] = [:]
        var untagged: [Note] = []
        for note in notes {
            if note.tags.isEmpty {
                untagged.append(note)
            } else {
                for tag in note.tags {
                    buckets[tag, default: []].append(note)
                }
            }
        }
        let tagged = buckets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { (tag: $0, notes: buckets[$0] ?? []) }
        if untagged.isEmpty { return tagged }
        return tagged + [(tag: "", notes: untagged)]
    }

    // MARK: - header

    private struct Header {
        var id: String
        var created: String
        var kind: NoteKind
        var tags: [String]
    }

    private static func serializeOne(_ note: Note) -> String {
        var tokens = ["NOTE", "id:\(note.id)", "created:\(note.created)", "kind:\(note.kind.rawValue)"]
        tokens.append(contentsOf: note.tags.map { "#\($0)" })
        let header = tokens.joined(separator: " ")
        if note.body.isEmpty { return header }
        return header + "\n" + note.body
    }

    private static func parseHeader(_ line: String) -> Header? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("NOTE") else { return nil }
        let rest = trimmed.dropFirst(4)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard words.first == "NOTE" else { return nil }
        var id = ""
        var created = ""
        var kind = NoteKind.plain
        var tags: [String] = []
        for word in words.dropFirst() {
            if word.hasPrefix("id:") {
                id = String(word.dropFirst(3))
            } else if word.hasPrefix("created:") {
                created = String(word.dropFirst(8))
            } else if word.hasPrefix("kind:"), let parsed = NoteKind(rawValue: String(word.dropFirst(5))) {
                kind = parsed
            } else if word.hasPrefix("#"), word.count > 1 {
                tags.append(String(word.dropFirst()))
            }
        }
        return Header(id: id, created: created, kind: kind, tags: Note.normalizedTags(tags))
    }

    private static func trimBody(_ body: String) -> String {
        var lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}
