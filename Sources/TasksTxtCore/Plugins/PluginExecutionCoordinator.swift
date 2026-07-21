import Foundation

public enum PluginExecutionError: LocalizedError, Equatable, Sendable {
    case transport(String)
    case invalidResponse
    case disabled

    public var errorDescription: String? {
        switch self {
        case .transport(let message): return "plugin transport failed: \(message)"
        case .invalidResponse: return "plugin returned an invalid action"
        case .disabled: return "plugin is disabled"
        }
    }
}

public struct PluginExecutionRecord: Codable, Equatable, Sendable {
    public let pluginID: String
    public let command: String
    public let succeeded: Bool
    public let timestamp: Date
    public let error: String?

    public init(pluginID: String, command: String, succeeded: Bool, timestamp: Date = Date(), error: String? = nil) {
        self.pluginID = pluginID; self.command = command; self.succeeded = succeeded
        self.timestamp = timestamp; self.error = error
    }
}

public protocol PluginExecutionTransport: Sendable {
    func execute(pluginID: String, request: Data) async throws -> Data
}

/// Host-owned execution boundary. Transport can be XPC, an in-process test double,
/// or a future signed broker without changing action validation or UI callers.
public actor PluginExecutionCoordinator {
    private let transport: any PluginExecutionTransport
    private var records: [PluginExecutionRecord] = []
    private let maximumRecords = 100

    public init(transport: any PluginExecutionTransport) { self.transport = transport }

    public func execute(manifest: PluginManifest, request: Data,
                        taskRevisions: [String: String]? = nil,
                        documentRevision: String? = nil) async throws -> ValidatedPluginIntent {
        do {
            let response = try await transport.execute(pluginID: manifest.id, request: request)
            guard response.count <= PluginLimits().maximumPayloadBytes else { throw PluginExecutionError.invalidResponse }
            try PluginJSON.rejectDuplicateKeys(response)
            let action = try JSONDecoder().decode(PluginAction.self, from: response)
            let intent = try PluginValidator.validate(action: action, manifest: manifest,
                                                      taskRevisions: taskRevisions,
                                                      documentRevision: documentRevision)
            append(PluginExecutionRecord(pluginID: manifest.id, command: intent.command.rawValue, succeeded: true))
            return intent
        } catch {
            append(PluginExecutionRecord(pluginID: manifest.id, command: "unknown", succeeded: false,
                                         error: (error as? LocalizedError)?.errorDescription ?? String(describing: error)))
            throw error
        }
    }

    public func executionRecords() -> [PluginExecutionRecord] { records }

    private func append(_ record: PluginExecutionRecord) {
        records.append(record)
        if records.count > maximumRecords { records.removeFirst(records.count - maximumRecords) }
    }
}
