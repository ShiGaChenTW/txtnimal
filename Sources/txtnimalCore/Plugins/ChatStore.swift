import Darwin
import Foundation

public struct ChatConversation: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var messages: [AgentChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, title: String, messages: [AgentChatMessage], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ChatStoreError: LocalizedError, Equatable, Sendable {
    case invalidData
    case readFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidData: return "chat history data is invalid"
        case .readFailed: return "cannot read chat history"
        case .writeFailed: return "cannot write chat history"
        }
    }
}

public struct ChatStore: Sendable {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("chats.json") }

    public init(directory: URL) {
        self.directory = directory.standardizedFileURL
    }

    public func list() throws -> [ChatConversation] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ChatStoreError.readFailed
        }
        let conversations: [ChatConversation]
        do {
            conversations = try JSONDecoder().decode([ChatConversation].self, from: data)
        } catch {
            throw ChatStoreError.invalidData
        }
        return conversations.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    public func save(_ conversation: ChatConversation) throws {
        var conversations = try list()
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.append(conversation)
        }
        try write(conversations)
    }

    public func delete(id: String) throws {
        let conversations = try list()
        guard conversations.contains(where: { $0.id == id }) else { return }
        try write(conversations.filter { $0.id != id })
    }

    private func write(_ conversations: [ChatConversation]) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(conversations)
            let temporaryURL = directory.appendingPathComponent(".chats-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try data.write(to: temporaryURL)
            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw ChatStoreError.writeFailed
            }
        } catch let error as ChatStoreError {
            throw error
        } catch {
            throw ChatStoreError.writeFailed
        }
    }
}
