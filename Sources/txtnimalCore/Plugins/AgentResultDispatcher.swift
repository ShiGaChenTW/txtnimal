import Foundation

enum AgentResultDispatcher {
    static func actions(resultSchema: String, response: Data, query: PluginAction,
                        limits: PluginLimits) throws -> [PluginAction] {
        switch resultSchema {
        case "reschedule.v1":
            return try rescheduleActions(response: response, query: query, limits: limits)
        default:
            throw AgentRunnerError.unsupportedResultSchema
        }
    }

    private static func rescheduleActions(response: Data, query: PluginAction,
                                          limits: PluginLimits) throws -> [PluginAction] {
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

        return updates.map { update in
            PluginAction(type: .hostCommand, command: PluginHostCommand.rescheduleTask.rawValue,
                         taskIDs: [update.taskID], due: update.newDue,
                         expectedRevision: query.expectedRevision,
                         documentRevision: query.documentRevision)
        }
    }
}

private struct AgentTaskUpdate: Codable, Sendable {
    let taskID: String
    let newDue: String
}
