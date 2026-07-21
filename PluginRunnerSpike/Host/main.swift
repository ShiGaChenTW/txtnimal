import Foundation
import txtnimalCore

struct ScenarioResult: Codable {
    let scenario: String
    let outcome: String
    let elapsedMilliseconds: Int
}

let arguments = CommandLine.arguments
let probePath = value(after: "--probe-path")
let repoRoot = value(after: "--repo-root") ?? FileManager.default.currentDirectoryPath

func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

func run(_ scenario: String, source: String? = nil, inputJSON: String? = nil,
         timeout: TimeInterval = 2.0) -> ScenarioResult {
    let started = ContinuousClock.now
    let connection = NSXPCConnection(serviceName: pluginRunnerSpikeServiceName)
    connection.remoteObjectInterface = NSXPCInterface(with: PluginRunnerXPCProtocol.self)
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var outcome: String?
    func finish(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        guard outcome == nil else { return }
        outcome = value
        semaphore.signal()
    }
    connection.invalidationHandler = { finish("invalidated") }
    connection.interruptionHandler = { finish("interrupted") }
    connection.resume()
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish("proxy-error") }
        as? PluginRunnerXPCProtocol
    proxy?.execute(request: scenario, source: source, inputJSON: inputJSON, probePath: probePath) { finish($0) }
    if semaphore.wait(timeout: .now() + timeout) == .timedOut { finish("host-timeout") }
    connection.invalidate()
    let duration = ContinuousClock.now - started
    return ScenarioResult(scenario: scenario, outcome: outcome ?? "no-result",
                          elapsedMilliseconds: Int(duration.components.seconds * 1_000)
                              + Int(duration.components.attoseconds / 1_000_000_000_000_000))
}

func runCommandFixture() -> ScenarioResult {
    let root = URL(fileURLWithPath: repoRoot).appendingPathComponent("PluginFixtures/reschedule-tomorrow")
    do {
        let manifest = try PluginValidator.decodeManifest(Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let source = try String(contentsOf: PluginValidator.resolveEntry(manifest.entry, in: root), encoding: .utf8)
        let input = "{\"taskIDs\":[\"task-123\"],\"tomorrow\":\"2026-07-22\",\"revision\":\"rev-1\"}"
        let result = run("execute-js", source: source, inputJSON: input)
        guard let data = result.outcome.data(using: .utf8),
              let action = try? JSONDecoder().decode(PluginAction.self, from: data),
              let intent = try? PluginValidator.validate(action: action, manifest: manifest,
                                                         taskRevisions: ["task-123": "rev-1"],
                                                         documentRevision: "rev-1") else {
            return ScenarioResult(scenario: "command-fixture", outcome: "fixture-validation-error",
                                  elapsedMilliseconds: result.elapsedMilliseconds)
        }
        return ScenarioResult(scenario: "command-fixture", outcome: "validated:\(intent.command.rawValue)",
                              elapsedMilliseconds: result.elapsedMilliseconds)
    } catch {
        return ScenarioResult(scenario: "command-fixture", outcome: "fixture-load-error", elapsedMilliseconds: 0)
    }
}

let results = [
    run("echo"), run("warm-echo"), runCommandFixture(), run("hang"), run("probe-task-file"),
    run("malformed"), run("oversized"), run("crash"), run("recovery")
]
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(data: try encoder.encode(results), encoding: .utf8)!)

let values = Dictionary(uniqueKeysWithValues: results.map { ($0.scenario, $0.outcome) })
let passed = values["echo"] == "ok:echo"
    && values["warm-echo"] == "ok:warm-echo"
    && values["command-fixture"] == "validated:tasks.reschedule"
    && values["hang"] == "runner-timeout"
    && values["probe-task-file"] == "denied"
    && values["malformed"] == "runner-malformed-response"
    && values["oversized"] == "runner-response-too-large"
    && values["crash"] == "runner-crash"
    && values["recovery"] == "ok:recovery"
exit(passed ? 0 : 1)
