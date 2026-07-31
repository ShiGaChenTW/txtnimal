import XCTest
@testable import txtnimalCore

/// SCO-175: the placement-override + enablement merge rules that drive the gallery and the
/// dynamic surface lists. Pure logic — no host, no SwiftUI — so the "which plugin shows where"
/// contract is pinned independent of the UI.
final class PluginSurfaceResolverTests: XCTestCase {

    // MARK: fixtures

    private func entry(id: String,
                       section: PluginPlacement.Section?,
                       order: Int = 0,
                       enabled: Bool = true,
                       pageCapable: Bool = true) -> PluginRegistryEntry {
        let placement = section.map { PluginPlacement(section: $0, order: order) }
        let capabilities: [PluginCapability] = pageCapable ? [.uiPage] : [.tasksAllRead]
        let manifest = PluginManifest(
            id: id, name: id, version: "1.0.0", apiVersion: 1, entry: "main.js",
            capabilities: capabilities, placement: placement)
        return PluginRegistryEntry(manifest: manifest, source: .bundled,
                                   packageRootURL: URL(fileURLWithPath: "/tmp/\(id)"),
                                   enabled: enabled)
    }

    // MARK: effectiveSection

    func testEffectiveSectionUsesManifestPlacementWhenNoOverride() {
        let reportsEntry = entry(id: "a", section: .reports)
        XCTAssertEqual(PluginSurfaceResolver.effectiveSection(for: reportsEntry, overrides: [:]), .reports)
    }

    func testEffectiveSectionOverrideWinsOverManifest() {
        let reportsEntry = entry(id: "a", section: .reports)
        let overrides: [String: PluginPlacement.Section] = ["a": .sidebar]
        XCTAssertEqual(PluginSurfaceResolver.effectiveSection(for: reportsEntry, overrides: overrides), .sidebar)
    }

    /// A page-capable plugin that declares no placement (typical of an installed third-party
    /// package) defaults to the reports surface rather than rendering nowhere.
    func testEffectiveSectionDefaultsToReportsForPlacelessPageCapablePlugin() {
        let placeless = entry(id: "a", section: nil)
        XCTAssertEqual(PluginSurfaceResolver.effectiveSection(for: placeless, overrides: [:]), .reports)
    }

    func testEffectiveSectionOverrideWinsOverReportsFallback() {
        let placeless = entry(id: "a", section: nil)
        let overrides: [String: PluginPlacement.Section] = ["a": .sidebar]
        XCTAssertEqual(PluginSurfaceResolver.effectiveSection(for: placeless, overrides: overrides), .sidebar)
    }

    func testEffectiveSectionNilWhenNoPlacementAndNotPageCapable() {
        let placeless = entry(id: "a", section: nil, pageCapable: false)
        XCTAssertNil(PluginSurfaceResolver.effectiveSection(for: placeless, overrides: [:]))
    }

    // MARK: pagePlugins — placeless fallback

    func testPlacelessPageCapablePluginRendersOnReportsSurfaceOnly() {
        let entries = [entry(id: "a", section: nil)]
        let reports = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: [:])
        let sidebar = PluginSurfaceResolver.pagePlugins(in: .sidebar, from: entries, overrides: [:])
        XCTAssertEqual(reports.map(\.manifest.id), ["a"])
        XCTAssertTrue(sidebar.isEmpty)
    }

    func testPinningPlacelessPluginToSidebarMovesItOffReports() {
        let entries = [entry(id: "a", section: nil)]
        let overrides: [String: PluginPlacement.Section] = ["a": .sidebar]
        let reports = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: overrides)
        let sidebar = PluginSurfaceResolver.pagePlugins(in: .sidebar, from: entries, overrides: overrides)
        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(sidebar.map(\.manifest.id), ["a"])
    }

    func testPlacelessNonPageCapablePluginRendersOnNoSurface() {
        let entries = [entry(id: "a", section: nil, pageCapable: false)]
        let reports = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: [:])
        let sidebar = PluginSurfaceResolver.pagePlugins(in: .sidebar, from: entries, overrides: [:])
        XCTAssertTrue(reports.isEmpty)
        XCTAssertTrue(sidebar.isEmpty)
    }

    // MARK: pagePlugins — reports surface

    func testReportsSurfaceIncludesReportsPluginByDefault() {
        let entries = [entry(id: "a", section: .reports)]
        let result = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: [:])
        XCTAssertEqual(result.map(\.manifest.id), ["a"])
    }

    func testPinningReportsPluginToSidebarRemovesItFromReports() {
        let entries = [entry(id: "a", section: .reports)]
        let overrides: [String: PluginPlacement.Section] = ["a": .sidebar]
        let reports = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: overrides)
        let sidebar = PluginSurfaceResolver.pagePlugins(in: .sidebar, from: entries, overrides: overrides)
        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(sidebar.map(\.manifest.id), ["a"])
    }

    func testPinningSidebarPluginToReportsAddsItToReports() {
        let entries = [entry(id: "a", section: .sidebar)]
        let overrides: [String: PluginPlacement.Section] = ["a": .reports]
        let reports = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: overrides)
        XCTAssertEqual(reports.map(\.manifest.id), ["a"])
    }

    // MARK: pagePlugins — enablement + capability filters

    func testDisabledPluginIsExcludedFromSurface() {
        let entries = [entry(id: "a", section: .reports, enabled: false)]
        let result = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testDisabledPluginIncludedWhenIncludeDisabledRequested() {
        let entries = [entry(id: "a", section: .reports, enabled: false)]
        let result = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries,
                                                       overrides: [:], includeDisabled: true)
        XCTAssertEqual(result.map(\.manifest.id), ["a"])
    }

    func testNonPageCapablePluginIsExcluded() {
        let entries = [entry(id: "a", section: .reports, pageCapable: false)]
        let result = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: [:])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: ordering

    func testSurfaceSortsByOrderThenID() {
        let entries = [
            entry(id: "zebra", section: .reports, order: 1),
            entry(id: "alpha", section: .reports, order: 5),
            entry(id: "beta", section: .reports, order: 1)
        ]
        let result = PluginSurfaceResolver.pagePlugins(in: .reports, from: entries, overrides: [:])
        // order 1 group first, id-sorted (beta < zebra); then order 5 (alpha).
        XCTAssertEqual(result.map(\.manifest.id), ["beta", "zebra", "alpha"])
    }
}
