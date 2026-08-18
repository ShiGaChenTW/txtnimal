import XCTest
@testable import txtnimalCLICore
import txtnimalCore

final class CLIParsingTests: XCTestCase {

    // MARK: - Subcommand dispatch

    func testAddParsesTitleAndEveryOption() throws {
        let parsed = try CLIParser.parse([
            "add", "write the report",
            "--due", "2026-10-10",
            "--project", "work",
            "--context", "office",
            "--note", "bring the numbers",
        ])
        XCTAssertEqual(parsed.command, .add(AddOptions(
            title: "write the report", due: "2026-10-10",
            projects: ["work"], contexts: ["office"], note: "bring the numbers")))
    }

    func testAddAcceptsRepeatedProjectAndContextFlags() throws {
        let parsed = try CLIParser.parse([
            "add", "ship it", "--project", "work", "--project", "q3", "--context", "home",
        ])
        guard case .add(let options) = parsed.command else { return XCTFail("expected add") }
        XCTAssertEqual(options.projects, ["work", "q3"])
        XCTAssertEqual(options.contexts, ["home"])
    }

    func testAddJoinsBareWordsSoUnquotedTitlesStillWork() throws {
        // `txtnimal add buy milk` without quotes is what a shell user types first.
        let parsed = try CLIParser.parse(["add", "buy", "milk", "--project", "errands"])
        guard case .add(let options) = parsed.command else { return XCTFail("expected add") }
        XCTAssertEqual(options.title, "buy milk")
    }

