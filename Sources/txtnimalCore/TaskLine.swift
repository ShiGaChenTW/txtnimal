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

    private static let knownKeys: Set<String> = ["due", "q", "focus", "created", "done", "id", "rec", "deleted"]

    private func tokenize() -> (segs: [Segment], trailing: String) {
        var segs: [Segment] = []
        let s = Array(raw)
        var i = 0
        while i < s.count {
            var ws = ""
            while i < s.count, s[i] == " " || s[i] == "\t" { ws.append(s[i]); i += 1 }
            if i >= s.count { return (segs, ws) } // trailing whitespace only
            var word = ""
            // note:"..." keeps spaces inside the quotes as one word.
            // Compare a fixed 6-char slice — never copy the tail (was O(n²) per token).
            if i + 6 <= s.count, String(s[i..<(i + 6)]) == "note:\"" {
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

    /// Raw `rec:` value, unvalidated — parse with `RecurrenceRule.parse` before trusting it.
    /// Exposed so the UI reads recurrence through this tokenizer instead of re-implementing it.
    public var recurrence: String? { value(forKey: "rec") }
    public var quadrant: Int? { value(forKey: "q").flatMap(Int.init) }
    public var isFocused: Bool { value(forKey: "focus") == "true" }
    public var created: String? { value(forKey: "created") }
    public var completedDate: String? { value(forKey: "done") }
    /// Stable identity persisted as an `id:` metadata token when available.
    public var stableID: String? { value(forKey: "id") }
    /// The date this line entered trash.txt, stamped as `deleted:`. Only lines living in
    /// trash.txt carry it; `restoreFromTrash` clears it on the way back out.
    public var deletedDate: String? { value(forKey: "deleted") }

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

    public mutating func setStableID(_ id: String?) {
        if let id, !id.isEmpty { setValue(id, forKey: "id") } else { removeKey("id") }
    }

    /// Stamp (or clear) the `deleted:` token. Every other token is left untouched, so a line
    /// survives the trash → restore round trip byte-identical apart from this one token.
    public mutating func setDeleted(_ ymd: String?) {
        if let ymd, !ymd.isEmpty { setValue(ymd, forKey: "deleted") } else { removeKey("deleted") }
    }

    /// Reduce untrusted text to a safe single-line title: no line breaks, and no words that would
    /// be reparsed as todo.txt control tokens (`x` completion, `due:`/`id:`/`done:`… keys,
    /// `+project`, `@context`). Prevents an agent-supplied title from injecting completion, dates,
    /// identity, tags, or extra task lines.
    public static func sanitizedTitle(_ text: String) -> String {
        // Split on ANY whitespace (space, tab, newline) — the tokenizer does, so space-only
        // splitting would let a tab smuggle "x", "due:", etc. past the filter. Drop every word the
        // tokenizer would treat as metadata: completion, +project, @context, note:"…", known key:.
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            .filter { word in
                if word == "x" { return false }
                if word.hasPrefix("+") || word.hasPrefix("@") || word.hasPrefix("note:\"") { return false }
                if let colon = word.firstIndex(of: ":"), colon != word.startIndex,
                   knownKeys.contains(String(word[..<colon])) { return false }
                return true
            }
            .joined(separator: " ")
    }

    /// An unknown `key:value`-shaped token (e.g. `pri:high`). Not part of the known schema, but
    /// the preservation invariant says it must survive edits — `setTitle` keeps it as metadata.
    /// Key must look like an identifier (letter first) so title words like `12:30` stay title.
    private static func isUnknownMetadataWord(_ w: String) -> Bool {
        guard let c = w.firstIndex(of: ":"), c != w.startIndex, c < w.index(before: w.endIndex) else { return false }
        let key = String(w[..<c])
        guard !knownKeys.contains(key), key.first?.isLetter == true else { return false }
        return key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// Replace the task's title text while preserving metadata tokens (x, +project,
    /// @context, note:, known key:value, and unknown key:value). The edited line normalizes to
    /// `[x] title metadata…` (single-spaced) — only this one line changes.
    public mutating func setTitle(_ newTitle: String) {
        let (segs, _) = tokenize()
        var hasX = false
        var meta: [String] = []
        for s in segs {
            let w = s.word
            if w == "x" { hasX = true; continue }
            if w.hasPrefix("+") || w.hasPrefix("@") || w.hasPrefix("note:\"") { meta.append(w); continue }
            if let c = w.firstIndex(of: ":"), c != w.startIndex, Self.knownKeys.contains(String(w[..<c])) { meta.append(w); continue }
            if Self.isUnknownMetadataWord(w) { meta.append(w); continue } // 不變量 2:未知 token 必須存活
            // otherwise a title word — dropped, replaced by newTitle
        }
        // 編輯欄以 `title` 預填、可能連未知 token 一起帶回來——已保留的不重複寫入。
        let preserved = Set(meta)
        let titleWords = newTitle.split(separator: " ").map(String.init).filter { !preserved.contains($0) }
        guard !titleWords.isEmpty else { return }
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

    public func recurringSuccessor(completionYMD: String, calendar: Calendar = .current) -> TaskLine? {
        guard let recValue = value(forKey: "rec"), let rule = RecurrenceRule.parse(recValue) else { return nil }
        guard let nextDue = Recurrence.nextDue(base: due, rule: rule, completionYMD: completionYMD, calendar: calendar) else {
            return nil
        }

        var words = title.split(separator: " ").map(String.init)
        words.append(contentsOf: projects.map { "+" + $0 })
        words.append(contentsOf: contexts.map { "@" + $0 })
        words.append("due:\(nextDue)")
        if let quadrant, (1...4).contains(quadrant) { words.append("q:\(quadrant)") }
        words.append("rec:\(recValue)")
        words.append("created:\(completionYMD)")
        if let note { words.append("note:\"\(note)\"") }
        return TaskLine(words.joined(separator: " "))
    }
}

/// Parse/serialize a whole file, preserving blank lines and the trailing newline exactly.
public enum TasksDocument {
    public static func parse(_ text: String) -> [TaskLine] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { TaskLine(String($0)) }
    }

    public static func serialize(_ lines: [TaskLine]) -> String {
        lines.map(\.raw).joined(separator: "\n")
    }

    /// Read-layer focus: the first `focus:true`. Load/save leave extras intact.
    public static func focusIndex(in lines: [TaskLine]) -> Int? {
        lines.firstIndex(where: { $0.isFocused })
    }

    /// Enforce the single-focus invariant: at most one line carries `focus:true`.
    /// Returns a new array with focus set on `index` and cleared everywhere else.
    public static func setFocus(_ lines: [TaskLine], onIndex index: Int?) -> [TaskLine] {
        var out = lines
        for i in out.indices { out[i].setFocus(i == index) }
        return out
    }

    /// Toggle using the read-layer focus (first `focus:true`). Any other line
    /// becomes the sole focus; the current read-layer focus clears every `focus:true`.
    public static func toggleFocus(_ lines: [TaskLine], at index: Int) -> [TaskLine] {
        setFocus(lines, onIndex: focusIndex(in: lines) == index ? nil : index)
    }
}
