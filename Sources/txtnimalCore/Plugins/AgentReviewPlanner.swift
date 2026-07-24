import Foundation

public struct AgentReviewItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let taskID: String
    public let title: String
    public let oldDue: String?
    public let newDue: String
    public let intent: ValidatedPluginIntent

    public init(id: String, taskID: String, title: String, oldDue: String?, newDue: String,
                intent: ValidatedPluginIntent) {
        self.id = id
        self.taskID = taskID
        self.title = title
        self.oldDue = oldDue
        self.newDue = newDue
        self.intent = intent
    }
}

public enum AgentReviewPlanner {
    public static func makeItems(intents: [ValidatedPluginIntent], currentTasks: [PluginTaskSnapshot],
                                 defaultDueYMD: String, createNoDueLabel: String = "無期限") -> [AgentReviewItem] {
        let tasksByID = Dictionary(uniqueKeysWithValues: currentTasks.map { ($0.id, $0) })

        return intents.enumerated().flatMap { index, intent -> [AgentReviewItem] in
            if intent.command == .createTask {
                let syntheticID = "new-\(index + 1)"
                return [AgentReviewItem(
                    id: syntheticID,
                    taskID: syntheticID,
                    title: intent.title ?? syntheticID,
                    oldDue: nil,
                    newDue: intent.due ?? createNoDueLabel,
                    intent: intent
                )]
            }

            return intent.taskIDs.map { taskID in
                let task = tasksByID[taskID]
                return AgentReviewItem(
                    id: taskID,
                    taskID: taskID,
                    title: task?.title ?? taskID,
                    oldDue: task?.due,
                    newDue: intent.due ?? defaultDueYMD,
                    intent: intent
                )
            }
        }
    }

    public static func removeItem(id: String, from items: [AgentReviewItem]) -> [AgentReviewItem] {
        items.filter { $0.id != id }
    }
}
