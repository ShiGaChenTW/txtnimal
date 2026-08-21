import XCTest
@testable import txtnimalCore

/// The token query DSL: parsing (shape + errors) and evaluation (per-atom semantics,
/// precedence, parens). Pure — no file access, no clock beyond the injected `today`.
final class TaskQueryTests: XCTestCase {

    private static let today: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 19
        return Calendar.current.date(from: c)!
    }()

    private func parse(_ text: String) throws -> TaskQuery.Expr {
        try TaskQuery.parse(text, today: Self.today, calendar: .current)
    }

    /// Titles of the fixture lines that satisfy `query`, in file order.
    private func hits(_ query: String, in raw: [String]) throws -> [String] {
        let expr = try parse(query)
        return raw.map(TaskLine.init).filter { TaskQuery.matches($0, expr: expr) }.map(\.title)
    }

    private static let corpus = [
        "write report +work @office due:2026-08-19 id:t0000001",
        "buy milk +errands @home due:2026-08-25 id:t0000002 note:\"the corner shop\"",
        "call plumber +errands @home id:t0000003 focus:true",
        "x file taxes +work due:2026-08-10 id:t0000004 done:2026-08-11",
    ]

    private func hits(_ query: String) throws -> [String] {
        try hits(query, in: Self.corpus)
    }

    // MARK: - Atoms

    func testEmptyQueryMatchesEverything() throws {
        XCTAssertEqual(try parse(""), .all)
        XCTAssertEqual(try parse("   "), .all)
        XCTAssertEqual(try hits(""), ["write report", "buy milk", "call plumber", "file taxes"])
    }

    func testProjectAtomMatchesMembershipCaseInsensitively() throws {
        XCTAssertEqual(try hits("+errands"), ["buy milk", "call plumber"])
        XCTAssertEqual(try hits("+ERRANDS"), ["buy milk", "call plumber"])
    }

    func testContextAtomMatchesMembershipCaseInsensitively() throws {
        XCTAssertEqual(try hits("@home"), ["buy milk", "call plumber"])
        XCTAssertEqual(try hits("@HOME"), ["buy milk", "call plumber"])
    }

    func testDoneFlagSelectsEitherSide() throws {
        XCTAssertEqual(try hits("done:true"), ["file taxes"])
        XCTAssertEqual(try hits("done:false"), ["write report", "buy milk", "call plumber"])
    }

    func testFocusFlagSelectsEitherSide() throws {
        XCTAssertEqual(try hits("focus:true"), ["call plumber"])
        XCTAssertEqual(try hits("focus:false"), ["write report", "buy milk", "file taxes"])
    }

    func testBareWordIsASubstringMatchOnTitleAndNote() throws {
        XCTAssertEqual(try hits("report"), ["write report"])
        XCTAssertEqual(try hits("REPORT"), ["write report"], "matching is case-insensitive")
        XCTAssertEqual(try hits("corner"), ["buy milk"], "the note is part of the haystack")
    }

    func testExplicitTextPrefixIsTheSameMatchAsABareWord() throws {
        XCTAssertEqual(try parse("q:report"), try parse("report"))
        XCTAssertEqual(try hits("q:report"), ["write report"])
    }

    /// Metadata the user never typed must not be searchable, or `q:` would match ids.
    func testTextMatchIgnoresMetadataTokens() throws {
        XCTAssertEqual(try hits("t0000001"), [])
    }

    /// `q:` is the escape hatch for the three reserved words.
    func testReservedWordsAreSearchableViaTheExplicitPrefix() throws {
        XCTAssertEqual(try parse("q:and"), .text("and"))
        XCTAssertEqual(try parse("q:or"), .text("or"))
        XCTAssertEqual(try parse("q:not"), .text("not"))
    }

    // MARK: - due comparisons

    func testDueDefaultsToEquality() throws {
        XCTAssertEqual(try parse("due:2026-08-19"), .due(.eq, "2026-08-19"))
        XCTAssertEqual(try hits("due:2026-08-19"), ["write report"])
        XCTAssertEqual(try hits("due:=2026-08-19"), ["write report"])
    }

    func testDueAcceptsEveryComparisonOperator() throws {
        XCTAssertEqual(try hits("due:<2026-08-19"), ["file taxes"])
        XCTAssertEqual(try hits("due:<=2026-08-19"), ["write report", "file taxes"])
        XCTAssertEqual(try hits("due:>2026-08-19"), ["buy milk"])
        XCTAssertEqual(try hits("due:>=2026-08-19"), ["write report", "buy milk"])
    }

    /// The whole point of routing through DueDateParser rather than reimplementing dates.
    func testDueAcceptsTheSharedParsersVocabulary() throws {
        XCTAssertEqual(try parse("due:today"), .due(.eq, "2026-08-19"))
        XCTAssertEqual(try parse("due:tomorrow"), .due(.eq, "2026-08-20"))
        XCTAssertEqual(try parse("due:<=1w"), .due(.le, "2026-08-26"))
        XCTAssertEqual(try parse("due:>3d"), .due(.gt, "2026-08-22"))
    }

    /// Absence is not "less than everything" — a task with no due date is simply not
    /// a participant in any date comparison.
    func testATaskWithoutADueDateNeverMatchesADueComparison() throws {
        let undated = ["call plumber id:t0000003"]
        for query in ["due:2026-08-19", "due:<2026-08-19", "due:<=2026-08-19",
                      "due:>2026-08-19", "due:>=2026-08-19", "due:<2099-01-01"] {
            XCTAssertEqual(try hits(query, in: undated), [], "\(query) must not match an undated task")
        }
    }

    /// …but NOT still negates the comparison, so the undated task reappears.
    func testNegatingADueComparisonReadmitsTheUndatedTask() throws {
        XCTAssertEqual(try hits("NOT due:<2026-08-19", in: ["call plumber id:t0000003"]), ["call plumber"])
    }

    // MARK: - Operators, precedence, grouping

    func testJuxtapositionIsImplicitAnd() throws {
        XCTAssertEqual(try parse("+errands @home"), .and(.project("errands"), .context("home")))
        XCTAssertEqual(try hits("+errands @home"), ["buy milk", "call plumber"])
        XCTAssertEqual(try hits("+errands @office"), [])
    }

    func testExplicitAndKeywordMeansTheSameThing() throws {
        XCTAssertEqual(try parse("+errands AND @home"), try parse("+errands @home"))
    }

    func testOrUnionsBothSides() throws {
        XCTAssertEqual(try hits("+work OR @home"), ["write report", "buy milk", "call plumber", "file taxes"])
    }

    func testNotBindsTighterThanAnd() throws {
        // NOT applies to `+work` alone, not to the whole conjunction.
        XCTAssertEqual(try parse("NOT +work done:false"),
                       .and(.not(.project("work")), .done(false)))
        XCTAssertEqual(try hits("NOT +work done:false"), ["buy milk", "call plumber"])
    }

    func testAndBindsTighterThanOr() throws {
        XCTAssertEqual(try parse("+work @office OR +errands"),
                       .or(.and(.project("work"), .context("office")), .project("errands")))
    }

    func testParenthesesOverridePrecedence() throws {
        XCTAssertEqual(try parse("+work AND (@office OR @home)"),
                       .and(.project("work"), .or(.context("office"), .context("home"))))
        XCTAssertEqual(try hits("(+work OR +errands) done:false @home"), ["buy milk", "call plumber"])
    }

    func testParenthesesNeedNoSurroundingWhitespace() throws {
        XCTAssertEqual(try parse("(+work)"), .project("work"))
        XCTAssertEqual(try parse("+work AND(@office OR @home)"), try parse("+work AND (@office OR @home)"))
    }

    func testDashIsShorthandForNot() throws {
        XCTAssertEqual(try parse("-+work"), .not(.project("work")))
        XCTAssertEqual(try hits("-+work done:false"), ["buy milk", "call plumber"])
    }

    func testOperatorKeywordsAreCaseInsensitive() throws {
        XCTAssertEqual(try parse("+work and @office"), try parse("+work AND @office"))
        XCTAssertEqual(try parse("+work or @office"), try parse("+work OR @office"))
        XCTAssertEqual(try parse("not +work"), try parse("NOT +work"))
    }

    func testNestedGroupsEvaluateCorrectly() throws {
        XCTAssertEqual(try hits("done:false AND (+work OR (@home AND focus:true))"),
                       ["write report", "call plumber"])
    }

    // MARK: - mentionsDone

    func testMentionsDoneFindsTheFlagAnywhereInTheTree() throws {
        XCTAssertTrue(TaskQuery.mentionsDone(try parse("done:true")))
        XCTAssertTrue(TaskQuery.mentionsDone(try parse("+work OR (NOT done:false)")))
        XCTAssertFalse(TaskQuery.mentionsDone(try parse("+work @office")))
        XCTAssertFalse(TaskQuery.mentionsDone(try parse("")))
    }

    // MARK: - Parse errors

    private func assertParseError(_ text: String,
                                  _ expected: TaskQuery.ParseError,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? TaskQuery.ParseError, expected, file: file, line: line)
        }
    }

    func testUnbalancedOpenParenIsAParseError() {
        assertParseError("(+work", .unbalancedParenthesis)
        assertParseError("(+work OR @home", .unbalancedParenthesis)
    }

    func testUnbalancedCloseParenIsAParseError() {
        assertParseError("+work)", .unexpectedToken(")"))
        assertParseError(")", .unexpectedToken(")"))
    }

    func testDanglingOperatorIsAParseError() {
        assertParseError("+work AND", .danglingOperator)
        assertParseError("+work OR", .danglingOperator)
        assertParseError("NOT", .danglingOperator)
        assertParseError("-", .danglingOperator)
    }

    func testLeadingBinaryOperatorIsAParseError() {
        assertParseError("AND +work", .unexpectedToken("AND"))
        assertParseError("OR +work", .unexpectedToken("OR"))
    }

    func testEmptyGroupIsAParseError() {
        assertParseError("()", .unexpectedToken(")"))
    }

    func testUnknownKeyIsAParseErrorRatherThanASilentTextMatch() {
        assertParseError("priority:high", .unknownKey("priority"))
        assertParseError("+work AND colour:red", .unknownKey("colour"))
    }

    func testUnreadableDateIsAParseError() {
        assertParseError("due:whenever", .unreadableDate("whenever"))
        assertParseError("due:<2026-13-40", .unreadableDate("2026-13-40"))
    }

    func testNonBooleanFlagValueIsAParseError() {
        assertParseError("done:yes", .unreadableFlag("done", "yes"))
        assertParseError("focus:1", .unreadableFlag("focus", "1"))
    }

    func testEmptyAtomValueIsAParseError() {
        assertParseError("+", .emptyValue("+"))
        assertParseError("@", .emptyValue("@"))
        assertParseError("q:", .emptyValue("q:"))
        assertParseError("due:", .emptyValue("due:"))
        assertParseError("due:<", .emptyValue("due:"))
    }

    /// A token that merely contains a colon is not a key — `12:30` is text a user
    /// can plausibly have in a title.
    func testAColonInsideAWordIsNotTreatedAsAKey() throws {
        XCTAssertEqual(try parse("12:30"), .text("12:30"))
    }

    func testEveryParseErrorCarriesAReadableMessage() throws {
        let errors: [TaskQuery.ParseError] = [
            .unbalancedParenthesis, .unexpectedToken(")"), .danglingOperator,
            .unknownKey("priority"), .emptyValue("+"), .unreadableDate("whenever"),
            .unreadableFlag("done", "yes"),
        ]
        for error in errors {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(error) needs a message a user can act on")
        }
    }
}
