import Foundation

public final class PluginExecutionLogStore {
    public let url: URL
    private let fileManager: FileManager
    private let maximumRecords = 100

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        self.url = directory.appendingPathComponent("execution-log.json")
    }

    public func load() throws -> [PluginExecutionRecord] {
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do { return try JSONDecoder().decode([PluginExecutionRecord].self, from: Data(contentsOf: url)) }
        catch { throw PluginExecutionError.transport("invalid execution log") }
    }

    public func append(_ record: PluginExecutionRecord) throws {
        var records = try load()
        records.append(record)
        if records.count > maximumRecords { records.removeFirst(records.count - maximumRecords) }
        do { try JSONEncoder().encode(records).write(to: url, options: .atomic) }
        catch { throw PluginExecutionError.transport("cannot write execution log") }
    }

    public func clear() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
