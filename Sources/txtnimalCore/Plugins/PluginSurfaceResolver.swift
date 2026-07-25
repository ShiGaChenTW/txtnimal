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
    /// control) wins over the manifest's declared placement; `nil` when neither is present.
    public static func effectiveSection(
        for entry: PluginRegistryEntry,
        overrides: [String: PluginPlacement.Section]
    ) -> PluginPlacement.Section? {
        overrides[entry.manifest.id] ?? entry.manifest.placement?.section
    }

    /// The page-capable plugins a surface should render, in display order.
    ///
    /// - Excludes disabled entries (unless `includeDisabled`) so a gallery toggle immediately
    ///   removes a plugin from its surface.
    /// - Requires `ui.page` — only page-capable plugins render a host view.
    /// - Matches the *effective* section (manifest placement merged with the user override).
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
