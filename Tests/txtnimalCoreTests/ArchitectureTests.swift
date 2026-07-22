import XCTest
@testable import txtnimalCore

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

    func testWorkspaceAppliesContextMenuCommandsToExplicitHandle() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("first\nsecond +old @home q:1"), generation: 7)
        let handle = TaskHandle(generation: 7, index: 1)
        var lines = try TaskWorkspace.apply(.setDue(handle, "2026-07-25"), to: snapshot, todayYMD: "2026-07-23")
        lines = try TaskWorkspace.apply(.setTag(handle, "+new", true),
                                        to: TaskDocumentSnapshot(lines: lines, generation: 7), todayYMD: "2026-07-23")
        lines = try TaskWorkspace.apply(.setTag(handle, "+old", false),
                                        to: TaskDocumentSnapshot(lines: lines, generation: 7), todayYMD: "2026-07-23")
        XCTAssertEqual(lines[0].raw, "first")
        XCTAssertEqual(lines[1].due, "2026-07-25")
        XCTAssertEqual(lines[1].projects, ["new"])
        XCTAssertEqual(lines[1].contexts, ["home"])

        lines = try TaskWorkspace.apply(.delete(handle),
                                        to: TaskDocumentSnapshot(lines: lines, generation: 7), todayYMD: "2026-07-23")
        XCTAssertEqual(lines.map(\.title), ["first"])
    }

    func testWorkspaceDoesNotEditCompletedTaskMetadata() throws {
        let snapshot = TaskDocumentSnapshot(lines: TasksDocument.parse("x done +old due:2026-07-20 done:2026-07-20"), generation: 2)
        let handle = TaskHandle(generation: 2, index: 0)
        let due = try TaskWorkspace.apply(.setDue(handle, "2026-08-01"), to: snapshot, todayYMD: "2026-07-23")
        let tag = try TaskWorkspace.apply(.setTag(handle, "+new", true), to: snapshot, todayYMD: "2026-07-23")
        XCTAssertEqual(due, snapshot.lines)
        XCTAssertEqual(tag, snapshot.lines)
    }

    func testManualArchiveMovesExactlyOneRawLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileSystemTaskDocumentStore(directory: dir)
        try store.bootstrap(sample: "first unknown:value\nsecond +work")
        let first = try store.load()
        let result = try store.archiveTask(TaskHandle(generation: first.generation, index: 0),
                                           expectedGeneration: first.generation)
        XCTAssertEqual(result.lines.filter { !$0.isBlank }.map(\.raw), ["second +work"])
        XCTAssertEqual(result.archiveLines.filter { !$0.isBlank }.map(\.raw), ["first unknown:value"])
        XCTAssertEqual(try String(contentsOf: store.archiveURL, encoding: .utf8), "first unknown:value\n")
    }

    func testManualArchiveRejectsStaleHandleWithoutChangingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try FileSystemTaskDocumentStore(directory: dir)
        try store.bootstrap(sample: "keep me")
        let first = try store.load()
        XCTAssertThrowsError(try store.archiveTask(TaskHandle(generation: first.generation - 1, index: 0),
                                                   expectedGeneration: first.generation))
        XCTAssertEqual(try String(contentsOf: store.tasksURL, encoding: .utf8), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.archiveURL.path))
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
