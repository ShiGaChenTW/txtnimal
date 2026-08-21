import Foundation
import JavaScriptCore

public enum ReportPluginRunnerError: LocalizedError, Sendable {
    case inputEncodingFailed
    case contextUnavailable
    case scriptException(String)
    case missingRunFunction
    case runReturnedNothing
    case resultNotJSONObject
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .inputEncodingFailed: return "failed to encode report input"
        case .contextUnavailable: return "JavaScript context unavailable"
        case .scriptException(let message): return "plugin script exception: \(message)"
        case .missingRunFunction: return "plugin does not define a global run(input) function"
        case .runReturnedNothing: return "plugin run(input) returned no value"
        case .resultNotJSONObject: return "plugin run(input) did not return a JSON object"
        case .decodeFailed(let message): return "failed to decode plugin page document: \(message)"
        }
    }
}

/// Runs a trusted first-party page-returning plugin in-process via JavaScriptCore.
///
/// This is deliberately NOT routed through the XPC broker: the task-report plugin
/// is first-party and only reads a task snapshot the host already holds. The host
/// evaluates `source`, calls the manifest-declared entry function (falling back to
/// `run(input)` for legacy callers), and validates the returned JSON object before
/// handing a `PluginPageDocument` to the host.
public struct ReportPluginRunner {
    /// The pre-G-snap side-channel for fields `PluginTaskSnapshot` did not carry. Since G-snap
    /// the snapshot carries `created` and `quadrant` itself and takes precedence; this type
    /// survives for `done` (completion date, not a G-snap field) and for callers that still
    /// build metadata by hand.
    public struct TaskMetadata: Sendable, Equatable {
        public let created: String?
        public let done: String?
        public let quadrant: Int?
        public init(created: String? = nil, done: String? = nil, quadrant: Int? = nil) {
            self.created = created; self.done = done; self.quadrant = quadrant
        }
    }

    private struct Input: Encodable {
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
            /// G-snap additions. Named after the file-format tokens (`note:`, `rec:`, `focus:`)
            /// to match the existing `q` key, so a plugin author reads one vocabulary.
            let note: String?
            let rec: String?
            let focus: Bool
        }
        let reportType: String
        let tasks: [Task]
        let todayYMD: String
        let kv: [String: String]
        let agentResult: String?
    }

    public init() {}

    public func run(source: String, reportType: String,
                    snapshot: PluginDocumentSnapshot, todayYMD: String,
                    metadata: [String: TaskMetadata] = [:],
                    kv: [String: String] = [:],
                    agentResult: String? = nil,
                    manifest: PluginManifest? = nil) throws -> PluginPageDocument {
        let input = Input(
            reportType: reportType,
            tasks: snapshot.tasks.map { task in
                let meta = metadata[task.id]
                return Input.Task(id: task.id, title: task.title, due: task.due,
                                  completed: task.completed, lists: task.lists, tags: task.tags,
                                  created: task.created ?? meta?.created, done: meta?.done,
                                  q: task.quadrant ?? meta?.quadrant,
                                  note: task.note, rec: task.recurrence, focus: task.focus)
            },
            todayYMD: todayYMD,
            kv: kv,
            agentResult: agentResult)

        // Encode to a JSON string and hand it to JS via JSON.parse. This avoids the
        // Foundation<->JSValue bridging ambiguity where a Swift Bool arrives as a JS
        // number: JSON.parse yields genuine JS booleans, strings, and nulls.
        guard let inputJSON = String(data: try JSONEncoder().encode(input), encoding: .utf8) else {
            throw ReportPluginRunnerError.inputEncodingFailed
        }
        guard let context = JSContext() else { throw ReportPluginRunnerError.contextUnavailable }

        var scriptException: String?
        context.exceptionHandler = { _, value in
            scriptException = value?.toString() ?? "unknown JavaScript exception"
        }

        context.evaluateScript(source)
        if let scriptException { throw ReportPluginRunnerError.scriptException(scriptException) }

        let entryFunctionName = manifest?.pages.first(where: { $0.id == reportType })?.entryFunction
            ?? manifest?.pages.first?.entryFunction
            ?? "run"
        guard let entryFunction = context.objectForKeyedSubscript(entryFunctionName),
              !entryFunction.isUndefined, !entryFunction.isNull else {
            throw ReportPluginRunnerError.missingRunFunction
        }

        // Setting the JSON as a native string (not concatenating it into evaluated
        // code) keeps the payload out of the parse path — no code injection surface.
        context.setObject(inputJSON, forKeyedSubscript: "__txtnimalReportInput" as NSString)
        guard let inputValue = context.evaluateScript("JSON.parse(__txtnimalReportInput)"),
              let result = entryFunction.call(withArguments: [inputValue]) else {
            throw ReportPluginRunnerError.runReturnedNothing
        }
        if let scriptException { throw ReportPluginRunnerError.scriptException(scriptException) }

        guard let object = result.toObject() as? [String: Any], JSONSerialization.isValidJSONObject(object) else {
            throw ReportPluginRunnerError.resultNotJSONObject
        }
        let resultData = try JSONSerialization.data(withJSONObject: object)
        do {
            let validationManifest = manifest.map { manifest in
                guard !manifest.pages.contains(where: { $0.id == reportType }) else { return manifest }
                return PluginManifest(id: manifest.id, name: manifest.name, version: manifest.version,
                                      apiVersion: manifest.apiVersion, entry: manifest.entry,
                                      capabilities: manifest.capabilities, commands: manifest.commands,
                                      pages: manifest.pages + [PluginPageDeclaration(id: reportType,
                                                                                    title: reportType,
                                                                                    entryFunction: entryFunctionName)],
                                      entryControls: manifest.entryControls, placement: manifest.placement)
            } ?? PluginManifest(id: "app.txtnimal.legacy", name: "Legacy", version: "1.0.0",
                                apiVersion: 1, entry: "main.js", capabilities: PluginCapability.allCases,
                                pages: Array(Set([reportType,
                                                   (object["page"] as? [String: Any])?["pageID"] as? String,
                                                   "weekly", "progress", "category", "standup",
                                                   "daily", "stalled", "gtd", "eisenhower", "para", "triage"]))
                                    .compactMap { $0 }
                                    .map { PluginPageDeclaration(id: $0, title: $0,
                                                                 entryFunction: entryFunctionName) })
            return try PluginValidator.decodePage(resultData, manifest: validationManifest)
        } catch {
            throw ReportPluginRunnerError.decodeFailed(String(describing: error))
        }
    }
}
