import SwiftUI
import txtnimalCore

/// Renders note body text with tappable auto-links. Markdown `[label](url)` and
/// leftover raw URLs (including GitHub `Github:owner/repo` labels) are clickable.
struct NoteLinkText: View {
    let text: String
    var font: Font
    var color: Color
    var italic: Bool = false

    var body: some View {
        Text(attributed)
            .font(font)
            .italic(italic)
            .tint(Theme.blue)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        for segment in LinkMarkup.segments(text) {
            switch segment {
            case .text(let value):
                var piece = AttributedString(value)
                piece.foregroundColor = color
                result += piece
            case .link(let label, let url):
                var piece = AttributedString(label)
                piece.link = url
                piece.foregroundColor = Theme.blue
                piece.underlineStyle = .single
                result += piece
            }
        }
        return result
    }
}
