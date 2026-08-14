import Foundation

public enum PluginPackageStoreError: LocalizedError, Equatable, Sendable {
    case invalidPackage
    case packageExists
    case packageNotFound
    case packageCopyFailed
    case bundledIDConflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPackage: return "invalid plugin package"
        case .packageExists: return "plugin package already exists"
        case .packageNotFound: return "plugin package not found"
        case .packageCopyFailed: return "plugin package copy failed"
        case .bundledIDConflict(let id): return "plugin id conflicts with bundled plugin: \(id)"
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
    private let securityPolicy: PluginSecurityPolicy
    private let bundledPluginIDs: Set<String>

    public init(directory: URL, fileManager: FileManager = .default,
                securityPolicy: PluginSecurityPolicy = .init(),
                bundledPluginIDs: Set<String> = []) throws {
        self.directory = directory.standardizedFileURL
        self.fileManager = fileManager
        self.securityPolicy = securityPolicy
        self.bundledPluginIDs = bundledPluginIDs
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
    public func install(from sourceURL: URL, bundledPluginIDs: Set<String>? = nil) throws -> InstalledPluginPackage {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard source.path.hasPrefix(sourceURL.standardizedFileURL.path),
              (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw PluginPackageStoreError.invalidPackage
        }
        let manifest = try loadManifest(at: source)
        if (bundledPluginIDs ?? self.bundledPluginIDs).contains(manifest.id) {
            throw PluginPackageStoreError.bundledIDConflict(manifest.id)
        }
        let signature = try loadSignatureIfRequired(manifest, packageURL: source)
        try securityPolicy.validate(manifest, signerTeamID: signature?.teamID)
        try validateSignatureIfRequired(signature, manifest: manifest, packageURL: source)
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
        let signature = try loadSignatureIfRequired(manifest, packageURL: url)
        try securityPolicy.validate(manifest, signerTeamID: signature?.teamID)
        try validateSignatureIfRequired(signature, manifest: manifest, packageURL: url)
        _ = try PluginValidator.resolveEntry(manifest.entry, in: url, fileManager: fileManager)
        return InstalledPluginPackage(manifest: manifest, url: url)
    }

    private func loadSignatureIfRequired(_ manifest: PluginManifest, packageURL: URL) throws -> PluginSignature? {
        guard securityPolicy.requiredSignerTeamID != nil else { return nil }
        let signatureURL = packageURL.appendingPathComponent("signature.json")
        do {
            return try JSONDecoder().decode(PluginSignature.self, from: Data(contentsOf: signatureURL))
        } catch {
            throw PluginPackageStoreError.invalidPackage
        }
    }

    private func validateSignatureIfRequired(_ signature: PluginSignature?, manifest: PluginManifest, packageURL: URL) throws {
        guard let signature else { return }
        do {
            let entryURL = try PluginValidator.resolveEntry(manifest.entry, in: packageURL, fileManager: fileManager)
            try securityPolicy.validateSignature(signature, entryData: Data(contentsOf: entryURL))
        } catch { throw PluginPackageStoreError.invalidPackage }
    }

    private func loadManifest(at url: URL) throws -> PluginManifest {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw PluginPackageStoreError.invalidPackage }
        do { return try PluginValidator.decodeManifest(Data(contentsOf: manifestURL)) }
        catch { throw PluginPackageStoreError.invalidPackage }
    }
}
