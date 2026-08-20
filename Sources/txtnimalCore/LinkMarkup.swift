import Foundation

/// One run of note body text after auto-link rewriting.
public enum LinkSegment: Equatable, Sendable {
    case text(String)
    case link(label: String, url: URL)
}

/// Turns typed `label,https://…` and GitHub URLs into markdown links, and
/// splits a body into tappable segments for the UI.
///
/// Label rule: the token immediately before a URL becomes the link text and
/// the URL is dropped from the visible body. GitHub URLs without a label
/// display as `Github:owner/repo`.
public enum LinkMarkup {
    public static func rewrite(_ text: String) -> String {
        let matches = urlMatches(in: text)
        guard !matches.isEmpty else { return text }
        var output = text
        for match in matches.reversed() {
            if isAlreadyMarkdown(match: match, in: output) { continue }
            let urlString = String(output[match])
            guard let url = normalizedURL(from: urlString) else { continue }
            let labelRange = labelRange(before: match, in: output)
            let label: String
            let replace: Range<String.Index>
            if let labelRange {
                label = String(output[labelRange])
                replace = labelRange.lowerBound..<match.upperBound
            } else if let github = githubLabel(for: url) {
                label = github
                replace = match
            } else {
                continue
            }
            output.replaceSubrange(replace, with: "[\(escapeLabel(label))](\(url.absoluteString))")
        }
        return output
    }

    public static func segments(_ text: String) -> [LinkSegment] {
        let rewritten = rewrite(text)
        var result: [LinkSegment] = []
        var cursor = rewritten.startIndex
        let markdown = markdownLinkRegex
        let ns = rewritten as NSString
        let full = NSRange(location: 0, length: ns.length)
        markdown.enumerateMatches(in: rewritten, range: full) { match, _, _ in
            guard let match,
                  let all = Range(match.range, in: rewritten),
                  match.numberOfRanges >= 3,
                  let labelR = Range(match.range(at: 1), in: rewritten),
                  let urlR = Range(match.range(at: 2), in: rewritten),
                  let url = URL(string: String(rewritten[urlR])) else { return }
            if cursor < all.lowerBound {
                result.append(contentsOf: rawURLSegments(String(rewritten[cursor..<all.lowerBound])))
            }
            result.append(.link(label: unescapeLabel(String(rewritten[labelR])), url: url))
            cursor = all.upperBound
        }
        if cursor < rewritten.endIndex {
            result.append(contentsOf: rawURLSegments(String(rewritten[cursor...])))
        }
        return coalesce(result)
    }

    public static func githubLabel(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        guard trimmedHost == "github.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty,
              owner != "login", owner != "settings", owner != "orgs", owner != "marketplace" else { return nil }
        return "Github:\(owner)/\(repo)"
    }

    // MARK: - scan

    private static func urlMatches(in text: String) -> [Range<String.Index>] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var ranges: [Range<String.Index>] = []
        urlRegex.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            ranges.append(trimTrailingPunctuation(range, in: text))
        }
        return ranges
    }

    private static func trimTrailingPunctuation(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var end = range.upperBound
        let trailing = CharacterSet(charactersIn: ".,;:!?)]}>\"'。，、；：）】」")
        while end > range.lowerBound {
            let prev = text.index(before: end)
            guard let scalar = text[prev].unicodeScalars.first, trailing.contains(scalar) else { break }
            end = prev
        }
        return range.lowerBound..<end
    }

    private static func isAlreadyMarkdown(match: Range<String.Index>, in text: String) -> Bool {
        String(text[text.startIndex..<match.lowerBound]).hasSuffix("](")
    }

    private static func labelRange(before url: Range<String.Index>, in text: String) -> Range<String.Index>? {
        var idx = url.lowerBound
        guard idx > text.startIndex else { return nil }
        var sawSeparator = false
        while idx > text.startIndex {
            let prev = text.index(before: idx)
            if text[prev].isNewline { return nil }
            if text[prev].isWhitespace {
                idx = prev
                sawSeparator = true
                continue
            }
            break
        }
        if idx > text.startIndex {
            let prev = text.index(before: idx)
            if ",，:：".contains(text[prev]) {
                idx = prev
                sawSeparator = true
            }
        }
        guard sawSeparator || (idx > text.startIndex && !text[text.index(before: idx)].isWhitespace) else {
            return nil
        }
        var start = idx
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev].isWhitespace { break }
            if "](".contains(text[prev]) { break }
            start = prev
        }
        let raw = text[start..<idx]
        let label = raw.trimmingCharacters(in: CharacterSet(charactersIn: ",，:："))
        guard !label.isEmpty,
              !label.contains("://"),
              !label.hasPrefix("#"),
              label != "[" else { return nil }
        return start..<idx
    }

    private static func normalizedURL(from raw: String) -> URL? {
        URL(string: raw)
    }

    private static func escapeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "]", with: "\\]")
    }

    private static func unescapeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\\]", with: "]")
    }

    private static func rawURLSegments(_ text: String) -> [LinkSegment] {
        guard !text.isEmpty else { return [] }
        let matches = urlMatches(in: text)
        guard !matches.isEmpty else { return [.text(text)] }
        var result: [LinkSegment] = []
        var cursor = text.startIndex
        for match in matches {
            if cursor < match.lowerBound {
                result.append(.text(String(text[cursor..<match.lowerBound])))
            }
            let urlString = String(text[match])
            if let url = URL(string: urlString) {
                let label = githubLabel(for: url) ?? urlString
                result.append(.link(label: label, url: url))
            } else {
                result.append(.text(urlString))
            }
            cursor = match.upperBound
        }
        if cursor < text.endIndex {
            result.append(.text(String(text[cursor...])))
        }
        return result
    }

    private static func coalesce(_ segments: [LinkSegment]) -> [LinkSegment] {
        var out: [LinkSegment] = []
        for seg in segments {
            if case .text(let s) = seg, s.isEmpty { continue }
            if case .text(let s) = seg, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + s)
            } else {
                out.append(seg)
            }
        }
        return out
    }

    private static let urlRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"https?://[^\s<>\[\]()]+"#, options: [])
    }()

    private static let markdownLinkRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\[([^\]\\]*(?:\\.[^\]\\]*)*)\]\((https?://[^)\s]+)\)"#, options: [])
    }()
}
