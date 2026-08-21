import XCTest
@testable import txtnimalCore

/// Stable task identity (`id:` token) — generation at capture, lazy backfill at save,
/// and silent collision repair. Mirrors the `Note.makeID()` precedent with a `t` prefix
/// so a task id is never mistaken for a note id at a glance.
/// Named for the `stableID` accessor rather than "identity" — `txtnimalCLICore` already has a
/// `TaskIdentity` (addressing/prefix resolution) with a test class of that name.
final class TaskStableIDTests: XCTestCase {

    private let shape = "^t[0-9a-f]{8}$"

    private func assertTaskID(_ id: String?, _ message: String = "", file: StaticString = #filePath,
                              line: UInt = #line) {
        let value = id ?? ""
        XCTAssertNotNil(value.range(of: shape, options: .regularExpression),
                        "\(message) — \(value) is not a t+8-hex id", file: file, line: line)
    }

    private func makeStore() throws -> (FileSystemTaskDocumentStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try FileSystemTaskDocumentStore(directory: dir), dir)
    }

    // MARK: - Generator

    func testMakeIDHasTaskPrefixAndIsUnique() {
        var seen = Set<String>()
        for _ in 0..<500 {
            let id = TaskLine.makeID()
            assertTaskID(id, "generated id")
            XCTAssertTrue(seen.insert(id).inserted, "makeID repeated \(id)")
        }
        // Visually distinguishable from the note precedent it copies.
        XCTAssertTrue(Note.makeID().hasPrefix("n"))
    }

    // MARK: - ISC-1: assigned at capture, before any save

    func testCaptureStampsStableIDBeforeAnySave() throws {
        let raw = try XCTUnwrap(Capture.makeTaskLine(from: "Call bank due:2026-07-10 +personal",
                                                     today: Date(), createdYMD: "2026-07-09"))
        let line = TaskLine(raw)
        assertTaskID(line.stableID, "captured task")
        // Identity is metadata, not title text, and everything typed still survives.
        XCTAssertEqual(line.title, "Call bank")
        XCTAssertEqual(line.projects, ["personal"])
        XCTAssertEqual(line.created, "2026-07-09")
    }

    func testCaptureKeepsAnIDTheUserTypedHimself() throws {
        let raw = try XCTUnwrap(Capture.makeTaskLine(from: "Ship it id:tabcdef12", today: Date(),
                                                     createdYMD: "2026-07-09"))
        XCTAssertEqual(TaskLine(raw).stableID, "tabcdef12")
    }

    func testCaptureIDGeneratorIsInjectableForDeterministicOutput() {
        XCTAssertEqual(Capture.makeTaskLine(from: "Just a task", today: Date(), createdYMD: "2026-07-09",
                                            makeID: { "t00000001" }),
                       "Just a task created:2026-07-09 id:t00000001")
    }

    // MARK: - ISC-2: lazy backfill on save

    func testSaveBackfillsMissingIDsAndPersistsThem() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.bootstrap(sample: "alpha +work\nbeta due:2026-08-01")
        let loaded = try store.load()
        XCTAssertNil(loaded.lines[0].stableID, "legacy file must load untouched")

        let saved = try store.save(lines: loaded.lines, expectedGeneration: loaded.generation)
        assertTaskID(saved.lines[0].stableID, "first line")
        assertTaskID(saved.lines[1].stableID, "second line")

        let onDisk = try String(contentsOf: store.tasksURL, encoding: .utf8)
        XCTAssertEqual(TasksDocument.parse(onDisk).map(\.stableID), saved.lines.map(\.stableID),
                       "in-memory snapshot and tasks.txt must agree")
        XCTAssertTrue(onDisk.contains("id:"), "id must reach the file, not just memory")
    }

    func testLoadAloneNeverStampsIDs() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = "alpha\nbeta"
        try store.bootstrap(sample: text)
        _ = try store.load()
        XCTAssertEqual(try String(contentsOf: store.tasksURL, encoding: .utf8), text,
                       "backfill is save-time, not a load-time sweep")
    }

    func testBackfillReachesEveryWritePathThatRewritesTasks() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.bootstrap(sample: "keep me\ntrash me")
        let loaded = try store.load()
        let trashed = try store.trashTask(TaskHandle(generation: loaded.generation, index: 1),
                                          deletedYMD: "2026-08-19", expectedGeneration: loaded.generation)
        assertTaskID(trashed.lines[0].stableID, "survivor of a trash transaction")

        let restored = try store.restoreFromTrash(at: 0, expectedGeneration: trashed.generation)
        XCTAssertEqual(restored.lines.filter { !$0.isBlank }.count, 2)
        let ids = restored.lines.filter { !$0.isBlank }.compactMap(\.stableID)
        XCTAssertEqual(ids.count, 2, "restored line is stamped too")
        XCTAssertEqual(Set(ids).count, 2)
    }

    // MARK: - ISC-3: duplicate ids repaired silently

    func testSaveResolvesDuplicateIDsWithoutLosingData() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A copy-pasted line: same id:, twice.
        try store.bootstrap(sample: "alpha id:tdeadbeef\nalpha id:tdeadbeef\ngamma id:tfeedface")
        let loaded = try store.load()

        let saved = try store.save(lines: loaded.lines, expectedGeneration: loaded.generation)

        let live = saved.lines.filter { !$0.isBlank }
        XCTAssertEqual(live.count, 3, "no line may be dropped to fix identity")
        XCTAssertEqual(live.map(\.title), ["alpha", "alpha", "gamma"])
        let ids = live.compactMap(\.stableID)
        XCTAssertEqual(Set(ids).count, 3, "every task ends up with a distinct id")
        XCTAssertEqual(ids[0], "tdeadbeef", "the first holder keeps the contested id")
        assertTaskID(ids[1], "re-stamped duplicate")
        XCTAssertEqual(ids[2], "tfeedface", "an uninvolved line is not disturbed")
        // The repair is silent: the save above returned a snapshot instead of throwing.
        XCTAssertFalse(saved.documentRevision.isEmpty)
    }

    func testRegeneratedIDNeverStealsAnIDAlreadyOwnedFurtherDown() {
        // The generator is rigged to hand out an id that line 3 already owns; the resolver
        // must skip it rather than evict the rightful holder.
        var queue = ["tfeedface", "t99999999"]
        let lines = TasksDocument.parse("alpha id:tdeadbeef\nbeta id:tdeadbeef\ngamma id:tfeedface")
        let out = TasksDocument.withUniqueIDs(lines, makeID: { queue.removeFirst() })
        XCTAssertEqual(out.map(\.stableID), ["tdeadbeef", "t99999999", "tfeedface"])
    }

    // MARK: - ISC-4: a valid unique id is left alone

    func testRepeatedSavesDoNotChurnExistingIDs() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.bootstrap(sample: "alpha\nbeta")
        let loaded = try store.load()
        let first = try store.save(lines: loaded.lines, expectedGeneration: loaded.generation)
        let ids = first.lines.map(\.stableID)

        var changed = first.lines
        changed[0].setFocus(true)
        let second = try store.save(lines: changed, expectedGeneration: first.generation)
        XCTAssertEqual(second.lines.map(\.stableID), ids, "ids must be stable across saves")

        let third = try store.save(lines: second.lines, expectedGeneration: second.generation)
        XCTAssertEqual(third.lines.map(\.stableID), ids)
        XCTAssertEqual(third.documentRevision, second.documentRevision,
                       "a no-op save must not rewrite the document")
    }

    func testNonHexUserAuthoredIDIsPreserved() {
        let lines = TasksDocument.parse("alpha id:my-own-label\nbeta")
        let out = TasksDocument.withUniqueIDs(lines)
        XCTAssertEqual(out[0].stableID, "my-own-label", "a hand-written id is data, not corruption")
        assertTaskID(out[1].stableID, "second line")
    }

    // MARK: - Anti-claim: nothing else about the line may move

    func testIdentityPassLeavesBlankLinesAndOtherTokensAlone() {
        let text = "alpha  +work pri:high note:\"keep  me\" due:2026-08-01\n\nx beta done:2026-08-02"
        let out = TasksDocument.withUniqueIDs(TasksDocument.parse(text))
        XCTAssertTrue(out[1].isBlank, "a spacer line is not a task and gets no id")
        XCTAssertNil(out[1].stableID)
        XCTAssertEqual(out[0].note, "keep  me")
        XCTAssertEqual(out[0].due, "2026-08-01")
        XCTAssertTrue(out[0].raw.hasPrefix("alpha  +work pri:high"), "unknown token and spacing survive")
        XCTAssertTrue(out[2].isDone)
        XCTAssertEqual(out[2].completedDate, "2026-08-02")
        // The only difference anywhere is an appended id: token.
        for (before, after) in zip(TasksDocument.parse(text), out) where !before.isBlank {
            var stripped = after
            stripped.setStableID(nil)
            XCTAssertEqual(stripped.raw, before.raw)
        }
    }

    func testIdentityPassIsAPureNoOpWhenEveryIDIsAlreadyValid() {
        let text = "alpha id:t00000001\nbeta id:t00000002"
        let out = TasksDocument.withUniqueIDs(TasksDocument.parse(text))
        XCTAssertEqual(TasksDocument.serialize(out), text)
    }
}
