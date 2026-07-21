import Foundation

public struct PluginPageDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let page: PluginPageNode
    public init(schemaVersion: Int, page: PluginPageNode) {
        self.schemaVersion = schemaVersion; self.page = page
    }
}

public struct PluginPageNode: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case page, section, text, taskList, statCard, barChart, button, form
        case textField, picker, toggle, divider, spacer, emptyState
    }

    public struct Query: Codable, Equatable, Sendable {
        public let status: String?
        public let due: String?
        public let limit: Int?
        public init(status: String? = nil, due: String? = nil, limit: Int? = nil) {
            self.status = status; self.due = due; self.limit = limit
        }
    }

    public let type: Kind
    public let id: String
    public let pageID: String?
    public let title: String?
    public let value: String?
    public let query: Query?
    public let action: PluginAction?
    public let children: [PluginPageNode]?

    public init(type: Kind, id: String, pageID: String? = nil, title: String? = nil,
                value: String? = nil, query: Query? = nil, action: PluginAction? = nil,
                children: [PluginPageNode]? = nil) {
        self.type = type; self.id = id; self.pageID = pageID; self.title = title
        self.value = value; self.query = query; self.action = action; self.children = children
    }
}
