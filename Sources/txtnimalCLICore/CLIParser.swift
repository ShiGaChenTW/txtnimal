import Foundation

/// Hand-rolled argument parsing. The surface is five subcommands and eight options —
/// small enough that a dependency would cost more than it saves, and this package
/// currently has zero external dependencies.
public enum CLIParser {

    public static func parse(_ arguments: [String]) throws -> ParsedInvocation {
        var args = arguments
        var global = GlobalOptions()

        // `--dir` and `--json` are accepted anywhere, so pull them out before the
        // subcommand parser sees the rest. Everything after a bare `--` is literal.
        var scanned: [String] = []
        var literalTail: [String] = []
        var index = 0
        while index < args.count {
            let token = args[index]
            if token == "--" {
                literalTail = Array(args[(index + 1)...])
                break
            }
            switch token {
            case "--dir":
                guard index + 1 < args.count else { throw CLIParseError.missingValue("--dir") }
                global.dir = args[index + 1]
                index += 2
            case "--json":
                global.json = true
                index += 1
            default:
                scanned.append(token)
                index += 1
            }
        }
        args = scanned

        guard let verb = args.first else {
            return ParsedInvocation(command: .help, global: global)
        }
        let rest = Array(args.dropFirst())

        switch verb {
        case "--help", "-h", "help":
            return ParsedInvocation(command: .help, global: global)
        case "--version", "-v", "version":
            return ParsedInvocation(command: .version, global: global)
        case "add":
            return ParsedInvocation(command: .add(try parseAdd(rest, literalTail: literalTail)), global: global)
        case "list":
            if rest.first == "ensure" {
                return ParsedInvocation(command: .listEnsure(try ensureName(Array(rest.dropFirst()), literalTail: literalTail)),
                                        global: global)
            }
            return ParsedInvocation(command: .list(try parseList(rest)), global: global)
        case "tag":
            guard rest.first == "ensure" else {
                throw CLIParseError.unknownCommand(([verb] + rest).joined(separator: " "))
            }
            return ParsedInvocation(command: .tagEnsure(try ensureName(Array(rest.dropFirst()), literalTail: literalTail)),
                                    global: global)
        case "done", "delete":
            let identifier = try single(rest, literalTail: literalTail, named: "id")
            return ParsedInvocation(command: verb == "done" ? .done(identifier) : .delete(identifier), global: global)
        case "focus":
            return ParsedInvocation(command: .focus(try parseFocus(rest, literalTail: literalTail)), global: global)
        case "view":
            return ParsedInvocation(command: try parseView(rest, literalTail: literalTail), global: global)
        default:
            throw CLIParseError.unknownCommand(verb)
        }
    }

    // MARK: - Subcommands

