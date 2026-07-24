import Foundation

/// The plugin-facing result of an `agent.query`. It carries ONLY the model's answer and the
/// schema id the caller asked for — never the API key, endpoint URL, or any credential config.
/// This type is the security boundary: a plugin that receives an `AgentQueryResult` structurally
/// cannot read the host's secrets, because there is nowhere for them to live.
public struct AgentQueryResult: Equatable, Sendable {
    public let resultSchema: String
    public let text: String

    public init(resultSchema: String, text: String) {
        self.resultSchema = resultSchema
        self.text = text
    }
}

public enum AgentQueryBrokerError: LocalizedError, Equatable, Sendable {
    case missingCapability
    case invalidRequest
    case timedOut
    case emptyResult
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .missingCapability:
            return "外掛未宣告 agent.query 權限,無法發送 AI 查詢。"
        case .invalidRequest:
            return "AI 查詢的提示或結果格式不可為空。"
        case .timedOut:
            return "AI 查詢逾時。"
        case .emptyResult:
            return "AI 未回傳有效結果。"
        case .transport(let message):
            return "AI 查詢傳輸失敗:\(message)"
        }
    }
}

/// Host-side broker for the `agent.query` capability.
///
/// A plugin sends only `{prompt, resultSchema}` and receives back an `AgentQueryResult`. The host
/// holds the credentials (`KeychainAgentCredentialStore`) and makes the network call through the
/// existing `AgentChatClient` — the plugin never sees the key, the endpoint, or the config. The
/// broker returns DATA only: it never writes tasks and never constructs a task mutation. Any task
/// change a plugin later derives from a result must still flow through `PluginValidator.validate`
/// and the reviewed-mutation pipeline.
public struct AgentQueryBroker: Sendable {
    private let credentialStore: any AgentCredentialStore
    private let session: URLSession
    private let timeoutNanoseconds: UInt64

    public init(credentialStore: any AgentCredentialStore, session: URLSession = .shared,
                timeoutNanoseconds: UInt64 = 90_000_000_000) {
        self.credentialStore = credentialStore
        self.session = session
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    /// Runs a plugin's `agent.query`. Gates the capability BEFORE any credential or network access,
    /// so a plugin without `agent.query` never triggers a request. Bounds the call with a wall-clock
    /// timeout (mirrors `AgentRunner`), and surfaces every failure as a typed error — never a silent nil.
    public func query(prompt: String, resultSchema: String, manifest: PluginManifest) async throws -> AgentQueryResult {
        guard Set(manifest.capabilities).contains(.agentQuery) else {
            throw AgentQueryBrokerError.missingCapability
        }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSchema = resultSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !trimmedSchema.isEmpty else {
            throw AgentQueryBrokerError.invalidRequest
        }

        // Reuse the existing text-only chat path; do NOT inject task-mutation tools into a generic query.
        let client = AgentChatClient(credentialStore: credentialStore, session: session)
        let messages: [AgentChatMessage] = [
            AgentChatMessage(role: .system, content: Self.systemInstruction(resultSchema: trimmedSchema)),
            AgentChatMessage(role: .user, content: trimmedPrompt),
        ]

        do {
            let content = try await complete(client, messages: messages)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AgentQueryBrokerError.emptyResult }
            return AgentQueryResult(resultSchema: trimmedSchema, text: trimmed)
        } catch let error as AgentQueryBrokerError {
            throw error
        } catch is CancellationError {
            throw AgentQueryBrokerError.timedOut
        } catch let error as HTTPAgentTransportError {
            // A missing/unparseable message body is an empty result; anything else is a transport fault.
            // Both are typed — the failure is never swallowed. Error messages never embed the API key.
            switch error {
            case .missingContent, .invalidResponse, .invalidContent:
                throw AgentQueryBrokerError.emptyResult
            case .invalidRequest, .httpStatus, .insecureEndpoint:
                throw AgentQueryBrokerError.transport(error.errorDescription ?? "HTTP transport failed")
            }
        } catch let error as AgentCredentialStoreError {
            throw AgentQueryBrokerError.transport(error.errorDescription ?? "missing agent credentials")
        } catch {
            throw AgentQueryBrokerError.transport((error as? LocalizedError)?.errorDescription
                                                  ?? String(describing: error))
        }
    }

    /// Races the completion against a hard deadline so a hung endpoint can't wait forever.
    private func complete(_ client: AgentChatClient, messages: [AgentChatMessage]) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await client.complete(messages: messages) }
            group.addTask { [timeoutNanoseconds] in
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw AgentQueryBrokerError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw AgentQueryBrokerError.emptyResult }
            group.cancelAll()
            return result
        }
    }

    private static func systemInstruction(resultSchema: String) -> String {
        "You are a helpful assistant answering a plugin's structured query. Respond strictly according "
        + "to this result schema: \(resultSchema). Return only the result content, with no markdown "
        + "fences or explanatory prose."
    }
}
