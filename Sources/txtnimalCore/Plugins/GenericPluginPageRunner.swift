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

    /// The request envelope shared with the PluginRunnerSpike XPC worker.
    /// `inputJSON` remains a JSON string for compatibility with the existing service.
    public struct ExecutionRequest: Codable, Equatable, Sendable {
        public let source: String
        public let inputJSON: String
        public init(source: String, inputJSON: String) {
            self.source = source
            self.inputJSON = inputJSON
        }
    }

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
                                            agentResult: agent,
                                            manifest: manifest)
    }

    /// Executes a page according to its registry origin. Bundled entries retain the trusted
    /// in-process JavaScriptCore path; installed entries can only use the supplied transport.
    /// Both paths return only a page that has passed `PluginValidator.decodePage`.
    public func run(entry: PluginRegistryEntry,
                    source: String,
                    snapshot: PluginDocumentSnapshot,
                    todayYMD: String,
                    metadata: [String: ReportPluginRunner.TaskMetadata] = [:],
                    kvNamespace: [String: String] = [:],
                    agentResult: String? = nil,
                    input: [String: String] = [:],
                    transport: any PluginExecutionTransport,
                    timeoutNanoseconds: UInt64 = 10_000_000_000,
                    limits: PluginLimits = .init()) async throws -> PluginPageDocument {
        guard entry.enabled else { throw PluginExecutionError.disabled }
        if entry.source == .bundled {
            return try run(manifest: entry.manifest, source: source, snapshot: snapshot,
                           todayYMD: todayYMD, metadata: metadata, kvNamespace: kvNamespace,
                           agentResult: agentResult, input: input)
        }

        let reportType = Self.resolveReportType(manifest: entry.manifest, input: input)
        let capabilities = Set(entry.manifest.capabilities)
        let pageInput = PageInput(
            reportType: reportType,
            tasks: snapshot.tasks.map { task in
                let meta = metadata[task.id]
                return PageInput.Task(id: task.id, title: task.title, due: task.due,
                                      completed: task.completed, lists: task.lists, tags: task.tags,
                                      created: meta?.created, done: meta?.done, q: meta?.quadrant)
            },
            todayYMD: todayYMD,
            kv: capabilities.contains(.storageKV) ? kvNamespace : [:],
            agentResult: capabilities.contains(.agentQuery) ? agentResult : nil)
        let inputData = try JSONEncoder().encode(pageInput)
        guard let inputJSON = String(data: inputData, encoding: .utf8) else {
            throw ReportPluginRunnerError.inputEncodingFailed
        }
        let request = try JSONEncoder().encode(ExecutionRequest(source: source, inputJSON: inputJSON))
        let bounded = LimitedPluginExecutionTransport(base: transport,
                                                       timeoutNanoseconds: timeoutNanoseconds,
                                                       limits: limits)
        let response = try await bounded.execute(pluginID: entry.manifest.id, request: request)
        return try PluginValidator.decodePage(response, manifest: entry.manifest, limits: limits)
    }

    private struct PageInput: Encodable {
        struct Task: Encodable {
            let id: String
            let title: String
            let due: String?
            let completed: Bool
            let lists: [String]
            let tags: [String]
            let created: String?
            let done: String?
            let q: Int?
        }
        let reportType: String
        let tasks: [Task]
        let todayYMD: String
        let kv: [String: String]
        let agentResult: String?
    }
}
