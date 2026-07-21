import XCTest
@testable import TasksTxtCore

final class ArchitectureTests: XCTestCase {
    func testFilesystemStoreRoundTripAndStaleGeneration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileSystemTaskDocumentStore(directory: dir)
        try store.bootstrap(sample: "one\ntwo")
        let first = try store.load()
        var changed = first.lines
        changed[0].setFocus(true)
        let second = try store.save(lines: changed, expectedGeneration: first.generation)
        XCTAssertTrue(second.lines[0].isFocused)
        XCTAssertThrowsError(try store.save(lines: changed, expectedGeneration: first.generation))
    }

    func testFilesystemStoreRecoversPendingJournalBeforeLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileSystemTaskDocumentStore(directory: dir)
        try store.bootstrap(sample: "old")
        let entry = TaskDocumentJournalEntry(tasksText: "new\n", archiveText: "x archived\n")
        try JSONEncoder().encode(entry).write(to: store.journalURL)
        let loaded = try store.load()
        XCTAssertEqual(loaded.lines.filter { !$0.isBlank }.map(\.title), ["new"])
        XCTAssertEqual(loaded.archiveLines.filter { !$0.isBlank }.map(\.title), ["archived"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL.path))
    }

    func testFilesystemStoreCanOpenCustomTaskFilename() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileSystemTaskDocumentStore(directory: dir, tasksFilename: "work.txt")
        try store.bootstrap(sample: "custom task")
        XCTAssertEqual(store.tasksURL.lastPathComponent, "work.txt")
        XCTAssertEqual(try store.load().lines.first?.title, "custom task")
    }

    func testArchiveMovesOnlyOldDoneTasks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileSystemTaskDocumentStore(directory: dir)
        try store.bootstrap(sample: "x old done:2026-07-01\nx today done:2026-07-20\nopen")
        let first = try store.load()
        let archived = try store.archiveCompleted(before: "2026-07-20", expectedGeneration: first.generation)
        XCTAssertEqual(archived.lines.filter { !$0.isBlank }.map(\.title), ["today", "open"])
        XCTAssertEqual(archived.archiveLines.filter { !$0.isBlank }.map(\.title), ["old"])
    }

    func testWorkspaceRejectsStaleHandleAndKeepsFocusSingleton() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("a focus:true\nb"), generation: 4)
        let lines = try TaskWorkspace.apply(.toggleFocus(TaskHandle(generation: 4, index: 1)), to: snapshot, todayYMD: "2026-07-20")
        XCTAssertEqual(lines.map(\.isFocused), [false, true])
        XCTAssertThrowsError(try TaskWorkspace.apply(.toggleDone(TaskHandle(generation: 3, index: 0)), to: snapshot, todayYMD: "2026-07-20"))
    }

    func testActivityReportIncludesArchive() {
        let live = TasksDocument.parse("x live +work created:2026-07-19 done:2026-07-20")
        let archive = TasksDocument.parse("x old +home created:2026-06-01 done:2026-07-18")
        let report = ActivityReporting.build(lines: live, archiveLines: archive, sinceYMD: "2026-07-15")
        XCTAssertEqual(report.doneByDay, ["2026-07-20": 1, "2026-07-18": 1])
        XCTAssertEqual(report.doneProjects.map(\.name), ["home", "work"])
        XCTAssertEqual(report.createdSince, 1)
    }
}
