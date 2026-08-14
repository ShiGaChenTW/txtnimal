import Foundation

public enum PluginExecutionError: LocalizedError, Equatable, Sendable {
    case transport(String)
    case invalidResponse
    case disabled
    case timedOut
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .transport(let message): return "plugin transport failed: \(message)"
        case .invalidResponse: return "plugin returned an invalid action"
        case .disabled: return "plugin is disabled"
        case .timedOut: return "plugin transport timed out"
        case .responseTooLarge(let bytes): return "plugin transport response exceeded payload limit (\(bytes) bytes)"
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

/// Core-level resource guard for every XPC/plugin transport call.
/// The timeout race intentionally returns immediately and cancels the underlying task;
/// an XPC implementation should invalidate its connection when it observes cancellation.
public struct LimitedPluginExecutionTransport: PluginExecutionTransport {
    public let base: any PluginExecutionTransport
    public let timeoutNanoseconds: UInt64
    public let limits: PluginLimits

    public init(base: any PluginExecutionTransport,
                timeoutNanoseconds: UInt64 = 10_000_000_000,
                limits: PluginLimits = .init()) {
        self.base = base
        self.timeoutNanoseconds = timeoutNanoseconds
        self.limits = limits
    }

    public func execute(pluginID: String, request: Data) async throws -> Data {
        let base = self.base
        let timeout = timeoutNanoseconds
        let maxBytes = limits.maximumPayloadBytes
        return try await withCheckedThrowingContinuation { continuation in
            let state = TransportRaceState()
            let operation = Task {
                do {
                    let response = try await base.execute(pluginID: pluginID, request: request)
                    guard state.complete() else { return }
                    guard response.count <= maxBytes else {
                        continuation.resume(throwing: PluginExecutionError.responseTooLarge(response.count))
                        return
                    }
                    continuation.resume(returning: response)
                } catch {
                    guard state.complete() else { return }
                    continuation.resume(throwing: error)
                }
            }
            Task {
                do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                guard state.complete() else { return }
                operation.cancel()
                continuation.resume(throwing: PluginExecutionError.timedOut)
            }
        }
    }
}

private final class TransportRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func complete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        finished = true
        return true
    }
}

/// Host-owned execution boundary. Transport can be XPC, an in-process test double,
/// or a future signed broker without changing action validation or UI callers.
public actor PluginExecutionCoordinator {
    private let transport: any PluginExecutionTransport
    private var records: [PluginExecutionRecord] = []
    private let maximumRecords = 100

    public init(transport: any PluginExecutionTransport,
                timeoutNanoseconds: UInt64 = 10_000_000_000,
                limits: PluginLimits = .init()) {
        self.transport = LimitedPluginExecutionTransport(base: transport,
                                                          timeoutNanoseconds: timeoutNanoseconds,
                                                          limits: limits)
    }

    public func execute(manifest: PluginManifest, request: Data,
                        taskRevisions: [String: String]? = nil,
                        documentRevision: String? = nil) async throws -> ValidatedPluginIntent {
        do {
            let response = try await transport.execute(pluginID: manifest.id, request: request)
            guard response.count <= PluginLimits().maximumPayloadBytes else {
                throw PluginExecutionError.responseTooLarge(response.count)
            }
            try PluginJSON.rejectDuplicateKeys(response)
            let action = try JSONDecoder().decode(PluginAction.self, from: response)
            let intent = try PluginValidator.validate(action: action, manifest: manifest,
                                                      taskRevisions: taskRevisions,
                                                      documentRevision: documentRevision)
            // Persist has not happened yet — stay pending until the host reports the save result.
            append(PluginExecutionRecord(pluginID: manifest.id, command: intent.command.rawValue, status: .pending))
            return intent
        } catch {
            append(PluginExecutionRecord(pluginID: manifest.id, command: "unknown", status: .failed,
                                         error: (error as? LocalizedError)?.errorDescription ?? String(describing: error)))
            throw error
        }
    }

    public func executionRecords() -> [PluginExecutionRecord] { records }

    /// Host persist of the last validated intent succeeded. No-op if there is no pending record.
    public func recordPersistSucceeded() {
        updateLastPending(to: .applied)
    }

    /// Host persist of the last validated intent failed. No-op if there is no pending record.
    public func recordPersistFailed(_ error: Error) {
        updateLastPending(to: .failed,
                          error: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }

    private func append(_ record: PluginExecutionRecord) {
        records.append(record)
        if records.count > maximumRecords { records.removeFirst(records.count - maximumRecords) }
    }

    private func updateLastPending(to status: PluginExecutionStatus, error: String? = nil) {
        guard let index = records.lastIndex(where: { $0.status == .pending }) else { return }
        let current = records[index]
        records[index] = PluginExecutionRecord(pluginID: current.pluginID, command: current.command,
                                               status: status, timestamp: current.timestamp, error: error)
    }
}
