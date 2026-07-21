import Darwin
import Foundation
import Security

private let maximumRequestBytes = 64 * 1024
private let maximumResponseBytes = 256 * 1024

final class PluginRunnerService: NSObject, PluginRunnerXPCProtocol {
    func execute(request: String, source: String?, inputJSON: String?, probePath: String?,
                 withReply reply: @escaping (String) -> Void) {
        let envelope = WorkerRequest(version: 1, request: request, source: source,
                                     inputJSON: inputJSON, probePath: probePath)
        guard let requestData = try? JSONEncoder().encode(envelope),
              requestData.count <= maximumRequestBytes else {
            reply("broker-request-too-large")
            return
        }
        guard let workerURL = workerExecutableURL() else {
            reply("broker-worker-missing")
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = workerURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch {
            reply("broker-launch-error")
            return
        }

        let state = ExecutionState()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            guard state.markTimedOut() else { return }
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }

        DispatchQueue.global().async {
            input.fileHandleForWriting.write(requestData + Data([0x0a]))
            try? input.fileHandleForWriting.close()
            let (responseData, exceededLimit) = readBounded(output.fileHandleForReading,
                                                            maximumBytes: maximumResponseBytes)
            if exceededLimit, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            state.markFinished()

            let outcome: String
            if state.wasTimedOut {
                outcome = "runner-timeout"
            } else if exceededLimit {
                outcome = "runner-response-too-large"
            } else if process.terminationStatus != 0 {
                outcome = "runner-crash"
            } else if let response = try? JSONDecoder().decode(WorkerResponse.self, from: responseData),
                      response.version == 1 {
                outcome = response.payload ?? response.status
            } else {
                outcome = "runner-malformed-response"
            }
            reply(outcome)
        }
    }

    private func workerExecutableURL() -> URL? {
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "PluginRunnerSpikeWorker"),
            Bundle.main.url(forResource: "PluginRunnerSpikeWorker", withExtension: "app")?
                .appendingPathComponent("Contents/MacOS/PluginRunnerSpikeWorker"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/PluginRunnerSpikeWorker.app/Contents/MacOS/PluginRunnerSpikeWorker")
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private func readBounded(_ handle: FileHandle, maximumBytes: Int) -> (Data, Bool) {
    var result = Data()
    while result.count <= maximumBytes {
        let remaining = maximumBytes + 1 - result.count
        guard let chunk = try? handle.read(upToCount: min(64 * 1024, remaining)),
              !chunk.isEmpty else { break }
        result.append(chunk)
    }
    return (result, result.count > maximumBytes)
}

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

private final class ExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false
    private var finished = false
    var wasTimedOut: Bool { lock.withLock { timedOut } }
    func markTimedOut() -> Bool {
        lock.withLock {
            guard !finished else { return false }
            timedOut = true
            return true
        }
    }
    func markFinished() { lock.withLock { finished = true } }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock(); defer { unlock() }
        return operation()
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = PluginRunnerService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard BrokerCallerIdentity.isAllowed(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: PluginRunnerXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

private enum BrokerCallerIdentity {
    private static let allowedIdentifiers = Set(["app.txtnimal.txtnimal", "app.taskstxt.PluginRunnerSpikeHost"])

    static func isAllowed(_ connection: NSXPCConnection) -> Bool {
        let attributes: [CFString: Any] = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)]
        var guest: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &guest) == errSecSuccess,
              let guest else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(guest, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String else { return false }
        guard allowedIdentifiers.contains(identifier) else { return false }
        // Require an Apple-generic signed code object with the expected bundle identifier;
        // ad-hoc identities expose no valid designated requirement and are rejected.
        var requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"\(identifier)\""
        guard SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess else { return false }
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
