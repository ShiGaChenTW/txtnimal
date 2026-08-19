import Foundation
import CryptoKit

public struct TaskDocumentSnapshot: Equatable {
    public var lines: [TaskLine]
    public var scratch: String
    public var archiveLines: [TaskLine]
    public var trashLines: [TaskLine]
    public var generation: UInt64
    public var tasksText: String
    public var documentRevision: String

    public init(lines: [TaskLine], scratch: String = "", archiveLines: [TaskLine] = [],
                trashLines: [TaskLine] = [], generation: UInt64 = 0,
                tasksText: String? = nil) {
        self.lines = lines
        self.scratch = scratch
        self.archiveLines = archiveLines
        self.trashLines = trashLines
        self.generation = generation
        let text = tasksText ?? TasksDocument.serialize(lines)
        self.tasksText = text
        self.documentRevision = DocumentRevision.make(for: text)
    }

    /// Agent-chat apply is keyed on content identity, not the in-memory generation
    /// counter. Returns this snapshot's generation when `expected` still matches;
    /// otherwise throws `staleSnapshot` so a review cannot land on a new document.
    public func generationForMatchingRevision(_ expected: String) throws -> UInt64 {
        guard documentRevision == expected else {
            throw TaskDocumentStoreError.staleSnapshot(expected: generation, actual: generation)
        }
        return generation
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
    /// `nil` means this transaction does not touch `trash.txt`. Same rule as `archiveText`.
    public let trashText: String?

    public init(transactionID: UUID = UUID(), tasksText: String, archiveText: String? = nil,
                trashText: String? = nil) {
        self.transactionID = transactionID
        self.tasksText = tasksText
        self.archiveText = archiveText
        self.trashText = trashText
    }

    // 升級相容:舊版 journal 沒有 transactionID(且 archiveText 必為全文),更舊的沒有 trashText。
    // 解碼失敗會讓 load() 整個炸掉,所以缺欄位時補一顆新 UUID 而不是丟錯。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transactionID = try container.decodeIfPresent(UUID.self, forKey: .transactionID) ?? UUID()
        tasksText = try container.decode(String.self, forKey: .tasksText)
        archiveText = try container.decodeIfPresent(String.self, forKey: .archiveText)
        trashText = try container.decodeIfPresent(String.self, forKey: .trashText)
    }
}

