import Foundation

// MARK: - Options

public struct GlobalOptions: Equatable {
    public var dir: String?
    public var json: Bool
    public init(dir: String? = nil, json: Bool = false) {
        self.dir = dir
        self.json = json
    }
}

public struct AddOptions: Equatable {
    public var title: String
    public var due: String?
    public var projects: [String]
    public var contexts: [String]
    public var note: String?
    public init(title: String = "", due: String? = nil, projects: [String] = [],
                contexts: [String] = [], note: String? = nil) {
        self.title = title
        self.due = due
        self.projects = projects
        self.contexts = contexts
        self.note = note
    }
}

public struct ListOptions: Equatable {
    public var project: String?
    public var context: String?
    public var query: String?
    public var includeDone: Bool
    public init(project: String? = nil, context: String? = nil,
                query: String? = nil, includeDone: Bool = false) {
        self.project = project
        self.context = context
        self.query = query
        self.includeDone = includeDone
    }
}

public enum CLICommand: Equatable {
    case add(AddOptions)
    case list(ListOptions)
    case listEnsure(String)
    case tagEnsure(String)
    case done(String)
    case delete(String)
    case help
    case version
}

public struct ParsedInvocation: Equatable {
    public var command: CLICommand
    public var global: GlobalOptions
    public init(command: CLICommand, global: GlobalOptions) {
        self.command = command
        self.global = global
    }
}

// MARK: - Errors

public enum CLIParseError: Error, Equatable {
    case unknownCommand(String)
    case unknownFlag(String)
    case missingValue(String)
    case missingArgument(String)
}

extension CLIParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownCommand(let name): return "unknown command: \(name)"
        case .unknownFlag(let flag): return "unknown option: \(flag)"
        case .missingValue(let flag): return "option \(flag) needs a value"
        case .missingArgument(let name): return "missing required argument: <\(name)>"
        }
    }
}

// MARK: - Process result

public struct CLIOutput: Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

// MARK: - Injected environment

/// Narrow read-only view of a `UserDefaults` domain, so path resolution is testable
/// without touching the real preferences store.
public protocol DefaultsReading {
    func stringValue(forKey key: String) -> String?
}

extension UserDefaults: DefaultsReading {
    public func stringValue(forKey key: String) -> String? { string(forKey: key) }
}

public struct CLIContext {
    public var environment: [String: String]
    public var defaults: DefaultsReading?
    public var home: URL
    public var today: Date
    public var calendar: Calendar
    public var randomIDFactory: () -> String

    public init(environment: [String: String],
                defaults: DefaultsReading?,
                home: URL,
                today: Date,
                calendar: Calendar = .current,
                randomIDFactory: @escaping () -> String = TaskIdentity.randomHex8) {
        self.environment = environment
        self.defaults = defaults
        self.home = home
        self.today = today
        self.calendar = calendar
        self.randomIDFactory = randomIDFactory
    }

    /// The context a real process runs in.
    public static func live() -> CLIContext {
        CLIContext(
            environment: ProcessInfo.processInfo.environment,
            defaults: UserDefaults(suiteName: PathResolver.guiSuiteName),
            home: FileManager.default.homeDirectoryForCurrentUser,
            today: Date())
    }
}
