import Foundation

public enum PluginKVStoreError: LocalizedError, Equatable, Sendable {
    case corruptStore
    case emptyPluginID
    case emptyKey
    case keyTooLong
    case valueTooLarge

    public var errorDescription: String? {
        switch self {
        case .corruptStore:
            return "KV 儲存檔已損毀，無法讀取。"
        case .emptyPluginID:
            return "Plugin ID 不可為空。"
        case .emptyKey:
            return "KV 鍵名不可為空。"
        case .keyTooLong:
            return "KV 鍵名長度不能超過 256 個字元。"
        case .valueTooLarge:
            return "KV 值大小不能超過 8192 位元組。"
        }
    }
}

public struct PluginKVStore: Equatable, Sendable {
    public static let maximumKeyLength = 256
    public static let maximumValueBytes = 8192

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func namespace(for pluginID: String) -> [String: String] {
        // UI read paths should degrade to an empty namespace instead of surfacing a
        // corrupt JSON file as a rendering crash.
        guard let all = try? loadAll() else { return [:] }
        return all[pluginID] ?? [:]
    }

    public func value(for key: String, pluginID: String) -> String? {
        namespace(for: pluginID)[key]
    }

    public func set(_ value: String, for key: String, pluginID: String) throws {
        try validate(pluginID: pluginID, key: key, value: value)
        var all = try loadAll()
        var namespace = all[pluginID] ?? [:]
        namespace[key] = value
        all[pluginID] = namespace

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(all)
        try data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    public func applyWrite(_ write: ValidatedPluginKVWrite) throws -> [String: String] {
        // Writes must surface corruption so we never overwrite unreadable user data.
        try set(write.value, for: write.key, pluginID: write.pluginID)
        return namespace(for: write.pluginID)
    }

    private func loadAll() throws -> [String: [String: String]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode([String: [String: String]].self, from: data)
        } catch {
            throw PluginKVStoreError.corruptStore
        }
    }

    private func validate(pluginID: String, key: String, value: String) throws {
        guard !pluginID.isEmpty else { throw PluginKVStoreError.emptyPluginID }
        guard !key.isEmpty else { throw PluginKVStoreError.emptyKey }
        guard key.count <= Self.maximumKeyLength else { throw PluginKVStoreError.keyTooLong }
        guard value.utf8.count <= Self.maximumValueBytes else { throw PluginKVStoreError.valueTooLarge }
    }
}
