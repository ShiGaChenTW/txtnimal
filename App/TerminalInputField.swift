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
        let scroll = TerminalInputScrollView()
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
        input.minSize = NSSize(width: 0, height: 20)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 20)
        input.string = text
        input.setAccessibilityLabel("Terminal task input")
        scroll.documentView = input

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let input = scroll.documentView as? BlockCursorTextView else { return }
        context.coordinator.parent = self
        input.onSubmit = onSubmit
        input.onCancel = onCancel
        input.font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        input.textColor = NSColor(Theme.fg)
        // Codex-style caret: a high-contrast, fully opaque block rather than the
        // theme accent or macOS's outlined insertion indicator.
        input.insertionPointColor = .clear
        input.blockColor = NSColor(Theme.fg)
        input.updateSolidCaret()
        input.focusWhenAttached()
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
            guard let input = notification.object as? BlockCursorTextView else { return }
            parent.text = input.string.replacingOccurrences(of: "\n", with: "")
            input.updateSolidCaret()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? BlockCursorTextView)?.updateSolidCaret()
        }
    }
}

private final class TerminalInputScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let documentView else { return }
        documentView.frame = NSRect(origin: .zero, size: contentSize)
    }
}

private final class BlockCursorTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    private let solidCaret = NSView()
    var blockColor = NSColor.systemGreen {
        didSet { solidCaret.layer?.backgroundColor = blockColor.cgColor }
    }

    convenience init() {
        self.init(frame: .zero, textContainer: nil)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureSolidCaret()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSolidCaret()
    }

    private func configureSolidCaret() {
        solidCaret.wantsLayer = true
        solidCaret.layer?.backgroundColor = blockColor.cgColor
        solidCaret.layer?.cornerRadius = 0
        addSubview(solidCaret, positioned: .above, relativeTo: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusWhenAttached()
        updateSolidCaret()
    }

    func focusWhenAttached() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
            self.updateSolidCaret()
        }
    }

    override func layout() {
        super.layout()
        updateSolidCaret()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        DispatchQueue.main.async { [weak self] in self?.updateSolidCaret() }
    }

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
        DispatchQueue.main.async { [weak self] in self?.updateSolidCaret() }
    }

    func updateSolidCaret() {
        guard let window,
              window.firstResponder === self,
              selectedRange().length == 0 else {
            solidCaret.isHidden = true
            return
        }

        var actualRange = NSRange()
        let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: &actualRange)
        // AppKit represents a valid insertion point as a zero-width rect.
        // `isEmpty` is therefore true even when its origin and height are valid.
        guard screenRect.height > 0 else {
            solidCaret.isHidden = true
            return
        }

        let windowOrigin = window.convertPoint(fromScreen: screenRect.origin)
        let localOrigin = convert(windowOrigin, from: nil)
        solidCaret.frame = NSRect(
            x: localOrigin.x,
            y: localOrigin.y,
            width: 8,
            height: max(1, screenRect.height)
        ).integral
        solidCaret.isHidden = false
    }
}
