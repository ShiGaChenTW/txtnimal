import Foundation
import txtnimalCore

public enum TaskFilter {

    /// Indices into `lines` that satisfy every supplied filter. Blank lines are file
    /// structure, not tasks, and are never returned.
    public static func matchingIndices(in lines: [TaskLine], options: ListOptions) -> [Int] {
        lines.indices.filter { matches(lines[$0], options: options) }
    }

    public static func matches(_ line: TaskLine, options: ListOptions) -> Bool {
        guard !line.isBlank else { return false }
        guard options.includeDone || !line.isDone else { return false }

        if let project = normalized(options.project, marker: "+") {
            guard line.projects.contains(where: { $0.lowercased() == project }) else { return false }
        }
        if let context = normalized(options.context, marker: "@") {
            guard line.contexts.contains(where: { $0.lowercased() == context }) else { return false }
        }
        if let query = options.query?.lowercased(), !query.isEmpty {
            // Title and note only. Searching `raw` would let a query match `id:`/`due:`
            // tokens the user never typed and cannot see in the list output.
            let haystack = (line.title + " " + (line.note ?? "")).lowercased()
            guard haystack.contains(query) else { return false }
        }
        return true
    }

    /// Accepts `work`, `+work`, or `WORK` alike — an agent should not have to guess
    /// whether the marker character belongs in the argument.
    static func normalized(_ value: String?, marker: Character) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        if trimmed.first == marker { trimmed = String(trimmed.dropFirst()) }
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}
