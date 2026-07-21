import SwiftUI
import AppKit
import QuartzCore
import KeyboardShortcuts
import txtnimalCore

/// 標記某個 ContentView 實例正跑在側邊面板裡(用來只讓側邊的背景層透明)。
private struct SidebarPanelKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isSidebarPanel: Bool {
        get { self[SidebarPanelKey.self] }
        set { self[SidebarPanelKey.self] = newValue }
    }
}

extension KeyboardShortcuts.Name {
    /// 全域捕捉，預設 ⌥Space;可在「設定」重綁。
    static let capture = Self("globalCapture", default: .init(.space, modifiers: [.option]))
    /// 側邊面板滑出/收回，預設 ⌥T;可在「設定」重綁。
    static let toggleSidebar = Self("toggleSidebar", default: .init(.t, modifiers: [.option]))
}

/// 借過鍵盤焦點的無邊框浮窗（borderless 預設不能成為 key window，要覆寫）。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 常駐螢幕邊緣的滑出面板：把整個 ContentView 掛進一個貼邊的無邊框 panel。
/// 邊緣可選右/左/頂(top = Ghostty 式下拉)。與 WindowGroup 共用同一個 TaskStore。
/// ponytail: 主視窗切換用 orderOut/orderFront（Route A）。若 WindowGroup 生命週期在
/// 全螢幕/重開窗邊角出問題，升級成把主 UI 也移出 WindowGroup（Route B）。
final class SidebarController {
    static let shared = SidebarController()
    private var panel: KeyablePanel?
    private var slider: NSView?           // 視窗內會滑動的內容容器(被視窗邊界裁切)
    private var resizeHandle: EdgeResizeHandle?  // 內緣拖曳把手,調整側邊寬度
    private var handle: NSPanel?
    private weak var store: TaskStore?
    /// 側邊寬度下限須 ≥ ContentView 的 minWidth(660),否則內容被裁。
    private let minSideWidth: Double = 660
    /// reveal 當下鎖定的螢幕;收回前都用它,避免焦點切螢幕導致座標飛掉(雙螢幕 bug)。
    private var activeScreen: NSScreen?

    func install(store: TaskStore) {
        self.store = store
        KeyboardShortcuts.onKeyUp(for: .toggleSidebar) { [weak self] in self?.toggle() }
        ensurePanel()                 // 預熱：首次滑出不卡頓
        apply(store.windowMode, store: store)
    }

