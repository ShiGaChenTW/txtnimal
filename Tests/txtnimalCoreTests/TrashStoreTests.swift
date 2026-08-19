import XCTest
@testable import txtnimalCore

/// trash.txt is a third sibling of tasks.txt/archive.txt with the same protected-commit shape.
/// These cover the four things the feature actually promises: a delete lands in trash, a restore
/// comes back whole, retention purges what has expired, and it purges nothing that has not.
final class TrashStoreTests: XCTestCase {
    private func makeStore(_ sample: String) throws -> (FileSystemTaskDocumentStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try FileSystemTaskDocumentStore(directory: dir)
        try store.bootstrap(sample: sample)
        return (store, dir)
    }

    private func trashText(_ store: FileSystemTaskDocumentStore) throws -> String {
        (try? String(contentsOf: store.trashURL, encoding: .utf8)) ?? ""
    }

    // MARK: - trash

    func testTrashTaskMovesTheLineOutOfTasksAndStampsDeleted() throws {
        let (store, dir) = try makeStore("keep me\ndelete me id:abc due:2026-08-01 +work @home")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store.load()

        let after = try store.trashTask(TaskHandle(generation: first.generation, index: 1),
                                        deletedYMD: "2026-08-19", expectedGeneration: first.generation)

        XCTAssertEqual(after.lines.filter { !$0.isBlank }.map(\.title), ["keep me"])
        XCTAssertEqual(after.trashLines.filter { !$0.isBlank }.map(\.title), ["delete me"])
        XCTAssertEqual(after.trashLines[0].deletedDate, "2026-08-19")
        // Every other token survives verbatim — only `deleted:` was added.
        XCTAssertEqual(try trashText(store), "delete me id:abc due:2026-08-01 +work @home deleted:2026-08-19\n")
    }

    func testTrashAppendsToAnExistingTrashFileWithoutRewritingIt() throws {
        let (store, dir) = try makeStore("one id:t1\ntwo id:t2")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "earlier id:t0 deleted:2026-08-01\n".write(to: store.trashURL, atomically: true, encoding: .utf8)
        let first = try store.load()

        _ = try store.trashTask(TaskHandle(generation: first.generation, index: 0),
                                deletedYMD: "2026-08-19", expectedGeneration: first.generation)

        XCTAssertEqual(try trashText(store),
                       "earlier id:t0 deleted:2026-08-01\none id:t1 deleted:2026-08-19\n")
    }

