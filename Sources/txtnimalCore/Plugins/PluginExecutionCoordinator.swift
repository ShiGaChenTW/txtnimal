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

public enum PluginExecutionStatus: String, Codable, Equatable, Sendable {
    case pending
    case cancelled
    case applied
    case failed
}

public struct PluginExecutionRecord: Codable, Equatable, Sendable {
    public let pluginID: String
    public let command: String
    public let status: PluginExecutionStatus
    public let timestamp: Date
    public let error: String?
    public var succeeded: Bool { status == .applied }

    public init(pluginID: String, command: String, succeeded: Bool, timestamp: Date = Date(), error: String? = nil) {
        self.init(pluginID: pluginID, command: command, status: succeeded ? .applied : .failed,
                  timestamp: timestamp, error: error)
    }

    public init(pluginID: String, command: String, status: PluginExecutionStatus,
                timestamp: Date = Date(), error: String? = nil) {
        self.pluginID = pluginID; self.command = command; self.status = status
        self.timestamp = timestamp; self.error = error
    }

    private enum CodingKeys: String, CodingKey { case pluginID, command, status, succeeded, timestamp, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginID = try container.decode(String.self, forKey: .pluginID)
        command = try container.decode(String.self, forKey: .command)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        if let decodedStatus = try container.decodeIfPresent(PluginExecutionStatus.self, forKey: .status) {
            status = decodedStatus
        } else {
            status = try container.decode(Bool.self, forKey: .succeeded) ? .applied : .failed
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pluginID, forKey: .pluginID)
        try container.encode(command, forKey: .command)
        try container.encode(status, forKey: .status)
        try container.encode(succeeded, forKey: .succeeded)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(error, forKey: .error)
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
            append(PluginExecutionRecord(pluginID: manifest.id, command: intent.command.rawValue, status: .applied))
            return intent
        } catch {
            append(PluginExecutionRecord(pluginID: manifest.id, command: "unknown", status: .failed,
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
