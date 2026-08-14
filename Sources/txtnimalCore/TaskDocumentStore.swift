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
    /// `nil` means this transaction does not touch `archive.txt`.
    public let archiveText: String?

    public init(transactionID: UUID = UUID(), tasksText: String, archiveText: String? = nil) {
        self.transactionID = transactionID
        self.tasksText = tasksText
        self.archiveText = archiveText
    }

    // 升級相容:舊版 journal 沒有 transactionID(且 archiveText 必為全文)。
    // 解碼失敗會讓 load() 整個炸掉,所以缺欄位時補一顆新 UUID 而不是丟錯。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionID = try container.decodeIfPresent(UUID.self, forKey: .transactionID) ?? UUID()
        tasksText = try container.decode(String.self, forKey: .tasksText)
        archiveText = try container.decodeIfPresent(String.self, forKey: .archiveText)
    }
}

public protocol TaskDocumentStore {
    func load() throws -> TaskDocumentSnapshot
    func save(lines: [TaskLine], expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func saveScratch(_ text: String) throws
    func archiveCompleted(before todayYMD: String, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func archiveTask(_ handle: TaskHandle, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
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
        // Ordinary save never rewrites archive.txt — journal carries nil archiveText
        // so recovery cannot roll archive back to a stale snapshot.
        try commit(tasksText: tasksText, archiveText: nil)
        generation &+= 1
        let archiveText = try readOptional(archiveURL)
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

    public func archiveTask(_ handle: TaskHandle, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireGeneration(expectedGeneration)
        guard handle.generation == expectedGeneration else {
            throw TaskDocumentStoreError.staleSnapshot(expected: handle.generation, actual: expectedGeneration)
        }
        let currentText = try readRequired(tasksURL)
        var current = TasksDocument.parse(currentText)
        guard current.indices.contains(handle.index), !current[handle.index].isBlank else {
            throw TaskWorkspaceError.missingTask
        }
        let archivedRaw = current.remove(at: handle.index).raw
        let previousArchive = try readOptional(archiveURL)
        let separator = previousArchive.isEmpty || previousArchive.hasSuffix("\n") ? "" : "\n"
        let archiveText = previousArchive + separator + archivedRaw + "\n"
        let tasksText = TasksDocument.serialize(current)
        try commit(tasksText: tasksText, archiveText: archiveText)
        generation &+= 1
        return TaskDocumentSnapshot(lines: current, scratch: try readOptional(scratchURL),
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

    private func commit(tasksText: String, archiveText: String?) throws {
        let entry = TaskDocumentJournalEntry(tasksText: tasksText, archiveText: archiveText)
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: journalURL, options: .atomic)
            // 不變量:archive 寫入失敗絕不能移除 live 任務——先落 archive,成功後才改 live。
            // archive 失敗時 tasks.txt 原封不動,journal 留待下次 load() 重放。
            // nil archiveText = 本交易不動 archive（普通 save）。
            if let archiveText {
                try write(archiveText, to: archiveURL)
            }
            try write(tasksText, to: tasksURL)
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
            // 與 commit 同序:有 archive 才先寫 archive,再改 live。nil = 不動 archive,
            // 避免把較新的 archive 回滾成 journal 裡的舊快照。
            if let archiveText = entry.archiveText {
                try write(archiveText, to: archiveURL)
            }
            try write(entry.tasksText, to: tasksURL)
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
