import Foundation

/// Turns one line (or a short paste) from note quick-capture into a draft.
///
/// Wrappers — same symbol (or a matching pair) before and after the text:
/// - `- … -`  list (split on newlines / `;` / `；` / `、`)
/// - `" … "` or `> … <`  quote
/// - `| … |`  block
///
/// Markdown prefixes (`- `, `> `, `| `) also work when there is no wrapper.
/// `#tag` tokens are stripped from the body and stored as tags.
public enum NoteCapture {
    public static func parse(_ input: String) -> NoteDraft? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let (tags, remainder) = extractTags(from: trimmed)
        let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }

        if let wrapped = unwrap(text) {
            let body = formatBody(wrapped.inner, kind: wrapped.kind)
            if body.isEmpty { return nil }
            return NoteDraft(kind: wrapped.kind, tags: tags, body: LinkMarkup.rewrite(body))
        }

        if let prefixed = prefixKind(of: text) {
            let body = formatBody(text, kind: prefixed)
            if body.isEmpty { return nil }
            return NoteDraft(kind: prefixed, tags: tags, body: LinkMarkup.rewrite(body))
        }

        return NoteDraft(kind: .plain, tags: tags, body: LinkMarkup.rewrite(text))
    }

    public static func extractTags(from input: String) -> (tags: [String], remainder: String) {
        var tags: [String] = []
        var kept: [String] = []
        input.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\t" }).forEach { token in
            let word = String(token)
            if word.hasPrefix("#"), word.count > 1, !word.dropFirst().contains(where: { $0 == "#" }) {
                tags.append(String(word.dropFirst()))
            } else {
                kept.append(word)
            }
        }
        let remainder = kept.joined(separator: " ")
            .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return (Note.normalizedTags(tags), remainder)
    }

    private static func unwrap(_ text: String) -> (kind: NoteKind, inner: String)? {
        guard text.count >= 2, let first = text.first, let last = text.last else { return nil }
        let kind: NoteKind?
        switch (first, last) {
        case ("-", "-"): kind = .list
        case ("\"", "\""): kind = .quote
        case ("|", "|"): kind = .block
        case (">", "<"): kind = .quote
        default: kind = nil
        }
        guard let kind else { return nil }
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return (kind, inner)
    }

    private static func prefixKind(of text: String) -> NoteKind? {
        if text.hasPrefix("- ") { return .list }
        if text.hasPrefix("> ") { return .quote }
        if text.hasPrefix("| ") { return .block }
        return nil
    }

    private static func formatBody(_ inner: String, kind: NoteKind) -> String {
        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .plain, .quote, .block:
            return trimmed
        case .list:
            var parts = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if parts.count <= 1 {
                let line = parts.first ?? trimmed
                parts = splitListItems(line)
            }
            return parts
                .map { item -> String in
                    var s = item
                    while s.hasPrefix("- ") { s = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                    return "- " + s
                }
                .filter { $0 != "- " }
                .joined(separator: "\n")
        }
    }

    private static func splitListItems(_ line: String) -> [String] {
        let separators = CharacterSet(charactersIn: ";；、")
        let pieces = line.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return pieces.isEmpty ? [line] : pieces
    }
}
