import Foundation

public protocol AgentTransport: Sendable {
    /// Sends a host-assembled request and returns raw structured JSON bytes.
    func complete(request: Data) async throws -> Data
}

public enum AgentRunnerError: LocalizedError, Equatable, Sendable {
    case transport(String)
    case timedOut
    case cancelled
    case payloadTooLarge
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .transport(let message): return "agent transport failed: \(message)"
        case .timedOut: return "agent query timed out"
        case .cancelled: return "agent query was cancelled"
        case .payloadTooLarge: return "agent response exceeded the payload limit"
        case .invalidResponse: return "agent returned an invalid structured response"
        }
    }
}

private struct AgentTransportRequest: Codable, Sendable {
    let prompt: String
    let taskIDs: [String]
    let resultSchema: String
}

private struct AgentTaskUpdate: Codable, Sendable {
    let taskID: String
    let newDue: String
}

public actor AgentRunner {
    private let transport: any AgentTransport
    private let timeoutNanoseconds: UInt64
    private let limits: PluginLimits
    private var records: [(id: UUID, record: PluginExecutionRecord)] = []
    private let maximumRecords = 100

    public init(transport: any AgentTransport, timeoutNanoseconds: UInt64 = 90_000_000_000,
                limits: PluginLimits = .init()) {
        self.transport = transport
        self.timeoutNanoseconds = timeoutNanoseconds
        self.limits = limits
    }

    public func execute(query: PluginAction, manifest: PluginManifest,
                        taskRevisions: [String: String], documentRevision: String? = nil) async throws
        -> [ValidatedPluginIntent] {
        let executionID = UUID()
        append(id: executionID, record: PluginExecutionRecord(pluginID: manifest.id,
                                                               command: PluginCapability.agentQuery.rawValue,
                                                               status: .pending))
        do {
            try PluginValidator.validateAgentQuery(action: query, manifest: manifest, limits: limits)
            try Task.checkCancellation()
            let request = try JSONEncoder().encode(AgentTransportRequest(prompt: query.prompt ?? "",
                                                                          taskIDs: query.taskIDs ?? [],
                                                                          resultSchema: query.resultSchema ?? ""))
            let response = try await response(for: request)
            try Task.checkCancellation()
            guard response.count <= limits.maximumPayloadBytes else { throw AgentRunnerError.payloadTooLarge }

            let updates: [AgentTaskUpdate]
            do {
                try PluginJSON.rejectDuplicateKeys(response)
                updates = try JSONDecoder().decode([AgentTaskUpdate].self, from: response)
            } catch {
                throw AgentRunnerError.invalidResponse
            }
            let selectedTaskIDs = Set(query.taskIDs ?? [])
            guard updates.count <= limits.maximumQueryResults,
                  Set(updates.map(\.taskID)).count == updates.count,
                  updates.allSatisfy({ selectedTaskIDs.contains($0.taskID) }) else {
                throw AgentRunnerError.invalidResponse
            }

            let intents = try updates.map { update in
                let action = PluginAction(type: .hostCommand, command: PluginHostCommand.rescheduleTask.rawValue,
                                          taskIDs: [update.taskID], due: update.newDue,
                                          expectedRevision: query.expectedRevision,
                                          documentRevision: query.documentRevision)
                return try PluginValidator.validate(action: action, manifest: manifest,
                                                    taskRevisions: taskRevisions,
                                                    documentRevision: documentRevision,
                                                    limits: limits)
            }
            update(id: executionID, status: .applied)
            return intents
        } catch {
            if let validationError = error as? PluginValidationError {
                update(id: executionID, status: .failed, error: validationError.errorDescription)
                throw validationError
            }
            let normalized = normalize(error)
            update(id: executionID, status: normalized == .cancelled ? .cancelled : .failed,
                   error: normalized.errorDescription)
            throw normalized
        }
    }

    public func executionRecords() -> [PluginExecutionRecord] { records.map(\.record) }

    private func response(for request: Data) async throws -> Data {
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { [transport] in try await transport.complete(request: request) }
                group.addTask { [timeoutNanoseconds] in
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    throw AgentRunnerError.timedOut
                }
                defer { group.cancelAll() }
                guard let response = try await group.next() else { throw AgentRunnerError.invalidResponse }
                group.cancelAll()
                return response
            }
        } catch is CancellationError {
            throw AgentRunnerError.cancelled
        } catch let error as AgentRunnerError {
            throw error
        } catch {
            throw AgentRunnerError.transport((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func normalize(_ error: Error) -> AgentRunnerError {
        if error is CancellationError { return .cancelled }
        if let agentError = error as? AgentRunnerError { return agentError }
        return .transport((error as? LocalizedError)?.errorDescription ?? String(describing: error))
    }

    private func append(id: UUID, record: PluginExecutionRecord) {
        records.append((id, record))
        if records.count > maximumRecords { records.removeFirst(records.count - maximumRecords) }
    }

    private func update(id: UUID, status: PluginExecutionStatus, error: String? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let current = records[index].record
        records[index].record = PluginExecutionRecord(pluginID: current.pluginID, command: current.command,
                                                       status: status, timestamp: current.timestamp, error: error)
    }
}
