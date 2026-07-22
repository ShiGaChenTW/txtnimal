import Foundation

public struct PluginLimits: Equatable, Sendable {
    public var maximumManifestBytes = 64 * 1024
    public var maximumPayloadBytes = 256 * 1024
    public var maximumNodes = 200
    public var maximumDepth = 8
    public var maximumQueryResults = 100
    public init(maximumManifestBytes: Int = 64 * 1024, maximumPayloadBytes: Int = 256 * 1024, maximumNodes: Int = 200,
                maximumDepth: Int = 8, maximumQueryResults: Int = 100) {
        self.maximumManifestBytes = maximumManifestBytes; self.maximumPayloadBytes = maximumPayloadBytes; self.maximumNodes = maximumNodes
        self.maximumDepth = maximumDepth; self.maximumQueryResults = maximumQueryResults
    }
}

public enum PluginValidationError: String, Error, Equatable, LocalizedError, Sendable {
    case incompatibleAPIVersion
    case incompatibleSchemaVersion
    case invalidIdentifier
    case duplicateIdentifier
    case invalidEntryPath
    case missingCapability
    case invalidAction
    case staleDocument
    case invalidPageRoot
    case invalidNode
    case payloadTooLarge
    case nodeLimitExceeded
    case depthLimitExceeded
    case queryLimitExceeded

    public var errorDescription: String? { rawValue }
}

public enum PluginValidator {
    public static let supportedAPIVersion = 1
    public static let supportedSchemaVersion = 1

    public static func decodeManifest(_ data: Data, limits: PluginLimits = .init()) throws -> PluginManifest {
        guard data.count <= limits.maximumManifestBytes else { throw PluginValidationError.payloadTooLarge }
        try PluginJSON.rejectDuplicateKeys(data)
        try validateManifestKeys(data)
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        try validate(manifest)
        return manifest
    }

    public static func validate(_ manifest: PluginManifest) throws {
        guard manifest.apiVersion == supportedAPIVersion else { throw PluginValidationError.incompatibleAPIVersion }
        guard isReverseDNS(manifest.id), isSemanticVersion(manifest.version) else { throw PluginValidationError.invalidIdentifier }
        guard isSafeRelativeEntry(manifest.entry) else { throw PluginValidationError.invalidEntryPath }
        let commandIDs = manifest.commands.map(\.id)
        let pageIDs = manifest.pages.map(\.id)
        guard Set(commandIDs).count == commandIDs.count, Set(pageIDs).count == pageIDs.count else {
            throw PluginValidationError.duplicateIdentifier
        }
        guard (commandIDs + pageIDs).allSatisfy(isScopedIdentifier) else {
            throw PluginValidationError.invalidIdentifier
        }
        if !manifest.pages.isEmpty && !Set(manifest.capabilities).contains(.uiPage) {
            throw PluginValidationError.missingCapability
        }
    }

