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

public enum AgentChatAction: Equatable, Sendable {
    case reschedule(taskID: String, newDue: String)
    case create(title: String, due: String?)
    case complete(taskID: String)
    case delete(taskID: String)
    case retitle(taskID: String, newTitle: String)
}

public enum AgentChatReply: Equatable, Sendable {
    case text(String)
    case actions([AgentChatAction], assistantNote: String?)
}

public struct AgentChatClient: Sendable {
    private let credentialStore: any AgentCredentialStore
    private let session: URLSession

    public init(credentialStore: any AgentCredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    /// Sends the full conversation with the two reviewed task-mutation tools.
    /// Endpoints that reject `tools` with a request-shape status are retried once as text-only.
    public func send(messages: [AgentChatMessage]) async throws -> AgentChatReply {
        let config = try credentialStore.endpointConfig()
        try AgentEndpointSecurity.assertSecure(config.baseURL)

        let first = try await perform(config: config, messages: messages, includesTools: true)
        if Self.toolUnsupportedStatuses.contains(first.statusCode) {
            let fallback = try await perform(config: config, messages: messages, includesTools: false)
            guard (200..<300).contains(fallback.statusCode) else {
                throw HTTPAgentTransportError.httpStatus(fallback.statusCode)
            }
            return try decodeReply(fallback.data)
        }
        guard (200..<300).contains(first.statusCode) else {
            throw HTTPAgentTransportError.httpStatus(first.statusCode)
        }
        return try decodeReply(first.data)
    }

    private func perform(config: AgentEndpointConfig, messages: [AgentChatMessage],
                         includesTools: Bool) async throws -> (data: Data, statusCode: Int) {
        let body: Data
        do {
            var object: [String: Any] = [
                "model": config.model,
                "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            ]
            if includesTools { object["tools"] = Self.taskTools }
            body = try JSONSerialization.data(withJSONObject: object)
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
        return (data, httpResponse.statusCode)
    }

    private func decodeReply(_ data: Data) throws -> AgentChatReply {
        let completion: ChatResponse
        do {
            completion = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw HTTPAgentTransportError.invalidResponse
        }
        guard let message = completion.choices?.first?.message else {
            throw HTTPAgentTransportError.missingContent
        }
        let note = message.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let calls = message.toolCalls, !calls.isEmpty else {
            guard let note, !note.isEmpty else { throw HTTPAgentTransportError.missingContent }
            return .text(note)
        }

        do {
            let actions = try calls.flatMap(Self.actions(from:))
            guard !actions.isEmpty else { throw ToolCallParseError.invalidArguments }
            return .actions(actions, assistantNote: note.flatMap { $0.isEmpty ? nil : $0 })
        } catch {
            return .text(note.flatMap { $0.isEmpty ? nil : $0 }
                         ?? "The agent returned an unsupported task action.")
        }
    }

    private static func actions(from call: ChatResponse.ToolCall) throws -> [AgentChatAction] {
        let arguments = Data(call.function.arguments.utf8)
        switch call.function.name {
        case "reschedule_tasks":
            let decoded = try JSONDecoder().decode(RescheduleArguments.self, from: arguments)
            guard !decoded.updates.isEmpty else { throw ToolCallParseError.invalidArguments }
            return decoded.updates.map { .reschedule(taskID: $0.taskID, newDue: $0.newDue) }
        case "add_tasks":
            let decoded = try JSONDecoder().decode(AddArguments.self, from: arguments)
            guard !decoded.tasks.isEmpty else { throw ToolCallParseError.invalidArguments }
            return decoded.tasks.map { .create(title: $0.title, due: $0.due) }
        case "complete_tasks":
            let decoded = try JSONDecoder().decode(TaskIDArguments.self, from: arguments)
            guard !decoded.taskIDs.isEmpty else { throw ToolCallParseError.invalidArguments }
            return decoded.taskIDs.map { .complete(taskID: $0) }
        case "delete_tasks":
            let decoded = try JSONDecoder().decode(TaskIDArguments.self, from: arguments)
            guard !decoded.taskIDs.isEmpty else { throw ToolCallParseError.invalidArguments }
            return decoded.taskIDs.map { .delete(taskID: $0) }
        case "retitle_tasks":
            let decoded = try JSONDecoder().decode(RetitleArguments.self, from: arguments)
            guard !decoded.updates.isEmpty else { throw ToolCallParseError.invalidArguments }
            return decoded.updates.map { .retitle(taskID: $0.taskID, newTitle: $0.newTitle) }
        default:
            throw ToolCallParseError.unknownTool
        }
    }

    private static let toolUnsupportedStatuses: Set<Int> = [400, 404, 422]

    private static let taskTools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "reschedule_tasks",
                "description": "Propose new ISO due dates for existing tasks. The user reviews every change before it is applied.",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "updates": [
                            "type": "array",
                            "minItems": 1,
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "properties": [
                                    "taskID": ["type": "string"],
                                    "newDue": ["type": "string", "description": "ISO date in YYYY-MM-DD format"],
                                ],
                                "required": ["taskID", "newDue"],
                            ],
                        ],
                    ],
                    "required": ["updates"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "add_tasks",
                "description": "Propose new tasks. The user reviews every task before it is created.",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "tasks": [
                            "type": "array",
                            "minItems": 1,
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "properties": [
                                    "title": ["type": "string"],
                                    "due": ["type": "string", "description": "Optional ISO date in YYYY-MM-DD format"],
                                ],
                                "required": ["title"],
                            ],
                        ],
                    ],
                    "required": ["tasks"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "complete_tasks",
                "description": "Propose marking existing tasks as done. The user reviews before it is applied.",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "taskIDs": ["type": "array", "minItems": 1, "items": ["type": "string"]],
                    ],
                    "required": ["taskIDs"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "delete_tasks",
                "description": "Propose deleting existing tasks. The user reviews before it is applied.",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "taskIDs": ["type": "array", "minItems": 1, "items": ["type": "string"]],
                    ],
                    "required": ["taskIDs"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "retitle_tasks",
                "description": "Propose new titles for existing tasks. The user reviews before it is applied.",
                "parameters": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "updates": [
                            "type": "array",
                            "minItems": 1,
                            "items": [
                                "type": "object",
                                "additionalProperties": false,
                                "properties": [
                                    "taskID": ["type": "string"],
                                    "newTitle": ["type": "string"],
                                ],
                                "required": ["taskID", "newTitle"],
                            ],
                        ],
                    ],
                    "required": ["updates"],
                ],
            ],
        ],
    ]
}

private enum ToolCallParseError: Error {
    case invalidArguments
    case unknownTool
}

private struct RescheduleArguments: Decodable {
    let updates: [Update]

    struct Update: Decodable {
        let taskID: String
        let newDue: String
    }
}

private struct AddArguments: Decodable {
    let tasks: [Task]

    struct Task: Decodable {
        let title: String
        let due: String?
    }
}

private struct TaskIDArguments: Decodable {
    let taskIDs: [String]
}

private struct RetitleArguments: Decodable {
    let updates: [Update]

    struct Update: Decodable {
        let taskID: String
        let newTitle: String
    }
}

private struct ChatResponse: Decodable {
    let choices: [Choice]?

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCall: Decodable {
        let function: Function

        struct Function: Decodable {
            let name: String
            let arguments: String
        }
    }
}
