import Foundation
import XCTest
@testable import txtnimalCore

final class ChatStoreTests: XCTestCase {
    func testMissingFileListsEmpty() throws {
        try withStore { store, _ in
            XCTAssertEqual(try store.list(), [])
        }
    }

    func testSaveAndListRoundTripSortedNewestFirst() throws {
        try withStore { store, _ in
            let older = conversation(id: "older", title: "Older", updatedAt: Date(timeIntervalSince1970: 100))
            let newer = conversation(id: "newer", title: "Newer", updatedAt: Date(timeIntervalSince1970: 200))

            try store.save(older)
            try store.save(newer)

            XCTAssertEqual(try store.list(), [newer, older])
        }
    }

    func testSaveUpsertsByID() throws {
        try withStore { store, _ in
            let original = conversation(id: "same", title: "Original", updatedAt: Date(timeIntervalSince1970: 100))
            var replacement = original
            replacement.title = "Replacement"
            replacement.messages.append(.init(role: .assistant, content: "Reply"))
            replacement.updatedAt = Date(timeIntervalSince1970: 200)

            try store.save(original)
            try store.save(replacement)

            XCTAssertEqual(try store.list(), [replacement])
        }
    }

    func testDeleteRemovesOnlyMatchingConversation() throws {
        try withStore { store, _ in
            let kept = conversation(id: "kept", title: "Kept", updatedAt: Date(timeIntervalSince1970: 100))
            let deleted = conversation(id: "deleted", title: "Deleted", updatedAt: Date(timeIntervalSince1970: 200))
            try store.save(kept)
            try store.save(deleted)

            try store.delete(id: deleted.id)

            XCTAssertEqual(try store.list(), [kept])
        }
    }

    func testMalformedJSONThrowsInvalidDataWithoutOverwritingFile() throws {
        try withStore { store, directory in
            let url = directory.appendingPathComponent("chats.json")
            let malformed = Data("not-json".utf8)
            try malformed.write(to: url)

            XCTAssertThrowsError(try store.list()) { error in
                XCTAssertEqual(error as? ChatStoreError, .invalidData)
            }
            XCTAssertEqual(try Data(contentsOf: url), malformed)
        }
    }

    private func conversation(id: String, title: String, updatedAt: Date) -> ChatConversation {
        ChatConversation(
            id: id,
            title: title,
            messages: [.init(role: .user, content: title)],
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt
        )
    }

    private func withStore(_ operation: (ChatStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("txtnimal-chat-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(ChatStore(directory: directory), directory)
    }
}
