import Foundation

public enum HTTPAgentTransportError: LocalizedError, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int)
    case missingContent
    case invalidContent
    case insecureEndpoint

    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "agent transport request is invalid"
        case .invalidResponse: return "agent endpoint response is invalid"
        case .httpStatus(let status): return "agent endpoint returned HTTP status \(status)"
        case .missingContent: return "agent endpoint response has no message content"
        case .invalidContent: return "agent endpoint message content is not JSON"
        case .insecureEndpoint: return "agent endpoint must use https (http allowed only for localhost)"
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
        try Self.assertSecure(config.baseURL)
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

        // The schema wraps the array in an object ({"updates":[...]}) because strict json_schema
        // requires an object root. Unwrap back to the bare array the dispatcher expects. Stay lenient:
        // accept a bare array too, for OpenAI-compatible endpoints that return one directly.
        let contentData = Data(content.utf8)
        let parsed = try? JSONSerialization.jsonObject(with: contentData)
        if let object = parsed as? [String: Any], let wrapped = object["updates"] {
            guard let arrayData = try? JSONSerialization.data(withJSONObject: wrapped) else {
                throw HTTPAgentTransportError.invalidContent
            }
            return arrayData
        }
        // Endpoint returned a bare array directly — pass the original bytes through unchanged.
        guard parsed is [Any] else { throw HTTPAgentTransportError.invalidContent }
        return contentData
    }

    private static func assertSecure(_ url: URL) throws {
        switch url.scheme?.lowercased() {
        case "https":
            return
        case "http" where ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? ""):
            return  // ponytail: loopback http allowed for local models (Ollama/LM Studio)
        default:
            throw HTTPAgentTransportError.insecureEndpoint
        }
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
        "Return only a JSON object {\"updates\":[{\"taskID\":\"...\",\"newDue\":\"YYYY-MM-DD\"}]}. " +
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
        let properties: [String: ArrayField]
        let required: [String]
        let additionalProperties: Bool

        // strict json_schema requires an object root, so wrap the array under "updates".
        static let reschedule = Schema(
            type: "object",
            properties: [
                "updates": ArrayField(
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
            ],
            required: ["updates"],
            additionalProperties: false
        )

        struct ArrayField: Encodable {
            let type: String
            let items: Items
        }

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
