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
    /// 側邊寬度下限。側邊模式的 ContentView minWidth 也放寬到此值,內容才不被裁。
    private let minSideWidth: Double = 100
    /// reveal 當下鎖定的螢幕;收回前都用它,避免焦點切螢幕導致座標飛掉(雙螢幕 bug)。
    private var activeScreen: NSScreen?
    private var outsideClickMonitor: Any?

    func install(store: TaskStore) {
        self.store = store
        KeyboardShortcuts.onKeyUp(for: .toggleSidebar) { [weak self] in self?.toggle() }
        // 點面板以外(其他 app / 桌面)→ 自動收起。全域監聽只在事件不屬於本 app 時觸發,
        // 也就是點在面板之外;面板內的點擊走 local、不會誤收。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel?.isVisible == true, self.store?.windowMode == .sidebar else { return }
            // 延一個 runloop:讓切換焦點的事件先結束,滑動收起動畫才不會被吞掉(否則直接消失)。
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                self.panel?.orderFrontRegardless()      // 收起過程維持在畫面上
                self.hide(animated: true, orderOut: true)
            }
        }
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
        applyCornerMask()
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
        applyCornerMask()
        return p
    }

    /// 只圓「內側」兩角(朝螢幕中央那側);接縫側維持方角,做出鑲嵌在螢幕邊的感覺。
    private func applyCornerMask() {
        guard let layer = panel?.contentView?.layer else { return }
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        switch store?.sidebarEdge ?? .right {          // CALayer 非翻轉:MinY=底、MaxY=頂
        case .right: layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]  // 左側兩角
        case .left:  layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]  // 右側兩角
        case .top:   layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]  // 底部兩角
        }
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

    // MARK: - 貼邊指示條(面板收起時顯示,7 種樣式可在設定切換)

    private var handleExpanded = false   // tab/synthesis hover 展開狀態
    private var handlePos: CGFloat = 0.5 // 指示條沿邊位置(0..1)

    /// 從 store 取即時摘要(徽章數字、Focus 標題、逾期數)。
    private func handleStats() -> HandleStats {
        guard let s = store else { return HandleStats() }
        let g = s.groups()
        let focus = s.focusIndex.flatMap { s.lines.indices.contains($0) ? s.lines[$0].title : nil }
        return HandleStats(focusTitle: focus, today: g.today.count, overdue: g.overdue.count)
    }

    /// 各樣式的(厚度, 長度);hotzone 為滿邊。以側邊方向表示。
    private func handleMetrics() -> (thickness: CGFloat, length: CGFloat, full: Bool) {
        switch store?.sidebarHandleStyle ?? .synthesis {
        case .tab:       return (handleExpanded ? 116 : 26, 38, false)
        case .synthesis: return (handleExpanded ? 124 : 34, 40, false)
        case .sliver:    return (16, 168, false)
        case .grabber:   return (10, 50, false)
        case .badge:     return (26, 26, false)
        case .dots:      return (14, 132, false)
        case .hotzone:   return (5, 0, true)
        }
    }

    /// 指示條幾何:貼在鎖定螢幕的目標邊,沿邊位置吃 handlePos。
    private func handleFrame() -> NSRect {
        let vf = (activeScreen ?? currentScreen()).visibleFrame
        let m = handleMetrics(), t = m.thickness, pos = min(max(handlePos, 0), 1)
        switch store?.sidebarEdge ?? .right {
        case .right, .left:
            let l = m.full ? vf.height : m.length
            let x = (store?.sidebarEdge == .left) ? vf.minX : vf.maxX - t
            let y = m.full ? vf.minY : vf.minY + pos * (vf.height - l)
            return NSRect(x: x, y: y, width: t, height: l)
        case .top:
            let l = m.full ? vf.width : m.length
            let x = m.full ? vf.minX : vf.minX + pos * (vf.width - l)
            return NSRect(x: x, y: vf.maxY - t, width: l, height: t)
        }
    }

    /// 拖曳指示條沿邊移動(用滑鼠絕對座標)。
    private func dragHandle(to mouse: NSPoint) {
        let vf = (activeScreen ?? currentScreen()).visibleFrame
        let l = handleMetrics().length
        switch store?.sidebarEdge ?? .right {
        case .right, .left: handlePos = (vf.height - l) > 0 ? (mouse.y - vf.minY - l/2) / (vf.height - l) : 0.5
        case .top:          handlePos = (vf.width  - l) > 0 ? (mouse.x - vf.minX - l/2) / (vf.width  - l) : 0.5
        }
        handlePos = min(max(handlePos, 0), 1)
        handle?.setFrame(handleFrame(), display: true)
    }
    private func endHandleDrag() { store?.sidebarHandlePos = Double(handlePos) }

    private func rootHandleView() -> SidebarHandleView {
        SidebarHandleView(
            style: store?.sidebarHandleStyle ?? .synthesis,
            edge: store?.sidebarEdge ?? .right,
            accent: store?.accent ?? Theme.focus,
            stats: handleStats(),
            onActivate: { [weak self] in self?.reveal(animated: true) },
            onHoverExpand: { [weak self] on in self?.setHandleExpanded(on) },
            onMove: { [weak self] mouse in self?.dragHandle(to: mouse) },
            onMoveEnd: { [weak self] in self?.endHandleDrag() })
    }

    private func showHandle() {
        if activeScreen == nil { activeScreen = currentScreen() }
        handleExpanded = false
        handlePos = CGFloat(store?.sidebarHandlePos ?? 0.5)
        let h = ensureHandle()
        positionHandle()
        h.orderFrontRegardless()
    }

    private func hideHandle() { handle?.orderOut(nil); handleExpanded = false }

    /// 設定改了樣式:重建指示條(尺寸/內容不同);若正處於收起狀態就重新顯示。
    func handleStyleChanged() {
        handle?.orderOut(nil)
        handle?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        handle = nil; handleExpanded = false
        if store?.windowMode == .sidebar, panel?.isVisible != true { showHandle() }
    }

    /// tab/synthesis 的 hover 展開/收合:動畫改變指示條寬度。
    private func setHandleExpanded(_ on: Bool) {
        let s = store?.sidebarHandleStyle
        guard (s == .tab || s == .synthesis), handleExpanded != on else { return }
        handleExpanded = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            handle?.animator().setFrame(handleFrame(), display: true)
        }
    }

    private func positionHandle() {
        guard let h = handle else { return }
        h.setFrame(handleFrame(), display: true)
        (h.contentView?.subviews.first as? NSHostingView<SidebarHandleView>)?.rootView = rootHandleView()
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
        let host = NSHostingView(rootView: rootHandleView())
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

/// 指示條需要的即時摘要。
struct HandleStats { var focusTitle: String? = nil; var today: Int = 0; var overdue: Int = 0 }

/// 貼邊指示條 — 7 種樣式的統一渲染。點一下滑出;hotzone 為懸停即滑出。
private struct SidebarHandleView: View {
    let style: SidebarHandleStyle
    let edge: SidebarEdge
    let accent: Color
    let stats: HandleStats
    let onActivate: () -> Void
    let onHoverExpand: (Bool) -> Void
    let onMove: (NSPoint) -> Void
    let onMoveEnd: () -> Void
    @State private var hovering = false
    @State private var cursorFrac: CGFloat = -1
    @State private var dragging = false

    private var horizontal: Bool { edge == .top }              // 指示條長邊為水平
    private var statusColor: Color { stats.overdue > 0 ? Theme.red : accent }
    private var onBadge: Color { Theme.bg }                    // 填色上的對比字色

    /// 只圓「內側」角(朝螢幕中央那側),外側齊平貼邊。
    private func innerRounded(_ r: CGFloat) -> UnevenRoundedRectangle {
        switch edge {
        case .right: return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r)
        case .left:  return UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r)
        case .top:   return UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r)
        }
    }
    private var outerAlign: Alignment { edge == .right ? .trailing : (edge == .left ? .leading : .top) }
    private var innerAlign: Alignment { edge == .right ? .leading : (edge == .left ? .trailing : .bottom) }

    @ViewBuilder private var content: some View {
        switch style {
        case .tab:       tab
        case .synthesis: synthesis
        case .sliver:    sliver
        case .grabber:   grabber
        case .badge:     badge
        case .dots:      dots
        case .hotzone:   hotzone
        }
    }

    /// 單一手勢同時處理「點一下開啟」與「拖曳移動」:按下沒移動 → 開啟;
    /// 移動超過門檻 → 拖曳。避免兩個手勢互搶導致點擊沒反應。
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if abs(v.translation.width) > 6 || abs(v.translation.height) > 6 {
                    dragging = true
                    onMove(NSEvent.mouseLocation)
                }
            }
            .onEnded { _ in
                if dragging { dragging = false; onMoveEnd() }
                else { onActivate() }          // 純點擊 → 滑出
            }
    }

    var body: some View {
        Group {
            if style == .hotzone { content }
            else { content.contentShape(Rectangle()).gesture(pressGesture) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 1 標籤把手
    private var tab: some View {
        innerRounded(9).fill(accent)
            .overlay(Text(hovering ? "tasks ⌥T" : "❯")
                .font(.system(size: hovering ? 11 : 13, weight: .bold, design: .monospaced))
                .foregroundColor(onBadge).lineLimit(1))
            .onHover { hovering = $0; onHoverExpand($0) }
            .help("點一下滑出 tasks.txt")
    }

    // 7 推薦合成:狀態(Focus/待辦數,逾期轉紅)+ hover 展開標籤
    private var synthesis: some View {
        let rest = stats.focusTitle != nil
            ? "▶\(stats.overdue > 0 ? "\(stats.overdue)!" : "\(stats.today)")"
            : (stats.overdue > 0 ? "\(stats.overdue)!" : "\(stats.today)")
        return innerRounded(9).fill(statusColor)
            .overlay(Text(hovering ? "tasks ⌥T" : rest)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(onBadge).lineLimit(1).padding(.horizontal, 6))
            .onHover { hovering = $0; onHoverExpand($0) }
            .help("滑出 tasks.txt ⌥T")
    }

    // 2 內容預覽 sliver
    private var sliver: some View {
        let text = stats.focusTitle ?? "tasks.txt"
        return ZStack(alignment: innerAlign) {
            innerRounded(4).fill(Theme.bg.opacity(0.92))
            Rectangle().fill(statusColor)
                .frame(width: horizontal ? nil : 2, height: horizontal ? 2 : nil)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(statusColor).lineLimit(1).fixedSize()
                .rotationEffect(horizontal ? .zero : .degrees(edge == .right ? 90 : -90))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onHover { hovering = $0 }
        .help(stats.focusTitle == nil ? "滑出 tasks.txt" : "▶ \(text)")
    }

    // 4 抓握把手
    private var grabber: some View {
        innerRounded(6).fill(Color(white: 0.11))
            .overlay(innerRounded(6).stroke(accent.opacity(hovering ? 0.85 : 0.45), lineWidth: 1))
            .overlay(Text(horizontal ? "⋯" : "⋮").font(.system(size: 13, weight: .bold)).foregroundColor(accent))
            .onHover { hovering = $0 }
            .help("點一下滑出 tasks.txt")
    }

    // 5 狀態徽章
    private var badge: some View {
        let label = stats.overdue > 0 ? "\(stats.overdue)!"
            : (stats.focusTitle != nil ? "▶" : "\(stats.today)")
        return innerRounded(13).fill(Theme.bg)
            .overlay(innerRounded(13).stroke(statusColor, lineWidth: 1))
            .overlay(Text(label).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(statusColor))
            .onHover { hovering = $0 }
            .help(stats.overdue > 0 ? "\(stats.overdue) 筆逾期 · 滑出" : "今日 \(stats.today) 筆 · 滑出")
    }

    // 6 磁吸放大點
    private var dots: some View {
        GeometryReader { geo in
            let n = 5
            let along = horizontal ? geo.size.width : geo.size.height
            ZStack {
                ForEach(0..<n, id: \.self) { i in
                    let frac = (CGFloat(i) + 0.5) / CGFloat(n)
                    let k = cursorFrac < 0 ? 0 : max(0, 1 - abs(frac - cursorFrac) / 0.3)
                    Circle().fill(accent)
                        .frame(width: 5 + k * 6, height: 5 + k * 6)
                        .shadow(color: accent.opacity(k * 0.9), radius: k * 6)
                        .position(x: horizontal ? along * frac : geo.size.width / 2,
                                  y: horizontal ? geo.size.height / 2 : along * frac)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    cursorFrac = horizontal ? p.x / max(1, geo.size.width) : p.y / max(1, geo.size.height)
                } else { cursorFrac = -1 }
            }
        }
        .help("點一下滑出 tasks.txt")
    }

    // 3 邊緣感應:平時一道極淡的線,懸停即滑出
    private var hotzone: some View {
        ZStack(alignment: outerAlign) {
            Color.clear
            Rectangle().fill(accent.opacity(0.18))
                .frame(width: horizontal ? nil : 2, height: horizontal ? 2 : nil)
        }
        .contentShape(Rectangle())
        .onHover { h in hovering = h; if h { onActivate() } }
        .help("滑鼠移到邊緣即滑出")
    }
}

/// 全域熱鍵 → 螢幕上方浮出一行捕捉框。任何 app 裡都能叫出來。
final class GlobalCapture {
    static let shared = GlobalCapture()
    private let panelWidth: CGFloat = 520
    private var panel: NSPanel?
    private weak var store: TaskStore?

    func install(store: TaskStore) {
        self.store = store
        KeyboardShortcuts.onKeyUp(for: .capture) { [weak self] in self?.toggle() }
    }

    func toggle() {
        if panel?.isVisible == true { hide(); return }
        // MenuBarExtra actions run while the menu is still tracking. Ordering a
        // floating panel in that same cycle lets AppKit dismiss it with the menu.
        // Defer one run-loop turn so the capture panel owns its own window cycle.
        DispatchQueue.main.async { [weak self] in
            guard self?.panel?.isVisible != true else { return }
            self?.show()
        }
    }

    private func show() {
        guard let store else { return }
        if panel == nil {
            let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 92),
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
                onCancel: { [weak self] in self?.hide() },
                onHeightChange: { [weak self] height in self?.resizePanel(to: height) }
            ).environmentObject(store))
            host.frame = p.contentView?.bounds ?? .zero
            host.autoresizingMask = [.width, .height]
            p.contentView?.addSubview(host)
            panel = p
        }
        if let f = NSScreen.main?.visibleFrame, let p = panel {
            p.setContentSize(NSSize(width: panelWidth, height: 92))
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - f.height * 0.22))
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func resizePanel(to height: CGFloat) {
        // SwiftUI may request a size while AppKit is still ordering the panel.
        // Resize on the next cycle and only while visible to avoid moving a hidden
        // panel whose origin has not been placed on the active screen yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, let p = self.panel, p.isVisible,
                  abs(p.frame.height - height) > 0.5 else { return }
            let top = p.frame.maxY
            p.setFrame(NSRect(x: p.frame.minX, y: top - height, width: self.panelWidth, height: height), display: true)
        }
    }

    private func hide() { panel?.orderOut(nil) }
}

