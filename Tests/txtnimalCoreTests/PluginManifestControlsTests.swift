import Foundation
import XCTest
@testable import txtnimalCore

/// SCO-173: manifest schema extension — entry controls + sidebar/report placement.
/// Covers schema decode/round-trip, backward compatibility, rejection of malformed
/// declarations, and that all 12 shipped fixture manifests still parse via `decodeManifest`.
final class PluginManifestControlsTests: XCTestCase {

    // MARK: - Helpers

    private func assertValidationError<T>(_ expected: PluginValidationError, file: StaticString = #filePath,
                                          line: UInt = #line, _ operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? PluginValidationError, expected, file: file, line: line)
        }
    }

    /// repoRoot/Tests/txtnimalCoreTests/ThisFile.swift -> repoRoot (mirrors ReportPluginRunnerTests).
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // txtnimalCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func fixtureManifestData(_ name: String) throws -> Data {
        let url = repoRoot().appendingPathComponent("PluginFixtures/\(name)/manifest.json")
        return try Data(contentsOf: url)
    }

    private static let allFixtures = [
        "analytics", "brain-dump", "export-pack", "habit-tracker", "importers", "methodology",
        "nl-report", "reschedule-tomorrow", "reviews-pack", "smart-triage", "task-report", "weekly-review",
    ]

    /// A full manifest JSON string with injectable `entryControls` / `placement` fragments.
    private func manifestJSON(entryControls: String? = nil, placement: String? = nil) -> Data {
        var fields = """
        "id":"app.txtnimal.controls-test","name":"Controls Test","version":"1.0.0","apiVersion":1,\
        "entry":"main.js","capabilities":["tasks.all.read","ui.page"],"commands":[],\
        "pages":[{"id":"page-1","title":"Page","entryFunction":"run"}]
        """
        if let entryControls { fields += ",\"entryControls\":\(entryControls)" }
        if let placement { fields += ",\"placement\":\(placement)" }
        return Data("{\(fields)}".utf8)
    }

    // MARK: - Round-trip / decode

    func testEntryControlPickerRoundTrips() throws {
        let control = PluginEntryControl(
            id: "reportType", type: .picker, label: "選擇範本", defaultValue: "weekly",
            options: [PluginEntryOption(value: "weekly", label: "週報"),
                      PluginEntryOption(value: "standup", label: "站會日報")])
        let manifest = PluginManifest(
            id: "app.txtnimal.rt", name: "RT", version: "1.0.0", apiVersion: 1, entry: "main.js",
            capabilities: [.tasksAllRead, .uiPage],
            pages: [PluginPageDeclaration(id: "rt", title: "RT", entryFunction: "run")],
            entryControls: [control],
            placement: PluginPlacement(section: .reports, order: 10, icon: "doc.text"))
        let decoded = try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.entryControls?.first?.id, "reportType")
        XCTAssertEqual(decoded.entryControls?.first?.options?.count, 2)
        XCTAssertEqual(decoded.placement?.section, .reports)
        XCTAssertEqual(decoded.placement?.icon, "doc.text")
    }

    func testPlacementSectionsRoundTrip() throws {
        for section in [PluginPlacement.Section.sidebar, .reports] {
            let placement = PluginPlacement(section: section, order: 5, icon: nil)
            let decoded = try JSONDecoder().decode(PluginPlacement.self, from: JSONEncoder().encode(placement))
            XCTAssertEqual(decoded, placement)
            XCTAssertNil(decoded.icon)
        }
    }

    func testLegacyManifestWithoutNewFieldsStillDecodesToNil() throws {
        let legacy = Data("""
        {"id":"app.txtnimal.legacy","name":"Legacy","version":"1.0.0","apiVersion":1,\
        "entry":"main.js","capabilities":["tasks.all.read","ui.page"],"commands":[],\
        "pages":[{"id":"legacy","title":"Legacy","entryFunction":"run"}]}
        """.utf8)
        let manifest = try PluginValidator.decodeManifest(legacy)
        XCTAssertNil(manifest.entryControls)
        XCTAssertNil(manifest.placement)
    }

    func testDecodeManifestAcceptsEntryControlsAndPlacement() throws {
        let data = manifestJSON(
            entryControls: """
            [{"id":"view","type":"picker","label":"視圖","defaultValue":"weekly",\
            "options":[{"value":"weekly","label":"週報"},{"value":"daily","label":"日報"}]}]
            """,
            placement: "{\"section\":\"reports\",\"order\":20,\"icon\":\"chart.bar\"}")
        let manifest = try PluginValidator.decodeManifest(data)
        XCTAssertEqual(manifest.entryControls?.count, 1)
        XCTAssertEqual(manifest.entryControls?.first?.type, .picker)
        XCTAssertEqual(manifest.placement?.order, 20)
    }

    func testToggleAndTextFieldControlsDecode() throws {
        let data = manifestJSON(entryControls: """
            [{"id":"includeDone","type":"toggle","label":"包含已完成","defaultValue":"false"},\
            {"id":"heading","type":"textField","label":"標題","defaultValue":"我的報告"}]
            """)
        let manifest = try PluginValidator.decodeManifest(data)
        XCTAssertEqual(manifest.entryControls?.count, 2)
        XCTAssertEqual(manifest.entryControls?[0].type, .toggle)
        XCTAssertEqual(manifest.entryControls?[1].type, .textField)
        XCTAssertEqual(manifest.entryControls?[1].defaultValue, "我的報告")
    }

    // MARK: - All fixtures parse

    func testAllTwelveFixtureManifestsDecode() throws {
        var seen = Set<String>()
        for name in Self.allFixtures {
            let data = try fixtureManifestData(name)
            let manifest = try PluginValidator.decodeManifest(data)
            XCTAssertTrue(seen.insert(manifest.id).inserted, "duplicate id \(manifest.id)")
            XCTAssertNotNil(manifest.placement, "\(name) should declare placement")
        }
        XCTAssertEqual(seen.count, 12)
    }

    func testFixturesWithEntryControlsExposeExpectedShape() throws {
        let taskReport = try PluginValidator.decodeManifest(try fixtureManifestData("task-report"))
        let control = try XCTUnwrap(taskReport.entryControls?.first)
        XCTAssertEqual(control.id, "reportType")
        XCTAssertEqual(control.type, .picker)
        XCTAssertEqual(control.defaultValue, "weekly")
        XCTAssertEqual(control.options?.map(\.value), ["weekly", "progress", "category", "standup"])

        let methodology = try PluginValidator.decodeManifest(try fixtureManifestData("methodology"))
        XCTAssertEqual(methodology.entryControls?.first?.defaultValue, "gtd")

        let analytics = try PluginValidator.decodeManifest(try fixtureManifestData("analytics"))
        XCTAssertNil(analytics.entryControls, "analytics has no entry inputs")
    }

    func testCommandPluginPlacedInSidebar() throws {
        let reschedule = try PluginValidator.decodeManifest(try fixtureManifestData("reschedule-tomorrow"))
        XCTAssertEqual(reschedule.placement?.section, .sidebar)
        XCTAssertTrue(reschedule.pages.isEmpty)
    }

    // MARK: - Rejections (missing / illegal declarations)

    func testPickerWithoutOptionsIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"view","type":"picker","label":"視圖"}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testPickerWithEmptyOptionsIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"view","type":"picker","label":"視圖","options":[]}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testDefaultNotAmongOptionsIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"view","type":"picker","label":"視圖","defaultValue":"nope",\
            "options":[{"value":"weekly","label":"週報"}]}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testDuplicateControlIDIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"view","type":"toggle","label":"A"},{"id":"view","type":"toggle","label":"B"}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testEmptyControlLabelIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"view","type":"toggle","label":"   "}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testInvalidControlIDIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"bad id!","type":"toggle","label":"A"}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testToggleWithOptionsIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"flag","type":"toggle","label":"旗標","options":[{"value":"x","label":"X"}]}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testToggleWithNonBooleanDefaultIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"flag","type":"toggle","label":"旗標","defaultValue":"maybe"}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testDuplicateOptionValuesRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"view","type":"picker","label":"視圖",\
            "options":[{"value":"weekly","label":"A"},{"value":"weekly","label":"B"}]}]
            """)
        assertValidationError(.invalidEntryControl) { try PluginValidator.decodeManifest(data) }
    }

    func testUnknownKeyInEntryControlIsRejected() {
        let data = manifestJSON(entryControls: """
            [{"id":"view","type":"toggle","label":"A","bogus":true}]
            """)
        // requireOnly rejects unknown keys as invalidNode.
        assertValidationError(.invalidNode) { try PluginValidator.decodeManifest(data) }
    }

    func testInvalidControlTypeEnumThrowsAtDecode() {
        let data = manifestJSON(entryControls: """
            [{"id":"view","type":"slider","label":"A"}]
            """)
        // Unknown enum value => JSONDecoder DecodingError (a rejection), not a PluginValidationError.
        XCTAssertThrowsError(try PluginValidator.decodeManifest(data)) { error in
            XCTAssertFalse(error is PluginValidationError)
        }
    }

    // MARK: - Placement rejections

    func testInvalidPlacementSectionThrowsAtDecode() {
        let data = manifestJSON(placement: "{\"section\":\"footer\",\"order\":1}")
        XCTAssertThrowsError(try PluginValidator.decodeManifest(data)) { error in
            XCTAssertFalse(error is PluginValidationError)
        }
    }

    func testPlacementOrderOutOfRangeIsRejected() {
        let data = manifestJSON(placement: "{\"section\":\"reports\",\"order\":-1}")
        assertValidationError(.invalidPlacement) { try PluginValidator.decodeManifest(data) }
    }

    func testPlacementIconWithPathSeparatorIsRejected() {
        let data = manifestJSON(placement: "{\"section\":\"reports\",\"order\":1,\"icon\":\"../evil\"}")
        assertValidationError(.invalidPlacement) { try PluginValidator.decodeManifest(data) }
    }

    func testPlacementIconWithSpaceIsRejected() {
        let data = manifestJSON(placement: "{\"section\":\"reports\",\"order\":1,\"icon\":\"chart bar\"}")
        assertValidationError(.invalidPlacement) { try PluginValidator.decodeManifest(data) }
    }

    func testUnknownKeyInPlacementIsRejected() {
        let data = manifestJSON(placement: "{\"section\":\"reports\",\"order\":1,\"color\":\"red\"}")
        assertValidationError(.invalidNode) { try PluginValidator.decodeManifest(data) }
    }
}
