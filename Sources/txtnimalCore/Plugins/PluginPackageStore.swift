import Foundation

public enum PluginPackageStoreError: LocalizedError, Equatable, Sendable {
    case invalidPackage
    case packageExists
    case packageNotFound
    case packageCopyFailed

    public var errorDescription: String? {
        switch self {
        case .invalidPackage: return "invalid plugin package"
        case .packageExists: return "plugin package already exists"
        case .packageNotFound: return "plugin package not found"
        case .packageCopyFailed: return "plugin package copy failed"
        }
    }
}

public struct InstalledPluginPackage: Equatable, Sendable {
    public let manifest: PluginManifest
    public let url: URL
}

/// Local package lifecycle boundary. It never executes plugin code.
public final class PluginPackageStore {
    public let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
        do { try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true) }
        catch { throw PluginPackageStoreError.packageCopyFailed }
    }

    public func list() throws -> [InstalledPluginPackage] {
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        return try urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return try load(at: url)
        }.sorted { $0.manifest.id < $1.manifest.id }
    }

    @discardableResult
    public func install(from sourceURL: URL) throws -> InstalledPluginPackage {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path.hasPrefix(sourceURL.standardizedFileURL.path),
              (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw PluginPackageStoreError.invalidPackage
        }
        let manifest = try loadManifest(at: source)
        _ = try PluginValidator.resolveEntry(manifest.entry, in: source, fileManager: fileManager)
        let destination = directory.appendingPathComponent(manifest.id, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { throw PluginPackageStoreError.packageExists }
        do { try fileManager.copyItem(at: source, to: destination) }
        catch { throw PluginPackageStoreError.packageCopyFailed }
        return try load(at: destination)
    }

    public func remove(id: String) throws {
        let destination = directory.appendingPathComponent(id, isDirectory: true)
        guard fileManager.fileExists(atPath: destination.path) else { throw PluginPackageStoreError.packageNotFound }
        do { try fileManager.removeItem(at: destination) }
        catch { throw PluginPackageStoreError.packageCopyFailed }
    }

    private func load(at url: URL) throws -> InstalledPluginPackage {
        let manifest = try loadManifest(at: url)
        _ = try PluginValidator.resolveEntry(manifest.entry, in: url, fileManager: fileManager)
        return InstalledPluginPackage(manifest: manifest, url: url)
    }

    private func loadManifest(at url: URL) throws -> PluginManifest {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw PluginPackageStoreError.invalidPackage }
        do { return try PluginValidator.decodeManifest(Data(contentsOf: manifestURL)) }
        catch { throw PluginPackageStoreError.invalidPackage }
    }
}
