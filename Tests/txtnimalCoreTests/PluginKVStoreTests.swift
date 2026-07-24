import XCTest
@testable import txtnimalCore

final class PluginKVStoreTests: XCTestCase {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(".plugins", isDirectory: true)
            .appendingPathComponent("kv.json")
    }

    private func removeParent(of fileURL: URL) {
        // Clean the unique per-test root (…/<uuid>/), not just the leaf file.
        try? FileManager.default.removeItem(
            at: fileURL.deletingLastPathComponent().deletingLastPathComponent())
    }

    // MARK: - Persistence

    func testRoundTripPersistAndLoad() throws {
        let url = tempFileURL()
        defer { removeParent(of: url) }

        try PluginKVStore(fileURL: url).set("5", for: "streak", pluginID: "app.a")

        // A fresh instance reading the same file must see the persisted value (no in-memory cache).
        let reloaded = PluginKVStore(fileURL: url)
        XCTAssertEqual(reloaded.namespace(for: "app.a"), ["streak": "5"])
        XCTAssertEqual(reloaded.value(for: "streak", pluginID: "app.a"), "5")
    }

    func testPerPluginNamespaceIsolation() throws {
        let url = tempFileURL()
        defer { removeParent(of: url) }
        let store = PluginKVStore(fileURL: url)

        try store.set("3", for: "streak", pluginID: "app.a")
        try store.set("9", for: "streak", pluginID: "app.b")

        XCTAssertEqual(store.namespace(for: "app.a"), ["streak": "3"])
        XCTAssertEqual(store.namespace(for: "app.b"), ["streak": "9"])
        // Neither namespace leaks the other's keys.
        XCTAssertNil(store.value(for: "streak", pluginID: "app.c"))
    }

    func testMissingFileYieldsEmptyNamespace() {
        let url = tempFileURL()
        defer { removeParent(of: url) }
        // No file has been written yet.
        XCTAssertEqual(PluginKVStore(fileURL: url).namespace(for: "app.a"), [:])
    }

    func testAtomicOverwritePreservesOtherKeys() throws {
        let url = tempFileURL()
        defer { removeParent(of: url) }
        let store = PluginKVStore(fileURL: url)

        try store.set("v1", for: "k1", pluginID: "app.a")
        try store.set("v2", for: "k2", pluginID: "app.a")
        try store.set("v1b", for: "k1", pluginID: "app.a")   // overwrite k1 only

        XCTAssertEqual(store.namespace(for: "app.a"), ["k1": "v1b", "k2": "v2"])
    }

    // MARK: - Corruption divergence (read degrades, write refuses)

    func testCorruptStoreThrowsOnWrite() throws {
        let url = tempFileURL()
        defer { removeParent(of: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        // Writing over an unreadable file would destroy data — it must surface the corruption.
        XCTAssertThrowsError(try PluginKVStore(fileURL: url).set("5", for: "k", pluginID: "app.a")) { error in
            XCTAssertEqual(error as? PluginKVStoreError, .corruptStore)
        }
        // The corrupt bytes were not clobbered.
        XCTAssertEqual(try Data(contentsOf: url), Data("not json".utf8))
    }

    func testCorruptStoreYieldsEmptyNamespaceOnRead() throws {
        let url = tempFileURL()
        defer { removeParent(of: url) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        // The read path feeds the UI and must degrade rather than crash.
        XCTAssertEqual(PluginKVStore(fileURL: url).namespace(for: "app.a"), [:])
    }

    // MARK: - Input bounds

    func testRejectsEmptyPluginIDEmptyKeyLongKeyLargeValue() {
        let store = PluginKVStore(fileURL: tempFileURL())

        XCTAssertThrowsError(try store.set("v", for: "k", pluginID: "")) {
            XCTAssertEqual($0 as? PluginKVStoreError, .emptyPluginID)
        }
        XCTAssertThrowsError(try store.set("v", for: "", pluginID: "app.a")) {
            XCTAssertEqual($0 as? PluginKVStoreError, .emptyKey)
        }
        let longKey = String(repeating: "k", count: PluginKVStore.maximumKeyLength + 1)
        XCTAssertThrowsError(try store.set("v", for: longKey, pluginID: "app.a")) {
            XCTAssertEqual($0 as? PluginKVStoreError, .keyTooLong)
        }
        let bigValue = String(repeating: "x", count: PluginKVStore.maximumValueBytes + 1)
        XCTAssertThrowsError(try store.set(bigValue, for: "k", pluginID: "app.a")) {
            XCTAssertEqual($0 as? PluginKVStoreError, .valueTooLarge)
        }
        // Boundary values are accepted.
        let maxKey = String(repeating: "k", count: PluginKVStore.maximumKeyLength)
        let maxValue = String(repeating: "x", count: PluginKVStore.maximumValueBytes)
        XCTAssertNoThrow(try store.set(maxValue, for: maxKey, pluginID: "app.a"))
    }

    // MARK: - Applier: KV writes never touch task lines

    func testApplyWriteReturnsUpdatedNamespace() throws {
        let url = tempFileURL()
        defer { removeParent(of: url) }
        let store = PluginKVStore(fileURL: url)

        let updated = try store.applyWrite(
            ValidatedPluginKVWrite(pluginID: "app.a", key: "streak", value: "4"))
        XCTAssertEqual(updated, ["streak": "4"])
        XCTAssertEqual(store.value(for: "streak", pluginID: "app.a"), "4")
    }

    func testKVWriteDoesNotAffectTaskLines() throws {
        let url = tempFileURL()
        defer { removeParent(of: url) }
        let store = PluginKVStore(fileURL: url)

        // A real task mutation through the task path.
        let snapshot = TaskDocumentSnapshot(
            lines: TasksDocument.parse("One id:task-one due:2026-07-20\nTwo id:task-two due:2026-07-20"))
        let intent = ValidatedPluginIntent(pluginID: "app.a", command: .rescheduleTask,
                                           taskIDs: ["task-one"], due: "2026-07-22",
                                           expectedRevision: "rev",
                                           documentRevision: snapshot.documentRevision)
        let baseline = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-21")

        // A KV write for the same plugin, against the same snapshot's world.
        try store.applyWrite(ValidatedPluginKVWrite(pluginID: "app.a", key: "streak", value: "1"))

        // The task lines are exactly the task-mutation result — the KV write changed nothing here.
        let afterKV = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: "2026-07-21")
        XCTAssertEqual(afterKV.map(\.raw), baseline.map(\.raw))
        XCTAssertEqual(afterKV.map(\.due), ["2026-07-22", "2026-07-20"])
        // And the KV side reflects only the KV write.
        XCTAssertEqual(store.namespace(for: "app.a"), ["streak": "1"])
    }

    // MARK: - Validator: kvSet action

    private func manifest(capabilities: [PluginCapability]) -> PluginManifest {
        PluginManifest(id: "app.txtnimal.habit", name: "Habit", version: "1.0.0",
                       apiVersion: 1, entry: "main.js", capabilities: capabilities)
    }

    func testValidatorProducesKVWriteWithCapability() throws {
        let action = PluginAction(type: .kvSet, command: PluginAction.kvSetCommand,
                                  key: "streak", value: "3")
        let write = try PluginValidator.validate(kvAction: action,
                                                 manifest: manifest(capabilities: [.storageKV, .uiPage]))
        XCTAssertEqual(write, ValidatedPluginKVWrite(pluginID: "app.txtnimal.habit",
                                                     key: "streak", value: "3"))
    }

    func testValidatorRejectsKVWriteWithoutCapability() {
        let action = PluginAction(type: .kvSet, command: PluginAction.kvSetCommand,
                                  key: "streak", value: "3")
        XCTAssertThrowsError(try PluginValidator.validate(kvAction: action,
                                                          manifest: manifest(capabilities: [.uiPage]))) {
            XCTAssertEqual($0 as? PluginValidationError, .missingCapability)
        }
    }

    func testValidatorRejectsEmptyKeyAction() {
        let action = PluginAction(type: .kvSet, command: PluginAction.kvSetCommand,
                                  key: "", value: "3")
        XCTAssertThrowsError(try PluginValidator.validate(kvAction: action,
                                                          manifest: manifest(capabilities: [.storageKV]))) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }
    }

    func testValidatorRejectsKVActionCarryingTaskFields() {
        // A kvSet must not smuggle task-mutation fields.
        let action = PluginAction(type: .kvSet, command: PluginAction.kvSetCommand,
                                  taskIDs: ["t1"], due: "2026-07-24", key: "streak", value: "3")
        XCTAssertThrowsError(try PluginValidator.validate(kvAction: action,
                                                          manifest: manifest(capabilities: [.storageKV]))) {
            XCTAssertEqual($0 as? PluginValidationError, .invalidAction)
        }
    }

    // MARK: - Read path: input.kv reaches run(input)

    private func singleTaskSnapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "任務", due: nil, completed: false,
                               lists: [], tags: [], revision: "r1"),
        ])
    }

    private let echoKVSource = """
    function run(input) {
      return { schemaVersion: 1, page: { type: "page", id: "root", title: "echo", children: [
        { type: "statCard", id: "kv-streak", title: "s", value: String(input.kv.streak) }
      ] } };
    }
    """

    func testInputKVReachesPluginRun() throws {
        let doc = try ReportPluginRunner().run(source: echoKVSource, reportType: "weekly",
                                               snapshot: singleTaskSnapshot(), todayYMD: "2026-07-24",
                                               kv: ["streak": "7"])
        let card = doc.page.children?.first { $0.id == "kv-streak" }
        XCTAssertEqual(card?.value, "7")
    }

    func testInputKVDefaultsToEmptyObject() throws {
        // No kv argument → input.kv is {} → input.kv.streak is undefined.
        let doc = try ReportPluginRunner().run(source: echoKVSource, reportType: "weekly",
                                               snapshot: singleTaskSnapshot(), todayYMD: "2026-07-24")
        let card = doc.page.children?.first { $0.id == "kv-streak" }
        XCTAssertEqual(card?.value, "undefined")
    }
}