    func testAddWithoutTitleIsAnError() {
        XCTAssertThrowsError(try CLIParser.parse(["add"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingArgument("title"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["add", "--project", "work"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingArgument("title"))
        }
    }

    func testListParsesFiltersAndJSON() throws {
        let parsed = try CLIParser.parse([
            "list", "--project", "work", "--context", "office", "--query", "report", "--json",
        ])
        XCTAssertEqual(parsed.command, .list(ListOptions(
            project: "work", context: "office", query: "report", includeDone: false)))
        XCTAssertTrue(parsed.global.json)
    }

    func testListDefaultsHideDoneUntilAllIsPassed() throws {
        guard case .list(let plain) = try CLIParser.parse(["list"]).command else { return XCTFail() }
        XCTAssertFalse(plain.includeDone)
        guard case .list(let all) = try CLIParser.parse(["list", "--all"]).command else { return XCTFail() }
        XCTAssertTrue(all.includeDone)
    }

    /// `list ensure NAME` must win over `list --project`; the two share a verb.
    func testListEnsureIsDistinctFromListFiltering() throws {
        XCTAssertEqual(try CLIParser.parse(["list", "ensure", "work"]).command, .listEnsure("work"))
        XCTAssertEqual(try CLIParser.parse(["tag", "ensure", "home"]).command, .tagEnsure("home"))
    }

    func testEnsureRequiresAName() {
        XCTAssertThrowsError(try CLIParser.parse(["list", "ensure"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingArgument("name"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["tag", "ensure"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingArgument("name"))
        }
    }

    func testTagRequiresTheEnsureVerb() {
        XCTAssertThrowsError(try CLIParser.parse(["tag", "home"])) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownCommand("tag home"))
        }
    }

    func testDoneAndDeleteTakeAnIdentifier() throws {
        XCTAssertEqual(try CLIParser.parse(["done", "3f9a"]).command, .done("3f9a"))
        XCTAssertEqual(try CLIParser.parse(["delete", "3f9a"]).command, .delete("3f9a"))
    }

    func testDoneWithoutIdentifierIsAnError() {
        XCTAssertThrowsError(try CLIParser.parse(["done"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingArgument("id"))
        }
    }

    func testGlobalDirFlagIsAcceptedOnEverySubcommand() throws {
        XCTAssertEqual(try CLIParser.parse(["list", "--dir", "/tmp/x"]).global.dir, "/tmp/x")
        XCTAssertEqual(try CLIParser.parse(["add", "t", "--dir", "/tmp/x"]).global.dir, "/tmp/x")
        XCTAssertEqual(try CLIParser.parse(["done", "ab", "--dir", "/tmp/x"]).global.dir, "/tmp/x")
    }

    func testNoArgumentsShowsHelpRatherThanFailing() throws {
        XCTAssertEqual(try CLIParser.parse([]).command, .help)
        XCTAssertEqual(try CLIParser.parse(["--help"]).command, .help)
        XCTAssertEqual(try CLIParser.parse(["--version"]).command, .version)
    }

    func testUnknownCommandAndFlagAreRejected() {
        XCTAssertThrowsError(try CLIParser.parse(["frobnicate"])) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownCommand("frobnicate"))
        }
        XCTAssertThrowsError(try CLIParser.parse(["list", "--nope"])) { error in
            XCTAssertEqual(error as? CLIParseError, .unknownFlag("--nope"))
        }
    }

    func testFlagWithoutValueIsRejected() {
        XCTAssertThrowsError(try CLIParser.parse(["list", "--project"])) { error in
            XCTAssertEqual(error as? CLIParseError, .missingValue("--project"))
        }
    }

    /// A title that starts with `-` must survive; agents pass arbitrary text.
    func testDoubleDashEndsFlagParsing() throws {
        let parsed = try CLIParser.parse(["add", "--", "--not-a-flag"])
        guard case .add(let options) = parsed.command else { return XCTFail("expected add") }
        XCTAssertEqual(options.title, "--not-a-flag")
    }
}

// MARK: - Path resolution

final class PathResolverTests: XCTestCase {

    private struct StubDefaults: DefaultsReading {
        var values: [String: String]
        func stringValue(forKey key: String) -> String? { values[key] }
    }

    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    func testExplicitDirFlagWinsOverEverythingElse() {
        let url = PathResolver.resolveTasksFile(
            dirFlag: "/flag/dir",
            environment: ["TXTNIMAL_DIR": "/env/dir"],
            defaults: StubDefaults(values: ["activeTaskFile": "/gui/tasks.txt", "dataDir": "/gui"]),
            home: home)
        XCTAssertEqual(url.path, "/flag/dir/tasks.txt")
    }

    func testEnvironmentVariableWinsOverGUIDefaults() {
        let url = PathResolver.resolveTasksFile(
            dirFlag: nil,
            environment: ["TXTNIMAL_DIR": "/env/dir"],
            defaults: StubDefaults(values: ["activeTaskFile": "/gui/tasks.txt"]),
            home: home)
        XCTAssertEqual(url.path, "/env/dir/tasks.txt")
    }

    /// `activeTaskFile` is a full file path, not a directory — and it may not be named tasks.txt.
    func testGUIActiveTaskFileIsUsedVerbatim() {
        let url = PathResolver.resolveTasksFile(
            dirFlag: nil, environment: [:],
            defaults: StubDefaults(values: ["activeTaskFile": "/gui/work.txt", "dataDir": "/gui"]),
            home: home)
        XCTAssertEqual(url.path, "/gui/work.txt")
    }

    func testGUIDataDirIsUsedWhenOnlyItIsSet() {
        let url = PathResolver.resolveTasksFile(
            dirFlag: nil, environment: [:],
            defaults: StubDefaults(values: ["dataDir": "/gui"]),
            home: home)
        XCTAssertEqual(url.path, "/gui/tasks.txt")
    }

    /// The live situation found in Step 1: the GUI domain exists but has never written
    /// either path key, so the CLI must land on the same default the GUI computes.
    func testFallsBackToTheSameDefaultTheGUIUses() {
        let url = PathResolver.resolveTasksFile(
            dirFlag: nil, environment: [:],
            defaults: StubDefaults(values: ["appTheme": "phosphorTerminal"]),
            home: home)
        XCTAssertEqual(url.path, "/Users/tester/Documents/txtnimal/tasks.txt")
    }

    func testNoDefaultsDomainAtAllStillResolves() {
        let url = PathResolver.resolveTasksFile(dirFlag: nil, environment: [:], defaults: nil, home: home)
        XCTAssertEqual(url.path, "/Users/tester/Documents/txtnimal/tasks.txt")
    }

    func testTildeIsExpandedInFlagAndEnvironment() {
        XCTAssertEqual(
            PathResolver.resolveTasksFile(dirFlag: "~/notes", environment: [:], defaults: nil, home: home).path,
            "/Users/tester/notes/tasks.txt")
        XCTAssertEqual(
            PathResolver.resolveTasksFile(dirFlag: nil, environment: ["TXTNIMAL_DIR": "~/notes"], defaults: nil, home: home).path,
            "/Users/tester/notes/tasks.txt")
    }

    func testBlankOverridesAreIgnoredRatherThanResolvingToRoot() {
        // An unset-but-exported `TXTNIMAL_DIR=` must not silently retarget the CLI at "/".
        let url = PathResolver.resolveTasksFile(
            dirFlag: nil, environment: ["TXTNIMAL_DIR": "  "], defaults: nil, home: home)
        XCTAssertEqual(url.path, "/Users/tester/Documents/txtnimal/tasks.txt")
    }
}
