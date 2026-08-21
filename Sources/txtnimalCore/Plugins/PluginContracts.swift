import Foundation

public enum PluginCapability: String, Codable, CaseIterable, Sendable {
    case tasksSelectedRead = "tasks.selected.read"
    case tasksAllRead = "tasks.all.read"
    case tasksCreate = "tasks.create"
    case tasksUpdate = "tasks.update"
    case tasksComplete = "tasks.complete"
    case tasksDelete = "tasks.delete"
    case scratchReadWrite = "scratch.read/write"
    case importRead = "import.read"
    case exportWrite = "export.write"
    case uiPage = "ui.page"
    case uiNotify = "ui.notify"
    case storageKV = "storage.kv"
    case agentQuery = "agent.query"
}

public struct PluginCommandDeclaration: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct PluginPageDeclaration: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let entryFunction: String
    public init(id: String, title: String, entryFunction: String) {
        self.id = id; self.title = title; self.entryFunction = entryFunction
    }
}

/// A single selectable option for a `picker` entry control.
/// `value` is the machine token the host passes to the plugin (e.g. "weekly");
/// `label` is the user-facing zh-Hant string shown in the control.
public struct PluginEntryOption: Codable, Equatable, Sendable {
    public let value: String
    public let label: String
    public init(value: String, label: String) { self.value = value; self.label = label }
}

/// A manifest-declared input the host must collect BEFORE running the plugin's entry function
/// (SCO-174 renders these; SCO-173 only declares/validates them). This abstracts the controls
/// currently hardcoded in `App/Views.swift` — e.g. the task-report `reportType` picker or the
/// reviews-pack `view` picker — into manifest data.
public struct PluginEntryControl: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case picker   // choose one of `options`
        case toggle   // boolean; defaultValue is "true"/"false"
        case textField // free text; defaultValue is the initial string
    }

    public let id: String
    public let type: Kind
    public let label: String
    /// Optional initial value. For `picker` it must match one of `options`' values;
    /// for `toggle` it must be "true"/"false"; for `textField` it is the seed text.
    public let defaultValue: String?
    /// Selectable options — required and non-empty for `picker`, forbidden otherwise.
    public let options: [PluginEntryOption]?

    public init(id: String, type: Kind, label: String,
                defaultValue: String? = nil, options: [PluginEntryOption]? = nil) {
        self.id = id; self.type = type; self.label = label
        self.defaultValue = defaultValue; self.options = options
    }
}

/// Where the host should surface the plugin in chrome, and with what icon.
/// `section` picks the surface, `order` sorts within it (ascending), `icon` is an SF Symbol name.
public struct PluginPlacement: Codable, Equatable, Sendable {
    public enum Section: String, Codable, Sendable {
        case sidebar   // left navigation / command surface
        case reports   // the report / analysis tab
    }

    public let section: Section
    public let order: Int
    public let icon: String?

    public init(section: Section, order: Int, icon: String? = nil) {
        self.section = section; self.order = order; self.icon = icon
    }
}

public struct PluginManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let apiVersion: Int
    public let entry: String
    public let capabilities: [PluginCapability]
    public let commands: [PluginCommandDeclaration]
    public let pages: [PluginPageDeclaration]
    /// SCO-173 additive: inputs the host collects before running the plugin. Optional/nil for
    /// legacy manifests so existing fixtures keep decoding unchanged.
    public let entryControls: [PluginEntryControl]?
    /// SCO-173 additive: where/how the host surfaces this plugin. Optional/nil for legacy manifests.
    public let placement: PluginPlacement?

    public init(id: String, name: String, version: String, apiVersion: Int, entry: String,
                capabilities: [PluginCapability], commands: [PluginCommandDeclaration] = [],
                pages: [PluginPageDeclaration] = [],
                entryControls: [PluginEntryControl]? = nil, placement: PluginPlacement? = nil) {
        self.id = id; self.name = name; self.version = version; self.apiVersion = apiVersion
        self.entry = entry; self.capabilities = capabilities; self.commands = commands; self.pages = pages
        self.entryControls = entryControls; self.placement = placement
    }
}

public struct PluginTaskSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let due: String?
    public let completed: Bool
    public let lists: [String]
    public let tags: [String]
    /// Eisenhower quadrant from the `q:` token, 1-4. `nil` when the line carries no `q:`.
    public let quadrant: Int?
    /// The `created:` date, verbatim. Plugins compute age from it; the host does not validate it.
    public let created: String?
    /// The `note:"..."` body with the quotes stripped, `nil` when absent.
    public let note: String?
    /// The raw `rec:` value, unvalidated — same contract as `TaskLine.recurrence`. Plugins that
    /// act on it must parse it themselves; the host deliberately does not pre-validate here,
    /// so a snapshot never silently differs from the bytes on disk.
    public let recurrence: String?
    /// `focus:true` — a Bool, not an optional: an absent token means false, never "unknown".
    public let focus: Bool
    public let revision: String

    /// The five G-snap fields default to absent so every call site written before they existed
    /// still compiles and still means the same thing.
    public init(id: String, title: String, due: String? = nil, completed: Bool = false,
                lists: [String] = [], tags: [String] = [],
                quadrant: Int? = nil, created: String? = nil, note: String? = nil,
                recurrence: String? = nil, focus: Bool = false,
                revision: String) {
        self.id = id; self.title = title; self.due = due; self.completed = completed
        self.lists = lists; self.tags = tags
        self.quadrant = quadrant; self.created = created; self.note = note
        self.recurrence = recurrence; self.focus = focus
        self.revision = revision
    }
}

