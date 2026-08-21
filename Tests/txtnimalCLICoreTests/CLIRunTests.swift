import XCTest
@testable import txtnimalCLICore
import txtnimalCore

/// End-to-end exercise of the runner against a scratch directory. These cover the
/// read → mutate → write round trip that the unit tests above cannot reach.
final class CLIRunTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Harness

    private var tasksURL: URL { dir.appendingPathComponent("tasks.txt") }
    private var trashURL: URL { dir.appendingPathComponent("trash.txt") }

    private func seed(_ text: String) throws {
        try text.write(to: tasksURL, atomically: true, encoding: .utf8)
    }

    private func fileText() throws -> String {
        try String(contentsOf: tasksURL, encoding: .utf8)
    }

    @discardableResult
    private func run(_ args: [String], ids: [String] = ["aaaa0001", "aaaa0002", "aaaa0003"]) -> CLIOutput {
        var supply = ids
        let context = CLIContext(
            environment: [:],
            defaults: nil,
            home: dir,
            today: Self.fixedToday,
            randomIDFactory: { supply.isEmpty ? "ffffffff" : supply.removeFirst() })
        return CLIRunner.run(arguments: args + ["--dir", dir.path], context: context)
    }

    private static let fixedToday: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 19
        return Calendar.current.date(from: c)!
    }()

    private func json(_ output: CLIOutput) throws -> [String: Any] {
        let data = Data(output.stdout.utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - add

    func testAddCreatesTheFileWhenTheDirectoryIsEmpty() throws {
        let out = run(["add", "first task"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertTrue(try fileText().contains("first task"))
    }

    func testAddStampsAStableIDAndEveryRequestedField() throws {
        try seed("")
        let out = run(["add", "write report", "--due", "2026-10-10",
                       "--project", "work", "--context", "office", "--note", "bring numbers"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)

        let lines = TasksDocument.parse(try fileText()).filter { !$0.isBlank }
        let task = try XCTUnwrap(lines.first)
        XCTAssertEqual(task.title, "write report")
        XCTAssertEqual(task.due, "2026-10-10")
        XCTAssertEqual(task.projects, ["work"])
        XCTAssertEqual(task.contexts, ["office"])
        XCTAssertEqual(task.note, "bring numbers")
        XCTAssertEqual(task.stableID, "aaaa0001")
        XCTAssertEqual(task.created, "2026-08-19", "created: should be stamped like the GUI does")
    }

    func testAddResolvesDueShorthandThroughTheSharedParser() throws {
        try seed("")
        run(["add", "soon", "--due", "tomorrow"])
        let task = try XCTUnwrap(TasksDocument.parse(try fileText()).first { !$0.isBlank })
        XCTAssertEqual(task.due, "2026-08-20")
    }

    func testAddRejectsAnUnparseableDueDateRatherThanWritingGarbage() throws {
        try seed("")
        let out = run(["add", "soon", "--due", "whenever"])
        XCTAssertNotEqual(out.exitCode, 0)
        XCTAssertTrue(out.stderr.lowercased().contains("due"), out.stderr)
        XCTAssertFalse(try fileText().contains("soon"), "a rejected command must not half-write")
    }

    func testAddPreservesTheTrailingNewlineAndExistingContent() throws {
        try seed("existing one\nexisting two\n")
        run(["add", "third"])
        let text = try fileText()
        XCTAssertTrue(text.hasSuffix("\n"), "the trailing newline must survive")
        // The save-time identity pass backfills the two pre-existing lines, so compare
        // titles plus the new line's own tokens rather than the whole file byte-for-byte.
        let lines = TasksDocument.parse(text).filter { !$0.isBlank }
        XCTAssertEqual(lines.map(\.title), ["existing one", "existing two", "third"])
        XCTAssertEqual(lines[2].created, "2026-08-19")
        XCTAssertEqual(lines[2].stableID, "aaaa0001")
        XCTAssertEqual(Set(lines.compactMap(\.stableID)).count, 3, "every line ends up separately addressable")
    }

    /// An agent-supplied title must not be able to smuggle in completion, tags, or a second line.
    func testAddSanitizesAHostileTitle() throws {
        try seed("")
        run(["add", "x due:2020-01-01 +sneaky @ctx real title"])
        let lines = TasksDocument.parse(try fileText()).filter { !$0.isBlank }
        XCTAssertEqual(lines.count, 1)
        let task = try XCTUnwrap(lines.first)
        XCTAssertFalse(task.isDone)
        XCTAssertEqual(task.due, nil)
        XCTAssertEqual(task.projects, [])
        XCTAssertEqual(task.title, "real title")
    }

    func testAddEmitsJSONForTheCreatedTask() throws {
        try seed("")
        let out = run(["add", "write report", "--project", "work", "--json"])
        let object = try json(out)
        XCTAssertEqual(object["id"] as? String, "aaaa0001")
        XCTAssertEqual(object["title"] as? String, "write report")
        XCTAssertEqual(object["projects"] as? [String], ["work"])
        XCTAssertEqual(object["done"] as? Bool, false)
    }

    // MARK: - list

    func testListPrintsOpenTasksWithTheirIDs() throws {
        try seed("alpha id:aaaa1111\nx beta id:aaaa2222 done:2026-08-01\n")
        let out = run(["list"])
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertTrue(out.stdout.contains("aaaa1111"))
        XCTAssertTrue(out.stdout.contains("alpha"))
        XCTAssertFalse(out.stdout.contains("beta"), "done tasks are hidden without --all")
    }

    func testListJSONCarriesEveryFieldAnAgentNeeds() throws {
        try seed("alpha +work @home due:2026-10-10 id:aaaa1111 note:\"the note\"\n")
        let out = run(["list", "--json"])
        let object = try json(out)
        let tasks = try XCTUnwrap(object["tasks"] as? [[String: Any]])
        XCTAssertEqual(tasks.count, 1)
        let task = tasks[0]
        XCTAssertEqual(task["id"] as? String, "aaaa1111")
        XCTAssertEqual(task["title"] as? String, "alpha")
        XCTAssertEqual(task["due"] as? String, "2026-10-10")
        XCTAssertEqual(task["projects"] as? [String], ["work"])
        XCTAssertEqual(task["contexts"] as? [String], ["home"])
        XCTAssertEqual(task["note"] as? String, "the note")
        XCTAssertEqual(task["done"] as? Bool, false)
    }

    func testListJSONIsValidJSONWhenNothingMatches() throws {
        try seed("alpha id:aaaa1111\n")
        let out = run(["list", "--project", "nonexistent", "--json"])
        XCTAssertEqual(out.exitCode, 0, "an empty result is not an error")
        let object = try json(out)
        XCTAssertEqual((object["tasks"] as? [[String: Any]])?.count, 0)
    }

    func testListOnAMissingFileIsAnEmptyResultNotACrash() throws {
        let out = run(["list", "--json"])
        XCTAssertEqual(out.exitCode, 0)
        XCTAssertEqual((try json(out)["tasks"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - done

    func testDoneMarksTheTaskCompleteAndStampsTheDate() throws {
        try seed("alpha id:aaaa1111\nbeta id:aaaa2222\n")
        let out = run(["done", "aaaa11"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        let lines = TasksDocument.parse(try fileText()).filter { !$0.isBlank }
        XCTAssertTrue(lines[0].isDone)
        XCTAssertEqual(lines[0].completedDate, "2026-08-19")
        XCTAssertFalse(lines[1].isDone)
    }

    /// The reason `done` goes through TaskWorkspace instead of calling setDone directly:
    /// completing a `rec:` task has to emit its successor, exactly as the GUI does.
    func testDoneOnARecurringTaskEmitsItsSuccessor() throws {
        try seed("water plants rec:7d due:2026-08-19 id:aaaa1111\n")
        let out = run(["done", "aaaa1111"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        let lines = TasksDocument.parse(try fileText()).filter { !$0.isBlank }
        XCTAssertEqual(lines.count, 2, "the next occurrence must be created")
        XCTAssertTrue(lines[0].isDone)
        XCTAssertFalse(lines[1].isDone)
        XCTAssertEqual(lines[1].due, "2026-08-26")
    }

    func testDoneWithAnAmbiguousPrefixChangesNothingAndListsCandidates() throws {
        try seed("alpha id:aaaa1111\nbeta id:aaaa2222\n")
        let before = try fileText()
        let out = run(["done", "aaaa"])
        XCTAssertNotEqual(out.exitCode, 0)
        XCTAssertTrue(out.stderr.contains("aaaa1111"), out.stderr)
        XCTAssertTrue(out.stderr.contains("aaaa2222"), out.stderr)
        XCTAssertEqual(try fileText(), before)
    }

    func testDoneWithAnUnknownIDFailsCleanly() throws {
        try seed("alpha id:aaaa1111\n")
        let out = run(["done", "zzzz"])
        XCTAssertNotEqual(out.exitCode, 0)
        XCTAssertEqual(try fileText(), "alpha id:aaaa1111\n")
    }

    func testDoneIsIdempotentOnAnAlreadyCompletedTask() throws {
        try seed("x alpha id:aaaa1111 done:2026-08-01\n")
        let out = run(["done", "aaaa1111"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        let task = try XCTUnwrap(TasksDocument.parse(try fileText()).first { !$0.isBlank })
        XCTAssertTrue(task.isDone, "completing a completed task must not un-complete it")
        XCTAssertEqual(task.completedDate, "2026-08-01", "and must not restamp the date")
    }

    // MARK: - delete

    func testDeleteRemovesTheLineWithNoConfirmation() throws {
        try seed("alpha id:aaaa1111\nbeta id:aaaa2222\n")
        let out = run(["delete", "aaaa11"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        let titles = TasksDocument.parse(try fileText()).filter { !$0.isBlank }.map(\.title)
        XCTAssertEqual(titles, ["beta"])
    }

    func testDeleteWithAnAmbiguousPrefixChangesNothing() throws {
        try seed("alpha id:aaaa1111\nbeta id:aaaa2222\n")
        let before = try fileText()
        XCTAssertNotEqual(run(["delete", "aaaa"]).exitCode, 0)
        XCTAssertEqual(try fileText(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashURL.path))
    }

    func testDeleteMovesTheTaskToTrashRatherThanDestroyingIt() throws {
        // The CLI has no confirmation prompt; trash.txt is what makes that safe.
        try seed("alpha id:aaaa1111 due:2026-09-01 +work\nbeta id:aaaa2222\n")
        let out = run(["delete", "aaaa11"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)

        let trashed = TasksDocument.parse(try String(contentsOf: trashURL, encoding: .utf8))
            .filter { !$0.isBlank }
        XCTAssertEqual(trashed.map(\.title), ["alpha"])
        XCTAssertEqual(trashed[0].deletedDate, "2026-08-19")
        // Metadata survives so the GUI can restore it whole.
        XCTAssertEqual(trashed[0].due, "2026-09-01")
        XCTAssertEqual(trashed[0].projects, ["work"])
    }

    func testDeleteJsonReportsTheTrashRouting() throws {
        try seed("alpha id:aaaa1111\n")
        let payload = try json(run(["delete", "aaaa1111", "--json"]))
        XCTAssertEqual(payload["deleted"] as? Bool, true)
        XCTAssertEqual(payload["trashed"] as? Bool, true)
    }

    // MARK: - ensure

    func testListEnsureCreatesAPlaceholderTaskCarryingTheTag() throws {
        try seed("")
        let out = run(["list", "ensure", "work"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        let lines = TasksDocument.parse(try fileText()).filter { !$0.isBlank }
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].projects, ["work"])
    }

    func testListEnsureIsANoOpWhenSomeTaskAlreadyCarriesTheTag() throws {
        try seed("alpha +work id:aaaa1111\n")
        let before = try fileText()
        let out = run(["list", "ensure", "work"])
        XCTAssertEqual(out.exitCode, 0, "already satisfied is success, not an error")
        XCTAssertEqual(try fileText(), before, "no placeholder should be appended")
    }

    func testListEnsureMatchesTheExistingTagCaseInsensitively() throws {
        try seed("alpha +Work id:aaaa1111\n")
        let before = try fileText()
        XCTAssertEqual(run(["list", "ensure", "work"]).exitCode, 0)
        XCTAssertEqual(try fileText(), before)
    }

    func testListEnsureIgnoresALeadingPlusInTheName() throws {
        try seed("")
        XCTAssertEqual(run(["list", "ensure", "+work"]).exitCode, 0)
        let lines = TasksDocument.parse(try fileText()).filter { !$0.isBlank }
        XCTAssertEqual(lines[0].projects, ["work"], "the + must not be doubled into ++work")
    }

    func testListEnsureIsSatisfiedByADoneTaskToo() throws {
        try seed("x alpha +work id:aaaa1111 done:2026-08-01\n")
        let before = try fileText()
        XCTAssertEqual(run(["list", "ensure", "work"]).exitCode, 0)
        XCTAssertEqual(try fileText(), before)
    }

    func testTagEnsureCreatesAPlaceholderCarryingTheContext() throws {
        try seed("")
        XCTAssertEqual(run(["tag", "ensure", "home"]).exitCode, 0)
        let lines = TasksDocument.parse(try fileText()).filter { !$0.isBlank }
        XCTAssertEqual(lines[0].contexts, ["home"])
    }

    func testTagEnsureIsANoOpWhenAlreadyPresent() throws {
        try seed("alpha @home id:aaaa1111\n")
        let before = try fileText()
        XCTAssertEqual(run(["tag", "ensure", "home"]).exitCode, 0)
        XCTAssertEqual(try fileText(), before)
    }

    /// Running the same ensure twice must converge, which is the whole point for a scripting caller.
    func testEnsureRunTwiceLeavesExactlyOneTask() throws {
        try seed("")
        XCTAssertEqual(run(["list", "ensure", "work"]).exitCode, 0)
        let afterFirst = try fileText()
        XCTAssertEqual(run(["list", "ensure", "work"]).exitCode, 0)
        XCTAssertEqual(try fileText(), afterFirst)
    }

    // MARK: - process contract

    func testHelpExitsZeroAndNamesEverySubcommand() {
        let out = run(["--help"])
        XCTAssertEqual(out.exitCode, 0)
        for verb in ["add", "list", "done", "delete", "ensure", "--json", "--dir", "TXTNIMAL_DIR"] {
            XCTAssertTrue(out.stdout.contains(verb), "help should mention \(verb)")
        }
    }

    func testUsageErrorsGoToStderrWithANonZeroExit() {
        let out = run(["frobnicate"])
        XCTAssertNotEqual(out.exitCode, 0)
        XCTAssertTrue(out.stdout.isEmpty, "stdout must stay clean so --json output is pipeable")
        XCTAssertFalse(out.stderr.isEmpty)
    }

    func testErrorsAreJSONShapedWhenJSONWasRequested() throws {
        try seed("alpha id:aaaa1111\n")
        let out = run(["done", "zzzz", "--json"])
        XCTAssertNotEqual(out.exitCode, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.stderr.utf8)) as? [String: Any])
        XCTAssertNotNil(object["error"] as? String)
    }

    // MARK: - list --filter

    /// The corpus the query tests below select from. `today` is 2026-08-19.
    private func seedCorpus() throws {
        try seed("""
            write report +work @office due:2026-08-19 id:aaaa1111
            buy milk +errands @home due:2026-08-25 id:aaaa2222
            call plumber +errands @home id:aaaa3333 focus:true
            x file taxes +work due:2026-08-10 id:aaaa4444 done:2026-08-11

            """)
    }

    private func listedTitles(_ output: CLIOutput) throws -> [String] {
        let tasks = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8))
            as? [String: Any])["tasks"] as? [[String: Any]]
        return (tasks ?? []).compactMap { $0["title"] as? String }
    }

    func testListFilterSelectsBySingleAtom() throws {
        try seedCorpus()
        let out = run(["list", "--filter", "+errands", "--json"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertEqual(try listedTitles(out), ["buy milk", "call plumber"])
    }

    func testListFilterEvaluatesGroupingAndDisjunction() throws {
        try seedCorpus()
        let out = run(["list", "--filter", "(@office OR @home) AND due:<=2026-08-19", "--json"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertEqual(try listedTitles(out), ["write report"],
                       "buy milk is due later; call plumber has no due date at all")
    }

    func testListFilterNegationExcludes() throws {
        try seedCorpus()
        let out = run(["list", "--filter", "-+work", "--json"])
        XCTAssertEqual(try listedTitles(out), ["buy milk", "call plumber"])
    }

    func testListFilterCanReachCompletedTasksByNamingDone() throws {
        try seedCorpus()
        let out = run(["list", "--filter", "done:true", "--json"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertEqual(try listedTitles(out), ["file taxes"],
                       "naming done: must override the default of hiding completed tasks")
    }

    func testListFilterComposesWithTheOlderFlags() throws {
        try seedCorpus()
        let out = run(["list", "--project", "errands", "--filter", "@home", "--json"])
        XCTAssertEqual(try listedTitles(out), ["buy milk", "call plumber"])
    }

    func testListFilterUsesTheSharedDateVocabulary() throws {
        try seedCorpus()
        let out = run(["list", "--filter", "due:today", "--json"])
        XCTAssertEqual(try listedTitles(out), ["write report"])
    }

    func testListFilterRendersTheSameColumnsAsAPlainList() throws {
        try seedCorpus()
        let out = run(["list", "--filter", "+work"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertTrue(out.stdout.contains("aaaa1111"))
        XCTAssertTrue(out.stdout.contains("write report"))
        XCTAssertFalse(out.stdout.contains("file taxes"), "still hidden — the query never said done:")
    }

    /// ISC-6: a bad query is a usage error, reported, with the file untouched.
    func testMalformedFilterIsAUsageErrorNotACrash() throws {
        try seedCorpus()
        let before = try fileText()
        let out = run(["list", "--filter", "+work AND ("])
        XCTAssertEqual(out.exitCode, 2, "a malformed query is a usage error")
        XCTAssertTrue(out.stdout.isEmpty, "stdout must stay clean")
        XCTAssertFalse(out.stderr.isEmpty)
        XCTAssertEqual(try fileText(), before)
    }

    func testMalformedFilterNamesTheProblem() throws {
        try seedCorpus()
        XCTAssertTrue(run(["list", "--filter", "priority:high"]).stderr.contains("priority"))
        XCTAssertTrue(run(["list", "--filter", "due:whenever"]).stderr.lowercased().contains("date"))
    }

    func testMalformedFilterStillReportsAsJSONWhenAsked() throws {
        try seedCorpus()
        let out = run(["list", "--filter", ")", "--json"])
        XCTAssertEqual(out.exitCode, 2)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.stderr.utf8)) as? [String: Any])
        XCTAssertNotNil(object["error"] as? String)
    }

    // MARK: - saved views

    private var viewsURL: URL { dir.appendingPathComponent("views.json") }

    func testViewSaveThenRunRoundTripsThroughTheFile() throws {
        try seedCorpus()
        let saved = run(["view", "save", "errands", "+errands @home"])
        XCTAssertEqual(saved.exitCode, 0, saved.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: viewsURL.path))

        let out = run(["view", "run", "errands", "--json"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertEqual(try listedTitles(out), ["buy milk", "call plumber"])
    }

    func testViewsFileHasTheAgreedShape() throws {
        try seedCorpus()
        run(["view", "save", "errands", "+errands"])
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: viewsURL)) as? [[String: Any]])
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0]["name"] as? String, "errands")
        XCTAssertEqual(stored[0]["query"] as? String, "+errands")
        XCTAssertEqual(stored[0]["createdYMD"] as? String, "2026-08-19")
    }

    /// The query text is stored, never a resolved date — a view must mean "today" on the
    /// day it runs, not on the day it was written.
    func testViewStoresQueryTextRatherThanAResolvedDate() throws {
        try seedCorpus()
        run(["view", "save", "duetoday", "due:today"])
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: viewsURL)) as? [[String: Any]])
        XCTAssertEqual(stored[0]["query"] as? String, "due:today")
    }

    func testViewRunAcceptsAllLikeListDoes() throws {
        try seedCorpus()
        run(["view", "save", "work", "+work"])
        XCTAssertEqual(try listedTitles(run(["view", "run", "work", "--json"])), ["write report"])
        XCTAssertEqual(try listedTitles(run(["view", "run", "work", "--all", "--json"])),
                       ["write report", "file taxes"])
    }

    func testViewListPrintsNamesAndQueries() throws {
        try seedCorpus()
        run(["view", "save", "errands", "+errands"])
        run(["view", "save", "thisweek", "due:<=1w"])
        let out = run(["view", "list"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertTrue(out.stdout.contains("errands"))
        XCTAssertTrue(out.stdout.contains("+errands"))
        XCTAssertTrue(out.stdout.contains("thisweek"))
        XCTAssertTrue(out.stdout.contains("due:<=1w"))
    }

    func testViewListOnAnEmptyStoreIsSuccessNotAnError() throws {
        try seedCorpus()
        let out = run(["view", "list", "--json"])
        XCTAssertEqual(out.exitCode, 0)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        XCTAssertEqual((object["views"] as? [[String: Any]])?.count, 0)
    }

    func testViewDeleteRemovesOnlyThatView() throws {
        try seedCorpus()
        run(["view", "save", "errands", "+errands"])
        run(["view", "save", "work", "+work"])
        XCTAssertEqual(run(["view", "delete", "errands"]).exitCode, 0)

        let out = run(["view", "list"])
        XCTAssertFalse(out.stdout.contains("errands"))
        XCTAssertTrue(out.stdout.contains("work"))
    }

    func testSavingADuplicateNameIsRefusedRatherThanOverwriting() throws {
        try seedCorpus()
        XCTAssertEqual(run(["view", "save", "errands", "+errands"]).exitCode, 0)
        let out = run(["view", "save", "errands", "+work"])
        XCTAssertEqual(out.exitCode, 2, "a name collision is a usage error")
        XCTAssertTrue(out.stderr.contains("--force"), "the message must say how to proceed")

        XCTAssertEqual(try listedTitles(run(["view", "run", "errands", "--json"])),
                       ["buy milk", "call plumber"], "the original query must survive")
    }

    func testDuplicateNamesAreCaughtCaseInsensitively() throws {
        try seedCorpus()
        run(["view", "save", "errands", "+errands"])
        XCTAssertEqual(run(["view", "save", "ERRANDS", "+work"]).exitCode, 2)
    }

    func testForceReplacesTheQueryAndKeepsTheCreationDate() throws {
        try seedCorpus()
        run(["view", "save", "errands", "+errands"])
        let out = run(["view", "save", "errands", "+work", "--force"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)

        let stored = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: viewsURL)) as? [[String: Any]])
        XCTAssertEqual(stored.count, 1, "replacing must not append a second entry")
        XCTAssertEqual(stored[0]["query"] as? String, "+work")
        XCTAssertEqual(stored[0]["createdYMD"] as? String, "2026-08-19")
    }

    func testSavingAnInvalidQueryIsRefusedBeforeItReachesTheFile() throws {
        try seedCorpus()
        let out = run(["view", "save", "broken", "+work AND ("])
        XCTAssertEqual(out.exitCode, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: viewsURL.path),
                       "a view that cannot run must never be written")
    }

    func testRunningAnUnknownViewFailsWithoutTouchingAnything() throws {
        try seedCorpus()
        let out = run(["view", "run", "nosuchview"])
        XCTAssertEqual(out.exitCode, 1, "a missing view is a state problem, not a usage error")
        XCTAssertTrue(out.stderr.contains("nosuchview"))
        XCTAssertTrue(out.stdout.isEmpty)
    }

    func testDeletingAnUnknownViewFails() throws {
        try seedCorpus()
        XCTAssertEqual(run(["view", "delete", "nosuchview"]).exitCode, 1)
    }

    func testAViewNameMayBeRunCaseInsensitively() throws {
        try seedCorpus()
        run(["view", "save", "Errands", "+errands"])
        XCTAssertEqual(try listedTitles(run(["view", "run", "errands", "--json"])),
                       ["buy milk", "call plumber"])
    }

    func testAnUnreadableViewsFileIsReportedRatherThanSilentlyReplaced() throws {
        try seedCorpus()
        try "not json at all".write(to: viewsURL, atomically: true, encoding: .utf8)
        let out = run(["view", "list"])
        XCTAssertEqual(out.exitCode, 1)
        XCTAssertFalse(out.stderr.isEmpty)
        XCTAssertEqual(try String(contentsOf: viewsURL, encoding: .utf8), "not json at all",
                       "a file we could not read must not be overwritten")
    }

    // MARK: - focus

    private func focusedTitles() throws -> [String] {
        TasksDocument.parse(try fileText()).filter { $0.isFocused }.map(\.title)
    }

    func testFocusSetsTheNamedTask() throws {
        try seed("alpha id:aaaa1111\nbeta id:aaaa2222\n")
        let out = run(["focus", "aaaa22"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertEqual(try focusedTitles(), ["beta"])
    }

    /// The single-focus invariant, enforced in the same write.
    func testFocusClearsFocusEverywhereElse() throws {
        try seed("alpha id:aaaa1111 focus:true\nbeta id:aaaa2222\ngamma id:aaaa3333 focus:true\n")
        XCTAssertEqual(run(["focus", "aaaa2222"]).exitCode, 0)
        XCTAssertEqual(try focusedTitles(), ["beta"], "exactly one task may carry focus")
    }

    func testFocusClearRemovesFocusWithNoReplacement() throws {
        try seed("alpha id:aaaa1111 focus:true\nbeta id:aaaa2222\n")
        let out = run(["focus", "--clear"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertEqual(try focusedTitles(), [])
    }

    func testFocusClearOnAnUnfocusedFileIsAHarmlessNoOp() throws {
        try seed("alpha id:aaaa1111\nbeta id:aaaa2222\n")
        let before = try fileText()
        let out = run(["focus", "--clear"])
        XCTAssertEqual(out.exitCode, 0, out.stderr)
        XCTAssertEqual(try fileText(), before, "a no-op must not rewrite the file")
    }

    func testFocusLeavesEveryOtherTokenAlone() throws {
        try seed("alpha +work @home due:2026-09-01 id:aaaa1111 note:\"keep me\"\n")
        XCTAssertEqual(run(["focus", "aaaa1111"]).exitCode, 0)
        let task = try XCTUnwrap(TasksDocument.parse(try fileText()).first { !$0.isBlank })
        XCTAssertTrue(task.isFocused)
        XCTAssertEqual(task.due, "2026-09-01")
        XCTAssertEqual(task.projects, ["work"])
        XCTAssertEqual(task.contexts, ["home"])
        XCTAssertEqual(task.note, "keep me")
    }

    func testFocusWithAnAmbiguousPrefixChangesNothingAndListsCandidates() throws {
        try seed("alpha id:aaaa1111\nbeta id:aaaa2222\n")
        let before = try fileText()
        let out = run(["focus", "aaaa"])
        XCTAssertNotEqual(out.exitCode, 0)
        XCTAssertTrue(out.stderr.contains("aaaa1111"), out.stderr)
        XCTAssertTrue(out.stderr.contains("aaaa2222"), out.stderr)
        XCTAssertEqual(try fileText(), before)
    }

    func testFocusWithAnUnknownIDFailsCleanly() throws {
        try seed("alpha id:aaaa1111\n")
        let out = run(["focus", "zzzz"])
        XCTAssertNotEqual(out.exitCode, 0)
        XCTAssertEqual(try fileText(), "alpha id:aaaa1111\n")
    }

    func testFocusEmitsJSONWhenAsked() throws {
        try seed("alpha id:aaaa1111\n")
        let payload = try json(run(["focus", "aaaa1111", "--json"]))
        XCTAssertEqual(payload["id"] as? String, "aaaa1111")
        XCTAssertEqual(payload["focused"] as? Bool, true)
    }

    func testFocusIsQueryableAfterwards() throws {
        try seed("alpha id:aaaa1111\nbeta id:aaaa2222\n")
        run(["focus", "aaaa2222"])
        XCTAssertEqual(try listedTitles(run(["list", "--filter", "focus:true", "--json"])), ["beta"])
    }

    func testFocusAndClearAreMutuallyExclusive() throws {
        try seed("alpha id:aaaa1111\n")
        XCTAssertNotEqual(run(["focus", "aaaa1111", "--clear"]).exitCode, 0)
    }

    func testFocusWithNoArgumentIsAUsageError() throws {
        try seed("alpha id:aaaa1111\n")
        let out = run(["focus"])
        XCTAssertEqual(out.exitCode, 2)
    }
}
