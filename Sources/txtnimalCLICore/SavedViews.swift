import Foundation

/// A named query, stored so it can be re-run by name.
///
/// The *text* of the query is what persists, never a parsed expression — a view holding
/// `due:<=1w` has to mean "within a week of today" every time it runs, not "within a week
/// of the day I saved it".
public struct SavedView: Equatable, Codable {
    public var name: String
    public var query: String
    public var createdYMD: String

    public init(name: String, query: String, createdYMD: String) {
        self.name = name
        self.query = query
        self.createdYMD = createdYMD
    }
}

public enum SavedViewsError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case duplicateName(String)
    case notFound(String)
    case invalidName(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let file):
            return "could not read \(file) — it is not the list of views this command writes"
        case .duplicateName(let name):
            return "a view named \"\(name)\" already exists — pass --force to replace it"
        case .notFound(let name):
            return "no view named \"\(name)\" — run `txtnimal view list` to see them"
        case .invalidName(let name):
            return "\"\(name)\" is not a usable view name"
        }
    }
}

/// `views.json`, kept in the same folder as tasks.txt — the convention trash.txt and
/// notes.txt already follow, so relocating the data directory moves the views with it.
public enum SavedViewStore {

    public static let filename = "views.json"

    public static func url(besideTasksFile tasks: URL) -> URL {
        tasks.deletingLastPathComponent().appendingPathComponent(filename)
    }

    /// A missing file is an empty list of views, not a failure — reading must never be the
    /// operation that creates state. A file that exists but does not parse *is* an error:
    /// silently treating it as empty would let `view save` overwrite something real.
    public static func load(from url: URL) throws -> [SavedView] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        guard let views = try? JSONDecoder().decode([SavedView].self, from: data) else {
            throw SavedViewsError.unreadable(url.lastPathComponent)
        }
        return views
    }

    public static func save(_ views: [SavedView], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(views)
        data.append(0x0A) // trailing newline, so the file is a well-behaved git citizen
        // Temp file + rename, matching how the task file itself is committed.
        try data.write(to: url, options: .atomic)
    }

    /// Names are matched case-insensitively, and therefore are unique case-insensitively:
    /// `work` and `Work` being two different views is a trap, not a feature.
    public static func index(of name: String, in views: [SavedView]) -> Int? {
        let needle = name.lowercased()
        return views.firstIndex { $0.name.lowercased() == needle }
    }

    public static func find(_ name: String, in views: [SavedView]) -> SavedView? {
        index(of: name, in: views).map { views[$0] }
    }

    /// Rejects what would be unusable or ambiguous on a command line: nothing at all, or
    /// something that would be read as a flag.
    public static func validated(name raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("-") else { throw SavedViewsError.invalidName(raw) }
        return name
    }
}