    public static func resolveEntry(_ entry: String, in packageRoot: URL,
                                    fileManager: FileManager = .default) throws -> URL {
        guard isSafeRelativeEntry(entry) else { throw PluginValidationError.invalidEntryPath }
        let root = packageRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = packageRoot.appendingPathComponent(entry).standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix), fileManager.fileExists(atPath: candidate.path) else {
            throw PluginValidationError.invalidEntryPath
        }
        let values = try candidate.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw PluginValidationError.invalidEntryPath }
        return candidate
    }

    public static func decodePage(_ data: Data, manifest: PluginManifest,
                                  limits: PluginLimits = .init()) throws -> PluginPageDocument {
        guard data.count <= limits.maximumPayloadBytes else { throw PluginValidationError.payloadTooLarge }
        try PluginJSON.rejectDuplicateKeys(data)
        try validatePageKeys(data)
        let page = try JSONDecoder().decode(PluginPageDocument.self, from: data)
        try validate(page, manifest: manifest, limits: limits)
        return page
    }

    public static func validate(_ document: PluginPageDocument, manifest: PluginManifest,
                                limits: PluginLimits = .init()) throws {
        guard document.schemaVersion == supportedSchemaVersion else {
            throw PluginValidationError.incompatibleSchemaVersion
        }
        guard document.page.type == .page, let pageID = document.page.pageID,
              manifest.pages.contains(where: { $0.id == pageID }),
              Set(manifest.capabilities).contains(.uiPage) else {
            throw PluginValidationError.invalidPageRoot
        }
        var nodeCount = 0
        var ids = Set<String>()
        try validateNode(document.page, depth: 1, isRoot: true, count: &nodeCount, ids: &ids,
                         manifest: manifest, limits: limits)
    }

    public static func validate(action: PluginAction, manifest: PluginManifest,
                                taskRevisions: [String: String]? = nil,
                                documentRevision: String? = nil,
                                limits: PluginLimits = .init()) throws -> ValidatedPluginIntent {
        if let expected = action.documentRevision {
            guard let current = documentRevision, expected == current else {
                throw PluginValidationError.staleDocument
            }
        }
        guard action.type == .hostCommand, let command = PluginHostCommand(rawValue: action.command) else {
            throw PluginValidationError.invalidAction
        }
        let taskIDs = action.taskIDs ?? []
        let title = action.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch command {
        case .createTask:
            guard Set(manifest.capabilities).contains(.tasksCreate) else {
                throw PluginValidationError.missingCapability
            }
            guard taskIDs.isEmpty, let title, !title.isEmpty,
                  action.due.map(isISODate) ?? true else {
                throw PluginValidationError.invalidAction
            }
        case .rescheduleTask:
            guard Set(manifest.capabilities).contains(.tasksUpdate) else {
                throw PluginValidationError.missingCapability
            }
            guard !taskIDs.isEmpty, taskIDs.count <= limits.maximumQueryResults,
                  Set(taskIDs).count == taskIDs.count, taskIDs.allSatisfy(isScopedIdentifier),
                  let due = action.due, isISODate(due), let expected = action.expectedRevision,
                  taskRevisions.map({ revisions in taskIDs.allSatisfy { revisions[$0] == expected } }) ?? true else {
                throw PluginValidationError.invalidAction
            }
        case .rescheduleOverdue:
            guard Set(manifest.capabilities).contains(.tasksUpdate) else {
                throw PluginValidationError.missingCapability
            }
            guard taskIDs.isEmpty, action.due == nil, let expected = action.expectedRevision,
                  documentRevision.map({ expected == $0 }) ?? true else { throw PluginValidationError.invalidAction }
        }
        return ValidatedPluginIntent(pluginID: manifest.id, command: command, taskIDs: taskIDs,
                                     title: title, due: action.due, expectedRevision: action.expectedRevision,
                                     documentRevision: action.documentRevision)
    }

    public static func validateAgentQuery(action: PluginAction, manifest: PluginManifest,
                                          limits: PluginLimits = .init()) throws {
        guard Set(manifest.capabilities).contains(.agentQuery) else {
            throw PluginValidationError.missingCapability
        }
        let taskIDs = action.taskIDs ?? []
        guard action.type == .agentQuery, action.command == PluginCapability.agentQuery.rawValue,
              let prompt = action.prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let schema = action.resultSchema, !schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expectedRevision = action.expectedRevision, !expectedRevision.isEmpty,
              !taskIDs.isEmpty, taskIDs.count <= limits.maximumQueryResults,
              Set(taskIDs).count == taskIDs.count, taskIDs.allSatisfy(isScopedIdentifier) else {
            throw PluginValidationError.invalidAction
        }
    }

    private static func validateNode(_ node: PluginPageNode, depth: Int, isRoot: Bool,
                                     count: inout Int,
                                     ids: inout Set<String>, manifest: PluginManifest,
                                     limits: PluginLimits) throws {
        guard depth <= limits.maximumDepth else { throw PluginValidationError.depthLimitExceeded }
        count += 1
        guard count <= limits.maximumNodes else { throw PluginValidationError.nodeLimitExceeded }
        guard isScopedIdentifier(node.id), ids.insert(node.id).inserted else {
            throw PluginValidationError.duplicateIdentifier
        }
        guard (isRoot && node.type == .page) || (!isRoot && node.type != .page) else {
            throw PluginValidationError.invalidNode
        }
        if let query = node.query {
            let limit = query.limit ?? limits.maximumQueryResults
            let statuses: Set<String> = ["open", "completed"]
            let dueValues: Set<String> = ["overdue", "today", "upcoming", "none"]
            guard (1...limits.maximumQueryResults).contains(limit),
                  query.status.map(statuses.contains) ?? true,
                  query.due.map(dueValues.contains) ?? true else {
                throw PluginValidationError.queryLimitExceeded
            }
        }
        try validateFields(of: node)
        if let action = node.action { _ = try validate(action: action, manifest: manifest) }
        let containerKinds: Set<PluginPageNode.Kind> = [.page, .section, .form]
        if !(node.children ?? []).isEmpty && !containerKinds.contains(node.type) {
            throw PluginValidationError.invalidNode
        }
        for child in node.children ?? [] {
            try validateNode(child, depth: depth + 1, isRoot: false, count: &count, ids: &ids,
                             manifest: manifest, limits: limits)
        }
    }

    private static func validateManifestKeys(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginValidationError.invalidNode
        }
        try requireOnly(Set(object.keys), allowed: ["id", "name", "version", "apiVersion", "entry", "capabilities", "commands", "pages"])
        guard let commands = object["commands"] as? [[String: Any]],
              let pages = object["pages"] as? [[String: Any]],
              object["capabilities"] is [String] else { throw PluginValidationError.invalidNode }
        for command in commands {
            try requireOnly(Set(command.keys), allowed: ["id", "title"])
        }
        for page in pages {
            try requireOnly(Set(page.keys), allowed: ["id", "title", "entryFunction"])
        }
    }

    private static func validatePageKeys(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let page = object["page"] as? [String: Any] else {
            throw PluginValidationError.invalidNode
        }
        try requireOnly(Set(object.keys), allowed: ["schemaVersion", "page"])
        try validateNodeKeys(page)
    }

    private static func validateNodeKeys(_ node: [String: Any]) throws {
        try requireOnly(Set(node.keys), allowed: ["type", "id", "pageID", "title", "value", "query", "action", "children"])
        if node.keys.contains("query"), !(node["query"] is [String: Any]) { throw PluginValidationError.invalidNode }
        if let query = node["query"] as? [String: Any] {
            try requireOnly(Set(query.keys), allowed: ["status", "due", "limit"])
        }
        if node.keys.contains("action"), !(node["action"] is [String: Any]) { throw PluginValidationError.invalidNode }
        if let action = node["action"] as? [String: Any] {
            try requireOnly(Set(action.keys), allowed: ["type", "command", "taskIDs", "title", "due", "expectedRevision", "documentRevision", "prompt", "resultSchema"])
        }
        if node.keys.contains("children"), !(node["children"] is [[String: Any]]) { throw PluginValidationError.invalidNode }
        for child in node["children"] as? [[String: Any]] ?? [] { try validateNodeKeys(child) }
    }

    private static func requireOnly(_ actual: Set<String>, allowed: Set<String>) throws {
        guard actual.isSubset(of: allowed) else { throw PluginValidationError.invalidNode }
    }

    private static func isReverseDNS(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy {
            let part = String($0)
            return !part.hasPrefix("-") && !part.hasSuffix("-") && !part.contains("_") && isScopedIdentifier(part)
        }
    }

    private static func isScopedIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 80 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeRelativeEntry(_ value: String) -> Bool {
        guard !value.isEmpty, !NSString(string: value).isAbsolutePath else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isSemanticVersion(_ value: String) -> Bool {
        let core = value.split(separator: "+", maxSplits: 1)[0].split(separator: "-", maxSplits: 1)[0]
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { Int($0) != nil }
    }

    private static func isISODate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private static func validateFields(of node: PluginPageNode) throws {
        switch node.type {
        case .page:
            guard node.pageID != nil, node.query == nil, node.action == nil else { throw PluginValidationError.invalidNode }
        case .section, .form:
            guard node.pageID == nil, node.query == nil, node.action == nil else { throw PluginValidationError.invalidNode }
        case .taskList:
            guard node.query != nil, node.pageID == nil, node.action == nil else { throw PluginValidationError.invalidNode }
        case .button:
            guard node.action != nil, node.title != nil, node.pageID == nil, node.query == nil else { throw PluginValidationError.invalidNode }
        case .barChart:
            let values = (node.value ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard !values.isEmpty, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  node.pageID == nil, node.query == nil, node.action == nil else { throw PluginValidationError.invalidNode }
        default:
            guard node.pageID == nil, node.query == nil, node.action == nil else { throw PluginValidationError.invalidNode }
        }
    }
}
