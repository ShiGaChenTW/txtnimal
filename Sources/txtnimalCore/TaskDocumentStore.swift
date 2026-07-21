import Foundation
import CryptoKit

public struct TaskDocumentSnapshot: Equatable {
    public var lines: [TaskLine]
    public var scratch: String
    public var archiveLines: [TaskLine]
    public var generation: UInt64
    public var tasksText: String
    public var documentRevision: String

    public init(lines: [TaskLine], scratch: String = "", archiveLines: [TaskLine] = [], generation: UInt64 = 0,
                tasksText: String? = nil) {
        self.lines = lines
        self.scratch = scratch
        self.archiveLines = archiveLines
        self.generation = generation
        let text = tasksText ?? TasksDocument.serialize(lines)
        self.tasksText = text
        self.documentRevision = DocumentRevision.make(for: text)
    }
}
public enum TaskDocumentStoreError: LocalizedError, Equatable {
    case readFailed(String)
    case writeFailed(String)
    case staleSnapshot(expected: UInt64, actual: UInt64)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let path): return "無法讀取 \(path)"
        case .writeFailed(let path): return "無法寫入 \(path)"
        case .staleSnapshot: return "檔案已在外部變更，請重新操作"
        }
    }
}

public struct TaskDocumentJournalEntry: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let tasksText: String
    public let archiveText: String

    public init(transactionID: UUID = UUID(), tasksText: String, archiveText: String) {
        self.transactionID = transactionID
        self.tasksText = tasksText
        self.archiveText = archiveText
    }
}

public protocol TaskDocumentStore {
    func load() throws -> TaskDocumentSnapshot
    func save(lines: [TaskLine], expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func saveScratch(_ text: String) throws
    func archiveCompleted(before todayYMD: String, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
}

/// Filesystem adapter. Failed reads never become empty documents and failed archive
/// writes never remove tasks from the live file.
public final class FileSystemTaskDocumentStore: TaskDocumentStore {
    public let directory: URL
    public let tasksFilename: String
    public var tasksURL: URL { directory.appendingPathComponent(tasksFilename) }
    public var scratchURL: URL { directory.appendingPathComponent("scratch.txt") }
    public var archiveURL: URL { directory.appendingPathComponent("archive.txt") }
    public var journalURL: URL { directory.appendingPathComponent(".txtnimal.journal") }

    private let fm: FileManager
    private var generation: UInt64 = 0

    public init(directory: URL, tasksFilename: String = "tasks.txt", fileManager: FileManager = .default) throws {
        self.directory = directory
        self.tasksFilename = tasksFilename
        self.fm = fileManager
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw TaskDocumentStoreError.writeFailed(directory.path) }
    }

    public func bootstrap(sample: String) throws {
        guard !fm.fileExists(atPath: tasksURL.path) else { return }
        do { try sample.write(to: tasksURL, atomically: true, encoding: .utf8) }
        catch { throw TaskDocumentStoreError.writeFailed(tasksURL.path) }
    }

    public func load() throws -> TaskDocumentSnapshot {
        try recoverPendingTransaction()
        let tasks = try readRequired(tasksURL)
        let scratch = try readOptional(scratchURL)
        let archive = try readOptional(archiveURL)
        generation &+= 1
        return TaskDocumentSnapshot(lines: TasksDocument.parse(tasks), scratch: scratch,
                                    archiveLines: TasksDocument.parse(archive), generation: generation,
                                    tasksText: tasks)
    }

    public func save(lines: [TaskLine], expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireGeneration(expectedGeneration)
        let tasksText = TasksDocument.serialize(lines)
        let archiveText = try readOptional(archiveURL)
        try commit(tasksText: tasksText, archiveText: archiveText)
        generation &+= 1
        return TaskDocumentSnapshot(lines: lines, scratch: try readOptional(scratchURL), archiveLines: TasksDocument.parse(archiveText),
                                    generation: generation, tasksText: tasksText)
    }

    public func saveScratch(_ text: String) throws { try write(text, to: scratchURL) }

    public func archiveCompleted(before todayYMD: String, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireGeneration(expectedGeneration)
        let currentText = try readRequired(tasksURL)
        let current = TasksDocument.parse(currentText)
        let old = current.filter { $0.isDone && ($0.completedDate ?? todayYMD) < todayYMD }
        guard !old.isEmpty else { return try load() }
        let kept = current.filter { !($0.isDone && ($0.completedDate ?? todayYMD) < todayYMD) }
        let previousArchive = try readOptional(archiveURL)
        let moved = old.map(\.raw).joined(separator: "\n") + "\n"
        let archiveText = previousArchive + (previousArchive.isEmpty || previousArchive.hasSuffix("\n") ? "" : "\n") + moved
        let tasksText = TasksDocument.serialize(kept)
        try commit(tasksText: tasksText, archiveText: archiveText)
        generation &+= 1
        return TaskDocumentSnapshot(lines: kept, scratch: try readOptional(scratchURL),
                                    archiveLines: TasksDocument.parse(archiveText), generation: generation,
                                    tasksText: tasksText)
    }

    private func requireGeneration(_ expected: UInt64) throws {
        guard expected == generation else { throw TaskDocumentStoreError.staleSnapshot(expected: expected, actual: generation) }
    }

    private func readRequired(_ url: URL) throws -> String {
        do { return try String(contentsOf: url, encoding: .utf8) }
        catch { throw TaskDocumentStoreError.readFailed(url.path) }
    }

    private func readOptional(_ url: URL) throws -> String {
        guard fm.fileExists(atPath: url.path) else { return "" }
        return try readRequired(url)
    }

    private func write(_ text: String, to url: URL) throws {
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw TaskDocumentStoreError.writeFailed(url.path) }
    }

    private func commit(tasksText: String, archiveText: String) throws {
        let entry = TaskDocumentJournalEntry(tasksText: tasksText, archiveText: archiveText)
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: journalURL, options: .atomic)
            try write(tasksText, to: tasksURL)
            try write(archiveText, to: archiveURL)
            try fm.removeItem(at: journalURL)
        } catch {
            throw TaskDocumentStoreError.writeFailed(directory.path)
        }
    }

    private func recoverPendingTransaction() throws {
        guard fm.fileExists(atPath: journalURL.path) else { return }
        do {
            let data = try Data(contentsOf: journalURL)
            let entry = try JSONDecoder().decode(TaskDocumentJournalEntry.self, from: data)
            try write(entry.tasksText, to: tasksURL)
            try write(entry.archiveText, to: archiveURL)
            try fm.removeItem(at: journalURL)
        } catch {
            throw TaskDocumentStoreError.readFailed(journalURL.path)
        }
    }
}

public enum DocumentRevision {
    public static func make(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
