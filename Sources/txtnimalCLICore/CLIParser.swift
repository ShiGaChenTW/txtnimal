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
            guard ["--project", "--context", "--query"].contains(token) else {
                throw CLIParseError.unknownFlag(token)
            }
            let value = try value(after: index, in: args, flag: token)
            switch token {
            case "--project": options.project = value
            case "--context": options.context = value
            default: options.query = value
            }
            index += 2
        }
        return options
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
