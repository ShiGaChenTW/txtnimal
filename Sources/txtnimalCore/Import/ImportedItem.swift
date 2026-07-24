import Foundation

public struct ImportedItem: Equatable, Sendable {
    public let title: String
    public let due: String?
    public let list: String?
    public let tags: [String]
    public let notes: String?
    public let completed: Bool
    public let sourceId: String

    public init(title: String,
                due: String? = nil,
                list: String? = nil,
                tags: [String] = [],
                notes: String? = nil,
                completed: Bool = false,
                sourceId: String) {
        self.title = title
        self.due = due
        self.list = list
        self.tags = tags
        self.notes = notes
        self.completed = completed
        self.sourceId = sourceId
    }
}

public protocol RemindersSource: Sendable {
    func fetch() async throws -> [ImportedItem]
}
