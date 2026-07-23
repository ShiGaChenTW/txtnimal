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
/// evaluates `source`, calls the global `run(input)`, and decodes the returned
/// JSON object into a `PluginPageDocument`.
public struct ReportPluginRunner {
    private struct Input: Encodable {
        struct Task: Encodable {
            let id: String
            let title: String
            let due: String?
            let completed: Bool
            let lists: [String]
            let tags: [String]
        }
        let reportType: String
        let tasks: [Task]
        let todayYMD: String
    }

    public init() {}

    public func run(source: String, reportType: String,
                    snapshot: PluginDocumentSnapshot, todayYMD: String) throws -> PluginPageDocument {
        let input = Input(
            reportType: reportType,
            tasks: snapshot.tasks.map {
                Input.Task(id: $0.id, title: $0.title, due: $0.due,
                           completed: $0.completed, lists: $0.lists, tags: $0.tags)
            },
            todayYMD: todayYMD)

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

        guard let runFunction = context.objectForKeyedSubscript("run"),
              !runFunction.isUndefined, !runFunction.isNull else {
            throw ReportPluginRunnerError.missingRunFunction
        }

        // Setting the JSON as a native string (not concatenating it into evaluated
        // code) keeps the payload out of the parse path — no code injection surface.
        context.setObject(inputJSON, forKeyedSubscript: "__txtnimalReportInput" as NSString)
        guard let result = context.evaluateScript("run(JSON.parse(__txtnimalReportInput))") else {
            throw ReportPluginRunnerError.runReturnedNothing
        }
        if let scriptException { throw ReportPluginRunnerError.scriptException(scriptException) }

        guard let object = result.toObject(), JSONSerialization.isValidJSONObject(object) else {
            throw ReportPluginRunnerError.resultNotJSONObject
        }
        let resultData = try JSONSerialization.data(withJSONObject: object)
        do {
            return try JSONDecoder().decode(PluginPageDocument.self, from: resultData)
        } catch {
            throw ReportPluginRunnerError.decodeFailed(String(describing: error))
        }
    }
}