private struct GlobalCaptureView: View {
    @EnvironmentObject var store: TaskStore
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    let onHeightChange: (CGFloat) -> Void
    @State private var text = ""
    @State private var cursorUTF16Offset = 0
    @State private var completionSelection = 0

    private enum CaptureCommand: CaseIterable {
        case due, project, context, note

        var key: String {
            switch self { case .due: return "due:"; case .project: return "+"; case .context: return "@"; case .note: return "note:\"\"" }
        }
        var title: LocalizedStringKey {
            switch self { case .due: return "/due"; case .project: return "/project"; case .context: return "/context"; case .note: return "/note" }
        }
        var detail: LocalizedStringKey {
            switch self { case .due: return "設定到期日"; case .project: return "加入專案"; case .context: return "加入情境"; case .note: return "加入備註" }
        }
    }

    private struct CompletionItem: Identifiable {
        let value: String
        let label: String
        let detail: String
        var id: String { value }
    }

    private var tokens: [CaptureAssist.Token] { CaptureAssist.tokens(from: text, today: Date()) }
    private var suggestion: CaptureAssist.DueSuggestion? { CaptureAssist.dueSuggestion(from: text) }
    private var commandMode: Bool {
        text.split(whereSeparator: { $0.isWhitespace }).last == "/"
    }
    private var completionQuery: CaptureAssist.CompletionQuery? {
        CaptureAssist.completionQuery(from: text, cursorUTF16Offset: cursorUTF16Offset)
    }
    private var completionItems: [CompletionItem] {
        guard let query = completionQuery else { return [] }
        return completionItems(for: query)
    }
    private func completionItems(for query: CaptureAssist.CompletionQuery) -> [CompletionItem] {
        let source: [CompletionItem]
        switch query.kind {
        case .project:
            source = store.allProjects().map { CompletionItem(value: $0, label: "+\($0)", detail: "專案") }
        case .context:
            source = store.allContexts().map { CompletionItem(value: $0, label: "@\($0)", detail: "情境") }
        case .due:
            source = [
                .init(value: "today", label: "due:today", detail: "今天"),
                .init(value: "tomorrow", label: "due:tomorrow", detail: "明天"),
                .init(value: "2d", label: "due:2d", detail: "後天"),
                .init(value: "mon", label: "due:mon", detail: "星期一"),
                .init(value: "tue", label: "due:tue", detail: "星期二"),
                .init(value: "wed", label: "due:wed", detail: "星期三"),
                .init(value: "thu", label: "due:thu", detail: "星期四"),
                .init(value: "fri", label: "due:fri", detail: "星期五"),
                .init(value: "sat", label: "due:sat", detail: "星期六"),
                .init(value: "sun", label: "due:sun", detail: "星期日"),
            ]
        }
        let fragment = query.fragment.lowercased()
        return Array(source.filter {
            fragment.isEmpty || $0.value.lowercased().hasPrefix(fragment) || $0.detail.lowercased().contains(fragment)
        }.prefix(5))
    }
    private var autocompleteOpen: Bool { completionQuery != nil }
    private var desiredHeight: CGFloat {
        if commandMode { return 226 }
        if autocompleteOpen { return CGFloat(92 + max(1, completionItems.count) * 34) }
        if !tokens.isEmpty || suggestion != nil { return 126 }
        return 92
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(">").foregroundColor(Theme.green)
                CaptureInputField(
                    text: $text,
                    cursorUTF16Offset: $cursorUTF16Offset,
                    placeholder: "新增任務…  due:fri  +List  @Tag",
                    onSubmit: submitFromKeyboard,
                    onCancel: cancelFromKeyboard,
                    onMoveSelection: moveCompletion,
                    onAcceptCompletion: acceptSelectedCompletion
                )
                .frame(height: 22)
                Text("⏎ 加入 · esc 取消").font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)