    private static func parseAdd(_ args: [String], literalTail: [String]) throws -> AddOptions {
        var options = AddOptions()
        var titleWords: [String] = []
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                titleWords.append(token)
                index += 1
                continue
            }
            // Reject an unknown flag before reaching for its value, so a typo reports
            // "unknown option" rather than the misleading "needs a value".
            guard ["--due", "--project", "--context", "--note"].contains(token) else {
                throw CLIParseError.unknownFlag(token)
            }
            let value = try value(after: index, in: args, flag: token)
            switch token {
            case "--due": options.due = value
            case "--project": options.projects.append(strip(value, of: "+"))
            case "--context": options.contexts.append(strip(value, of: "@"))
            default: options.note = value
            }
            index += 2
        }
        titleWords.append(contentsOf: literalTail)
        options.title = titleWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !options.title.isEmpty else { throw CLIParseError.missingArgument("title") }
        return options
    }

    private static func parseList(_ args: [String]) throws -> ListOptions {
        var options = ListOptions()
        var index = 0
        while index < args.count {
            let token = args[index]
            if token == "--all" {
                options.includeDone = true
                index += 1
                continue
            }
            guard token.hasPrefix("--") else { throw CLIParseError.unknownCommand("list \(token)") }
            guard ["--project", "--context", "--query", "--filter"].contains(token) else {
                throw CLIParseError.unknownFlag(token)
            }
            let value = try value(after: index, in: args, flag: token)
            switch token {
            case "--project": options.project = value
            case "--context": options.context = value
            case "--filter": options.filter = value
            default: options.query = value
            }
            index += 2
        }
        return options
    }

    /// `focus <id-prefix>` or `focus --clear`. The two are mutually exclusive: naming a
    /// task *and* asking to clear is a contradiction worth reporting, not resolving.
    private static func parseFocus(_ args: [String], literalTail: [String]) throws -> String? {
        var clear = false
        var positional: [String] = []
        for token in args {
            if token == "--clear" {
                clear = true
            } else if token.hasPrefix("--") {
                throw CLIParseError.unknownFlag(token)
            } else {
                positional.append(token)
            }
        }
        positional.append(contentsOf: literalTail)

        if clear {
            guard positional.isEmpty else {
                throw CLIParseError.unknownCommand("focus --clear \(positional[0])")
            }
            return nil
        }
        guard let identifier = positional.first, !identifier.isEmpty else {
            throw CLIParseError.missingArgument("id")
        }
        return identifier
    }

    private static func parseView(_ args: [String], literalTail: [String]) throws -> CLICommand {
        guard let sub = args.first else { throw CLIParseError.missingArgument("view subcommand") }
        let rest = Array(args.dropFirst())

        switch sub {
        case "list":
            let (flags, positional) = try split(rest, accepting: [], literalTail: literalTail)
            _ = flags
            guard positional.isEmpty else { throw CLIParseError.unknownCommand("view list \(positional[0])") }
            return .viewList

        case "save":
            let (flags, positional) = try split(rest, accepting: ["--force"], literalTail: literalTail)
            guard let name = positional.first, !name.isEmpty else { throw CLIParseError.missingArgument("name") }
            guard positional.count >= 2 else { throw CLIParseError.missingArgument("query") }
            // Everything after the name is the query, so a caller may leave it unquoted:
            // `view save week +work due:<=1w` reads the same as the quoted form.
            let query = positional.dropFirst().joined(separator: " ")
            return .viewSave(SaveViewOptions(name: name, query: query, force: flags.contains("--force")))

        case "run":
            let (flags, positional) = try split(rest, accepting: ["--all"], literalTail: literalTail)
            guard let name = positional.first, !name.isEmpty else { throw CLIParseError.missingArgument("name") }
            guard positional.count == 1 else { throw CLIParseError.unknownCommand("view run \(positional[1])") }
            return .viewRun(RunViewOptions(name: name, includeDone: flags.contains("--all")))

        case "delete":
            return .viewDelete(try single(rest, literalTail: literalTail, named: "name"))

        default:
            throw CLIParseError.unknownCommand("view \(sub)")
        }
    }

    /// Separates recognised boolean flags from positional arguments, rejecting anything
    /// flag-shaped that is not on the accept list.
    private static func split(_ args: [String], accepting accepted: Set<String>,
                              literalTail: [String]) throws -> (flags: Set<String>, positional: [String]) {
        var flags: Set<String> = []
        var positional: [String] = []
        for token in args {
            if accepted.contains(token) {
                flags.insert(token)
            } else if token.hasPrefix("--") {
                throw CLIParseError.unknownFlag(token)
            } else {
                positional.append(token)
            }
        }
        positional.append(contentsOf: literalTail)
        return (flags, positional)
    }

    private static func ensureName(_ args: [String], literalTail: [String]) throws -> String {
        try single(args, literalTail: literalTail, named: "name")
    }

    // MARK: - Helpers

    private static func single(_ args: [String], literalTail: [String], named: String) throws -> String {
        let candidates = args + literalTail
        if let flag = candidates.first(where: { $0.hasPrefix("--") }) { throw CLIParseError.unknownFlag(flag) }
        guard let first = candidates.first, !first.isEmpty else { throw CLIParseError.missingArgument(named) }
        return first
    }

    private static func value(after index: Int, in args: [String], flag: String) throws -> String {
        guard index + 1 < args.count else { throw CLIParseError.missingValue(flag) }
        return args[index + 1]
    }

    private static func strip(_ value: String, of marker: Character) -> String {
        value.first == marker ? String(value.dropFirst()) : value
    }
}
