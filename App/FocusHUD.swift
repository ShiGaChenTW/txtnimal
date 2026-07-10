import SwiftUI
import AppKit
import TasksTxtCore

/// 一個常駐置頂的迷你浮窗，只顯示目前 Focus 那一件。可拖到螢幕任意角落。
/// 有 Focus 且不在 Focus 模式時顯示（Focus 模式已是全頁專注，不需要再疊浮窗）。
final class FocusHUD {
    static let shared = FocusHUD()
    private var panel: NSPanel?

    func update(store: TaskStore) {
        (store.focusIndex != nil && !store.focusMode) ? show(store) : hide()
    }

    private func show(_ store: TaskStore) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 262, height: 78),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = false
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: FocusHUDView().environmentObject(store))
            host.frame = p.contentView?.bounds ?? .zero
            host.autoresizingMask = [.width, .height]
            p.contentView?.addSubview(host)
            if let f = NSScreen.main?.visibleFrame {
                p.setFrameOrigin(NSPoint(x: f.maxX - 282, y: f.maxY - 108))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }
}

struct FocusHUDView: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        Group {
            if let i = store.focusIndex, store.lines.indices.contains(i) {
                let t = store.lines[i]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("▶").font(Theme.monoSmall)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Rectangle().stroke(Theme.focus))
                        Text(t.title).font(Theme.mono).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("✕").font(Theme.monoSmall).foregroundColor(Theme.dim)
                            .onTapGesture { store.clearFocus() }
                    }
                    .foregroundColor(Theme.focus)
                    if let due = t.due, let r = RelativeDate.label(due) {
                        Text("\(due) · \(r.text)\(r.overdue ? " ⚠" : "")")
                            .font(Theme.monoSmall).foregroundColor(r.overdue ? Theme.red : Theme.dim)
                    }
                }
                .padding(12)
                .frame(width: 262, alignment: .leading)
                .background(Theme.bg)
                .overlay(Rectangle().stroke(Theme.focus))
                .clipShape(Rectangle())
            } else {
                Color.clear
            }
        }
    }
}
