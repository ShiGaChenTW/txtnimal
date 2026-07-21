import Foundation

public struct ActivityReport: Equatable {
    public var doneByDay: [String: Int]
    public var doneProjects: [(name: String, count: Int)]
    public var createdSince: Int

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.doneByDay == rhs.doneByDay && lhs.doneProjects.map { "\($0.name):\($0.count)" } == rhs.doneProjects.map { "\($0.name):\($0.count)" } && lhs.createdSince == rhs.createdSince
    }
}

public enum ActivityReporting {
    public static func build(lines: [TaskLine], archiveLines: [TaskLine], sinceYMD: String) -> ActivityReport {
        let all = lines + archiveLines
        var days: [String: Int] = [:]
        var projects: [String: Int] = [:]
        for task in all where !task.isBlank {
            if let done = task.completedDate {
                days[done, default: 0] += 1
                if done >= sinceYMD { for project in task.projects { projects[project, default: 0] += 1 } }
            }
        }
        let created = all.filter { ($0.created ?? "") >= sinceYMD }.count
        let ranked = projects.map { (name: $0.key, count: $0.value) }.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
        return ActivityReport(doneByDay: days, doneProjects: ranked, createdSince: created)
    }
}