    /// 滑鼠所在的螢幕優先(使用者正在看的那個);退回 key window 螢幕、再退回 main。
    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first!
    }

    func apply(_ mode: WindowMode, store: TaskStore) {
        self.store = store
        switch mode {
        case .sidebar:
            setMainWindowVisible(false)
            reveal(animated: false)
        case .window:
            hide(animated: false, orderOut: true)
            hideHandle()
            setMainWindowVisible(true)
        }
    }

    func toggle() {
        guard store?.windowMode == .sidebar else { return }
        (panel?.isVisible == true) ? hide(animated: true, orderOut: true) : reveal(animated: true)
    }

    /// 使用者在設定改了邊緣：面板/指示條都重新擺位(同尺寸只換幾何,不重繪內容樹)。
    func edgeChanged(store: TaskStore) {
        self.store = store
        guard store.windowMode == .sidebar else { return }
        if panel?.isVisible == true {
            panel?.setFrame(onFrame(), display: true, animate: true)  // 同螢幕重定位,不跨螢幕
            slider?.setFrameOrigin(.zero)
            layoutResizeHandle()
        } else {
            positionHandle()
        }
    }

    @discardableResult
    private func ensurePanel() -> KeyablePanel {
        if let panel { return panel }
        let p = KeyablePanel(contentRect: onFrame(),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.hasShadow = false           // 視窗固定不動、內容在內部滑動,關陰影避免出現靜止外框
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false            // 讓 behind-window 毛玻璃透得出去
        if let store, let clip = p.contentView {
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true   // 關鍵:內容滑出視窗邊界即被裁切,絕不溢到隔壁螢幕
            let slider = NSView(frame: clip.bounds)
            slider.autoresizingMask = [.width, .height]
            slider.wantsLayer = true
            // 毛玻璃背板:模糊面板後方(桌面/其他 app),文字層鋪在上面維持清楚。
            let fx = NSVisualEffectView(frame: slider.bounds)
            fx.autoresizingMask = [.width, .height]
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            slider.addSubview(fx)
            let host = NSHostingView(rootView:
                ContentView().environmentObject(store).environment(\.isSidebarPanel, true))
            host.frame = slider.bounds
            host.autoresizingMask = [.width, .height]
            slider.addSubview(host)
            // 內緣拖曳把手(疊在最上層才收得到滑鼠):拖曳 → 依滑鼠絕對座標算新寬度。
            let rh = EdgeResizeHandle()
            rh.onDragTo = { [weak self] mouse in
                guard let self else { return }
                let vf = (self.activeScreen ?? self.currentScreen()).visibleFrame
                let raw: Double = (self.store?.sidebarEdge == .left)
                    ? Double(mouse.x - vf.minX) : Double(vf.maxX - mouse.x)
                self.store?.sidebarWidth = min(max(raw, self.minSideWidth), Double(vf.width))
            }
            slider.addSubview(rh)
            self.resizeHandle = rh
            clip.addSubview(slider)
            self.slider = slider
            layoutResizeHandle()
        }
        panel = p
        return p
    }

    /// 使用者設定的側邊寬度,夾在 [minSideWidth, 螢幕寬] 之間。
    private func spanWidth(_ vf: NSRect) -> CGFloat {
        CGFloat(min(max(store?.sidebarWidth ?? 700, minSideWidth), Double(vf.width)))
    }

    /// 面板「就位」時的視窗 frame:相對鎖定螢幕,貼在目標邊。視窗只會擺在這裡,不做滑動。
    /// 側邊(右/左)上下各留 30px,呈浮動面板感,不貼滿螢幕高。
    private func onFrame() -> NSRect {
        let vf = (activeScreen ?? currentScreen()).visibleFrame
        let gap: CGFloat = 100
        switch store?.sidebarEdge ?? .right {
        case .right: let w = spanWidth(vf); return NSRect(x: vf.maxX - w, y: vf.minY + gap, width: w, height: vf.height - gap * 2)
        case .left:  let w = spanWidth(vf); return NSRect(x: vf.minX, y: vf.minY + gap, width: w, height: vf.height - gap * 2)
        case .top:   let h = max(600, vf.height * 0.55); return NSRect(x: vf.minX, y: vf.maxY - h, width: vf.width, height: h)
        }
    }

    /// 內容「藏起」時在視窗內的位移(推出視窗邊界外,被 clip 裁掉)。
    private func hiddenOrigin(_ f: NSRect) -> CGPoint {
        switch store?.sidebarEdge ?? .right {
        case .right: return CGPoint(x: f.width, y: 0)     // 往右推出
        case .left:  return CGPoint(x: -f.width, y: 0)    // 往左推出
        case .top:   return CGPoint(x: 0, y: f.height)    // 往上推出 → 下滑進場
        }
    }

    private func reveal(animated: Bool) {
        let p = ensurePanel()
        let firstShow = !p.isVisible
        if firstShow { activeScreen = currentScreen() }    // reveal 當下鎖定螢幕
        hideHandle()
        let on = onFrame()
        p.setFrame(on, display: true)                       // 視窗固定在正確螢幕,永不跨螢幕
        layoutResizeHandle()
        guard let slider else { p.makeKeyAndOrderFront(nil); return }
        if firstShow {
            slider.setFrameOrigin(hiddenOrigin(on))         // 內容先藏在視窗外
            slider.alphaValue = 0
            p.makeKeyAndOrderFront(nil)
            if animated {
                DispatchQueue.main.async { [weak self] in self?.animateSlider(to: .zero, alpha: 1, animated: true) }
                return
            }
        }
        animateSlider(to: .zero, alpha: 1, animated: animated)
    }

    private func hide(animated: Bool, orderOut: Bool) {
        guard let p = panel, p.isVisible else { return }
        animateSlider(to: hiddenOrigin(p.frame), alpha: 0, animated: animated) { [weak self] in
            if orderOut { p.orderOut(nil) }
            self?.slider?.alphaValue = 1                     // 復位,供下次 reveal
            if self?.store?.windowMode == .sidebar { self?.showHandle() }
        }
    }

    /// 拖曳把手改了寬度:即時把視窗調整到新尺寸(拖曳中不加動畫)。
    func resize() {
        guard store?.windowMode == .sidebar else { return }
        if panel?.isVisible == true {
            panel?.setFrame(onFrame(), display: true)
            slider?.setFrameOrigin(.zero)
            layoutResizeHandle()
        } else {
            positionHandle()
        }
    }

    /// 只滑「視窗內的內容容器」+ 淡入淡出。視窗本身不動 → 動畫再快也不會跨進另一個螢幕。
    /// expo-out 曲線:起步快、尾段柔和收尾,比 easeOut 更有記憶點。
    private func animateSlider(to origin: CGPoint, alpha: CGFloat, animated: Bool, then: (() -> Void)? = nil) {
        guard let slider else { then?(); return }
        guard animated else { slider.setFrameOrigin(origin); slider.alphaValue = alpha; then?(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.30
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            slider.animator().setFrameOrigin(origin)
            slider.animator().alphaValue = alpha
        }, completionHandler: then)
    }

    /// 把內緣拖曳把手擺到目前邊緣的內側(頂部模式本版不提供寬度調整)。
    private func layoutResizeHandle() {
        guard let slider, let h = resizeHandle else { return }
        let b = slider.bounds, t: CGFloat = 8
        switch store?.sidebarEdge ?? .right {
        case .right: h.isHidden = false; h.frame = NSRect(x: 0, y: 0, width: t, height: b.height); h.autoresizingMask = [.height]
        case .left:  h.isHidden = false; h.frame = NSRect(x: b.width - t, y: 0, width: t, height: b.height); h.autoresizingMask = [.height, .minXMargin]
        case .top:   h.isHidden = true
        }
        h.window?.invalidateCursorRects(for: h)
    }

    /// 找出 WindowGroup 主視窗（非 panel 的標準視窗）並顯示/隱藏。
    private func setMainWindowVisible(_ visible: Bool) {
        for w in NSApp.windows where !(w is NSPanel) && w.contentView != nil {
            visible ? w.makeKeyAndOrderFront(nil) : w.orderOut(nil)
        }
    }

    // MARK: - 貼邊指示條(面板收起時顯示,點一下滑出)

    /// 指示條幾何:貼在鎖定螢幕的目標邊,置中的一小段。
    private func handleFrame() -> NSRect {
        let vf = (activeScreen ?? currentScreen()).visibleFrame
        let t: CGFloat = 6, len: CGFloat = 132
        switch store?.sidebarEdge ?? .right {
        case .right: return NSRect(x: vf.maxX - t, y: vf.midY - len / 2, width: t, height: len)
        case .left:  return NSRect(x: vf.minX,     y: vf.midY - len / 2, width: t, height: len)
        case .top:   return NSRect(x: vf.midX - len / 2, y: vf.maxY - t, width: len, height: t)
        }
    }

    private func showHandle() {
        if activeScreen == nil { activeScreen = currentScreen() }
        let h = ensureHandle()
        positionHandle()
        h.orderFrontRegardless()
    }

    private func hideHandle() { handle?.orderOut(nil) }

    private func positionHandle() {
        guard let h = handle else { return }
        h.setFrame(handleFrame(), display: true)
        (h.contentView?.subviews.first as? NSHostingView<SidebarHandleView>)?
            .rootView = SidebarHandleView(edge: store?.sidebarEdge ?? .right,
                                          color: store?.accent ?? Theme.focus) { [weak self] in
                self?.reveal(animated: true)
            }
    }

    private func ensureHandle() -> NSPanel {
        if let handle { return handle }
        let p = NSPanel(contentRect: handleFrame(),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        let host = NSHostingView(rootView: SidebarHandleView(edge: store?.sidebarEdge ?? .right,
                                                             color: store?.accent ?? Theme.focus) { [weak self] in
            self?.reveal(animated: true)
        })
        host.frame = p.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(host)
        handle = p
        return p
    }
}

/// 側邊面板內緣的拖曳把手:拖動時回報滑鼠絕對座標,由 controller 換算成新寬度。
/// 用 NSEvent.mouseLocation(螢幕絕對座標)→ 視窗即時重繪也不會抖。
private final class EdgeResizeHandle: NSView {
    var onDragTo: ((NSPoint) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {}                 // 接管,避免拖到底層
    override func mouseDragged(with event: NSEvent) { onDragTo?(NSEvent.mouseLocation) }
}

/// 貼邊的小指示條:平時半透明,滑鼠移上去變亮並加寬提示,點一下把面板滑出。
private struct SidebarHandleView: View {
    let edge: SidebarEdge
    var color: Color = Theme.focus
    let onActivate: () -> Void
    @State private var hovering = false

    var body: some View {
        let horizontal = edge == .top
        Capsule()
            .fill(color.opacity(hovering ? 0.95 : 0.5))
            .frame(width: horizontal ? nil : (hovering ? 5 : 3),
                   height: horizontal ? (hovering ? 5 : 3) : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { onActivate() }
            .help("點一下滑出 tasks.txt")
    }
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
                    row("+List", "+business +side（可多個）", Theme.mag)
                    row("@Tag", "@mac @calls @home（可多個）", Theme.cyan)
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

    private func row(_ k: LocalizedStringKey, _ v: LocalizedStringKey, _ c: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).foregroundColor(c).frame(width: 52, alignment: .leading)
            Text(v).foregroundColor(Theme.dim)
        }
    }
}

/// 設定視窗(⌘,)：個人 / 快速鍵 / 外觀 / 檔案。
struct SettingsView: View {
    @EnvironmentObject var store: TaskStore
    @State private var showingTaskFiles = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            section("個人")
            HStack(spacing: 8) {
                Text("語言").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(LocalizedStringKey(language.label)).tag(language)
                    }
                }.labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("使用者名稱").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                TextField("", text: $store.userName,
                          prompt: Text("留空則用通用問候").foregroundColor(Theme.dim.opacity(0.4)))
                    .textFieldStyle(.plain).foregroundColor(Theme.fg)
                    .padding(8).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            hint("統計頁問候語會用這個名字")

            section("快速鍵")
            HStack(spacing: 8) {
                Text("全域捕捉").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                KeyboardShortcuts.Recorder("", name: .capture)
            }
            hint("在任何 app 按此熱鍵即可快速記一筆")
            hint("app 內快速鍵固定：⌘1 清單 · ⌘2 象限 · ⌘3 便箋 · ⌘4 統計 · ⌘E 編輯 · ⌘K 指令")

            section("視窗")
            HStack(spacing: 8) {
                Text("視窗模式").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.windowMode) {
                    ForEach(WindowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("出現位置").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.sidebarEdge) {
                    ForEach(SidebarEdge.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 150)
                    .disabled(store.windowMode != .sidebar)
            }
            HStack(spacing: 8) {
                Text("滑出熱鍵").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                KeyboardShortcuts.Recorder("", name: .toggleSidebar)
            }
            HStack(spacing: 8) {
                Text("背景透明").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Slider(value: $store.sidebarOpacity, in: 0.3...1.0)
                    .frame(width: 150)
                    .disabled(store.windowMode != .sidebar)
                Text("\(Int(store.sidebarOpacity * 100))%").foregroundColor(Theme.dim)
                    .font(Theme.monoSmall).frame(width: 40, alignment: .leading)
            }
            hint("側邊模式：面板貼邊常駐，按熱鍵滑出/收回;「頂部下拉」為 Ghostty 式滿寬下拉")

            section("外觀")
            HStack(alignment: .top, spacing: 8) {
                Text("介面主題").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                VStack(alignment: .leading, spacing: 5) {
                    Picker("", selection: $store.appTheme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(LocalizedStringKey(theme.label)).tag(theme)
                        }
                    }.labelsHidden().frame(width: 190)
                    Text(LocalizedStringKey(store.appTheme.detail)).font(Theme.monoSmall).foregroundColor(Theme.dim)
                }
            }
            HStack(spacing: 8) {
                Text("主題").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.appearanceMode) {
                    Text("跟隨系統").tag(0); Text("深色").tag(1); Text("淺色").tag(2)
                }.labelsHidden().frame(width: 150).disabled(store.appTheme == .phosphorTerminal)
            }
            if store.appTheme == .phosphorTerminal { hint("Phosphor Terminal 固定使用深色，以維持終端介面的清楚層次") }
            HStack(spacing: 8) {
                Text("強調色").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                ForEach(Array(Theme.accentPalette.enumerated()), id: \.offset) { i, item in
                    Rectangle().fill(item.color).frame(width: 22, height: 22)
                        .overlay(Rectangle().stroke(store.accentIndex == i ? Theme.fg : Theme.border,
                                                    lineWidth: store.accentIndex == i ? 2 : 1))
                        .contentShape(Rectangle())
                        .onTapGesture { store.accentIndex = i }
                        .help(item.name)
                }
            }
            hint("逾期紅 · Focus teal · 完成綠 為語意固定色，不受此設定影響")
            HStack(spacing: 8) {
                Text("App 圖示").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.appIconStyle) {
                    ForEach(AppIconStyle.allCases, id: \.self) { style in
                        Text(LocalizedStringKey(style.label)).tag(style)
                    }
                }.labelsHidden().frame(width: 180)
                Image(nsImage: appIconPreview(store.appIconStyle))
                    .resizable().frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            hint("選擇後會立即更新 Dock 圖示，並保留至下次啟動")
            HStack(spacing: 8) {
                Text("行距").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.density) {
                    ForEach(Density.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("英數字體").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.latinFontChoice) {
                    ForEach(LatinFontChoice.allCases, id: \.self) { choice in
                        Text(LocalizedStringKey(choice.label)).tag(choice)
                    }
                }.labelsHidden().frame(width: 180)
            }
            HStack(spacing: 8) {
                Text("中文字體").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.chineseFontChoice) {
                    ForEach(ChineseFontChoice.allCases, id: \.self) { choice in
                        Text(LocalizedStringKey(choice.label)).tag(choice)
                    }
                }.labelsHidden().frame(width: 180)
            }
            hint("中英文字體可分別選擇，並會套用至全 app")
            fontSizeRow("Task 內容", value: $store.taskTextSize, range: 10...24)
            fontSizeRow("List／Tag", value: $store.tagTextSize, range: 9...20)
            hint("兩種文字大小可分開設定，並會即時套用")
            HStack(spacing: 8) {
                Text("統計圖示").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.dashboardIconStyle) {
                    ForEach(DashboardIconStyle.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("開機自啟").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Toggle("", isOn: Binding(get: { store.launchAtLogin },
                                         set: { store.setLaunchAtLogin($0) })).labelsHidden()
            }

            section("檔案")
            HStack(spacing: 8) {
                Text("資料夾").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Text((store.dataDirPath as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
                    .lineLimit(1).truncationMode(.middle)
                Button("更改…") { pickFolder() }
            }
            hint("tasks.txt / scratch.txt / archive.txt 所在資料夾；搬到空資料夾會自動帶檔（複製，原檔保留）")
            HStack(spacing: 8) {
                Text("任務檔案").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Text(store.fileURL.lastPathComponent)
                    .font(Theme.monoSmall).foregroundColor(Theme.fg)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("選擇／釘選…") { showingTaskFiles = true }
            }
            hint("開啟其他 .txt 文件，或管理已釘選的常用文件")
            section("插件")
            ForEach(TaskStore.bundledPlugins) { plugin in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).foregroundColor(Theme.fg)
                        Text("\(plugin.id) · v\(plugin.version)").font(Theme.monoSmall).foregroundColor(Theme.dim)
                        Text(plugin.capabilities.joined(separator: ", ")).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.75))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { store.isPluginEnabled(plugin) },
                                             set: { store.setPluginEnabled(plugin, $0) })).labelsHidden()
                }
                .padding(.vertical, 4)
            }
            hint("插件目前採內建 registry；正式公開插件前仍需簽章與權限驗證")
            ForEach(store.installedPluginPackages, id: \.manifest.id) { package in
                HStack {
                    Text(package.manifest.name)
                    Text("v\(package.manifest.version)").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    Spacer()
                    Button("移除") { store.removeInstalledPlugin(package) }.buttonStyle(.plain)
                }
            }
            Button("重新掃描已安裝插件") { store.refreshInstalledPlugins() }
            Button("安裝插件 package…") { installPluginPackage() }
            Button("執行 Reschedule Tomorrow（目前 task）") { store.runRescheduleTomorrow() }
            HStack {
                Text("執行紀錄").foregroundColor(Theme.dim)
                Spacer()
                Button("重新整理") { store.refreshPluginExecutionRecords() }
                Button("清除") { store.clearPluginExecutionRecords() }.buttonStyle(.plain)
            }
            ForEach(store.pluginExecutionRecords.suffix(10), id: \.timestamp) { record in
                HStack(alignment: .top, spacing: 8) {
                    Text(record.succeeded ? "✓" : "×").foregroundColor(record.succeeded ? Theme.green : Theme.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(record.pluginID) · \(record.command)").font(Theme.monoSmall)
                        if let error = record.error { Text(error).font(Theme.monoSmall).foregroundColor(Theme.red) }
                    }
                }
            }
            }
            .font(Theme.mono)
            .padding(.horizontal, 28).padding(.vertical, 24).frame(maxWidth: 600, alignment: .leading)
        }
        .sheet(isPresented: $showingTaskFiles) { TaskFileBrowserView().environmentObject(store) }
    }

    private func section(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.5)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.top, 14).padding(.bottom, 4)
    }
    private func hint(_ s: LocalizedStringKey) -> some View {
        Text(s).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.75))
            .padding(.leading, 104).padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func fontSizeRow(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
            Stepper(value: value, in: range, step: 1) {
                Text("\(Int(value.wrappedValue)) pt")
                    .frame(width: 54, alignment: .leading).foregroundColor(Theme.fg)
            }
            .frame(width: 150)
        }
    }

    private func appIconPreview(_ style: AppIconStyle) -> NSImage {
        style.image() ?? AppIconStyle.flatGeometric.image() ?? NSApp.applicationIconImage
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = store.appLanguage == .english ? "Choose Folder" : "選這個資料夾"
        if p.runModal() == .OK, let url = p.url { store.setDataDir(url) }
    }

    private func installPluginPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = store.appLanguage == .english ? "Install" : "安裝"
        if panel.runModal() == .OK, let url = panel.url { store.installPluginPackage(from: url) }
    }
}
