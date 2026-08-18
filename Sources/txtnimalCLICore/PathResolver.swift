import Foundation

/// Works out which tasks.txt this invocation operates on.
///
/// The CLI is a separate process from the GUI, so it cannot see the GUI's
/// `UserDefaults.standard`. It can, however, read the GUI's *domain* by suite name —
/// the app ships unsandboxed (`ENABLE_APP_SANDBOX: NO`), so its preferences live at
/// `~/Library/Preferences/app.txtnimal.txtnimal.plist` rather than inside a container.
/// Verified from a plain `swiftc`-built binary: the suite reads back values the GUI wrote.
///
/// Today that lookup yields nothing, because `activeTaskFile`/`dataDir` are only written
/// when the user actively relocates the data directory (`App/TaskStore.swift:526`, `:1362`)
/// and this user never has. The default below is therefore the branch that actually fires,
/// and it is deliberately the same path `TaskStore.defaultDataDir` computes — so both
/// programs land on the same file. The defaults lookup stays in the chain because it is
/// the only thing that keeps the CLI following the GUI on the day the user *does* move the
/// folder; without it the CLI would keep writing the old path silently, and silence is the
/// expensive failure mode here.
///
/// This reads the GUI domain and never writes it. While the GUI is running, its in-memory
/// values are authoritative and an external write would not be picked up — it would only
/// create a setting that looks applied and is not.
public enum PathResolver {

    public static let guiSuiteName = "app.txtnimal.txtnimal"
    public static let environmentKey = "TXTNIMAL_DIR"

    /// Resolution order: `--dir` → `TXTNIMAL_DIR` → GUI `activeTaskFile` → GUI `dataDir` → default.
    public static func resolveTasksFile(dirFlag: String?,
                                        environment: [String: String],
                                        defaults: DefaultsReading?,
                                        home: URL) -> URL {
        if let dir = usable(dirFlag) {
            return directory(dir, home: home).appendingPathComponent("tasks.txt")
        }
        if let dir = usable(environment[environmentKey]) {
            return directory(dir, home: home).appendingPathComponent("tasks.txt")
        }
        // `activeTaskFile` is a full file path and need not be named tasks.txt.
        if let file = usable(defaults?.stringValue(forKey: "activeTaskFile")) {
            return expand(file, home: home)
        }
        if let dir = usable(defaults?.stringValue(forKey: "dataDir")) {
            return directory(dir, home: home).appendingPathComponent("tasks.txt")
        }
        return defaultDataDirectory(home: home).appendingPathComponent("tasks.txt")
    }

    /// Mirrors `TaskStore.defaultDataDir` (`App/TaskStore.swift:495`).
    public static func defaultDataDirectory(home: URL) -> URL {
        home.appendingPathComponent("Documents/txtnimal", isDirectory: true)
    }

    // MARK: - Helpers

    /// An exported-but-empty `TXTNIMAL_DIR=` must not retarget the CLI at `/`.
    private static func usable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func directory(_ path: String, home: URL) -> URL {
        expand(path, home: home, isDirectory: true)
    }

    private static func expand(_ path: String, home: URL, isDirectory: Bool = false) -> URL {
        var resolved = path
        if resolved == "~" {
            resolved = home.path
        } else if resolved.hasPrefix("~/") {
            resolved = home.appendingPathComponent(String(resolved.dropFirst(2))).path
        }
        return URL(fileURLWithPath: resolved, isDirectory: isDirectory).standardizedFileURL
    }
}
