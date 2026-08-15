import Foundation

/// Pure, deterministic helpers for the progressive quick-capture UI.
///
/// The task line remains the source of truth. These helpers only expose recognized
/// metadata as removable chips and offer conservative, opt-in date suggestions.
public enum CaptureAssist {
    public enum CompletionKind: Equatable, Sendable { case due, project, context, rec }

    public struct CompletionQuery: Equatable, Sendable {
        public let kind: CompletionKind
        public let fragment: String
        public let tokenRange: NSRange

        public init(kind: CompletionKind, fragment: String, tokenRange: NSRange) {
            self.kind = kind
            self.fragment = fragment
            self.tokenRange = tokenRange
        }
    }

    public struct CompletionResult: Equatable, Sendable {
        public let text: String
        public let cursorUTF16Offset: Int

        public init(text: String, cursorUTF16Offset: Int) {
            self.text = text
            self.cursorUTF16Offset = cursorUTF16Offset
        }
    }

    public struct Token: Equatable, Sendable, Identifiable {
        public enum Kind: Equatable, Sendable { case due, project, context, rec }

        public let kind: Kind
        public let raw: String
        public let displayValue: String
        public var id: String { "\(kind)-\(raw)" }

        public init(kind: Kind, raw: String, displayValue: String) {
            self.kind = kind
            self.raw = raw
            self.displayValue = displayValue
        }
    }

    public struct DueSuggestion: Equatable, Sendable {
        public let matchedText: String
        public let dueValue: String
        public let label: String

        public init(matchedText: String, dueValue: String, label: String) {
            self.matchedText = matchedText
            self.dueValue = dueValue
            self.label = label
        }
    }

    public static func tokens(
        from input: String,
        today: Date,
        calendar: Calendar = .current
    ) -> [Token] {
        input.split(whereSeparator: { $0.isWhitespace }).compactMap { part in
            let raw = String(part)
            if raw.hasPrefix("due:"), raw.count > 4 {
                let value = String(raw.dropFirst(4))
                guard let normalized = DueDateParser.parse(value, today: today, calendar: calendar) else { return nil }
                return Token(kind: .due, raw: raw, displayValue: normalized)
            }
            if raw.hasPrefix("+"), raw.count > 1 {
                return Token(kind: .project, raw: raw, displayValue: String(raw.dropFirst()))
            }
            if raw.hasPrefix("@"), raw.count > 1 {
                return Token(kind: .context, raw: raw, displayValue: String(raw.dropFirst()))
            }
            // 與 due: 同規則:值解析不過就不是可見 chip,原字不動、不報錯。
            if raw.hasPrefix("rec:"), raw.count > 4 {
                guard let label = recurrenceLabel(for: String(raw.dropFirst(4))) else { return nil }
                return Token(kind: .rec, raw: raw, displayValue: label)
            }
            return nil
        }
    }

    /// 週期候選值 — 兩個捕捉介面共用同一份清單,避免各自手抄一份而漂移。
    /// 排序:非 strict 的常用節奏在前(從完成日往後推,多數人要的),strict(`+`,從原 due 往後推)在後。
    public static let recurrenceCandidates: [String] = [
        "1d", "1w", "2w", "1m", "1y",
        "+1d", "+1w", "+2w", "+1m", "+1y",
    ]

    /// `rec:` 原始值 → 人話標籤。純函式,只吃字串。
    ///
    /// 語意與 `RecurrenceRule.parse` 嚴格對齊:parse 回 nil 時本函式必回 nil,
    /// 使 UI 徽章與捕捉補全共用同一份「什麼算有效週期」的判斷。
    public static func recurrenceLabel(for value: String) -> String? {
        guard let rule = RecurrenceRule.parse(value) else { return nil }
        let unit: String
        switch rule.unit {
        case .day: unit = "天"
        case .week: unit = "週"
        case .month: unit = "月"
        case .year: unit = "年"
        }
        let cadence = rule.count == 1 ? "每\(unit)" : "每 \(rule.count) \(unit)"
        return rule.strict ? cadence + "(固定)" : cadence
    }

