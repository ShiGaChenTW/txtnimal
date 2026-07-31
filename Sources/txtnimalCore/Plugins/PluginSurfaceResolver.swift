import Foundation

/// SCO-175: pure placement/enablement resolution shared by the plugin gallery and the dynamic
/// surface lists (`reportPagePlugins` / `sidebarPagePlugins`).
///
/// The registry already stamps each entry's `enabled` flag from the host's `disabledIDs`. This
/// resolver layers the *user placement override* on top of the manifest's declared placement and
/// produces the ordered, capability-filtered list a given surface should render. Keeping it a pure
/// function (no host / SwiftUI dependency) makes the "which plugin shows where" rules testable in
/// isolation — the gallery toggles only mutate persisted state, then re-ask this resolver.
public enum PluginSurfaceResolver {

    /// The section a plugin effectively belongs to: a user override (from the gallery's "pin"
    /// control) wins over the manifest's declared placement.
    ///
    /// When neither is present, a **page-capable** plugin falls back to `.reports` — a plugin that
    /// renders a page but declares no home still has to land on the default surface, otherwise it
    /// renders nowhere while the gallery's pin control claims it is on 報表. Plugins without
    /// `ui.page` stay `nil`: they never render a host view, so pinning them is meaningless.
    public static func effectiveSection(
        for entry: PluginRegistryEntry,
        overrides: [String: PluginPlacement.Section]
    ) -> PluginPlacement.Section? {
        if let declared = overrides[entry.manifest.id] ?? entry.manifest.placement?.section {
            return declared
        }
        return entry.manifest.capabilities.contains(.uiPage) ? .reports : nil
    }

    /// The page-capable plugins a surface should render, in display order.
    ///
    /// - Excludes disabled entries (unless `includeDisabled`) so a gallery toggle immediately
    ///   removes a plugin from its surface.
    /// - Requires `ui.page` — only page-capable plugins render a host view.
    /// - Matches the *effective* section (manifest placement merged with the user override, with
    ///   page-capable plugins that declare neither defaulting to `.reports`).
    /// - Sorts by `placement.order` ascending, then by id as a stable tiebreak.
    public static func pagePlugins(
        in section: PluginPlacement.Section,
        from entries: [PluginRegistryEntry],
        overrides: [String: PluginPlacement.Section],
        includeDisabled: Bool = false
    ) -> [PluginRegistryEntry] {
        entries
            .filter { includeDisabled || $0.enabled }
            .filter { $0.manifest.capabilities.contains(.uiPage) }
            .filter { effectiveSection(for: $0, overrides: overrides) == section }
            .sorted {
                let lhs = $0.manifest.placement?.order ?? Int.max
                let rhs = $1.manifest.placement?.order ?? Int.max
                if lhs != rhs { return lhs < rhs }
                return $0.manifest.id < $1.manifest.id
            }
    }
}
