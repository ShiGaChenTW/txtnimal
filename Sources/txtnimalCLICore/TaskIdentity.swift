import Foundation
import txtnimalCore

public enum IdentityResolution: Equatable {
    case unique(index: Int, id: String)
    case ambiguous([String])
    case notFound
}

/// Task addressing for the CLI.
///
/// The app now stamps `id:` too — `Capture` at creation, and `TasksDocument.withUniqueIDs`
/// on every save for anything older — so most lines arrive here already addressable. The CLI
/// still generates its own id for tasks *it* creates and never rewrites anyone else's.
///
/// Note the two generators produce different shapes: `randomHex8` here yields bare 8-hex
/// (`3f9a2c71`), `TaskLine.makeID()` yields `t`+8-hex (`t3f9a2c71`, distinguishable from a
/// note's `n…`). Both sit inside the plugin layer's 4–80 `[A-Za-z0-9-_]` window and both
/// resolve by prefix, so they interoperate; unifying them is a separate decision.
///
/// Reading identity goes through `PluginSnapshotBuilder.identityMap`, the scheme the
/// in-process plugin host already uses: a valid `id:` token when present, otherwise a
/// content-derived `legacy-…` for a line not yet saved since the backfill landed.
public enum TaskIdentity {

    /// 8 lowercase hex characters: inside the plugin layer's 4–80 `[A-Za-z0-9-_]` window,
    /// contains no colon so it cannot be reparsed as a todo.txt `key:value` token, and
    /// short enough to stay readable in a plain-text file.
    public static func randomHex8() -> String {
        String(format: "%08x", UInt32.random(in: UInt32.min...UInt32.max))
    }

    public static func existingIDs(in lines: [TaskLine]) -> Set<String> {
        Set(lines.compactMap(\.stableID))
    }

    /// Retries until the candidate is unused, so in-file collisions are impossible
    /// rather than merely improbable.
    public static func generateID(existing: Set<String>,
                                  random: () -> String = TaskIdentity.randomHex8) -> String {
        for _ in 0..<64 {
            let candidate = random()
            if !existing.contains(candidate) { return candidate }
        }
        // Exhausting 64 draws means the supply is degenerate (a stubbed generator, say).
        // Fall back to something that cannot collide rather than looping forever.
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Resolves a user-supplied prefix against every addressable line.
    /// An exact hit wins outright — otherwise an id that is a strict prefix of another
    /// could never be named.
    public static func resolve(prefix: String, in lines: [TaskLine]) -> IdentityResolution {
        guard !prefix.isEmpty else { return .notFound }
        let map = PluginSnapshotBuilder.identityMap(for: lines)
        if let index = map[prefix] { return .unique(index: index, id: prefix) }

        let matches = map.filter { $0.key.hasPrefix(prefix) }
        switch matches.count {
        case 0: return .notFound
        case 1:
            let match = matches.first!
            return .unique(index: match.value, id: match.key)
        default:
            return .ambiguous(matches.keys.sorted())
        }
    }
}
