import Foundation
import txtnimalCore

@objc private protocol PluginBrokerXPCProtocol {
    func execute(request: String, source: String?, inputJSON: String?, probePath: String?,
                 withReply reply: @escaping (String) -> Void)
}

final class PluginBrokerXPCTransport: PluginExecutionTransport, @unchecked Sendable {
    private let serviceName = "app.taskstxt.PluginRunnerSpikeService"

    func execute(pluginID: String, request: Data) async throws -> Data {
        struct Envelope: Codable { let source: String; let inputJSON: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: request),
              let requestJSON = envelope.inputJSON.data(using: .utf8),
              let input = String(data: requestJSON, encoding: .utf8) else {
            throw PluginExecutionError.invalidResponse
        }
        return try await withCheckedThrowingContinuation { continuation in
            // error handler 與 reply 可能都觸發:continuation 只允許 resume 一次
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<Data, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: PluginBrokerXPCProtocol.self)
            connection.invalidationHandler = { connection.invalidationHandler = nil }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate(); resumeOnce(.failure(PluginExecutionError.transport(error.localizedDescription)))
            } as? PluginBrokerXPCProtocol
            guard let proxy else {
                connection.invalidate(); resumeOnce(.failure(PluginExecutionError.transport("invalid broker proxy"))); return
            }
            proxy.execute(request: "execute-js", source: envelope.source, inputJSON: input, probePath: nil) { response in
                connection.invalidate()
                guard let data = response.data(using: .utf8),
                      (try? PluginJSON.rejectDuplicateKeys(data)) != nil else {
                    resumeOnce(.failure(PluginExecutionError.invalidResponse)); return
                }
                resumeOnce(.success(data))
            }
        }
    }

}