public protocol TaskDocumentStore {
    func load() throws -> TaskDocumentSnapshot
    func save(lines: [TaskLine], expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    /// Write `lines` and move `trashing` into trash.txt in ONE transaction. Used by every
    /// delete path that computes the surviving lines itself (plugin/agent intents).
    func save(lines: [TaskLine], trashing: [TaskLine], deletedYMD: String,
              expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func saveScratch(_ text: String) throws
    func archiveCompleted(before todayYMD: String, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func archiveTask(_ handle: TaskHandle, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func trashTask(_ handle: TaskHandle, deletedYMD: String, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func restoreFromTrash(at index: Int, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func deleteFromTrash(at index: Int, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func emptyTrash(expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
    func purgeExpiredTrash(before cutoffYMD: String, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot
}

/// Filesystem adapter. Failed reads never become empty documents and failed archive
/// writes never remove tasks from the live file.
public final class FileSystemTaskDocumentStore: TaskDocumentStore {
    public let directory: URL
    public let tasksFilename: String
    public var tasksURL: URL { directory.appendingPathComponent(tasksFilename) }
    public var scratchURL: URL { directory.appendingPathComponent("scratch.txt") }
    public var archiveURL: URL { directory.appendingPathComponent("archive.txt") }
    public var trashURL: URL { directory.appendingPathComponent("trash.txt") }
    public var journalURL: URL { directory.appendingPathComponent(".txtnimal.journal") }

    private let fm: FileManager
    private var generation: UInt64 = 0
    /// SHA-256 of the last tasks.txt bytes this store adopted. Used to (a) skip
    /// generation bumps on no-op reloads and (b) reject writes after an unread
    /// external edit, even when `generation` has not moved yet.
    private var lastDocumentRevision: String?

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
        let trash = try readOptional(trashURL)
        adoptContent(tasks)
        return TaskDocumentSnapshot(lines: TasksDocument.parse(tasks), scratch: scratch,
                                    archiveLines: TasksDocument.parse(archive),
                                    trashLines: TasksDocument.parse(trash), generation: generation,
                                    tasksText: tasks)
    }

    public func save(lines: [TaskLine], expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireFresh(expectedGeneration)
        let tasksText = TasksDocument.serialize(lines)
        // Ordinary save never rewrites archive.txt / trash.txt — journal carries nil for both
        // so recovery cannot roll either back to a stale snapshot.
        try commit(tasksText: tasksText, archiveText: nil, trashText: nil)
        adoptContent(tasksText)
        return try snapshot(lines: lines, tasksText: tasksText)
    }

    public func save(lines: [TaskLine], trashing: [TaskLine], deletedYMD: String,
                     expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        // Nothing to trash → this is an ordinary save; don't rewrite trash.txt for no reason.
        guard !trashing.isEmpty else { return try save(lines: lines, expectedGeneration: expectedGeneration) }
        try requireFresh(expectedGeneration)
        let tasksText = TasksDocument.serialize(lines)
        let trashText = try appendingToTrash(trashing, deletedYMD: deletedYMD)
        try commit(tasksText: tasksText, archiveText: nil, trashText: trashText)
        adoptContent(tasksText)
        return try snapshot(lines: lines, tasksText: tasksText, trashText: trashText)
    }

    public func saveScratch(_ text: String) throws { try write(text, to: scratchURL) }

    public func archiveCompleted(before todayYMD: String, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireFresh(expectedGeneration)
        let currentText = try readRequired(tasksURL)
        let current = TasksDocument.parse(currentText)
        let old = current.filter { $0.isDone && ($0.completedDate ?? todayYMD) < todayYMD }
        guard !old.isEmpty else { return try load() }
        let kept = current.filter { !($0.isDone && ($0.completedDate ?? todayYMD) < todayYMD) }
        let previousArchive = try readOptional(archiveURL)
        let moved = old.map(\.raw).joined(separator: "\n") + "\n"
        let archiveText = previousArchive + (previousArchive.isEmpty || previousArchive.hasSuffix("\n") ? "" : "\n") + moved
        let tasksText = TasksDocument.serialize(kept)
        try commit(tasksText: tasksText, archiveText: archiveText, trashText: nil)
        adoptContent(tasksText)
        return try snapshot(lines: kept, tasksText: tasksText, archiveText: archiveText)
    }

    public func archiveTask(_ handle: TaskHandle, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireFresh(expectedGeneration)
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
        try commit(tasksText: tasksText, archiveText: archiveText, trashText: nil)
        adoptContent(tasksText)
        return try snapshot(lines: current, tasksText: tasksText, archiveText: archiveText)
    }

    // MARK: - trash.txt
    //
    // A third sibling file with exactly archive.txt's protected-commit shape: the journal
    // carries the whole intended trash text, trash.txt lands BEFORE tasks.txt, and a nil
    // `trashText` means "this transaction does not touch trash.txt". A failed trash write
    // therefore leaves the task in tasks.txt — deleting can lose the trash copy, never the task.

    /// Move one live task into trash.txt, stamping `deleted:`. Mirrors `archiveTask`.
    public func trashTask(_ handle: TaskHandle, deletedYMD: String,
                          expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireFresh(expectedGeneration)
        guard handle.generation == expectedGeneration else {
            throw TaskDocumentStoreError.staleSnapshot(expected: handle.generation, actual: expectedGeneration)
        }
        let currentText = try readRequired(tasksURL)
        var current = TasksDocument.parse(currentText)
        guard current.indices.contains(handle.index), !current[handle.index].isBlank else {
            throw TaskWorkspaceError.missingTask
        }
        let removed = current.remove(at: handle.index)
        let trashText = try appendingToTrash([removed], deletedYMD: deletedYMD)
        let tasksText = TasksDocument.serialize(current)
        try commit(tasksText: tasksText, archiveText: nil, trashText: trashText)
        adoptContent(tasksText)
        return try snapshot(lines: current, tasksText: tasksText, trashText: trashText)
    }

    /// Move one trashed line back into tasks.txt, clearing `deleted:`. Every other token —
    /// `id:`, `due:`, `+project`, `@context`, unknown keys — comes back verbatim.
    public func restoreFromTrash(at index: Int, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireFresh(expectedGeneration)
        var trash = TasksDocument.parse(try readOptional(trashURL))
        guard trash.indices.contains(index), !trash[index].isBlank else { throw TaskWorkspaceError.missingTask }
        var restored = trash.remove(at: index)
        restored.setDeleted(nil)

        var lines = TasksDocument.parse(try readRequired(tasksURL))
        // Insert after the last real task so an existing trailing blank line stays trailing.
        let insertion = (lines.lastIndex { !$0.isBlank }).map { $0 + 1 } ?? lines.count
        lines.insert(restored, at: insertion)

        let tasksText = TasksDocument.serialize(lines)
        let trashText = serializeTrash(trash)
        try commit(tasksText: tasksText, archiveText: nil, trashText: trashText)
        adoptContent(tasksText)
        return try snapshot(lines: lines, tasksText: tasksText, trashText: trashText)
    }

    /// Permanently drop one trashed line. tasks.txt is untouched.
    public func deleteFromTrash(at index: Int, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireFresh(expectedGeneration)
        var trash = TasksDocument.parse(try readOptional(trashURL))
        guard trash.indices.contains(index), !trash[index].isBlank else { throw TaskWorkspaceError.missingTask }
        trash.remove(at: index)
        return try commitTrashOnly(serializeTrash(trash))
    }

    public func emptyTrash(expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireFresh(expectedGeneration)
        return try commitTrashOnly("")
    }

    /// Drop every trashed line whose `deleted:` date is older than `cutoffYMD`. A no-op
    /// (no write at all) when nothing has expired, so the daily sweep is free.
    public func purgeExpiredTrash(before cutoffYMD: String, expectedGeneration: UInt64) throws -> TaskDocumentSnapshot {
        try requireFresh(expectedGeneration)
        let trash = TasksDocument.parse(try readOptional(trashURL))
        let kept = trash.filter { !Trash.isExpired($0, cutoffYMD: cutoffYMD) }
        guard kept.count != trash.count else { return try load() }
        return try commitTrashOnly(serializeTrash(kept))
    }

    /// Rewrite trash.txt alone, replaying the CURRENT tasks.txt bytes unchanged so the journal
    /// stays a complete description of the intended on-disk state.
    private func commitTrashOnly(_ trashText: String) throws -> TaskDocumentSnapshot {
        let tasksText = try readRequired(tasksURL)
        try commit(tasksText: tasksText, archiveText: nil, trashText: trashText)
        adoptContent(tasksText)
        return try snapshot(lines: TasksDocument.parse(tasksText), tasksText: tasksText, trashText: trashText)
    }

    /// Existing trash.txt with `lines` appended, each stamped `deleted:<deletedYMD>`.
    private func appendingToTrash(_ lines: [TaskLine], deletedYMD: String) throws -> String {
        let previous = try readOptional(trashURL)
        let separator = previous.isEmpty || previous.hasSuffix("\n") ? "" : "\n"
        let stamped = lines.filter { !$0.isBlank }.map { line -> String in
            var copy = line
            copy.setDeleted(deletedYMD)
            return copy.raw
        }
        guard !stamped.isEmpty else { return previous }
        return previous + separator + stamped.joined(separator: "\n") + "\n"
    }

    /// trash.txt is a plain line list; keep the trailing newline so appends stay clean.
    private func serializeTrash(_ lines: [TaskLine]) -> String {
        let raws = lines.filter { !$0.isBlank }.map(\.raw)
        return raws.isEmpty ? "" : raws.joined(separator: "\n") + "\n"
    }

    /// Snapshot builder — reads back whichever sibling files this transaction did not rewrite.
    private func snapshot(lines: [TaskLine], tasksText: String,
                          archiveText: String? = nil, trashText: String? = nil) throws -> TaskDocumentSnapshot {
        let archive = try archiveText ?? readOptional(archiveURL)
        let trash = try trashText ?? readOptional(trashURL)
        return TaskDocumentSnapshot(lines: lines, scratch: try readOptional(scratchURL),
                                    archiveLines: TasksDocument.parse(archive),
                                    trashLines: TasksDocument.parse(trash), generation: generation,
                                    tasksText: tasksText)
    }

    private func requireGeneration(_ expected: UInt64) throws {
        guard expected == generation else { throw TaskDocumentStoreError.staleSnapshot(expected: expected, actual: generation) }
    }

    /// Rejects both a stale in-memory generation and an unread external edit.
    /// Disk bytes are compared via `documentRevision` so an old handle cannot
    /// land on a different task at the same index after the file was rewritten.
    private func requireFresh(_ expected: UInt64) throws {
        try requireGeneration(expected)
        let diskText = try readRequired(tasksURL)
        let diskRevision = DocumentRevision.make(for: diskText)
        if let lastDocumentRevision, lastDocumentRevision != diskRevision {
            throw TaskDocumentStoreError.staleSnapshot(expected: expected, actual: generation)
        }
    }

    /// Bump `generation` only when tasks.txt content actually changed.
    private func adoptContent(_ tasksText: String) {
        let revision = DocumentRevision.make(for: tasksText)
        if lastDocumentRevision != revision {
            generation &+= 1
            lastDocumentRevision = revision
        }
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

    private func commit(tasksText: String, archiveText: String?, trashText: String?) throws {
        let entry = TaskDocumentJournalEntry(tasksText: tasksText, archiveText: archiveText, trashText: trashText)
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: journalURL, options: .atomic)
            // 不變量:archive/trash 寫入失敗絕不能移除 live 任務——先落側檔,成功後才改 live。
            // 側檔失敗時 tasks.txt 原封不動,journal 留待下次 load() 重放。
            // nil = 本交易不動該側檔（普通 save）。
            if let archiveText {
                try write(archiveText, to: archiveURL)
            }
            if let trashText {
                try write(trashText, to: trashURL)
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
            // 與 commit 同序:有側檔才先寫側檔,再改 live。nil = 不動該側檔,
            // 避免把較新的 archive/trash 回滾成 journal 裡的舊快照。
            if let archiveText = entry.archiveText {
                try write(archiveText, to: archiveURL)
            }
            if let trashText = entry.trashText {
                try write(trashText, to: trashURL)
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
