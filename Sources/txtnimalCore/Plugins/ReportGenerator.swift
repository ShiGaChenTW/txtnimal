import Foundation

public struct ReportTemplate: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let systemPrompt: String

    public init(id: String, name: String, systemPrompt: String) {
        self.id = id
        self.name = name
        self.systemPrompt = systemPrompt
    }

    public static let builtIn: [ReportTemplate] = [
        ReportTemplate(
            id: "weekly",
            name: "週報",
            systemPrompt: "你是任務週報整理助手。請根據提供的任務資料產出一份條理清楚的 markdown 週報，整理本週進展、已完成事項、待跟進事項與風險提醒。只輸出 markdown，不要前言，不要把整份內容包在程式碼區塊。"
        ),
        ReportTemplate(
            id: "progress",
            name: "進度摘要",
            systemPrompt: "你是進度摘要助手。請根據提供的任務資料產出一份精簡但完整的 markdown 進度摘要，聚焦目前進度、重要里程碑、阻塞點與下一步。只輸出 markdown，不要前言，不要把整份內容包在程式碼區塊。"
        ),
        ReportTemplate(
            id: "category",
            name: "分類統計",
            systemPrompt: "你是任務分類分析助手。請根據提供的任務資料產出一份 markdown 分類統計報表，按任務內容歸納主題或工作類別，摘要各類別的數量、狀態與觀察。只輸出 markdown，不要前言，不要把整份內容包在程式碼區塊。"
        ),
        ReportTemplate(
            id: "standup",
            name: "站會日報",
            systemPrompt: "你是站會日報助手。請根據提供的任務資料產出一份適合晨會或站會使用的 markdown 日報，清楚分成已完成、進行中、下一步與需要協助。只輸出 markdown，不要前言，不要把整份內容包在程式碼區塊。"
        ),
    ]
}

public struct ReportTask: Encodable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let due: String?
    public let completed: Bool

    public init(id: String, title: String, due: String?, completed: Bool) {
        self.id = id
        self.title = title
        self.due = due
        self.completed = completed
    }
}

public struct ReportGenerator: Sendable {
    private let credentialStore: any AgentCredentialStore
    private let session: URLSession

    public init(credentialStore: any AgentCredentialStore, session: URLSession = .shared) {
        self.credentialStore = credentialStore
        self.session = session
    }

    public func generate(template: ReportTemplate, tweak: String, tasks: [ReportTask]) async throws -> String {
        let config = try credentialStore.endpointConfig()
        try AgentEndpointSecurity.assertSecure(config.baseURL)

        let trimmedTweak = tweak.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = trimmedTweak.isEmpty
            ? template.systemPrompt
            : template.systemPrompt + "\n\n額外要求：" + trimmedTweak

        let userData = try JSONEncoder().encode(tasks)
        guard let userContent = String(data: userData, encoding: .utf8) else {
            throw HTTPAgentTransportError.invalidRequest
        }

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": userContent],
                ],
            ])
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

        let completion: ChatCompletionResponse
        do {
            completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw HTTPAgentTransportError.invalidResponse
        }

        guard let content = completion.choices?.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw HTTPAgentTransportError.missingContent
        }
        return content
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