    /// 整行原始文字 → 人話週期標籤。無 `rec:`、或其值無法解析時回 nil。
    /// 列渲染只讀不寫:回 nil 就是不畫徽章,絕不改寫該行。
    public static func recurrenceLabel(inRawLine raw: String) -> String? {
        guard let value = recurrenceValue(inRawLine: raw) else { return nil }
        return recurrenceLabel(for: value)
    }

    /// 取出整行中第一個 `rec:` token 的值(未經驗證的原始字串)。
    /// 斷詞交給 `TaskLine`,不在這裡另寫一份 — 兩份規則必然漂移。
    public static func recurrenceValue(inRawLine raw: String) -> String? {
        TaskLine(raw).recurrence
    }

    /// Only suggests unambiguous Traditional Chinese date phrases. Project and
    /// context inference intentionally remain out of scope for the first release.
    public static func dueSuggestion(from input: String) -> DueSuggestion? {
        guard !input.split(whereSeparator: { $0.isWhitespace }).contains(where: { $0.hasPrefix("due:") }) else { return nil }

        let candidates: [(text: String, value: String)] = [
            ("明天", "tomorrow"), ("後天", "2d"),
            ("星期一", "mon"), ("星期二", "tue"), ("星期三", "wed"),
            ("星期四", "thu"), ("星期五", "fri"), ("星期六", "sat"),
            ("星期日", "sun"), ("星期天", "sun"),
        ]
        guard let match = candidates.first(where: { input.contains($0.text) }) else { return nil }
        return DueSuggestion(matchedText: match.text, dueValue: match.value, label: match.text)
    }

    public static func applying(_ suggestion: DueSuggestion, to input: String) -> String {
        let withoutPhrase = input.replacingOccurrences(of: suggestion.matchedText, with: "")
        return normalizedSpacing("\(withoutPhrase) due:\(suggestion.dueValue)")
    }

    public static func removingToken(_ token: String, from input: String) -> String {
        let parts = input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let index = parts.firstIndex(of: token) else { return normalizedSpacing(input) }
        var remaining = parts
        remaining.remove(at: index)
        return remaining.joined(separator: " ")
    }

    /// Finds an autocomplete token immediately before the insertion point.
    /// Working in UTF-16 mirrors NSTextView's selection offsets exactly.
    public static func completionQuery(from input: String, cursorUTF16Offset: Int) -> CompletionQuery? {
        let source = input as NSString
        let cursor = max(0, min(cursorUTF16Offset, source.length))
        var start = cursor
        while start > 0 {
            let scalar = source.character(at: start - 1)
            guard let unicode = UnicodeScalar(scalar), !CharacterSet.whitespacesAndNewlines.contains(unicode) else { break }
            start -= 1
        }
        let range = NSRange(location: start, length: cursor - start)
        let token = source.substring(with: range)

        if token.hasPrefix("due:") {
            return CompletionQuery(kind: .due, fragment: String(token.dropFirst(4)), tokenRange: range)
        }
        if token.hasPrefix("rec:") {
            return CompletionQuery(kind: .rec, fragment: String(token.dropFirst(4)), tokenRange: range)
        }
        if token.hasPrefix("+") {
            return CompletionQuery(kind: .project, fragment: String(token.dropFirst()), tokenRange: range)
        }
        if token.hasPrefix("@") {
            return CompletionQuery(kind: .context, fragment: String(token.dropFirst()), tokenRange: range)
        }
        return nil
    }

    public static func applyingCompletion(
        _ candidate: String,
        query: CompletionQuery,
        to input: String
    ) -> CompletionResult {
        let prefix: String
        switch query.kind {
        case .due: prefix = "due:"
        case .project: prefix = "+"
        case .context: prefix = "@"
        case .rec: prefix = "rec:"
        }
        let source = input as NSString
        let replacement = prefix + candidate
        var result = source.replacingCharacters(in: query.tokenRange, with: replacement)
        var cursor = query.tokenRange.location + replacement.utf16.count
        if cursor == (result as NSString).length {
            result += " "
            cursor += 1
        }
        return CompletionResult(text: result, cursorUTF16Offset: cursor)
    }

    private static func normalizedSpacing(_ input: String) -> String {
        input.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
