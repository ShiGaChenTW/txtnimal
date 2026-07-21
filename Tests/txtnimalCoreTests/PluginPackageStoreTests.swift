import XCTest
@testable import txtnimalCore

final class PluginPackageStoreTests: XCTestCase {
    func testInstallListAndRemoveValidatedPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let store = try PluginPackageStore(directory: root.appendingPathComponent("installed", isDirectory: true))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let manifest = #"{"id":"app.txtnimal.local","name":"Local","version":"1.0.0","apiVersion":1,"entry":"main.js","capabilities":[],"commands":[],"pages":[]}"#
        try Data(manifest.utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("function run(input) { return input; }".utf8).write(to: source.appendingPathComponent("main.js"))
        let installed = try store.install(from: source)
        XCTAssertEqual(installed.manifest.id, "app.txtnimal.local")
        XCTAssertEqual(try store.list().map { $0.manifest.id }, ["app.txtnimal.local"])
        try store.remove(id: installed.manifest.id)
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testInvalidPackageDoesNotInstall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let store = try PluginPackageStore(directory: root.appendingPathComponent("installed", isDirectory: true))
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: source.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.install(from: source))
        XCTAssertTrue(try store.list().isEmpty)
    }
}
