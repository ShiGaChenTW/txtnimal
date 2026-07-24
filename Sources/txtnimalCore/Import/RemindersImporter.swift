import Foundation

public struct ImportProposal: Equatable, Sendable {
    public let sourceId: String
    public let rawLine: String
    public let title: String
    public let due: String?

    public init(sourceId: String, rawLine: String, title: String, due: String?) {
        self.sourceId = sourceId
        self.rawLine = rawLine
        self.title = title
        self.due = due
    }
}

public struct RemindersImporter: Sendable {
    public struct Options: Sendable {
        public var includeCompleted: Bool

        public init(includeCompleted: Bool = false) {
            self.includeCompleted = includeCompleted
        }
    }

    public init() {}

    public func plan(from source: RemindersSource,
                     today: Date,
                     options: Options = .init(),
                     calendar: Calendar = .current) async throws -> [ImportProposal] {
        let items = try await source.fetch()
        return items.compactMap { item in
            if item.completed && !options.includeCompleted {
                return nil
            }

            let sanitizedTitle = TaskLine.sanitizedTitle(item.title)
            if sanitizedTitle.isEmpty {
                return nil
            }

            let rawLine = ImportMapper.todoTxtLine(for: item, today: today, calendar: calendar)
            let normalized = TaskLine(rawLine)
            return ImportProposal(sourceId: item.sourceId, rawLine: rawLine, title: sanitizedTitle, due: normalized.due)
        }
    }
}
