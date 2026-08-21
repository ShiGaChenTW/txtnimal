import Foundation

/// A small token query language over `TaskLine`.
///
/// ```
/// query   := orExpr
/// orExpr  := andExpr ("OR" andExpr)*
/// andExpr := term ("AND"? term)*        // bare juxtaposition is an implicit AND
/// term    := "NOT" term | "-" atom | "(" orExpr ")" | atom
/// atom    := +project | @context | due:[<|<=|>|>=|=]date | done:bool | focus:bool | q:text | text
/// ```
///
/// Deliberately bounded. There is no arithmetic, no field-to-field comparison and no
/// quoting: a phrase is simply several words, which the implicit AND already handles.
///
/// **Dates resolve at parse time.** `due:today` becomes a fixed `YYYY-MM-DD` the moment
/// the query is parsed, which is what makes an unreadable date a *parse* error the caller
/// can report with a usage exit code, instead of a clause that silently matches nothing.
/// Callers that must track the passing day (a saved view, say) store the query *text* and
/// re-parse it per run — which is exactly what `view run` does.
///
/// Pure: no file access, no ambient clock, no AppKit. The evaluator is shared with the
/// CLI's flag-shaped filters so there is only ever one definition of what a filter means.
public enum TaskQuery {

    // MARK: - Shape

    public enum Comparison: Equatable {
        case eq, lt, le, gt, ge
    }

    public indirect enum Expr: Equatable {
        case all
        /// Lowercased, without the leading `+`.
        case project(String)
        /// Lowercased, without the leading `@`.
        case context(String)
        /// Comparison against an already-resolved `YYYY-MM-DD`.
        case due(Comparison, String)
        case done(Bool)
        case focus(Bool)
        /// Lowercased substring of title + note.
        case text(String)
        case not(Expr)
        case and(Expr, Expr)
        case or(Expr, Expr)
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case unbalancedParenthesis
        case unexpectedToken(String)
        case danglingOperator
        case unknownKey(String)
        case emptyValue(String)
        case unreadableDate(String)
        case unreadableFlag(String, String)

        public var errorDescription: String? {
            switch self {
            case .unbalancedParenthesis:
                return "unbalanced parentheses in filter"
            case .unexpectedToken(let token):
                return "unexpected \"\(token)\" in filter"
            case .danglingOperator:
                return "filter ends after an operator — AND, OR and NOT each need something to operate on"
            case .unknownKey(let key):
                return "unknown filter key \"\(key):\" — try due:, done:, focus:, q:, +list or @tag"
            case .emptyValue(let marker):
                return "\"\(marker)\" needs a value"
            case .unreadableDate(let text):
                return "could not read date \"\(text)\" (try 2026-10-10, today, tomorrow, 3d, 2w, mon)"
            case .unreadableFlag(let key, let value):
                return "\(key): takes true or false, not \"\(value)\""
            }
        }
    }

    // MARK: - Parsing

