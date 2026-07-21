import Foundation
import JavaScriptCore
import Darwin

private func applyResourceLimits() {
    var cpu = rlimit(rlim_cur: 2, rlim_max: 2)
    _ = setrlimit(RLIMIT_CPU, &cpu)
    // Keep accidental runaway output bounded independently of Broker framing.
    var fileSize = rlimit(rlim_cur: 512 * 1024, rlim_max: 512 * 1024)
    _ = setrlimit(RLIMIT_FSIZE, &fileSize)
}

applyResourceLimits()

private struct WorkerRequest: Codable {
    let version: Int
    let request: String
    let source: String?
    let inputJSON: String?
    let probePath: String?
}

private struct WorkerResponse: Codable {
    let version: Int
    let status: String
    let payload: String?
}

private func respond(_ status: String, payload: String? = nil) {
    let response = WorkerResponse(version: 1, status: status, payload: payload)
    guard let data = try? JSONEncoder().encode(response) else { exit(70) }
    FileHandle.standardOutput.write(data)
}

guard let line = readLine(), let data = line.data(using: .utf8),
      let request = try? JSONDecoder().decode(WorkerRequest.self, from: data), request.version == 1 else {
    respond("runner-malformed-request")
    exit(65)
}

switch request.request {
case "hang":
    signal(SIGTERM, SIG_IGN)
    Thread.sleep(forTimeInterval: 60)
case "crash":
    exit(72)
case "malformed":
    print("not-json")
case "oversized":
    FileHandle.standardOutput.write(Data(repeating: 0x41, count: 300 * 1024))
case "probe-task-file":
    guard let path = request.probePath else { respond("probe-missing"); break }
    do {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        _ = try handle.read(upToCount: 1)
        try handle.close()
        respond("readable")
    } catch {
        respond("denied")
    }
case "execute-js":
    guard let source = request.source, let inputJSON = request.inputJSON,
          let inputData = inputJSON.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: inputData),
          let context = JSContext() else { respond("js-invalid-input"); break }
    context.exceptionHandler = { _, _ in }
    context.evaluateScript(source)
    guard context.exception == nil, let function = context.objectForKeyedSubscript("run"),
          let result = function.call(withArguments: [input]), context.exception == nil,
          let object = result.toObject(), JSONSerialization.isValidJSONObject(object),
          let resultData = try? JSONSerialization.data(withJSONObject: object),
          let resultJSON = String(data: resultData, encoding: .utf8) else {
        respond("js-execution-error")
        break
    }
    respond("ok", payload: resultJSON)
default:
    respond("ok", payload: "ok:\(request.request)")
}
