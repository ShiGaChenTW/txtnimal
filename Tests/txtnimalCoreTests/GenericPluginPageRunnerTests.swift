import XCTest
@testable import txtnimalCore

/// SCO-172 regression protection: the single generic `GenericPluginPageRunner` must produce
/// output byte-for-byte equivalent to the ten bespoke `*PluginPage` methods it replaces, and
/// must inject host context purely from the manifest's declared capabilities + entry controls.
///
/// Each equivalence test runs the real bundled fixture `main.js` twice: once through the
/// generic runner (manifest-driven), once through `ReportPluginRunner` with the exact
/// hardcoded arguments the old bespoke method used. The two documents must be equal.
final class GenericPluginPageRunnerTests: XCTestCase {
    private let today = "2026-07-24"

    // MARK: - Fixture loading

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadSource(_ plugin: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/\(plugin)/main.js"),
                   encoding: .utf8)
    }

    private func loadManifest(_ plugin: String) throws -> PluginManifest {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("PluginFixtures/\(plugin)/manifest.json"))
        return try PluginValidator.decodeManifest(data)
    }

    // MARK: - Shared inputs (mirroring the bespoke callers)

    private func reportSnapshot() -> PluginDocumentSnapshot {
        PluginDocumentSnapshot(documentRevision: "doc-rev", tasks: [
            PluginTaskSnapshot(id: "t1", title: "停滯甲", due: nil, completed: false, revision: "r1"),
            PluginTaskSnapshot(id: "t2", title: "停滯乙", due: nil, completed: false, revision: "r2"),
            PluginTaskSnapshot(id: "t3", title: "今日", due: "2026-07-24", completed: false, revision: "r3"),
            PluginTaskSnapshot(id: "t4", title: "已完成", due: nil, completed: true, revision: "r4"),
        ])
    }

    private func metadata() -> [String: ReportPluginRunner.TaskMetadata] {
        [
            "t1": ReportPluginRunner.TaskMetadata(created: "2026-07-01"),
            "t2": ReportPluginRunner.TaskMetadata(created: "2026-06-20"),
            "t3": ReportPluginRunner.TaskMetadata(created: "2026-07-20"),
            "t4": ReportPluginRunner.TaskMetadata(created: "2026-06-01"),
        ]
    }

    private func node(in document: PluginPageDocument, id: String) -> PluginPageNode? {
        func search(_ node: PluginPageNode) -> PluginPageNode? {
            if node.id == id { return node }
            for child in node.children ?? [] { if let found = search(child) { return found } }
            return nil
        }
        return search(document.page)
    }

    // MARK: - resolveReportType (pure)

    func testResolveReportTypeUsesCollectedPickerValue() throws {
        let manifest = try loadManifest("task-report")
        XCTAssertEqual(
            GenericPluginPageRunner.resolveReportType(manifest: manifest, input: ["reportType": "progress"]),
            "progress")
    }

    func testResolveReportTypeFallsBackToPickerDefaultWhenKeyAbsent() throws {
        let manifest = try loadManifest("methodology") // picker id "view", default "gtd"
        XCTAssertEqual(
            GenericPluginPageRunner.resolveReportType(manifest: manifest, input: [:]),
            "gtd")
    }

    func testResolveReportTypePassesEmptyCollectedValueVerbatim() throws {
        // Old bespoke reviewsPackPluginPage(view: "") passed "" straight through — preserve that.
        let manifest = try loadManifest("reviews-pack")
        XCTAssertEqual(
            GenericPluginPageRunner.resolveReportType(manifest: manifest, input: ["view": ""]),
            "")
    }

    func testResolveReportTypeUsesShortNameWhenNoPicker() throws {
        let manifest = try loadManifest("export-pack") // no entry controls
        XCTAssertEqual(
            GenericPluginPageRunner.resolveReportType(manifest: manifest, input: [:]),
            "export-pack")
    }

    func testShortNameExtractsLastDottedComponent() {
        XCTAssertEqual(GenericPluginPageRunner.shortName(for: "app.txtnimal.habit-tracker"), "habit-tracker")
        XCTAssertEqual(GenericPluginPageRunner.shortName(for: "solo"), "solo")
    }

    // MARK: - Equivalence: reportType / view picker plugins

    func testTaskReportEquivalence() throws {
        let manifest = try loadManifest("task-report")
        let source = try loadSource("task-report")
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata(), input: ["reportType": "weekly"])
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "weekly", snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        XCTAssertEqual(generic, bespoke)
    }

    func testReviewsPackEquivalenceStalledUsesMetadata() throws {
        let manifest = try loadManifest("reviews-pack")
        let source = try loadSource("reviews-pack")
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata(), input: ["view": "stalled"])
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "stalled", snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        XCTAssertEqual(generic, bespoke)
        // Discriminator: "stalled" is metadata-sensitive, proving view + metadata both flowed.
        XCTAssertEqual(node(in: generic, id: "stalled-stat-count")?.value, "2")
    }

    func testMethodologyEquivalence() throws {
        let manifest = try loadManifest("methodology")
        let source = try loadSource("methodology")
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata(), input: ["view": "eisenhower"])
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "eisenhower", snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        XCTAssertEqual(generic, bespoke)
    }

    // MARK: - Equivalence: pickerless report plugins (fixed reportType == short name)

    func testExportPackEquivalence() throws {
        let manifest = try loadManifest("export-pack")
        let source = try loadSource("export-pack")
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "export-pack", snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        XCTAssertEqual(generic, bespoke)
    }

    func testAnalyticsEquivalence() throws {
        let manifest = try loadManifest("analytics")
        let source = try loadSource("analytics")
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "analytics", snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        XCTAssertEqual(generic, bespoke)
    }

    func testImportersEquivalence() throws {
        let manifest = try loadManifest("importers")
        let source = try loadSource("importers")
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "importers", snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata())
        XCTAssertEqual(generic, bespoke)
    }

    // MARK: - Equivalence: storage.kv plugin (habit-tracker)

    func testHabitTrackerEquivalenceWithKV() throws {
        let manifest = try loadManifest("habit-tracker")
        let source = try loadSource("habit-tracker")
        let kv = ["checkins:water": "[\"2026-07-22\",\"2026-07-23\",\"2026-07-24\"]"]
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata(), kvNamespace: kv)
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "habit-tracker", snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata(), kv: kv)
        XCTAssertEqual(generic, bespoke)
        // Discriminator: streak value derives from the injected kv namespace.
        XCTAssertEqual(node(in: generic, id: "habit-water-current")?.value, "3")
    }

    // MARK: - Equivalence: agent.query plugins (brain-dump, nl-report)

    func testBrainDumpEquivalenceWithAgentResult() throws {
        let manifest = try loadManifest("brain-dump")
        let source = try loadSource("brain-dump")
        let result = #"[{"title":"交季報","due":"2026-07-25"},{"title":"準備投影片"}]"#
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            agentResult: result)
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "brain-dump", snapshot: reportSnapshot(), todayYMD: today,
            agentResult: result)
        XCTAssertEqual(generic, bespoke)
        // Discriminator: with agentResult injected the plugin renders drafts, not the empty state.
        XCTAssertNil(node(in: generic, id: "brain-empty"))
    }

    func testNlReportEquivalenceViewAndAgentResult() throws {
        let manifest = try loadManifest("nl-report")
        let source = try loadSource("nl-report")
        let report = "本週完成三項任務。"
        let generic = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            agentResult: report, input: ["view": "weekly"])
        let bespoke = try ReportPluginRunner().run(
            source: source, reportType: "weekly", snapshot: reportSnapshot(), todayYMD: today,
            agentResult: report)
        XCTAssertEqual(generic, bespoke)
        // Discriminator: the export button only renders once agentResult flows through.
        XCTAssertNotNil(node(in: generic, id: "nl-report-export"))
    }

    // MARK: - Capability gating

    func testStorageKVGatingDropsKVWhenCapabilityAbsent() throws {
        let source = try loadSource("habit-tracker")
        let kv = ["checkins:water": "[\"2026-07-22\",\"2026-07-23\",\"2026-07-24\"]"]
        // Manifest WITHOUT storage.kv → kv must be dropped, so the plugin sees no namespace.
        let noKVManifest = PluginManifest(
            id: "app.txtnimal.habit-tracker", name: "Habit Tracker", version: "0.1.0", apiVersion: 1,
            entry: "main.js", capabilities: [.uiPage],
            pages: [PluginPageDeclaration(id: "habit-tracker", title: "Habit Tracker", entryFunction: "run")])
        let dropped = try GenericPluginPageRunner().run(
            manifest: noKVManifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            kvNamespace: kv)
        let asEmpty = try ReportPluginRunner().run(
            source: source, reportType: "habit-tracker", snapshot: reportSnapshot(), todayYMD: today,
            kv: [:])
        XCTAssertEqual(dropped, asEmpty)
        // Streak collapses to 0 because the kv namespace never reached the plugin.
        XCTAssertEqual(node(in: dropped, id: "habit-water-current")?.value, "0")
    }

    func testAgentQueryGatingDropsAgentResultWhenCapabilityAbsent() throws {
        let source = try loadSource("nl-report")
        let report = "本週完成三項任務。"
        // Manifest WITHOUT agent.query → agentResult must be dropped, so the plugin renders
        // its first (pre-query) state with the generate button and no export.
        let noAgentManifest = PluginManifest(
            id: "app.txtnimal.nl-report", name: "NL Report", version: "0.1.0", apiVersion: 1,
            entry: "main.js", capabilities: [.tasksAllRead, .uiPage, .exportWrite],
            pages: [PluginPageDeclaration(id: "nl-report", title: "NL Report", entryFunction: "run")])
        let dropped = try GenericPluginPageRunner().run(
            manifest: noAgentManifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            agentResult: report, input: ["view": "weekly"])
        let asNil = try ReportPluginRunner().run(
            source: source, reportType: "weekly", snapshot: reportSnapshot(), todayYMD: today,
            agentResult: nil)
        XCTAssertEqual(dropped, asNil)
        XCTAssertNotNil(node(in: dropped, id: "nl-report-generate"))
        XCTAssertNil(node(in: dropped, id: "nl-report-export"))
    }

    // MARK: - Determinism

    func testGenericRunnerIsDeterministic() throws {
        let manifest = try loadManifest("reviews-pack")
        let source = try loadSource("reviews-pack")
        let first = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata(), input: ["view": "stalled"])
        let second = try GenericPluginPageRunner().run(
            manifest: manifest, source: source, snapshot: reportSnapshot(), todayYMD: today,
            metadata: metadata(), input: ["view": "stalled"])
        XCTAssertEqual(first, second)
    }
}
