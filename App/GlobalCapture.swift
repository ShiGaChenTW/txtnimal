import SwiftUI
import AppKit
import KeyboardShortcuts
import TasksTxtCore

extension KeyboardShortcuts.Name {
    /// 全域捕捉，預設 ⌥Space;可在「設定」重綁。
    static let capture = Self("globalCapture", default: .init(.space, modifiers: [.option]))
}

/// 借過鍵盤焦點的無邊框浮窗（borderless 預設不能成為 key window，要覆寫）。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 全域熱鍵 → 螢幕上方浮出一行捕捉框。任何 app 裡都能叫出來。
final class GlobalCapture {
    static let shared = GlobalCapture()
    private var panel: NSPanel?
    private weak var store: TaskStore?

    func install(store: TaskStore) {
        self.store = store
        KeyboardShortcuts.onKeyUp(for: .capture) { [weak self] in self?.toggle() }
    }

    func toggle() {
        if panel?.isVisible == true { hide(); return }
        show()
    }

    private func show() {
        guard let store else { return }
        if panel == nil {
            let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 92),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: GlobalCaptureView(
                onCommit: { [weak self] text in
                    store.addFromCapture(text)
                    self?.hide()
                },
                onCancel: { [weak self] in self?.hide() }
            ).environmentObject(store))
            host.frame = p.contentView?.bounds ?? .zero
            host.autoresizingMask = [.width, .height]
            p.contentView?.addSubview(host)
            panel = p
        }
        if let f = NSScreen.main?.visibleFrame, let p = panel {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - f.height * 0.22))
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func hide() { panel?.orderOut(nil) }
}

private struct GlobalCaptureView: View {
    @EnvironmentObject var store: TaskStore
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(">").foregroundColor(Theme.green)
                TextField("Call bank due:fri +personal", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(Theme.fg)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { text = ""; onCancel() }
            }
            preview
            CaptureHelp()
        }
        .padding(16)
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.border))
        .clipShape(Rectangle())
        .onAppear { text = ""; focused = true }
    }

    @ViewBuilder private var preview: some View {
        let parts = text.split(separator: " ").map(String.init)
        let dueTok = parts.first { $0.hasPrefix("due:") }?.dropFirst(4)
        HStack(spacing: 12) {
            if let d = dueTok, let norm = DueDateParser.parse(String(d), today: Date()) {
                Text("due:\(norm)").foregroundColor(Theme.blue)
            }
            ForEach(parts.filter { $0.hasPrefix("+") && $0.count > 1 }, id: \.self) { Text($0).foregroundColor(Theme.mag) }
            ForEach(parts.filter { $0.hasPrefix("@") && $0.count > 1 }, id: \.self) { Text($0).foregroundColor(Theme.cyan) }
            Spacer()
            Text("⏎ 加入 · esc 取消").foregroundColor(Theme.dim)
        }
        .font(Theme.monoSmall).frame(height: 15)
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        text = ""
        if t.isEmpty { onCancel() } else { onCommit(t) }
    }
}

/// 新增視窗共用的「語法說明」摺疊區：預設縮起,點擊或 ⌘/ 展開。
struct CaptureHelp: View {
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(open ? "▾" : "▸").foregroundColor(Theme.dim)
                Text("? 語法說明").foregroundColor(Theme.dim)
                Spacer()
                Text("⌘/").foregroundColor(Theme.dim).opacity(0.7)
            }
            .font(Theme.monoSmall)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    row("due:", "due:fri · due:tomorrow · due:3d · due:2026-07-25", Theme.blue)
                    row("+專案", "+business +side（可多個）", Theme.mag)
                    row("@情境", "@mac @calls @home（可多個）", Theme.cyan)
                    row("note:", "note:\"含空格要加引號\"", Theme.dim)
                    Text("例：寄出報價單給王經理 due:fri +business @mac note:\"附上7月折扣方案\"")
                        .foregroundColor(Theme.fg).padding(.top, 3)
                    Text("例：繳房租 due:tomorrow +personal ／ 只打一句話也行 → 落「無期限」")
                        .foregroundColor(Theme.dim)
                }
                .font(Theme.monoSmall)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.border))
            }
            // 隱形按鈕承接 ⌘/ 快捷鍵
            Button("") { open.toggle() }
                .keyboardShortcut("/", modifiers: .command)
                .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0)
        }
    }

    private func row(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).foregroundColor(c).frame(width: 52, alignment: .leading)
            Text(v).foregroundColor(Theme.dim)
        }
    }
}

/// 設定視窗：重綁全域熱鍵 + 檔案位置(SPEC 9:真正的設定只有這兩個)。
struct SettingsView: View {
    @EnvironmentObject var store: TaskStore
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder("全域捕捉熱鍵：", name: .capture)
            Text("在任何 app 按此熱鍵即可快速記一筆").font(Theme.monoSmall).foregroundColor(Theme.dim)
            Divider().padding(.vertical, 6)
            HStack(spacing: 8) {
                Text("檔案位置：")
                Text((store.dataDirPath as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
                    .lineLimit(1).truncationMode(.middle)
                Button("更改…") { pickFolder() }
            }
            Text("tasks.txt / scratch.txt / archive.txt 所在資料夾;搬到空資料夾會自動帶檔(複製,原檔保留)")
                .font(Theme.monoSmall).foregroundColor(Theme.dim)
        }
        .padding(20)
        .frame(width: 420)
    }
    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = "選這個資料夾"
        if p.runModal() == .OK, let url = p.url { store.setDataDir(url) }
    }
}
