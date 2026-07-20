import Foundation

/// One line of a tasks.txt file.
///
/// `raw` is the source of truth. Every edit mutates `raw` with a minimal, targeted
/// change — untouched tokens (including unknown ones) and their exact whitespace are
/// preserved verbatim. This keeps round-trips byte-identical and git diffs clean, which
/// is the whole point of a plain-text task file you version-control.
public struct TaskLine: Equatable {
    public private(set) var raw: String

    public init(_ raw: String) { self.raw = raw }

    // MARK: - Lossless tokenization

    /// A `(whitespace, word)` pair. Concatenating every `ws + word` (plus the trailing
    /// whitespace) reproduces `raw` exactly.
    private struct Segment { var ws: String; var word: String }

    private static let knownKeys: Set<String> = ["due", "q", "focus", "created", "done"]

    private func tokenize() -> (segs: [Segment], trailing: String) {
        var segs: [Segment] = []
        let s = Array(raw)
        var i = 0
        while i < s.count {
            var ws = ""
            while i < s.count, s[i] == " " || s[i] == "\t" { ws.append(s[i]); i += 1 }
            if i >= s.count { return (segs, ws) } // trailing whitespace only
            var word = ""
            // note:"..." keeps spaces inside the quotes as one word
            if String(s[i...]).hasPrefix("note:\"") {
                word = "note:\""
                i += 6
                while i < s.count {
                    word.append(s[i])
                    let closed = s[i] == "\""
                    i += 1
                    if closed { break }
                }
            } else {
                while i < s.count, s[i] != " ", s[i] != "\t" { word.append(s[i]); i += 1 }
            }
            segs.append(Segment(ws: ws, word: word))
        }
        return (segs, "")
    }

    private static func render(_ segs: [Segment], _ trailing: String) -> String {
        segs.map { $0.ws + $0.word }.joined() + trailing
    }

    private var words: [String] { tokenize().segs.map(\.word) }

    private func value(forKey key: String) -> String? {
        let p = key + ":"
        guard let w = words.first(where: { $0.hasPrefix(p) && !$0.hasPrefix("note:\"") }) else { return nil }
        return String(w.dropFirst(p.count))
    }

    // MARK: - Read

