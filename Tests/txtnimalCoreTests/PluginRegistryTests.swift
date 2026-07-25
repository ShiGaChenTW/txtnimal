import XCTest
@testable import txtnimalCore

final class PluginRegistryTests: XCTestCase {
    private let fileManager = FileManager.default

    func testBundledOnlyDiscoveryReturnsAllFixtureEntries() throws {
        let registry = PluginRegistry(bundledDirectory: pluginFixturesDirectory(), installedStore: nil)

        let entries = try registry.discover()
        let expectedManifests = try fixtureManifests()
        let expectedRootsByID = try fixtureRootsByID()

        XCTAssertEqual(entries.map(\.manifest.id), expectedManifests.map(\.id).sorted())
        XCTAssertTrue(entries.allSatisfy { $0.source == .bundled })
        XCTAssertTrue(entries.allSatisfy { $0.enabled })
        for entry in entries {
            XCTAssertEqual(entry.packageRootURL, expectedRootsByID[entry.manifest.id])
        }
    }

    func testInstalledEntryOverridesBundledEntryWithSameIdentifier() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }

        let store = try PluginPackageStore(directory: root.appendingPathComponent("installed", isDirectory: true))
        let source = root.appendingPathComponent("source", isDirectory: true)
        try writePluginPackage(at: source,
                               id: "app.txtnimal.habit-tracker",
                               name: "Installed Habit Tracker",
                               version: "9.9.9")
        let installed = try store.install(from: source)

        let registry = PluginRegistry(bundledDirectory: pluginFixturesDirectory(), installedStore: store)
        let entries = try registry.discover()
        let habitTrackerEntry = try XCTUnwrap(entries.first { $0.manifest.id == "app.txtnimal.habit-tracker" })

        XCTAssertEqual(habitTrackerEntry.source, .installed)
        XCTAssertEqual(habitTrackerEntry.manifest.name, "Installed Habit Tracker")
        XCTAssertEqual(habitTrackerEntry.manifest.version, "9.9.9")
        XCTAssertEqual(habitTrackerEntry.packageRootURL, installed.url.standardizedFileURL)
        XCTAssertEqual(entries.filter { $0.manifest.id == "app.txtnimal.habit-tracker" }.count, 1)
        XCTAssertEqual(entries.count, try fixtureManifests().count)
    }

    func testDiscoverEnabledFiltersDisabledIdentifiers() throws {
        let disabledID = "app.txtnimal.habit-tracker"
        let registry = PluginRegistry(
            bundledDirectory: pluginFixturesDirectory(),
            installedStore: nil,
            disabledIDs: [disabledID]
        )

        let discovered = try registry.discover()
        let enabledOnly = try registry.discoverEnabled()

        let disabledEntry = try XCTUnwrap(discovered.first { $0.manifest.id == disabledID })
        XCTAssertFalse(disabledEntry.enabled)
        XCTAssertNil(enabledOnly.first { $0.manifest.id == disabledID })
        XCTAssertEqual(enabledOnly.count, discovered.count - 1)
        XCTAssertTrue(enabledOnly.allSatisfy { $0.enabled })
    }

    func testNilBundledDirectoryAndNilStoreReturnEmptyDiscovery() throws {
        let registry = PluginRegistry(bundledDirectory: nil, installedStore: nil)

        XCTAssertEqual(try registry.discover(), [])
        XCTAssertEqual(try registry.discoverEnabled(), [])
    }

    func testBundledScanSkipsMalformedChildrenAndContinues() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }

        let validPackage = root.appendingPathComponent("valid-plugin", isDirectory: true)
        try writePluginPackage(at: validPackage, id: "app.txtnimal.valid-plugin")

        let missingManifest = root.appendingPathComponent("missing-manifest", isDirectory: true)
        try fileManager.createDirectory(at: missingManifest, withIntermediateDirectories: true)

        let invalidManifest = root.appendingPathComponent("invalid-manifest", isDirectory: true)
        try fileManager.createDirectory(at: invalidManifest, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: invalidManifest.appendingPathComponent("manifest.json"))

        try Data("not a package directory".utf8).write(to: root.appendingPathComponent("README.txt"))

        let registry = PluginRegistry(bundledDirectory: root, installedStore: nil)
        let entries = try registry.discover()

        XCTAssertEqual(entries.map(\.manifest.id), ["app.txtnimal.valid-plugin"])
        XCTAssertEqual(entries.first?.source, .bundled)
        XCTAssertEqual(entries.first?.packageRootURL, validPackage.standardizedFileURL)
    }

    func testInstalledOnlyDiscoveryReturnsInstalledEntriesWhenBundledDirectoryIsNil() throws {
        let root = temporaryRoot()
        defer { try? fileManager.removeItem(at: root) }

        let store = try PluginPackageStore(directory: root.appendingPathComponent("installed", isDirectory: true))
        let source = root.appendingPathComponent("source", isDirectory: true)
        try writePluginPackage(at: source, id: "app.txtnimal.installed-only")
        let installed = try store.install(from: source)

        let registry = PluginRegistry(bundledDirectory: nil, installedStore: store)
        let entries = try registry.discover()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.manifest.id, "app.txtnimal.installed-only")
        XCTAssertEqual(entries.first?.source, .installed)
        XCTAssertEqual(entries.first?.packageRootURL, installed.url.standardizedFileURL)
        XCTAssertEqual(try registry.discoverEnabled(), entries)
    }

    private func pluginFixturesDirectory() -> URL {
        repoRoot().appendingPathComponent("PluginFixtures", isDirectory: true)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func fixtureManifests() throws -> [PluginManifest] {
        try fixtureDirectories().map { directory in
            let manifestURL = directory.appendingPathComponent("manifest.json")
            return try PluginValidator.decodeManifest(Data(contentsOf: manifestURL))
        }
    }

    private func fixtureRootsByID() throws -> [String: URL] {
        var rootsByID = [String: URL]()
        for directory in try fixtureDirectories() {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            let manifest = try PluginValidator.decodeManifest(Data(contentsOf: manifestURL))
            rootsByID[manifest.id] = directory.standardizedFileURL
        }
        return rootsByID
    }

    private func fixtureDirectories() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: pluginFixturesDirectory(),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func temporaryRoot() -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func writePluginPackage(at directory: URL, id: String,
                                    name: String = "Habit Tracker",
                                    version: String = "0.1.0") throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        {
          "id": "\(id)",
          "name": "\(name)",
          "version": "\(version)",
          "apiVersion": 1,
          "entry": "main.js",
          "capabilities": ["storage.kv", "ui.page"],
          "commands": [],
          "pages": [{"id": "habit-tracker", "title": "Habit Tracker", "entryFunction": "run"}]
        }
        """
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        try Data("function run(input) { return input; }".utf8).write(to: directory.appendingPathComponent("main.js"))
    }
}
