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

public enum AgentChatStreamEvent: Equatable, Sendable {
    case textDelta(String)              // incremental assistant text as it arrives
    case completed(AgentChatReply)      // final result: assembled text or reviewed actions
}

public struct AgentChatClient: Sendable {
    private let credentialStore: any AgentCredentialStore
    private let session: URLSession
    private let streamTimeoutNanoseconds: UInt64

    public init(credentialStore: any AgentCredentialStore, session: URLSession = .shared,
                streamTimeoutNanoseconds: UInt64 = 120_000_000_000) {
        self.credentialStore = credentialStore
        self.session = session
        self.streamTimeoutNanoseconds = streamTimeoutNanoseconds
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

    /// Streaming variant: yields text deltas as they arrive, then a single `.completed` event with
    /// the final reply (assembled text, or reviewed tool actions). tool_calls are accumulated across
    /// SSE chunks by index. Endpoints that reject `tools` are retried once as a text-only stream.
    public func stream(messages: [AgentChatMessage]) -> AsyncThrowingStream<AgentChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let config = try credentialStore.endpointConfig()
                    try AgentEndpointSecurity.assertSecure(config.baseURL)
                    // Wall-clock cap: an idle timeout can't catch a keepalive-fed stream that never
                    // sends [DONE], so race the whole stream against a hard deadline instead.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            do {
                                try await runStream(config: config, messages: messages,
                                                    includesTools: true, continuation: continuation)
                            } catch StreamControl.toolUnsupported {
                                try await runStream(config: config, messages: messages,
                                                    includesTools: false, continuation: continuation)
                            }
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: streamTimeoutNanoseconds)
                            throw AgentRunnerError.timedOut
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum StreamControl: Error { case toolUnsupported }

    private func runStream(config: AgentEndpointConfig, messages: [AgentChatMessage], includesTools: Bool,
                           continuation: AsyncThrowingStream<AgentChatStreamEvent, Error>.Continuation) async throws {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        var object: [String: Any] = [
            "model": config.model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true,
        ]
        if includesTools {
            object["tools"] = Self.taskTools
            // gpt-5.x reasoning models reject function tools in chat/completions unless reasoning is
            // off ("Function tools with reasoning_effort are not supported"). Disabling it also drops
            // the reasoning latency. Models that reject the param 400 and fall back to text-only below.
            object["reasoning_effort"] = "none"
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw HTTPAgentTransportError.invalidRequest
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HTTPAgentTransportError.invalidResponse }
        if includesTools, Self.toolUnsupportedStatuses.contains(http.statusCode) { throw StreamControl.toolUnsupported }
        guard (200..<300).contains(http.statusCode) else { throw HTTPAgentTransportError.httpStatus(http.statusCode) }

        var textAccum = ""
        var toolAccum: [Int: (name: String, args: String)] = [:]

        // Decode one fully-assembled SSE event's JSON and fold it into the accumulators. Both name
        // and arguments concatenate across chunks — some endpoints fragment either.
        func consume(_ payload: String) {
            guard !payload.isEmpty,
                  let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let delta = chunk.choices?.first?.delta else { return }
            if let content = delta.content, !content.isEmpty {
                textAccum += content
                continuation.yield(.textDelta(content))
            }
            for call in delta.toolCalls ?? [] {
                var entry = toolAccum[call.index] ?? (name: "", args: "")
                if let name = call.function?.name { entry.name += name }
                if let args = call.function?.arguments { entry.args += args }
                toolAccum[call.index] = entry
            }
        }

        // An SSE event's JSON may span multiple `data:` lines. Accumulate and dispatch as soon as the
        // joined payload is complete JSON — no reliance on blank-line separators (the line sequence
        // may not surface them). Only keep a fragment that starts like JSON (`{`/`[`); anything else
        // (e.g. a `data: ping` keepalive) is discarded so it can't poison later events. Bounded.
        let maxPending = 512 * 1024
        var pending = ""
        streamLoop: for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break streamLoop }
            if payload.isEmpty { continue }
            if payload.utf8.count > maxPending { pending = ""; continue }  // oversized single line — drop
            let candidate = pending.isEmpty ? payload : pending + "\n" + payload
            // Bound BEFORE parsing/consuming so a single oversized (even valid) payload can't be
            // buffered or emitted.
            if candidate.utf8.count > maxPending {
                pending = ""                       // accumulated overflow — drop
            } else if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil {
                consume(candidate)
                pending = ""
            } else if let first = candidate.first(where: { !$0.isWhitespace }), first == "{" || first == "[" {
                pending = candidate               // partial JSON — keep assembling
            } else {
                pending = ""                       // non-JSON keepalive — drop
            }
        }

        let trimmedText = textAccum.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = trimmedText.isEmpty ? nil : trimmedText
        if toolAccum.isEmpty {
            guard let note else { throw HTTPAgentTransportError.missingContent }
            continuation.yield(.completed(.text(note)))
            return
        }
        let assembled = toolAccum.sorted { $0.key < $1.key }.map { $0.value }
        let actions = (try? assembled.flatMap { try Self.actions(fromName: $0.name, arguments: $0.args) }) ?? []
        if actions.isEmpty {
            continuation.yield(.completed(.text(note ?? "The agent returned an unsupported task action.")))
        } else {
            continuation.yield(.completed(.actions(actions, assistantNote: note)))
        }
    }

    private func perform(config: AgentEndpointConfig, messages: [AgentChatMessage],
                         includesTools: Bool) async throws -> (data: Data, statusCode: Int) {
        let body: Data
        do {
            var object: [String: Any] = [
                "model": config.model,
                "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            ]
            if includesTools {
                object["tools"] = Self.taskTools
                // See runStream: reasoning models need reasoning off to accept tools here.
                object["reasoning_effort"] = "none"
            }
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
            let actions = try calls.flatMap { try Self.actions(fromName: $0.function.name, arguments: $0.function.arguments) }
            guard !actions.isEmpty else { throw ToolCallParseError.invalidArguments }
            return .actions(actions, assistantNote: note.flatMap { $0.isEmpty ? nil : $0 })
        } catch {
            return .text(note.flatMap { $0.isEmpty ? nil : $0 }
                         ?? "The agent returned an unsupported task action.")
        }
    }

    static func actions(fromName name: String, arguments argumentsString: String) throws -> [AgentChatAction] {
        let arguments = Data(argumentsString.utf8)
        switch name {
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

private struct StreamChunk: Decodable {
    let choices: [Choice]?

    struct Choice: Decodable {
        let delta: Delta?
    }

    struct Delta: Decodable {
        let content: String?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable {
        let index: Int
        let function: FunctionDelta?

        struct FunctionDelta: Decodable {
            let name: String?
            let arguments: String?
        }
    }
}
