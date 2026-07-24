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

public struct PluginManifest: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let apiVersion: Int
    public let entry: String
    public let capabilities: [PluginCapability]
    public let commands: [PluginCommandDeclaration]
    public let pages: [PluginPageDeclaration]

    public init(id: String, name: String, version: String, apiVersion: Int, entry: String,
                capabilities: [PluginCapability], commands: [PluginCommandDeclaration] = [],
                pages: [PluginPageDeclaration] = []) {
        self.id = id; self.name = name; self.version = version; self.apiVersion = apiVersion
        self.entry = entry; self.capabilities = capabilities; self.commands = commands; self.pages = pages
    }
}

public struct PluginTaskSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let due: String?
    public let completed: Bool
    public let lists: [String]
    public let tags: [String]
    public let revision: String

    public init(id: String, title: String, due: String? = nil, completed: Bool = false,
                lists: [String] = [], tags: [String] = [], revision: String) {
        self.id = id; self.title = title; self.due = due; self.completed = completed
        self.lists = lists; self.tags = tags; self.revision = revision
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
    public enum Kind: String, Codable, Sendable { case hostCommand, pluginAction, agentQuery, kvSet }

    public static let kvSetCommand = "storage.kv.set"

    public let type: Kind
    public let command: String
    public let taskIDs: [String]?
    public let title: String?
    public let due: String?
    public let expectedRevision: String?
    public let documentRevision: String?
    public let prompt: String?
    public let resultSchema: String?
    public let key: String?
    public let value: String?

    public init(type: Kind, command: String, taskIDs: [String]? = nil, title: String? = nil, due: String? = nil,
                expectedRevision: String? = nil, documentRevision: String? = nil,
                prompt: String? = nil, resultSchema: String? = nil, key: String? = nil, value: String? = nil) {
        self.type = type; self.command = command; self.taskIDs = taskIDs
        self.title = title
        self.due = due; self.expectedRevision = expectedRevision; self.documentRevision = documentRevision
        self.prompt = prompt; self.resultSchema = resultSchema
        self.key = key; self.value = value
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

    public init(pluginID: String, command: PluginHostCommand, taskIDs: [String], title: String? = nil,
                due: String?, expectedRevision: String?, documentRevision: String?) {
        self.pluginID = pluginID
        self.command = command
        self.taskIDs = taskIDs
        self.title = title
        self.due = due
        self.expectedRevision = expectedRevision
        self.documentRevision = documentRevision
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