public struct PluginDocumentSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let documentRevision: String
    public let tasks: [PluginTaskSnapshot]

    public init(schemaVersion: Int = 1, documentRevision: String, tasks: [PluginTaskSnapshot]) {
        self.schemaVersion = schemaVersion
        self.documentRevision = documentRevision
        self.tasks = tasks
    }
}

public enum PluginHostCommand: String, Codable, Equatable, Sendable {
    case createTask = "tasks.create"
    case rescheduleTask = "tasks.reschedule"
    case rescheduleOverdue = "tasks.rescheduleOverdue"
    case completeTask = "tasks.complete"
    case deleteTask = "tasks.delete"
    case retitleTask = "tasks.retitle"
}

public struct PluginAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case hostCommand, pluginAction, agentQuery, kvSet, exportWrite, importRead }

    public static let kvSetCommand = "storage.kv.set"
    public static let exportWriteCommand = "export.write"
    public static let importReadCommand = "import.read"

    public let type: Kind
    public let command: String
    public let taskIDs: [String]?
    public let title: String?
    public let due: String?
    public let expectedRevision: String?
    public let documentRevision: String?
    public let prompt: String?
    public let resultSchema: String?
    public let lists: [String]?
    public let tags: [String]?
    public let key: String?
    public let value: String?
    public let source: String?
    public let filename: String?
    public let mimeType: String?
    public let content: String?
    public let destination: PluginExportDestination?

    public init(type: Kind, command: String, taskIDs: [String]? = nil, title: String? = nil, due: String? = nil,
                expectedRevision: String? = nil, documentRevision: String? = nil,
                prompt: String? = nil, resultSchema: String? = nil, lists: [String]? = nil, tags: [String]? = nil,
                key: String? = nil, value: String? = nil, source: String? = nil,
                filename: String? = nil, mimeType: String? = nil, content: String? = nil,
                destination: PluginExportDestination? = nil) {
        self.type = type; self.command = command; self.taskIDs = taskIDs
        self.title = title
        self.due = due; self.expectedRevision = expectedRevision; self.documentRevision = documentRevision
        self.prompt = prompt; self.resultSchema = resultSchema
        self.lists = lists; self.tags = tags
        self.key = key; self.value = value; self.source = source
        self.filename = filename; self.mimeType = mimeType; self.content = content; self.destination = destination
    }
}

public struct ValidatedPluginIntent: Equatable, Sendable {
    public let pluginID: String
    public let command: PluginHostCommand
    public let taskIDs: [String]
    public let title: String?
    public let due: String?
    public let expectedRevision: String?
    public let documentRevision: String?
    public let lists: [String]
    public let tags: [String]

    public init(pluginID: String, command: PluginHostCommand, taskIDs: [String], title: String? = nil,
                due: String?, expectedRevision: String?, documentRevision: String?,
                lists: [String] = [], tags: [String] = []) {
        self.pluginID = pluginID
        self.command = command
        self.taskIDs = taskIDs
        self.title = title
        self.due = due
        self.expectedRevision = expectedRevision
        self.documentRevision = documentRevision
        self.lists = lists
        self.tags = tags
    }
}

public struct ValidatedPluginKVWrite: Equatable, Sendable {
    public let pluginID: String
    public let key: String
    public let value: String

    public init(pluginID: String, key: String, value: String) {
        self.pluginID = pluginID
        self.key = key
        self.value = value
    }
}

public struct ValidatedImportRequest: Equatable, Sendable {
    public let pluginID: String
    public let source: String

    public init(pluginID: String, source: String) {
        self.pluginID = pluginID
        self.source = source
    }
}

public struct PluginExportArtifact: Codable, Equatable, Sendable {
    public static let maximumContentBytes = 256 * 1024
    public static let maximumFilenameLength = 255
    public let filename: String
    public let mimeType: String
    public let content: String

    public init(filename: String, mimeType: String, content: String) {
        self.filename = filename
        self.mimeType = mimeType
        self.content = content
    }
}

public enum PluginExportDestination: String, Codable, Equatable, Sendable {
    case file
    case share
}

public struct ValidatedPluginExport: Equatable, Sendable {
    public let pluginID: String
    public let artifact: PluginExportArtifact
    public let destination: PluginExportDestination

    public init(pluginID: String, artifact: PluginExportArtifact, destination: PluginExportDestination) {
        self.pluginID = pluginID
        self.artifact = artifact
        self.destination = destination
    }
}

/// A validated plugin-facing `agent.query`. Carries only the prompt and the requested result schema
/// — never any credential or endpoint config. The host broker turns this into a network call; the
/// plugin never sees the key or URL.
public struct ValidatedAgentQuery: Equatable, Sendable {
    public let pluginID: String
    public let prompt: String
    public let resultSchema: String

    public init(pluginID: String, prompt: String, resultSchema: String) {
        self.pluginID = pluginID
        self.prompt = prompt
        self.resultSchema = resultSchema
    }
}
