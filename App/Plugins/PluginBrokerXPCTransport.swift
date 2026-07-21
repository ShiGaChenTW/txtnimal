import Foundation
import txtnimalCore

@objc private protocol PluginBrokerXPCProtocol {
    func execute(request: String, source: String?, inputJSON: String?, probePath: String?,
                 withReply reply: @escaping (String) -> Void)
}

final class PluginBrokerXPCTransport: PluginExecutionTransport, @unchecked Sendable {
    private let serviceName = "app.taskstxt.PluginRunnerSpikeService"

    func execute(pluginID: String, request: Data) async throws -> Data {
        guard let requestJSON = String(data: request, encoding: .utf8) else {
            throw PluginExecutionError.invalidResponse
        }
        return try await withCheckedThrowingContinuation { continuation in
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: PluginBrokerXPCProtocol.self)
            connection.invalidationHandler = { connection.invalidationHandler = nil }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate(); continuation.resume(throwing: PluginExecutionError.transport(error.localizedDescription))
            } as? PluginBrokerXPCProtocol
            guard let proxy else {
                connection.invalidate(); continuation.resume(throwing: PluginExecutionError.transport("invalid broker proxy")); return
            }
            proxy.execute(request: "broker-data", source: nil, inputJSON: requestJSON, probePath: nil) { response in
                connection.invalidate()
                guard let data = response.data(using: .utf8), (try? PluginJSON.rejectDuplicateKeys(data)) == nil else {
                    continuation.resume(throwing: PluginExecutionError.invalidResponse); return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
