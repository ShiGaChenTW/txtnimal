import Foundation

public struct AgentChatMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable {
        case system
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct AgentChatClient: Sendable {
    private let credentialStore: any AgentCredentialStore
    private let session: URLSession

    public init(credentialStore: any AgentCredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    /// Sends the full conversation to an OpenAI-compatible chat completion endpoint.
    /// The response is intentionally free-form text; no response_format is requested.
    public func send(messages: [AgentChatMessage]) async throws -> String {
        let config = try credentialStore.endpointConfig()
        try AgentEndpointSecurity.assertSecure(config.baseURL)

        let body: Data
        do {
            body = try JSONEncoder().encode(ChatRequest(model: config.model, messages: messages))
        } catch {
            throw HTTPAgentTransportError.invalidRequest
        }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPAgentTransportError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPAgentTransportError.httpStatus(httpResponse.statusCode)
        }

        let completion: ChatResponse
        do {
            completion = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw HTTPAgentTransportError.invalidResponse
        }
        guard let content = completion.choices?.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPAgentTransportError.missingContent
        }
        return content
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [AgentChatMessage]
}

private struct ChatResponse: Decodable {
    let choices: [Choice]?

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