    /// An empty (or whitespace-only) query is `.all`. Note that `.all` says nothing about
    /// completion — hiding done tasks by default is the *caller's* policy, not the
    /// language's, so that `done:` in a query can override it.
    public static func parse(_ text: String, today: Date, calendar: Calendar = .current) throws -> Expr {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return .all }
        var parser = Parser(tokens: tokens, today: today, calendar: calendar)
        let expr = try parser.parseOr()
        // Anything left over is a token no production could consume — a stray `)`, in practice.
        if let leftover = parser.peek {
            throw ParseError.unexpectedToken(describe(leftover))
        }
        return expr
    }

    /// True when the expression constrains completion anywhere in the tree. Callers use
    /// this to stand down their own default "hide done tasks" gate: once the user has said
    /// `done:` out loud, a gate that silently contradicts them is a bug.
    public static func mentionsDone(_ expr: Expr) -> Bool {
        switch expr {
        case .done:
            return true
        case .not(let inner):
            return mentionsDone(inner)
        case .and(let lhs, let rhs), .or(let lhs, let rhs):
            return mentionsDone(lhs) || mentionsDone(rhs)
        case .all, .project, .context, .due, .focus, .text:
            return false
        }
    }

    // MARK: - Evaluation

    /// Whether one line satisfies the expression. Blank lines are file structure rather
    /// than tasks, but that judgement belongs to the caller listing them — this evaluates
    /// exactly what it is asked to.
    public static func matches(_ line: TaskLine, expr: Expr) -> Bool {
        switch expr {
        case .all:
            return true
        case .project(let name):
            return line.projects.contains { $0.lowercased() == name }
        case .context(let name):
            return line.contexts.contains { $0.lowercased() == name }
        case .due(let comparison, let value):
            // A task with no due date is not a participant in a date comparison. Absence
            // is not "earlier than everything" — `due:<friday` asking for overdue work
            // must not sweep in every undated task in the file.
            guard let due = line.due, !due.isEmpty else { return false }
            switch comparison {
            case .eq: return due == value
            case .lt: return due < value
            case .le: return due <= value
            case .gt: return due > value
            case .ge: return due >= value
            }
        case .done(let flag):
            return line.isDone == flag
        case .focus(let flag):
            return line.isFocused == flag
        case .text(let needle):
            // Title and note only. Searching `raw` would let a query match `id:`/`due:`
            // tokens the user never typed and cannot see in the list output.
            return (line.title + " " + (line.note ?? "")).lowercased().contains(needle)
        case .not(let inner):
            return !matches(line, expr: inner)
        case .and(let lhs, let rhs):
            return matches(line, expr: lhs) && matches(line, expr: rhs)
        case .or(let lhs, let rhs):
            return matches(line, expr: lhs) || matches(line, expr: rhs)
        }
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case lparen, rparen, and, or, not
        case word(String)
    }

    private static func describe(_ token: Token) -> String {
        switch token {
        case .lparen: return "("
        case .rparen: return ")"
        case .and: return "AND"
        case .or: return "OR"
        case .not: return "NOT"
        case .word(let text): return text
        }
    }

    /// Parentheses are self-delimiting, so `(a OR b)` needs no spaces around the brackets.
    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append(contentsOf: classify(current))
            current = ""
        }

        for character in text {
            switch character {
            case "(":
                flush()
                tokens.append(.lparen)
            case ")":
                flush()
                tokens.append(.rparen)
            default:
                if character.isWhitespace { flush() } else { current.append(character) }
            }
        }
        flush()
        return tokens
    }

    /// One raw word becomes a leading run of `-` negations plus at most one payload token.
    private static func classify(_ raw: String) -> [Token] {
        var tokens: [Token] = []
        var body = Substring(raw)
        while body.first == "-" {
            tokens.append(.not)
            body = body.dropFirst()
        }
        guard !body.isEmpty else { return tokens }

        switch body.lowercased() {
        case "and": tokens.append(.and)
        case "or": tokens.append(.or)
        case "not": tokens.append(.not)
        default: tokens.append(.word(String(body)))
        }
        return tokens
    }

    // MARK: - Recursive-descent parser

    private struct Parser {
        let tokens: [Token]
        let today: Date
        let calendar: Calendar
        var position = 0

        var peek: Token? { position < tokens.count ? tokens[position] : nil }

        mutating func advance() { position += 1 }

        mutating func parseOr() throws -> Expr {
            var left = try parseAnd()
            while peek == .or {
                advance()
                left = .or(left, try parseAnd())
            }
            return left
        }

        mutating func parseAnd() throws -> Expr {
            var left = try parseTerm()
            while true {
                if peek == .and {
                    advance()
                } else if !startsTerm(peek) {
                    break
                }
                left = .and(left, try parseTerm())
            }
            return left
        }

        private func startsTerm(_ token: Token?) -> Bool {
            switch token {
            case .word, .not, .lparen: return true
            case .and, .or, .rparen, nil: return false
            }
        }

        mutating func parseTerm() throws -> Expr {
            guard let token = peek else { throw ParseError.danglingOperator }
            switch token {
            case .not:
                advance()
                return .not(try parseTerm())
            case .lparen:
                advance()
                let inner = try parseOr()
                guard peek == .rparen else { throw ParseError.unbalancedParenthesis }
                advance()
                return inner
            case .word(let raw):
                advance()
                return try atom(raw)
            case .rparen, .and, .or:
                throw ParseError.unexpectedToken(describe(token))
            }
        }

        // MARK: Atoms

        private func atom(_ raw: String) throws -> Expr {
            if raw.hasPrefix("+") {
                let name = String(raw.dropFirst())
                guard !name.isEmpty else { throw ParseError.emptyValue("+") }
                return .project(name.lowercased())
            }
            if raw.hasPrefix("@") {
                let name = String(raw.dropFirst())
                guard !name.isEmpty else { throw ParseError.emptyValue("@") }
                return .context(name.lowercased())
            }

            // `key:value`, but only when the key *looks* like a key. A colon inside a word
            // is ordinary text — `12:30` is a plausible thing to have in a title, and
            // rejecting it would make the language harder to use than the flags it replaces.
            if let colon = raw.firstIndex(of: ":"), colon != raw.startIndex {
                let key = String(raw[raw.startIndex..<colon]).lowercased()
                let value = String(raw[raw.index(after: colon)...])
                switch key {
                case "due":
                    return try dueAtom(value)
                case "done":
                    return .done(try flag(value, key: "done"))
                case "focus":
                    return .focus(try flag(value, key: "focus"))
                case "q":
                    guard !value.isEmpty else { throw ParseError.emptyValue("q:") }
                    return .text(value.lowercased())
                default:
                    if !key.isEmpty, key.allSatisfy(\.isLetter) {
                        throw ParseError.unknownKey(key)
                    }
                }
            }
            return .text(raw.lowercased())
        }

        private func dueAtom(_ value: String) throws -> Expr {
            var rest = Substring(value)
            var comparison = Comparison.eq
            // Two-character operators first, or `<=` would read as `<` followed by a date
            // beginning with `=`.
            if rest.hasPrefix("<=") { comparison = .le; rest = rest.dropFirst(2) }
            else if rest.hasPrefix(">=") { comparison = .ge; rest = rest.dropFirst(2) }
            else if rest.hasPrefix("<") { comparison = .lt; rest = rest.dropFirst() }
            else if rest.hasPrefix(">") { comparison = .gt; rest = rest.dropFirst() }
            else if rest.hasPrefix("=") { comparison = .eq; rest = rest.dropFirst() }

            guard !rest.isEmpty else { throw ParseError.emptyValue("due:") }
            // The one date vocabulary in the app — `today`, `3d`, `mon`, ISO — reused rather
            // than reimplemented, so the query language can never drift from `--due`.
            guard let resolved = DueDateParser.parse(String(rest), today: today, calendar: calendar) else {
                throw ParseError.unreadableDate(String(rest))
            }
            return .due(comparison, resolved)
        }

        private func flag(_ value: String, key: String) throws -> Bool {
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: throw ParseError.unreadableFlag(key, value)
            }
        }
    }
}
