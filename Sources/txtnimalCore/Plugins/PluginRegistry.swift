import Foundation

public struct PluginRegistryEntry: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case bundled
        case installed
    }

    public let manifest: PluginManifest
    public let source: Source
    public let packageRootURL: URL
    public let enabled: Bool

    public init(manifest: PluginManifest, source: Source, packageRootURL: URL, enabled: Bool) {
        self.manifest = manifest
        self.source = source
        self.packageRootURL = packageRootURL.standardizedFileURL
        self.enabled = enabled
    }

    /// The entry file for this plugin, resolved through the containment guard.
    ///
    /// `PluginValidator.decodeManifest` only rejects *literal* `..` / absolute entry paths
    /// (`isSafeRelativeEntry`); it does not resolve symlinks. Consumers must therefore never build
    /// the entry URL themselves with `packageRootURL.appendingPathComponent(manifest.entry)` — a
    /// symlinked entry inside an installed third-party package would escape the package root and
    /// its target would be loaded as plugin source. Routing every consumer through this helper is
    /// what keeps the guard unskippable from the registry path (the SCO-172 bypass).
    ///
    /// - Throws: `PluginValidationError.invalidEntryPath` when the resolved path escapes
    ///   `packageRootURL`, does not exist, or is not a regular file.
    public func resolvedEntryURL(fileManager: FileManager = .default) throws -> URL {
        try PluginValidator.resolveEntry(manifest.entry, in: packageRootURL, fileManager: fileManager)
    }
}

public final class PluginRegistry {
    public let bundledDirectory: URL?
    public let installedStore: PluginPackageStore?

    private let disabledIDs: Set<String>
    private let fileManager: FileManager

    public init(bundledDirectory: URL?, installedStore: PluginPackageStore?,
                disabledIDs: Set<String> = [], fileManager: FileManager = .default) {
        self.bundledDirectory = bundledDirectory?.standardizedFileURL
        self.installedStore = installedStore
        self.disabledIDs = disabledIDs
        self.fileManager = fileManager
    }

    public func discover() throws -> [PluginRegistryEntry] {
        var entriesByID = [String: PluginRegistryEntry]()

        for entry in try discoverBundledEntries() where entriesByID[entry.manifest.id] == nil {
            entriesByID[entry.manifest.id] = entry
        }
        for entry in try discoverInstalledEntries() {
            entriesByID[entry.manifest.id] = entry
        }

        return entriesByID.values.sorted { $0.manifest.id < $1.manifest.id }
    }

    public func discoverEnabled() throws -> [PluginRegistryEntry] {
        try discover().filter { $0.enabled }
    }

    private func discoverBundledEntries() throws -> [PluginRegistryEntry] {
        guard let bundledDirectory else { return [] }

        let childURLs = try fileManager.contentsOfDirectory(
            at: bundledDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }

        var entries = [PluginRegistryEntry]()
        entries.reserveCapacity(childURLs.count)

        for childURL in childURLs {
            guard (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            let packageRootURL = childURL.standardizedFileURL
            let manifestURL = packageRootURL.appendingPathComponent("manifest.json")
            guard let manifestData = try? Data(contentsOf: manifestURL),
                  let manifest = try? PluginValidator.decodeManifest(manifestData) else {
                continue
            }

            entries.append(makeEntry(manifest: manifest, source: .bundled, packageRootURL: packageRootURL))
        }

        return entries
    }

    private func discoverInstalledEntries() throws -> [PluginRegistryEntry] {
        guard let installedStore else { return [] }

        return try installedStore.list().map { package in
            makeEntry(manifest: package.manifest, source: .installed, packageRootURL: package.url)
        }
    }

    private func makeEntry(manifest: PluginManifest, source: PluginRegistryEntry.Source,
                           packageRootURL: URL) -> PluginRegistryEntry {
        PluginRegistryEntry(
            manifest: manifest,
            source: source,
            packageRootURL: packageRootURL,
            enabled: !disabledIDs.contains(manifest.id)
        )
    }
}
