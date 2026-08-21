import XCTest
@testable import txtnimalCLICore
import txtnimalCore

final class TaskIdentityTests: XCTestCase {

    // MARK: - Generation

    func testGeneratedIDLooksLikeAShortHexTokenAndIsColonFree() {
        let id = TaskIdentity.generateID(existing: [])
        XCTAssertEqual(id.count, 8)
        XCTAssertFalse(id.contains(":"), "a colon would be reparsed as a todo.txt key:value token")
        XCTAssertTrue(id.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// The contract that matters is not the shape of the string — it is that the plugin
    /// layer accepts it as a *persisted* identity instead of falling back to `legacy-…`.
    /// Asserted through the public identity API rather than by copying its private predicate.
    func testGeneratedIDIsAcceptedByThePluginIdentityLayerAsPersisted() {
        let id = TaskIdentity.generateID(existing: [])
        let lines = TasksDocument.parse("some task id:\(id)")
        let map = PluginSnapshotBuilder.identityMap(for: lines)
        XCTAssertEqual(map[id], 0, "generated id must be treated as persisted, not rewritten to legacy-…")
        XCTAssertTrue(map.keys.allSatisfy { !$0.hasPrefix("legacy-") })
    }

    func testGenerationRetriesUntilItAvoidsIDsAlreadyInTheDocument() {
        var supply = ["aaaaaaaa", "aaaaaaaa", "bbbbbbbb"]
        let id = TaskIdentity.generateID(existing: ["aaaaaaaa"]) { supply.removeFirst() }
        XCTAssertEqual(id, "bbbbbbbb", "must not hand back an id that already exists in the file")
    }

    func testExistingIDsAreCollectedFromTheDocument() {
        let lines = TasksDocument.parse("one id:aaaa1111\nx two id:bbbb2222\nthree")
        XCTAssertEqual(TaskIdentity.existingIDs(in: lines), ["aaaa1111", "bbbb2222"])
    }

    // MARK: - Resolution

    private func lines(_ text: String) -> [TaskLine] { TasksDocument.parse(text) }

    func testResolvesAUniquePrefixToItsLineIndex() {
        let doc = lines("alpha id:3f9a2c71\nbeta id:77b10c4d")
        XCTAssertEqual(TaskIdentity.resolve(prefix: "3f9a", in: doc), .unique(index: 0, id: "3f9a2c71"))
        XCTAssertEqual(TaskIdentity.resolve(prefix: "77", in: doc), .unique(index: 1, id: "77b10c4d"))
    }

    func testFullIDResolvesToo() {
        let doc = lines("alpha id:3f9a2c71")
        XCTAssertEqual(TaskIdentity.resolve(prefix: "3f9a2c71", in: doc), .unique(index: 0, id: "3f9a2c71"))
    }

    func testAmbiguousPrefixReportsEveryCandidateInsteadOfGuessing() {
        let doc = lines("alpha id:3f9a2c71\nbeta id:3f9affff")
        guard case .ambiguous(let candidates) = TaskIdentity.resolve(prefix: "3f9a", in: doc) else {
            return XCTFail("expected ambiguity")
        }
        XCTAssertEqual(candidates.sorted(), ["3f9a2c71", "3f9affff"])
    }

    /// If one id is a strict prefix of another, an exact hit is an unambiguous answer.
    func testExactMatchWinsOverLongerIDsThatShareThePrefix() {
        let doc = lines("alpha id:3f9a\nbeta id:3f9a2c71")
        XCTAssertEqual(TaskIdentity.resolve(prefix: "3f9a", in: doc), .unique(index: 0, id: "3f9a"))
    }

    func testUnknownPrefixIsNotFound() {
        XCTAssertEqual(TaskIdentity.resolve(prefix: "zzzz", in: lines("alpha id:3f9a2c71")), .notFound)
    }

    func testEmptyPrefixNeverMatchesEverything() {
        XCTAssertEqual(TaskIdentity.resolve(prefix: "", in: lines("alpha id:3f9a2c71")), .notFound)
    }

    /// GUI-created tasks carry no `id:` token. They must still be addressable, using the
    /// same `legacy-…` identity the in-process plugin host derives — one identity scheme.
    func testTasksWithoutAnIDTokenAreAddressableViaThePluginLegacyIdentity() {
        let doc = lines("happy created:2026-08-19\nfjiff due:2026.10.10")
        let map = PluginSnapshotBuilder.identityMap(for: doc)
        guard let legacyID = map.first(where: { $0.value == 0 })?.key else { return XCTFail("no identity") }
        XCTAssertTrue(legacyID.hasPrefix("legacy-"))
        XCTAssertEqual(TaskIdentity.resolve(prefix: String(legacyID.prefix(12)), in: doc),
                       .unique(index: 0, id: legacyID))
    }

    func testBlankLinesAreNotAddressable() {
        let doc = lines("\nalpha id:3f9a2c71\n")
        XCTAssertEqual(TaskIdentity.resolve(prefix: "3f9a", in: doc), .unique(index: 1, id: "3f9a2c71"))
    }
}

// MARK: - Filtering

final class TaskFilterTests: XCTestCase {

    private let doc = TasksDocument.parse("""

        write report +work @office due:2026-10-10 id:aaaa0001
        buy milk +errands @home id:aaaa0002
        x shipped release +work id:aaaa0003 done:2026-08-01
        call plumber note:"ask about the leak" id:aaaa0004
        """)

    private static let today: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 19
        return Calendar.current.date(from: c)!
    }()

    private func titles(_ options: ListOptions) throws -> [String] {
        try TaskFilter.matchingIndices(in: doc, options: options, today: Self.today).map { doc[$0].title }
    }

    func testOpenTasksOnlyByDefault() throws {
        XCTAssertEqual(try titles(ListOptions()), ["write report", "buy milk", "call plumber"])
    }

    func testIncludeDoneAddsCompletedTasks() throws {
        XCTAssertEqual(try titles(ListOptions(includeDone: true)),
                       ["write report", "buy milk", "shipped release", "call plumber"])
    }

    func testProjectFilterIsCaseInsensitiveAndTolerantOfALeadingPlus() throws {
        XCTAssertEqual(try titles(ListOptions(project: "work")), ["write report"])
        XCTAssertEqual(try titles(ListOptions(project: "WORK")), ["write report"])
        XCTAssertEqual(try titles(ListOptions(project: "+work")), ["write report"])
    }

    func testContextFilterIsCaseInsensitiveAndTolerantOfALeadingAt() throws {
        XCTAssertEqual(try titles(ListOptions(context: "home")), ["buy milk"])
        XCTAssertEqual(try titles(ListOptions(context: "@HOME")), ["buy milk"])
    }

    func testQueryMatchesTitleSubstringCaseInsensitively() throws {
        XCTAssertEqual(try titles(ListOptions(query: "REPORT")), ["write report"])
        XCTAssertEqual(try titles(ListOptions(query: "l")), ["buy milk", "call plumber"])
    }

    func testQueryAlsoSearchesTheNoteBody() throws {
        XCTAssertEqual(try titles(ListOptions(query: "leak")), ["call plumber"])
    }

    func testQueryDoesNotLeakIntoMetadataTokens() throws {
        // "aaaa0002" is an id: token, not user-visible text — searching it must not match.
        XCTAssertEqual(try titles(ListOptions(query: "aaaa0002")), [])
    }

    func testFiltersCombineWithAnd() throws {
        XCTAssertEqual(try titles(ListOptions(project: "work", context: "office")), ["write report"])
        XCTAssertEqual(try titles(ListOptions(project: "errands", context: "office")), [])
    }

    func testBlankLinesAreNeverListed() throws {
        XCTAssertFalse(try titles(ListOptions(includeDone: true)).contains(""))
    }

    // MARK: - --filter

    func testFilterQuerySelectsTheSameWayTheFlagsDo() throws {
        XCTAssertEqual(try titles(ListOptions(filter: "+work")), ["write report"])
        XCTAssertEqual(try titles(ListOptions(filter: "@home")), ["buy milk"])
    }

    func testFilterQuerySupportsDisjunctionTheFlagsCannotExpress() throws {
        XCTAssertEqual(try titles(ListOptions(filter: "@office OR @home")),
                       ["write report", "buy milk"])
    }

    /// The two filtering surfaces compose rather than compete.
    func testFilterQueryAndsWithTheFlags() throws {
        XCTAssertEqual(try titles(ListOptions(project: "work", filter: "@office")), ["write report"])
        XCTAssertEqual(try titles(ListOptions(project: "errands", filter: "@office")), [])
    }

    /// Otherwise the obvious query returns nothing, which no one wants.
    func testMentioningDoneStandsDownTheDefaultHideCompletedGate() throws {
        XCTAssertEqual(try titles(ListOptions(filter: "done:true")), ["shipped release"])
        XCTAssertEqual(try titles(ListOptions(filter: "+work AND done:true")), ["shipped release"])
    }

    func testWithoutMentioningDoneCompletedTasksStayHidden() throws {
        XCTAssertEqual(try titles(ListOptions(filter: "+work")), ["write report"],
                       "the completed +work task must stay hidden")
    }

    func testAnEmptyFilterStringIsNotAFilter() throws {
        XCTAssertEqual(try titles(ListOptions(filter: "   ")),
                       ["write report", "buy milk", "call plumber"])
    }

    func testAMalformedFilterThrows() {
        XCTAssertThrowsError(try titles(ListOptions(filter: "+work AND (")))
    }
}