            if commandMode {
                commandComposer
            } else if autocompleteOpen {
                autocompleteList
            } else if let suggestion, tokens.isEmpty {
                suggestionRow(suggestion)
            } else if !tokens.isEmpty {
                tokenRow
            }
        }
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.border))
        .clipShape(Rectangle())
        .onAppear { text = ""; cursorUTF16Offset = 0; onHeightChange(desiredHeight) }
        .onChange(of: text) { _ in completionSelection = 0; onHeightChange(desiredHeight) }
        .onChange(of: cursorUTF16Offset) { _ in completionSelection = 0; onHeightChange(desiredHeight) }
    }

    private var autocompleteList: some View {
        VStack(spacing: 0) {
            if completionItems.isEmpty {
                HStack {
                    Text(emptyCompletionMessage).foregroundColor(Theme.dim)
                    Spacer()
                    Text("繼續輸入可建立新項目").foregroundColor(Theme.dim)
                }
                .font(Theme.monoSmall).padding(.horizontal, 16).frame(height: 34)
            } else {
                ForEach(Array(completionItems.enumerated()), id: \.element.id) { index, item in
                    Button { applyCompletion(item) } label: {
                        HStack {
                            Text(item.label).foregroundColor(completionColor)
                            Spacer()
                            Text(item.detail).foregroundColor(Theme.dim)
                            if index == completionSelection { Text("↵").foregroundColor(Theme.dim) }
                        }
                        .font(Theme.monoSmall).padding(.horizontal, 16).frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(index == completionSelection ? Theme.focusBg : Color.clear)
                }
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var emptyCompletionMessage: LocalizedStringKey {
        switch completionQuery?.kind { case .project: return "沒有符合的專案"; case .context: return "沒有符合的情境"; default: return "沒有符合的日期快捷" }
    }

    private var completionColor: Color {
        switch completionQuery?.kind { case .project: return Theme.mag; case .context: return Theme.cyan; default: return Theme.blue }
    }

    private var tokenRow: some View {
        HStack(spacing: 7) {
            ForEach(tokens) { token in
                Button { text = CaptureAssist.removingToken(token.raw, from: text); cursorUTF16Offset = text.utf16.count } label: {
                    Text("\(tokenLabel(token)): \(token.displayValue) ×")
                        .font(Theme.monoSmall).foregroundColor(tokenColor(token))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .overlay(Rectangle().stroke(Theme.border))
                }
                .buttonStyle(.plain)
                .help("移除 \(token.raw)")
            }
            Spacer()
            Text(store.fileURL.lastPathComponent).font(Theme.monoSmall).foregroundColor(Theme.dim)
        }
        .padding(.horizontal, 16).frame(height: 42)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func suggestionRow(_ suggestion: CaptureAssist.DueSuggestion) -> some View {
        HStack(spacing: 8) {
            Text("偵測到").foregroundColor(Theme.dim)
            Button("到期：\(suggestion.label)") { apply(suggestion) }
                .buttonStyle(.plain).foregroundColor(Theme.blue)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .overlay(Rectangle().stroke(Theme.border))
            Spacer()
            Button("Tab 套用") { apply(suggestion) }
                .buttonStyle(.plain).foregroundColor(Theme.green)
            Button("") { apply(suggestion) }
                .keyboardShortcut(.tab, modifiers: [])
                .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0)
        }
        .font(Theme.monoSmall).padding(.horizontal, 16).frame(height: 42)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var commandComposer: some View {
        VStack(spacing: 0) {
            ForEach(CaptureCommand.allCases, id: \.key) { command in
                Button { applyCommand(command) } label: {
                    HStack {
                        Text(command.title).foregroundColor(Theme.green).frame(width: 76, alignment: .leading)
                        Text(command.detail).foregroundColor(Theme.fg)
                        Spacer()
                        if command == .due { Text("↵").foregroundColor(Theme.dim) }
                    }
                    .font(Theme.monoSmall).padding(.horizontal, 16).frame(height: 41)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(command == .due ? Theme.focusBg : Color.clear)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func tokenLabel(_ token: CaptureAssist.Token) -> String {
        switch token.kind { case .due: return "日期"; case .project: return "專案"; case .context: return "情境" }
    }

    private func tokenColor(_ token: CaptureAssist.Token) -> Color {
        switch token.kind { case .due: return Theme.blue; case .project: return Theme.mag; case .context: return Theme.cyan }
    }

    private func apply(_ suggestion: CaptureAssist.DueSuggestion) {
        text = CaptureAssist.applying(suggestion, to: text)
        cursorUTF16Offset = text.utf16.count
    }

    private func applyCommand(_ command: CaptureCommand) {
        var parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.last == "/" { parts.removeLast() }
        text = (parts + [command.key]).joined(separator: " ")
        if command == .note { text = text.replacingOccurrences(of: "note:\"\"", with: "note:\"") }
        cursorUTF16Offset = text.utf16.count
    }

    private func moveCompletion(_ delta: Int, _ fieldText: String, _ cursor: Int) -> Bool {
        guard let query = CaptureAssist.completionQuery(from: fieldText, cursorUTF16Offset: cursor) else { return false }
        let items = completionItems(for: query)
        guard !items.isEmpty else { return false }
        let current = min(completionSelection, items.count - 1)
        completionSelection = (current + delta + items.count) % items.count
        return true
    }

    private func acceptSelectedCompletion(_ fieldText: String, _ cursor: Int) -> Bool {
        guard let query = CaptureAssist.completionQuery(from: fieldText, cursorUTF16Offset: cursor) else { return false }
        let items = completionItems(for: query)
        guard !items.isEmpty else { return false }
        let selected = min(completionSelection, items.count - 1)
        let result = CaptureAssist.applyingCompletion(items[selected].value, query: query, to: fieldText)
        text = result.text
        cursorUTF16Offset = result.cursorUTF16Offset
        return true
    }

    private func applyCompletion(_ item: CompletionItem) {
        guard let query = completionQuery else { return }
        let result = CaptureAssist.applyingCompletion(item.value, query: query, to: text)
        text = result.text
        cursorUTF16Offset = result.cursorUTF16Offset
    }

    private func submitFromKeyboard(_ fieldText: String, _ cursor: Int) {
        if fieldText.split(whereSeparator: { $0.isWhitespace }).last == "/" { text = fieldText; applyCommand(.due); return }
        if acceptSelectedCompletion(fieldText, cursor) { return }
        text = fieldText
        commit()
    }

    private func cancelFromKeyboard() {
        text = ""
        onCancel()
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        text = ""
        if t.isEmpty { onCancel() } else { onCommit(t) }
    }
}

/// AppKit-backed field editor used by global capture so autocomplete can own
/// Up/Down/Return/Tab without stealing ordinary typing or IME composition.
private struct CaptureInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorUTF16Offset: Int
    let placeholder: String
    let onSubmit: (String, Int) -> Void
    let onCancel: () -> Void
    let onMoveSelection: (Int, String, Int) -> Bool
    let onAcceptCompletion: (String, Int) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.placeholderString = placeholder
        field.setAccessibilityLabel("新增任務")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        field.textColor = NSColor(Theme.fg)
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
        DispatchQueue.main.async {
            guard let editor = field.currentEditor() else {
                field.window?.makeFirstResponder(field)
                return
            }
            let location = min(cursorUTF16Offset, (field.stringValue as NSString).length)
            if editor.selectedRange.location != location || editor.selectedRange.length != 0 {
                editor.selectedRange = NSRange(location: location, length: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaptureInputField
        init(_ parent: CaptureInputField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            if let editor = field.currentEditor() { parent.cursorUTF16Offset = editor.selectedRange.location }
        }

        func controlTextDidChangeSelection(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                  let editor = field.currentEditor() else { return }
            parent.cursorUTF16Offset = editor.selectedRange.location
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if textView.hasMarkedText() { return false }
            let currentText = textView.string.replacingOccurrences(of: "\n", with: "")
            let cursor = textView.selectedRange.location
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onMoveSelection(-1, currentText, cursor)
            case #selector(NSResponder.moveDown(_:)): return parent.onMoveSelection(1, currentText, cursor)
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(currentText, cursor); return true
            case #selector(NSResponder.insertTab(_:)):
                return parent.onAcceptCompletion(currentText, cursor)
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            default: return false
            }
        }
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
    @State private var agentBaseURL = ""
    @State private var agentAPIKey = ""
    @State private var agentModel = ""
    @State private var agentEndpointStatus = ""
    @State private var agentEndpointConfigured = false

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
            hint("app 內快速鍵固定：⌘1 清單 · ⌘2 象限 · ⌘3 Agent · ⌘4 統計 · ⌘E 編輯 · ⌘K 指令")

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
                Text("收起指示").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.sidebarHandleStyle) {
                    ForEach(SidebarHandleStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 200)
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

            section("Agent Endpoint")
            HStack(spacing: 8) {
                Text("Base URL").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                TextField("https://api.openai.com/v1", text: $agentBaseURL)
                    .textFieldStyle(.plain).foregroundColor(Theme.fg)
                    .padding(8).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            HStack(spacing: 8) {
                Text("API Key").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                SecureField(agentEndpointConfigured ? "留空以保留現有 API Key" : "sk-…", text: $agentAPIKey)
                    .textFieldStyle(.plain).foregroundColor(Theme.fg)
                    .padding(8).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            HStack(spacing: 8) {
                Text("Model").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                TextField("gpt-4o-mini", text: $agentModel)
                    .textFieldStyle(.plain).foregroundColor(Theme.fg)
                    .padding(8).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            HStack(spacing: 8) {
                Text(LocalizedStringKey(agentEndpointStatus))
                    .font(Theme.monoSmall)
                    .foregroundColor(agentEndpointConfigured ? Theme.green : Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("儲存 Endpoint") { saveAgentEndpoint() }
            }
            .padding(.leading, 104)
            hint("API Key 不會回顯，只會儲存在 macOS Keychain。")

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
        .onAppear { loadAgentEndpoint() }
        .onChange(of: store.appLanguage) { _ in loadAgentEndpoint() }
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

    private func loadAgentEndpoint() {
        do {
            let config = try KeychainAgentCredentialStore().endpointConfig()
            agentBaseURL = config.baseURL.absoluteString
            agentModel = config.model
            agentAPIKey = ""
            agentEndpointConfigured = true
            agentEndpointStatus = store.appLanguage == .english
                ? "Configured · \(config.baseURL.host ?? config.baseURL.absoluteString) · \(config.model)"
                : "已設定 · \(config.baseURL.host ?? config.baseURL.absoluteString) · \(config.model)"
        } catch AgentCredentialStoreError.missingConfiguration {
            agentBaseURL = ""
            agentModel = ""
            agentAPIKey = ""
            agentEndpointConfigured = false
            agentEndpointStatus = store.appLanguage == .english ? "Not configured" : "尚未設定"
        } catch {
            agentEndpointConfigured = false
            agentEndpointStatus = error.localizedDescription
        }
    }

    private func saveAgentEndpoint() {
        let baseURLText = agentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = agentModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLText), baseURL.scheme != nil, baseURL.host != nil else {
            agentEndpointConfigured = false
            agentEndpointStatus = store.appLanguage == .english ? "Enter a valid Base URL" : "請輸入有效的 Base URL"
            return
        }
        // Reject insecure remote endpoints at save time (not only at send time) — same rule the
        // transport enforces: https required, http only for loopback.
        do {
            try AgentEndpointSecurity.assertSecure(baseURL)
        } catch {
            agentEndpointConfigured = false
            agentEndpointStatus = store.appLanguage == .english
                ? "Remote endpoints must use https (http only for localhost)"
                : "遠端必須使用 https(http 僅限 localhost)"
            return
        }
        guard !model.isEmpty else {
            agentEndpointConfigured = false
            agentEndpointStatus = store.appLanguage == .english ? "Model is required" : "請填寫 Model"
            return
        }

        do {
            let credentialStore = KeychainAgentCredentialStore()
            let existing: AgentEndpointConfig?
            do {
                existing = try credentialStore.endpointConfig()
            } catch AgentCredentialStoreError.missingConfiguration {
                existing = nil
            }
            let apiKey = agentAPIKey.isEmpty ? (existing?.apiKey ?? "") : agentAPIKey
            guard !apiKey.isEmpty else {
                agentEndpointConfigured = false
                agentEndpointStatus = store.appLanguage == .english ? "API Key is required" : "請填寫 API Key"
                return
            }
            try credentialStore.save(AgentEndpointConfig(baseURL: baseURL, apiKey: apiKey, model: model))
            agentAPIKey = ""
            agentEndpointConfigured = true
            agentEndpointStatus = store.appLanguage == .english
                ? "Saved · \(baseURL.host ?? baseURL.absoluteString) · \(model)"
                : "已儲存 · \(baseURL.host ?? baseURL.absoluteString) · \(model)"
        } catch {
            agentEndpointConfigured = false
            agentEndpointStatus = error.localizedDescription
        }
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