    func testTrashRejectsAStaleHandleAndWritesNothing() throws {
        let (store, dir) = try makeStore("only id:t1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store.load()

        XCTAssertThrowsError(try store.trashTask(TaskHandle(generation: first.generation - 1, index: 0),
                                                 deletedYMD: "2026-08-19",
                                                 expectedGeneration: first.generation - 1))

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.trashURL.path))
        XCTAssertEqual(try store.load().lines.filter { !$0.isBlank }.map(\.title), ["only"])
    }

    func testSaveWithTrashingLandsPluginDeletesInTrashInOneTransaction() throws {
        // The agent/plugin path: the applier computes surviving lines and hands back what it
        // removed; both halves must land together.
        let (store, dir) = try makeStore("keep id:t1\ndrop id:t2 +work")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store.load()
        let survivors = first.lines.filter { $0.stableID != "t2" }
        let removed = first.lines.filter { $0.stableID == "t2" }

        let after = try store.save(lines: survivors, trashing: removed, deletedYMD: "2026-08-19",
                                   expectedGeneration: first.generation)

        XCTAssertEqual(after.lines.filter { !$0.isBlank }.map(\.title), ["keep"])
        XCTAssertEqual(try trashText(store), "drop id:t2 +work deleted:2026-08-19\n")
    }

    func testSaveWithNothingToTrashDoesNotCreateTrashFile() throws {
        let (store, dir) = try makeStore("one id:t1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store.load()

        _ = try store.save(lines: first.lines, trashing: [], deletedYMD: "2026-08-19",
                           expectedGeneration: first.generation)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.trashURL.path))
    }

    // MARK: - restore

    func testRestoreReturnsTheLineToTasksWithMetadataIntactAndDeletedCleared() throws {
        let (store, dir) = try makeStore("survivor id:t1")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "gone id:t2 due:2026-08-01 +work @home note:\"keep me\" pri:high deleted:2026-08-19\n"
            .write(to: store.trashURL, atomically: true, encoding: .utf8)
        let first = try store.load()

        let after = try store.restoreFromTrash(at: 0, expectedGeneration: first.generation)

        XCTAssertTrue(after.trashLines.filter { !$0.isBlank }.isEmpty)
        let restored = try XCTUnwrap(after.lines.first { $0.stableID == "t2" })
        XCTAssertNil(restored.deletedDate)
        XCTAssertEqual(restored.due, "2026-08-01")
        XCTAssertEqual(restored.projects, ["work"])
        XCTAssertEqual(restored.contexts, ["home"])
        XCTAssertEqual(restored.note, "keep me")
        XCTAssertTrue(restored.raw.contains("pri:high"), "unknown tokens must survive the round trip")
        XCTAssertFalse(restored.raw.contains("deleted:"))
    }

    func testTrashThenRestoreIsAByteIdenticalRoundTrip() throws {
        let raw = "round trip id:t1 due:2026-08-01 +work @home note:\"spaces here\" pri:high"
        let (store, dir) = try makeStore(raw)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store.load()

        let trashed = try store.trashTask(TaskHandle(generation: first.generation, index: 0),
                                          deletedYMD: "2026-08-19", expectedGeneration: first.generation)
        let restored = try store.restoreFromTrash(at: 0, expectedGeneration: trashed.generation)

        XCTAssertEqual(restored.lines.filter { !$0.isBlank }.map(\.raw), [raw])
    }

    func testRestoreRejectsAnOutOfRangeIndex() throws {
        let (store, dir) = try makeStore("one id:t1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store.load()
        XCTAssertThrowsError(try store.restoreFromTrash(at: 3, expectedGeneration: first.generation))
    }

    // MARK: - permanent delete / empty

    func testDeleteFromTrashDropsOnlyThatLineAndLeavesTasksAlone() throws {
        let (store, dir) = try makeStore("live id:t0")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a id:t1 deleted:2026-08-19\nb id:t2 deleted:2026-08-19\n"
            .write(to: store.trashURL, atomically: true, encoding: .utf8)
        let first = try store.load()

        let after = try store.deleteFromTrash(at: 0, expectedGeneration: first.generation)

        XCTAssertEqual(after.trashLines.filter { !$0.isBlank }.map(\.title), ["b"])
        XCTAssertEqual(after.lines.filter { !$0.isBlank }.map(\.title), ["live"])
    }

    func testEmptyTrashClearsTheFileButNotTheTasks() throws {
        let (store, dir) = try makeStore("live id:t0")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a id:t1 deleted:2026-08-19\nb id:t2 deleted:2026-08-19\n"
            .write(to: store.trashURL, atomically: true, encoding: .utf8)
        let first = try store.load()

        let after = try store.emptyTrash(expectedGeneration: first.generation)

        XCTAssertTrue(after.trashLines.filter { !$0.isBlank }.isEmpty)
        XCTAssertEqual(try trashText(store), "")
        XCTAssertEqual(after.lines.filter { !$0.isBlank }.map(\.title), ["live"])
    }

    // MARK: - purge

    func testPurgeRemovesOnlyLinesOlderThanTheCutoff() throws {
        let (store, dir) = try makeStore("live id:t0")
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        expired id:t1 deleted:2026-07-01
        boundary id:t2 deleted:2026-07-20
        fresh id:t3 deleted:2026-08-18

        """.write(to: store.trashURL, atomically: true, encoding: .utf8)
        let first = try store.load()

        let after = try store.purgeExpiredTrash(before: "2026-07-20", expectedGeneration: first.generation)

        // The boundary line is NOT expired — the comparison is strictly older than the cutoff.
        XCTAssertEqual(after.trashLines.filter { !$0.isBlank }.map(\.title), ["boundary", "fresh"])
    }

    func testPurgeIsANoOpWhenNothingHasExpired() throws {
        let (store, dir) = try makeStore("live id:t0")
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = "fresh id:t1 deleted:2026-08-18\n"
        try original.write(to: store.trashURL, atomically: true, encoding: .utf8)
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: store.trashURL.path)
        let first = try store.load()

        let after = try store.purgeExpiredTrash(before: "2026-07-20", expectedGeneration: first.generation)

        XCTAssertEqual(after.trashLines.filter { !$0.isBlank }.map(\.title), ["fresh"])
        XCTAssertEqual(try trashText(store), original)
        // Untouched means untouched: no rewrite at all, so the daily sweep costs nothing.
        let mtime = try XCTUnwrap(FileManager.default
            .attributesOfItem(atPath: store.trashURL.path)[.modificationDate] as? Date)
        XCTAssertEqual(mtime.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL.path))
    }

    func testPurgeKeepsLinesThatCarryNoDeletedStamp() throws {
        // We refuse to permanently destroy something we cannot date.
        let (store, dir) = try makeStore("live id:t0")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "undated id:t1\nexpired id:t2 deleted:2026-01-01\n"
            .write(to: store.trashURL, atomically: true, encoding: .utf8)
        let first = try store.load()

        let after = try store.purgeExpiredTrash(before: "2026-07-20", expectedGeneration: first.generation)

        XCTAssertEqual(after.trashLines.filter { !$0.isBlank }.map(\.title), ["undated"])
    }

    // MARK: - crash safety

    func testJournalReplayRestoresTrashBeforeTasks() throws {
        let (store, dir) = try makeStore("old")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = TaskDocumentJournalEntry(tasksText: "new\n", archiveText: nil,
                                             trashText: "trashed id:t1 deleted:2026-08-19\n")
        try JSONEncoder().encode(entry).write(to: store.journalURL)

        let loaded = try store.load()

        XCTAssertEqual(loaded.lines.filter { !$0.isBlank }.map(\.title), ["new"])
        XCTAssertEqual(loaded.trashLines.filter { !$0.isBlank }.map(\.title), ["trashed"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL.path))
    }

    func testOrdinarySaveNeverRollsBackTrash() throws {
        // nil trashText in the journal means "this transaction does not touch trash.txt" —
        // an ordinary save must not resurrect a stale trash snapshot.
        let (store, dir) = try makeStore("one")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "current id:t1 deleted:2026-08-19\n".write(to: store.trashURL, atomically: true, encoding: .utf8)
        let first = try store.load()

        _ = try store.save(lines: TasksDocument.parse("one\ntwo"), expectedGeneration: first.generation)

        XCTAssertEqual(try trashText(store), "current id:t1 deleted:2026-08-19\n")
    }
}

final class TrashRetentionTests: XCTestCase {
    func testCutoffIsTodayMinusRetentionDays() {
        XCTAssertEqual(Trash.cutoffYMD(todayYMD: "2026-08-19", retentionDays: 30), "2026-07-20")
        XCTAssertEqual(Trash.cutoffYMD(todayYMD: "2026-08-19", retentionDays: 7), "2026-08-12")
        XCTAssertEqual(Trash.cutoffYMD(todayYMD: "2026-03-01", retentionDays: 15), "2026-02-14")
    }

    func testATaskSurvivesExactlyItsRetentionWindow() {
        let line = TaskLine("task deleted:2026-07-20")
        // Day 30 after deletion: cutoff equals the stamp, so it is not yet strictly older.
        let day30 = try! XCTUnwrap(Trash.cutoffYMD(todayYMD: "2026-08-19", retentionDays: 30))
        XCTAssertFalse(Trash.isExpired(line, cutoffYMD: day30))
        // Day 31: cutoff has moved past the stamp.
        let day31 = try! XCTUnwrap(Trash.cutoffYMD(todayYMD: "2026-08-20", retentionDays: 30))
        XCTAssertTrue(Trash.isExpired(line, cutoffYMD: day31))
    }

    func testLinesWithoutAUsableDeletedStampAreNeverExpired() {
        XCTAssertFalse(Trash.isExpired(TaskLine("no stamp"), cutoffYMD: "2026-08-19"))
        XCTAssertFalse(Trash.isExpired(TaskLine("bad deleted:not-a-date"), cutoffYMD: "2026-08-19"))
        XCTAssertFalse(Trash.isExpired(TaskLine("   "), cutoffYMD: "2026-08-19"))
    }

    func testDaysRemainingCountsDownAndFloorsAtZero() {
        let line = TaskLine("task deleted:2026-08-01")
        XCTAssertEqual(Trash.daysRemaining(line, todayYMD: "2026-08-01", retentionDays: 30), 30)
        XCTAssertEqual(Trash.daysRemaining(line, todayYMD: "2026-08-19", retentionDays: 30), 12)
        XCTAssertEqual(Trash.daysRemaining(line, todayYMD: "2026-08-31", retentionDays: 30), 0)
        XCTAssertEqual(Trash.daysRemaining(line, todayYMD: "2026-09-30", retentionDays: 30), 0)
        XCTAssertNil(Trash.daysRemaining(TaskLine("no stamp"), todayYMD: "2026-08-19", retentionDays: 30))
    }

    func testRetentionOptionsAreTheThreeOfferedWindowsAndUnknownValuesFallBack() {
        XCTAssertEqual(Trash.retentionOptions, [7, 15, 30])
        XCTAssertEqual(Trash.defaultRetentionDays, 30)
        XCTAssertEqual(Trash.normalizedRetentionDays(7), 7)
        XCTAssertEqual(Trash.normalizedRetentionDays(0), 30)
        XCTAssertEqual(Trash.normalizedRetentionDays(999), 30)
    }

    func testDeletedTokenIsMetadataNotTitleText() {
        // `deleted:` must be a known key, or the trash list would render the stamp as title text
        // and `setTitle` would treat it as a title word to be replaced.
        var line = TaskLine("write the report deleted:2026-08-19 id:t1")
        XCTAssertEqual(line.title, "write the report")
        XCTAssertEqual(line.deletedDate, "2026-08-19")
        line.setDeleted(nil)
        XCTAssertNil(line.deletedDate)
        XCTAssertEqual(line.raw, "write the report id:t1")
    }
}
