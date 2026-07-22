import Foundation

public enum HTTPAgentTransportError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case missingContent
    case invalidContent

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "agent transport request is invalid"
        case .invalidResponse: return "agent endpoint response is invalid"
        case .httpStatus(let status): return "agent endpoint returned HTTP status \(status)"
        case .missingContent: return "agent endpoint response has no message content"
        case .invalidContent: return "agent endpoint message content is not JSON"
        }
    }
}

public struct HTTPAgentTransport: AgentTransport {
    private let credentialStore: any AgentCredentialStore
    private let session: URLSession

    public init(credentialStore: any AgentCredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    public func complete(request: Data) async throws -> Data {
        let hostRequest: AgentTransportRequest
        do {
            hostRequest = try JSONDecoder().decode(AgentTransportRequest.self, from: request)
        } catch {
            throw HTTPAgentTransportError.invalidRequest
        }

        let config = try credentialStore.endpointConfig()
        let body = try makeRequestBody(hostRequest: hostRequest, model: config.model)
        var urlRequest = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPAgentTransportError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw HTTPAgentTransportError.httpStatus(httpResponse.statusCode)
        }

        let endpointResponse: ChatCompletionResponse
        do {
            endpointResponse = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw HTTPAgentTransportError.invalidResponse
        }
        guard let content = endpointResponse.choices?.first?.message.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HTTPAgentTransportError.missingContent
        }

        let contentData = Data(content.utf8)
        guard (try? JSONSerialization.jsonObject(with: contentData, options: [.fragmentsAllowed])) != nil else {
            throw HTTPAgentTransportError.invalidContent
        }
        return contentData
    }

    private func makeRequestBody(hostRequest: AgentTransportRequest, model: String) throws -> Data {
        let userPayload = UserPayload(prompt: hostRequest.prompt, taskIDs: hostRequest.taskIDs,
                                      tasks: hostRequest.tasks)
        let userData = try JSONEncoder().encode(userPayload)
        guard let userContent = String(data: userData, encoding: .utf8) else {
            throw HTTPAgentTransportError.invalidRequest
        }

        let request = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: Self.systemInstruction),
                .init(role: "user", content: userContent),
            ],
            responseFormat: .init(
                type: "json_schema",
                jsonSchema: .init(name: "reschedule_v1", strict: true, schema: .reschedule)
            )
        )
        do {
            return try JSONEncoder().encode(request)
        } catch {
            throw HTTPAgentTransportError.invalidRequest
        }
    }

    private static let systemInstruction =
        "Return only a JSON array [{\"taskID\":\"...\",\"newDue\":\"YYYY-MM-DD\"}]. " +
        "newDue must use YYYY-MM-DD. Do not include markdown or explanatory text."
}

private struct UserPayload: Encodable {
    let prompt: String
    let taskIDs: [String]
    let tasks: [AgentTransportTask]
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, messages
        case responseFormat = "response_format"
    }

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String
        let jsonSchema: JSONSchema

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }
    }

    struct JSONSchema: Encodable {
        let name: String
        let strict: Bool
        let schema: Schema
    }

    struct Schema: Encodable {
        let type: String
        let items: Items

        static let reschedule = Schema(
            type: "array",
            items: Items(
                type: "object",
                properties: [
                    "taskID": Property(type: "string", pattern: nil),
                    "newDue": Property(type: "string", pattern: #"^\d{4}-\d{2}-\d{2}$"#),
                ],
                required: ["taskID", "newDue"],
                additionalProperties: false
            )
        )

        struct Items: Encodable {
            let type: String
            let properties: [String: Property]
            let required: [String]
            let additionalProperties: Bool
        }

        struct Property: Encodable {
            let type: String
            let pattern: String?
        }
    }
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]?

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
    }
}
