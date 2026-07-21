import AppKit
import SwiftUI

/// 單行 shell 輸入欄。使用真正的 NSTextView selection rect 繪製 block caret，
/// 所以左右移動、選字與輸入法組字時，游標仍會跟著實際插入位置。
struct TerminalInputField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false

        let input = BlockCursorTextView()
        input.delegate = context.coordinator
        input.onSubmit = onSubmit
        input.onCancel = onCancel
        input.isRichText = false
        input.importsGraphics = false
        input.drawsBackground = false
        input.textContainerInset = .zero
        input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.maximumNumberOfLines = 1
        input.textContainer?.lineBreakMode = .byClipping
        input.isHorizontallyResizable = true
        input.isVerticallyResizable = false
        input.autoresizingMask = [.width]
        input.string = text
        input.setAccessibilityLabel("Terminal task input")
        scroll.documentView = input

        DispatchQueue.main.async { input.window?.makeFirstResponder(input) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let input = scroll.documentView as? BlockCursorTextView else { return }
        input.onSubmit = onSubmit
        input.onCancel = onCancel
        input.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        input.textColor = NSColor(Theme.fg)
        input.insertionPointColor = NSColor(Theme.green)
        input.blockColor = NSColor(Theme.green)
        if input.string != text {
            let selection = input.selectedRange()
            input.string = text
            input.setSelectedRange(NSRange(location: min(selection.location, text.utf16.count), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TerminalInputField
        init(_ parent: TerminalInputField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let input = notification.object as? NSTextView else { return }
            parent.text = input.string.replacingOccurrences(of: "\n", with: "")
        }
    }
}

private final class BlockCursorTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var blockColor = NSColor.systemGreen

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let block = NSRect(x: rect.minX, y: rect.minY, width: 8, height: rect.height)
        super.drawInsertionPoint(in: block, color: blockColor.withAlphaComponent(0.82), turnedOn: flag)
    }
}
