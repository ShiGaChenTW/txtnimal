import Foundation
import txtnimalCore

/// Turns `list`'s options into one `TaskQuery.Expr` and evaluates it.
///
/// The flag-shaped filters (`--project`/`--context`/`--query`) and the `--filter` query
/// language are not two filtering systems: the flags compile down to the same expression
/// tree and run through the same evaluator. That is the point — two implementations of
/// "does this task match" would drift, and the flags are the ones with existing callers.
public enum TaskFilter {

    /// Every supplied filter, AND-ed together. Throws only when `--filter` will not parse.
    public static func expression(for options: ListOptions,
                                  today: Date,
                                  calendar: Calendar = .current) throws -> TaskQuery.Expr {
        var clauses: [TaskQuery.Expr] = []
        if let project = normalized(options.project, marker: "+") { clauses.append(.project(project)) }
        if let context = normalized(options.context, marker: "@") { clauses.append(.context(context)) }
        if let query = options.query?.lowercased(), !query.isEmpty { clauses.append(.text(query)) }
        if let filter = options.filter, !filter.trimmingCharacters(in: .whitespaces).isEmpty {
            clauses.append(try TaskQuery.parse(filter, today: today, calendar: calendar))
        }

        var expression = TaskQuery.Expr.all
        for clause in clauses {
            expression = expression == .all ? clause : .and(expression, clause)
        }
        return expression
    }

    /// Indices into `lines` that satisfy the expression. Blank lines are file structure,
    /// not tasks, and are never returned.
    public static func matchingIndices(in lines: [TaskLine],
                                       matching expression: TaskQuery.Expr,
                                       includeDone: Bool) -> [Int] {
        // `list` hides completed tasks unless asked. That default stands down the moment
        // the query mentions `done:` — once the user has named completion explicitly, a
        // hidden gate contradicting them would make `--filter "done:true"` return nothing.
        let showDone = includeDone || TaskQuery.mentionsDone(expression)
        return lines.indices.filter { index in
            let line = lines[index]
            guard !line.isBlank else { return false }
            guard showDone || !line.isDone else { return false }
            return TaskQuery.matches(line, expr: expression)
        }
    }

    /// Build-then-evaluate in one step, for callers with no reason to hold the expression.
    public static func matchingIndices(in lines: [TaskLine],
                                       options: ListOptions,
                                       today: Date = Date(),
                                       calendar: Calendar = .current) throws -> [Int] {
        let expression = try expression(for: options, today: today, calendar: calendar)
        return matchingIndices(in: lines, matching: expression, includeDone: options.includeDone)
    }

    /// Accepts `work`, `+work`, or `WORK` alike — an agent should not have to guess
    /// whether the marker character belongs in the argument.
    static func normalized(_ value: String?, marker: Character) -> String? {
        guard var trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        if trimmed.first == marker { trimmed = String(trimmed.dropFirst()) }
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}
