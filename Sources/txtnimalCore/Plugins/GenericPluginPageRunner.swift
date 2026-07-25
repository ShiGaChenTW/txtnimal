import Foundation

/// SCO-172: the single generic page entry that collapses the ten bespoke `*PluginPage`
/// methods on `TaskStore`. Given an already-resolved manifest + source, it decides which
/// host context to inject purely from the manifest's declared capabilities and entry
/// controls, then runs the plugin in-process via `ReportPluginRunner`.
///
/// Injection contract (SCO-172):
///   - snapshot / todayYMD / metadata : always injected
///   - `storage.kv` capability         : inject the plugin's kv namespace, otherwise `[:]`
///   - `agent.query` capability        : inject the supplied `agentResult`, otherwise `nil`
///   - reportType / view               : taken from the first `picker` entry control's
///                                       collected value (→ its `defaultValue` → the plugin's
///                                       short id component, e.g. "habit-tracker")
///
/// Keeping the resolution pure (manifest + input in, `PluginPageDocument` out) makes the
/// injection rules unit-testable without the App target's `TaskStore`. `TaskStore.runPluginPage`
/// is a thin adapter that supplies the live snapshot / kv / registry-resolved source.
public struct GenericPluginPageRunner {
    public init() {}

    /// The machine token the entry function switches on — historically `reportType` for
    /// reports and `view` for reviews / methodology / nl-report. Resolution order:
    ///   1. the first `picker` entry control's collected value (`input[control.id]`, verbatim
    ///      even when empty — matching the old bespoke pass-through);
    ///   2. that picker's `defaultValue` when the host collected nothing for it;
    ///   3. the plugin id's last dotted component (e.g. `app.txtnimal.habit-tracker` → `habit-tracker`),
    ///      which reproduces the fixed reportType the pickerless bespoke methods hardcoded.
    public static func resolveReportType(manifest: PluginManifest, input: [String: String]) -> String {
        if let picker = manifest.entryControls?.first(where: { $0.type == .picker }) {
            if let collected = input[picker.id] { return collected }
            if let fallback = picker.defaultValue { return fallback }
        }
        return shortName(for: manifest.id)
    }

    /// The last dotted component of a plugin id — the historical bundled subdirectory /
    /// fixed reportType token (e.g. `app.txtnimal.export-pack` → `export-pack`).
    public static func shortName(for id: String) -> String {
        String(id.split(separator: ".").last ?? Substring(id))
    }

    /// Runs the resolved plugin, injecting host context by capability.
    ///
    /// - Parameters:
    ///   - kvNamespace: the plugin's kv namespace; injected only when the manifest declares
    ///     `storage.kv` (pickerless report plugins never wrote kv, so `[:]` is equivalent).
    ///   - agentResult: the LLM result text; injected only when the manifest declares `agent.query`.
    ///   - input: entry-control values keyed by control id (e.g. `["reportType": "weekly"]`).
    public func run(manifest: PluginManifest,
                    source: String,
                    snapshot: PluginDocumentSnapshot,
                    todayYMD: String,
                    metadata: [String: ReportPluginRunner.TaskMetadata] = [:],
                    kvNamespace: [String: String] = [:],
                    agentResult: String? = nil,
                    input: [String: String] = [:]) throws -> PluginPageDocument {
        let capabilities = Set(manifest.capabilities)
        let reportType = Self.resolveReportType(manifest: manifest, input: input)
        let kv = capabilities.contains(.storageKV) ? kvNamespace : [:]
        let agent = capabilities.contains(.agentQuery) ? agentResult : nil
        return try ReportPluginRunner().run(source: source,
                                            reportType: reportType,
                                            snapshot: snapshot,
                                            todayYMD: todayYMD,
                                            metadata: metadata,
                                            kv: kv,
                                            agentResult: agent)
    }
}