    /// A whitespace-only line — a spacer in the file, not a task.
    public var isBlank: Bool { raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var isDone: Bool { words.first == "x" }
    public var due: String? { value(forKey: "due") }
    public var quadrant: Int? { value(forKey: "q").flatMap(Int.init) }
    public var isFocused: Bool { value(forKey: "focus") == "true" }
    public var created: String? { value(forKey: "created") }
    public var completedDate: String? { value(forKey: "done") }

    public var projects: [String] {
        words.filter { $0.hasPrefix("+") && $0.count > 1 }.map { String($0.dropFirst()) }
    }

    public var contexts: [String] {
        words.filter { $0.hasPrefix("@") && $0.count > 1 }.map { String($0.dropFirst()) }
    }

    public var note: String? {
        guard let w = words.first(where: { $0.hasPrefix("note:\"") }) else { return nil }
        let inner = w.dropFirst(6)
        return inner.hasSuffix("\"") ? String(inner.dropLast()) : String(inner)
    }

    /// The human-readable task text with all metadata tokens stripped.
    public var title: String {
        words.filter { w in
            if w == "x" || w.hasPrefix("+") || w.hasPrefix("@") || w.hasPrefix("note:\"") { return false }
            if let c = w.firstIndex(of: ":"), c != w.startIndex,
               Self.knownKeys.contains(String(w[..<c])) { return false }
            return true
        }.joined(separator: " ")
    }

    // MARK: - Edit (minimal mutation of `raw`)

    /// Replace an existing `key:value` token in place, or append one at the end.
    public mutating func setValue(_ value: String, forKey key: String) {
        var (segs, trailing) = tokenize()
        let p = key + ":"
        if let idx = segs.firstIndex(where: { $0.word.hasPrefix(p) && !$0.word.hasPrefix("note:\"") }) {
            segs[idx].word = p + value
        } else {
            segs.append(Segment(ws: segs.isEmpty ? "" : " ", word: p + value))
        }
        raw = Self.render(segs, trailing)
    }

    /// Remove a `key:value` token (and its leading whitespace) if present.
    public mutating func removeKey(_ key: String) {
        var (segs, trailing) = tokenize()
        let p = key + ":"
        guard let idx = segs.firstIndex(where: { $0.word.hasPrefix(p) && !$0.word.hasPrefix("note:\"") }) else { return }
        segs.remove(at: idx)
        if idx == 0, !segs.isEmpty { segs[0].ws = "" } // new first token owns no leading space
        raw = Self.render(segs, trailing)
    }

    public mutating func setDue(_ date: String?) {
        if let date { setValue(date, forKey: "due") } else { removeKey("due") }
    }

    /// Set (or clear, when nil/empty) the `note:"…"` token. Quotes are always emitted
    /// so notes containing spaces survive a round-trip.
    public mutating func setNote(_ text: String?) {
        var (segs, trailing) = tokenize()
        let clean = (text ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "'")
        let idx = segs.firstIndex { $0.word.hasPrefix("note:\"") }
        if clean.isEmpty {
            guard let i = idx else { return }
            segs.remove(at: i)
            if i == 0, !segs.isEmpty { segs[0].ws = "" }
        } else if let i = idx {
            segs[i].word = "note:\"\(clean)\""
        } else {
            segs.append(Segment(ws: segs.isEmpty ? "" : " ", word: "note:\"\(clean)\""))
        }
        raw = Self.render(segs, trailing)
    }

    public mutating func setQuadrant(_ q: Int?) {
        if let q, (1...4).contains(q) { setValue(String(q), forKey: "q") } else { removeKey("q") }
    }

    public mutating func setFocus(_ on: Bool) {
        if on { setValue("true", forKey: "focus") } else { removeKey("focus") }
    }

    /// Replace the task's title text while preserving metadata tokens (x, +project,
    /// @context, note:, known key:value). The edited line normalizes to
    /// `[x] title metadata…` (single-spaced) — only this one line changes.
    public mutating func setTitle(_ newTitle: String) {
        let titleWords = newTitle.split(separator: " ").map(String.init)
        guard !titleWords.isEmpty else { return }
        let (segs, _) = tokenize()
        var hasX = false
        var meta: [String] = []
        for s in segs {
            let w = s.word
            if w == "x" { hasX = true; continue }
            if w.hasPrefix("+") || w.hasPrefix("@") || w.hasPrefix("note:\"") { meta.append(w); continue }
            if let c = w.firstIndex(of: ":"), c != w.startIndex, Self.knownKeys.contains(String(w[..<c])) { meta.append(w); continue }
            // otherwise a title word — dropped, replaced by newTitle
        }
        raw = ((hasX ? ["x"] : []) + titleWords + meta).joined(separator: " ")
    }

    /// Append a bare tag token — `+project` or `@context` — if not already present.
    public mutating func addTag(_ token: String) {
        let tok = (token.hasPrefix("+") || token.hasPrefix("@")) ? token : "+" + token
        guard tok.count > 1, !words.contains(tok) else { return }
        var (segs, trailing) = tokenize()
        segs.append(Segment(ws: segs.isEmpty ? "" : " ", word: tok))
        raw = Self.render(segs, trailing)
    }

    /// Remove a bare tag token — `+project` or `@context` — if present.
    public mutating func removeTag(_ token: String) {
        var (segs, trailing) = tokenize()
        guard let i = segs.firstIndex(where: { $0.word == token }) else { return }
        segs.remove(at: i)
        if i == 0, !segs.isEmpty { segs[0].ws = "" }
        raw = Self.render(segs, trailing)
    }

    /// Toggle completion. Completing also stamps `done:` and clears focus + quadrant
    /// (a finished task is neither what you're working on now nor sitting in the matrix).
    public mutating func setDone(_ done: Bool, date: String) {
        var (segs, trailing) = tokenize()
        let hasX = segs.first?.word == "x"
        if done {
            if !hasX {
                let leadWs = segs.first?.ws ?? ""
                if !segs.isEmpty { segs[0].ws = " " }
                segs.insert(Segment(ws: leadWs, word: "x"), at: 0)
            }
            raw = Self.render(segs, trailing)
            setValue(date, forKey: "done")
            setFocus(false)
            setQuadrant(nil)
        } else {
            if hasX {
                segs.removeFirst()
                if !segs.isEmpty { segs[0].ws = "" }
            }
            raw = Self.render(segs, trailing)
            removeKey("done")
        }
    }
}

/// Parse/serialize a whole file, preserving blank lines and the trailing newline exactly.
public enum TasksDocument {
    public static func parse(_ text: String) -> [TaskLine] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { TaskLine(String($0)) }
    }

    public static func serialize(_ lines: [TaskLine]) -> String {
        lines.map(\.raw).joined(separator: "\n")
    }

    /// Enforce the single-focus invariant: at most one line carries `focus:true`.
    /// Returns a new array with focus set on `index` and cleared everywhere else.
    public static func setFocus(_ lines: [TaskLine], onIndex index: Int?) -> [TaskLine] {
        var out = lines
        for i in out.indices { out[i].setFocus(i == index) }
        return out
    }
}
