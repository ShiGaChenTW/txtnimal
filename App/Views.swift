import SwiftUI
import txtnimalCore
import AppKit
import UniformTypeIdentifiers

struct TaskContextActions {
    var edit: (TaskHandle) -> Void = { _ in }
    var confirmArchive: (TaskHandle, String) -> Void = { _, _ in }
    var confirmDelete: (TaskHandle, String) -> Void = { _, _ in }
}

private struct TaskContextActionsKey: EnvironmentKey {
    static let defaultValue = TaskContextActions()
}

extension EnvironmentValues {
    var taskContextActions: TaskContextActions {
        get { self[TaskContextActionsKey.self] }
        set { self[TaskContextActionsKey.self] = newValue }
    }
}

// MARK: - ⌘1 主清單

struct ListView: View {
    @EnvironmentObject var store: TaskStore
    @State private var addText = ""
    @State private var addVisible = false
    @State private var showingListEditor = false
    @State private var editingListOriginal: String?
    @State private var listName = ""
    @State private var listDescription = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        let g = store.groups()
        VStack(alignment: .leading, spacing: 0) {
            if selectedList != nil { listInfoBar }
            if let i = store.focusIndex { focusBar(store.lines[i]) }
            section("Today", g.today, group: "today", color: store.accent)    // 當下=強調色(設定頁可換)
            overdueSection(g.overdue)                                          // 逾期=紅(獨佔)
            section("Upcoming", g.upcoming, group: "up", color: Theme.yellow) // 未來=黃(呼應 q2 Schedule)
            // No date 區塊 + 尾端新增列;帶 due: 的新任務由重新分組自動跳到對應區塊
            if !g.noDate.isEmpty { sectionHeader("No date", g.noDate.count, color: Theme.dim, neutral: true) }
            else { sectionHeader("No date", 0, color: Theme.dim, neutral: true) }
            ForEach(g.noDate, id: \.self) { rowOrEdit($0, "nd") }
            if addVisible { addRow }   // 預設隱藏,按 n 才出現
            section("Done", g.done, group: "done", color: Theme.green)        // 完成=綠(色彩契約)
        }
        .padding(.top, 4).padding(.bottom, 14)
        .onChange(of: store.requestInlineAdd) { req in   // n 鍵:顯示並聚焦輸入列,游標移到此
            if req { activateInlineAdd() }
        }
        // 從其他頁切回清單時，request 可能在 ListView 掛載前已變成 true；
        // onChange 不會對初始值觸發，所以掛載時也必須消費一次。
        .onAppear { if store.requestInlineAdd { activateInlineAdd() } }
        .onDisappear { store.inlineAddActive = false }
        .sheet(isPresented: $showingListEditor) { listEditor }
    }

    private var selectedList: String? {
        guard let filter = store.tagFilter, filter.hasPrefix("+") else { return nil }
        return String(filter.dropFirst())
    }

    private var listInfoBar: some View {
        HStack(alignment: .top, spacing: 12) {
            if let name = selectedList {
                VStack(alignment: .leading, spacing: 5) {
                    Text("+\(name)").font(store.tagFont).foregroundColor(Theme.mag)
                    let detail = store.listDescription(name)
                    Text(detail.isEmpty ? LocalizedStringKey("尚未加入 List 說明") : LocalizedStringKey(detail))
                        .font(Theme.monoSmall).foregroundColor(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("List 增加／編輯") { openListEditor() }
                .buttonStyle(.plain).font(Theme.monoSmall).foregroundColor(store.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func openListEditor() {
        editingListOriginal = selectedList
        listName = selectedList ?? ""
        listDescription = selectedList.map(store.listDescription) ?? ""
        showingListEditor = true
    }

    private var listEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingListOriginal == nil ? LocalizedStringKey("新增 List") : LocalizedStringKey("編輯 List"))
                .font(Theme.mono).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 5) {
                Text("List 名稱").font(Theme.monoSmall).foregroundColor(Theme.dim)
                HStack(spacing: 6) {
                    Text("+").foregroundColor(Theme.mag)
                    TextField("marketing", text: $listName).textFieldStyle(.plain)
                }
                .padding(8).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("List 說明").font(Theme.monoSmall).foregroundColor(Theme.dim)
                TextEditor(text: $listDescription)
                    .scrollContentBackground(.hidden).frame(height: 92).padding(6)
                    .background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            HStack {
                Spacer()
                Button("取消") { showingListEditor = false }.keyboardShortcut(.cancelAction)
                Button("儲存") {
                    store.saveList(originalName: editingListOriginal, name: listName, description: listDescription)
                    showingListEditor = false
                }
                .disabled(listName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .font(Theme.mono).padding(20).frame(width: 480).background(Theme.bg).foregroundColor(Theme.fg)
    }

    private func activateInlineAdd() {
        addVisible = true
        store.inlineAddActive = true
        store.cursor = nil
        store.requestInlineAdd = false
        DispatchQueue.main.async { addFocused = true }
    }

    private var addRow: some View {
        HStack(spacing: Theme.isTerminal ? 0 : 10) {
            if Theme.isTerminal {
                Text("❯ ")
                    .foregroundColor(Theme.green)
                    .fontWeight(.bold)
                ZStack(alignment: .leading) {
                    if addText.isEmpty {
                        Text("輸入任務指令  due:fri  +List  @Tag")
                            .foregroundColor(Theme.dim.opacity(0.62))
                    }
                    TerminalInputField(text: $addText, onSubmit: submitInlineAdd, onCancel: closeInlineAdd)
                        .frame(height: 20)
                }
            } else {
                Text("+").foregroundColor(Theme.green)
                TextField("", text: $addText,
                          prompt: Text("新增任務…  due:fri  +List  @Tag").foregroundColor(Theme.dim.opacity(0.35)))
                    .textFieldStyle(.plain).font(store.taskFont).foregroundColor(Theme.fg)
                    .focused($addFocused)
                    .onSubmit { submitInlineAdd() }
                    .onExitCommand { closeInlineAdd() }
            }
        }
        .font(Theme.mono)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, store.density.rowPad)
        .background(Theme.isTerminal ? Theme.bg : Theme.cursorBg)
        .overlay(alignment: .leading) {
            if !Theme.isTerminal { Rectangle().fill(Theme.dim).frame(width: 3) }
        }
        .overlay(alignment: .top) {
            if Theme.isTerminal { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .overlay(alignment: .bottom) {
            if Theme.isTerminal { Rectangle().fill(Theme.border.opacity(0.55)).frame(height: 1) }
        }
        .onAppear { addFocused = true }
    }

    private func submitInlineAdd() {
        let task = addText.trimmingCharacters(in: .whitespaces)
        if !task.isEmpty { store.addFromCapture(task) }
        addText = ""
        addFocused = true
    }

    private func closeInlineAdd() {
        addText = ""
        addFocused = false
        addVisible = false
        store.inlineAddActive = false
        store.ensureCursor()
    }

    private func focusBar(_ t: TaskLine) -> some View {
        HStack(spacing: 10) {
            Text("▶ FOCUS").font(Theme.monoSmall)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(Rectangle().stroke(Theme.focus))
            Text(t.title).fontWeight(.semibold).lineLimit(1)
            Spacer()
            Text("z 進入專注 →").font(Theme.monoSmall).opacity(0.8)
        }
        .foregroundColor(Theme.focus)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(Theme.focusBg)
        .overlay(Rectangle().fill(Theme.focus).frame(width: 3), alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { store.toggleFocusMode() }
        .padding(.bottom, 12)
    }

    @ViewBuilder private func section(_ title: String, _ idx: [Int], group: String, color: Color) -> some View {
        if !idx.isEmpty {
            sectionHeader(title, idx.count, color: color)
            ForEach(idx, id: \.self) { rowOrEdit($0, group) }
        }
    }

    @ViewBuilder private func rowOrEdit(_ i: Int, _ group: String) -> some View {
        if store.lines.indices.contains(i) {   // 防過期 index 越界(側邊雙實例共享 store)
            if store.editingIndex == i { EditRow(index: i, initial: store.lines[i].title) }
            else { RowView(index: i, group: group) }
        }
    }

    @ViewBuilder private func overdueSection(_ idx: [Int]) -> some View {
        if !idx.isEmpty {
            HStack(spacing: 8) {
                Text("Overdue").foregroundColor(Theme.red)
                Text("\(idx.count)").foregroundColor(Theme.red)   // 計數與標題同色
                Rectangle().fill(Theme.red.opacity(0.35)).frame(height: 1)   // 線條同色分類
            }
            .font(Theme.monoSmall).tracking(1)
            .padding(.horizontal, 16).padding(.top, store.density.sectionTop).padding(.bottom, 6)
            ForEach(idx, id: \.self) { rowOrEdit($0, "overdue") }
        }
    }

    private func sectionHeader(_ title: String, _ count: Int, color: Color, neutral: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(color)
            Text("\(count)").foregroundColor(color)   // 計數與標題同色
            // 灰組維持既有邊框線,彩色組用同色低透明度 — 標題與線條成一組分類訊號
            Rectangle().fill(neutral ? Theme.border : color.opacity(0.35)).frame(height: 1)
        }
        .font(Theme.monoSmall).tracking(1)
        .padding(.horizontal, 16).padding(.top, store.density.sectionTop).padding(.bottom, 6)
    }
}

// MARK: - 單列

struct RowView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.taskContextActions) private var contextActions
    let index: Int
    let group: String
    @State private var flash = false   // 完成瞬間綠光一閃(SPEC 7.5 招牌時刻)

    var body: some View {
        // 側邊模式下有兩個 ContentView 共享同一 store；清單變短時，另一個實例的
        // RowView 可能仍持有過期 index。渲染前先 guard，避免越界 fatal crash。
        if store.lines.indices.contains(index) {
            row(store.lines[index])
        }
    }

    @ViewBuilder private func row(_ t: TaskLine) -> some View {
        let isCursor = store.cursor == index
        VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 10) {
            Text(t.isDone ? "[✓]" : "[ ]").foregroundColor(t.isDone ? Theme.green : groupColor)
            Text(t.title)
                .font(store.taskFont)
                .foregroundColor(t.isFocused ? Theme.focus : (t.isDone ? Theme.dim : Theme.fg))
                .fontWeight(t.isFocused ? .semibold : .regular)
                .strikethrough(t.isDone, color: Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 8)
            ForEach(t.projects, id: \.self) { p in
                Text("+\(p)").foregroundColor(Theme.mag)
                    .font(store.tagFont)
                    .onTapGesture { store.toggleTagFilter("+" + p) }
            }
            ForEach(t.contexts, id: \.self) { c in
                Text("@\(c)").foregroundColor(Theme.cyan)
                    .font(store.tagFont)
                    .onTapGesture { store.toggleTagFilter("@" + c) }
            }
            dueBadge(t)
        }
        .font(Theme.mono)
        // 便箋另起第二行,對齊標題起點,透明灰 — 次要資訊不與標題爭寬度
        if let note = t.note, !note.isEmpty {
            Text(note)
                .font(store.taskSmallFont).foregroundColor(Theme.dim.opacity(0.65))
                .lineLimit(2).padding(.leading, 34)
        }
        }
        .padding(.leading, 16)   // 每列內容內縮兩個等寬字元(背景/游標條仍貼邊)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, store.density.rowPad)
        .background(isCursor ? Theme.cursorBg : (t.isFocused ? Theme.focusBg : .clear))
        .background(Theme.green.opacity(flash ? 0.22 : 0))
        .onChange(of: t.isDone) { done in
            guard done else { return }
            flash = true
            withAnimation(.easeOut(duration: 0.45)) { flash = false }
        }
        .overlay(alignment: .leading) {
            if isCursor { Rectangle().fill(t.isFocused ? Theme.focus : Theme.dim).frame(width: 3) }
            else if t.isFocused { Rectangle().fill(Theme.focus).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.cursor = index
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { store.toggleDone() }
        }
        .onTapGesture { store.cursor = index }
        .background {
            ThemedTaskContextMenuPresenter(handle: store.handle(for: index), task: t,
                                           actions: contextActions, store: store)
        }
    }

    /// checkbox 顏色跟隨分組(與分組標題同色系)
    private var groupColor: Color {
        switch group {
        case "today": return store.accent
        case "overdue": return Theme.red
        case "up": return Theme.yellow
        case "done": return Theme.green
        default: return Theme.dim   // 無期限維持中性灰
        }
    }

    @ViewBuilder private func dueBadge(_ t: TaskLine) -> some View {
        if group != "today", let due = t.due, let r = RelativeDate.label(due) {
            Text(r.text + (r.overdue ? " ⚠" : ""))
                .font(Theme.monoSmall)
                .foregroundColor(r.overdue ? Theme.red : Theme.dim)
        }
    }
}

// MARK: - 行內編輯

struct EditRow: View {
    @EnvironmentObject var store: TaskStore
    let index: Int
    @State private var draft: String
    @FocusState private var focused: Bool

    init(index: Int, initial: String) {
        self.index = index
        _draft = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("[ ]").foregroundColor(Theme.dim)
            TextField("", text: $draft)
                .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.fg)
                .focused($focused)
                .onSubmit { store.updateTitle(index, draft) }
                .onExitCommand { store.editingIndex = nil }
        }
        .padding(.horizontal, 16).padding(.vertical, store.density.rowPad)
        .background(Theme.selBg)
        .overlay(Rectangle().fill(Theme.blue).frame(width: 3), alignment: .leading)
        .onAppear { focused = true }
    }
}

// MARK: - ⌘4 四象限（v1：鍵盤 1–4 指派;拖拉為 v2）

struct QuadrantView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.taskContextActions) private var contextActions
    private let meta: [(Int, String, String, Color)] = [
        (1, "Do", "重要且緊急", Theme.red), (2, "Schedule", "重要但不緊急", Theme.yellow),
        (3, "Delegate", "緊急但不重要", Theme.cyan), (4, "Delete", "不重要且不緊急", Theme.dim),
    ]

    var body: some View {
        let b = store.board()
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("↑ 重要"); Spacer(); Text("緊急 →") }
                .font(Theme.monoSmall).foregroundColor(Theme.dim).padding(.horizontal, 14).padding(.vertical, 4)
            // 上半 1/2:四象限
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow { cell(meta[0], indices(b, 1)); cell(meta[1], indices(b, 2)) }
                GridRow { cell(meta[2], indices(b, 3)); cell(meta[3], indices(b, 4)) }
            }
            .background(Theme.border).padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
            // 下半 1/2:歸位池
            poolView(b.unplaced)
                .frame(maxHeight: .infinity)
        }
        .padding(.vertical, 6)
    }

    private func indices(_ b: QuadrantBoard, _ q: Int) -> [Int] {
        switch q { case 1: return b.q1; case 2: return b.q2; case 3: return b.q3; default: return b.q4 }
    }

    private func cell(_ m: (Int, String, String, Color), _ idx: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("q\(m.0) ·").foregroundColor(m.3)
                Text(m.1).fontWeight(.bold).foregroundColor(m.3)
                Text("· \(m.2)").foregroundColor(Theme.dim)
            }.font(Theme.monoSmall)
            ScrollView {   // 半屏固定高,格內溢出改捲動
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(idx, id: \.self) { qRow($0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(11)
        .background(ZStack { Theme.bg; m.3.opacity(0.13) })   // 各象限不同底色，低透明度保持 TUI
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { handleDrop($0, q: m.0) }
    }

    private func handleDrop(_ providers: [NSItemProvider], q: Int?) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            if let s = obj as? String, let handle = store.handle(from: s) {
                DispatchQueue.main.async {
                    store.setQuadrant(q, using: handle)
                    if store.lines.indices.contains(handle.index) { store.cursor = handle.index }
                }
            }
        }
        return true
    }

    @ViewBuilder private func qRow(_ i: Int) -> some View {
        if store.lines.indices.contains(i) {   // 防過期 index 越界
            let t = store.lines[i]
            HStack(spacing: 7) {
                Text("[ ]").foregroundColor(Theme.dim)
                Text(t.title).foregroundColor(t.isFocused ? Theme.focus : Theme.fg).lineLimit(1)
                    .font(store.taskFont)
            }
            .font(Theme.mono).padding(.horizontal, 4).padding(.vertical, 2)
            .background(store.cursor == i ? Theme.selBg : .clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                store.cursor = i
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { store.toggleDone() }
            }
            .onTapGesture { store.cursor = i }
            .onDrag { NSItemProvider(object: store.dragPayload(for: i) as NSString) }
            .background {
                ThemedTaskContextMenuPresenter(handle: store.handle(for: i), task: t,
                                               actions: contextActions, store: store)
            }
        }
    }

    private func poolView(_ idx: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("未歸位池 — 選取後按 1–4 指派").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if idx.isEmpty { Text("（空）").font(Theme.monoSmall).foregroundColor(Theme.dim) }
                    ForEach(idx, id: \.self) { qRow($0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10).padding(.horizontal, 4)
        .overlay(Rectangle().stroke(Theme.border, style: StrokeStyle(dash: [4])))
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { handleDrop($0, q: nil) }
        .padding(14)
    }
}

private struct ThemedTaskContextMenuPresenter: NSViewRepresentable {
    let handle: TaskHandle
    let task: TaskLine
    let actions: TaskContextActions
    @ObservedObject var store: TaskStore

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        configure(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        configure(view, coordinator: context.coordinator)
    }

    private func configure(_ view: RightClickView, coordinator: Coordinator) {
        view.onRightClick = { [weak view] point in
            guard let view else { return }
            coordinator.show(from: view, point: point, handle: handle, task: task,
                             actions: actions, store: store)
        }
    }

    final class Coordinator {
        private var popover: NSPopover?

        func show(from view: NSView, point: NSPoint, handle: TaskHandle, task: TaskLine,
                  actions: TaskContextActions, store: TaskStore) {
            popover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            let menu = ThemedTaskContextMenu(
                handle: handle, task: task, actions: actions,
                dismiss: { [weak popover] in popover?.close() }
            )
            .environmentObject(store)
            let host = NSHostingController(rootView: menu)
            popover.contentViewController = host
            host.view.layoutSubtreeIfNeeded()
            let fittingHeight = host.view.fittingSize.height
            popover.contentSize = NSSize(width: 286, height: min(max(fittingHeight, 1), 560))
            self.popover = popover

            popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1),
                         of: view, preferredEdge: .maxX)
        }
    }
}

/// 以 local monitor 觀察右鍵，不攔截 row 原本的左鍵與拖曳事件。
private final class RightClickView: NSView {
    var onRightClick: ((NSPoint) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                return event
            }
            self.onRightClick?(self.convert(event.locationInWindow, from: nil))
            return event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

private struct ThemedTaskContextMenu: View {
    private enum ExpandedSection { case due, quadrant, list, tag }

    @EnvironmentObject private var store: TaskStore
    let handle: TaskHandle
    let task: TaskLine
    let actions: TaskContextActions
    let dismiss: () -> Void
    @State private var expanded: ExpandedSection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
                    .lineLimit(2).padding(.horizontal, 12).padding(.vertical, 9)
                separator

                actionRow("編輯任務…", symbol: "e", enabled: !task.isDone) { actions.edit(handle) }
                actionRow(task.isDone ? "取消完成" : "完成", symbol: "x") {
                    store.toggleDone(using: handle)
                }
                actionRow(task.isFocused ? "取消 Focus" : "設為 Focus", symbol: "f",
                          color: Theme.focus, enabled: !task.isDone) {
                    store.toggleFocus(using: handle)
                }
                separator

                disclosureRow("到期日", symbol: "d", section: .due, enabled: !task.isDone)
                if expanded == .due {
                    childRow("今天") { store.setDue(store.todayYMD, using: handle) }
                    childRow("明天") { store.setDue(date(daysFromToday: 1), using: handle) }
                    childRow("下週") { store.setDue(date(daysFromToday: 7), using: handle) }
                    childRow("清除到期日", enabled: task.due != nil) { store.setDue(nil, using: handle) }
                }

                disclosureRow("象限", symbol: "q", section: .quadrant, enabled: !task.isDone)
                if expanded == .quadrant {
                    ForEach(1...4, id: \.self) { quadrant in
                        childRow("\(quadrant) \(quadrantName(quadrant))",
                                 checked: task.quadrant == quadrant) {
                            store.setQuadrant(quadrant, using: handle)
                        }
                    }
                    childRow(NSLocalizedString("未歸位", comment: "Task without a quadrant"),
                             checked: task.quadrant == nil) {
                        store.setQuadrant(nil, using: handle)
                    }
                }

                disclosureRow("List", symbol: "+", section: .list, color: Theme.mag,
                              enabled: !task.isDone)
                if expanded == .list {
                    if store.allProjects().isEmpty { emptyRow("尚無 List") }
                    ForEach(store.allProjects(), id: \.self) { project in
                        childRow("+\(project)", checked: task.projects.contains(project),
                                 color: Theme.mag, dismissAfter: false) {
                            store.setTag("+\(project)", enabled: !task.projects.contains(project), using: handle)
                        }
                    }
                    childRow("編輯更多…") { actions.edit(handle) }
                }

                disclosureRow("Tag", symbol: "@", section: .tag, color: Theme.cyan,
                              enabled: !task.isDone)
                if expanded == .tag {
                    if store.allContexts().isEmpty { emptyRow("尚無 Tag") }
                    ForEach(store.allContexts(), id: \.self) { context in
                        childRow("@\(context)", checked: task.contexts.contains(context),
                                 color: Theme.cyan, dismissAfter: false) {
                            store.setTag("@\(context)", enabled: !task.contexts.contains(context), using: handle)
                        }
                    }
                    childRow("編輯更多…") { actions.edit(handle) }
                }

                separator
                actionRow("複製任務文字", symbol: "y") { copyRawTask() }
                actionRow("封存任務…", symbol: "a", color: Theme.yellow) {
                    actions.confirmArchive(handle, task.title)
                }
                actionRow("永久刪除…", symbol: "!", color: Theme.red) {
                    actions.confirmDelete(handle, task.title)
                }
            }
        }
        .frame(width: 286)
        .frame(maxHeight: 560)
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.border))
    }

    private var separator: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
    }

    private func actionRow(_ title: String, symbol: String, color: Color = Theme.fg,
                           enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            dismiss()
            action()
        } label: {
            HStack(spacing: 9) {
                Text(symbol).foregroundColor(enabled ? color : Theme.dim.opacity(0.45)).frame(width: 16)
                Text(title).foregroundColor(enabled ? Theme.fg : Theme.dim.opacity(0.45))
                Spacer()
            }
            .font(Theme.mono).padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(ThemedMenuButtonStyle(enabled: enabled))
        .disabled(!enabled)
    }

    private func disclosureRow(_ title: String, symbol: String, section: ExpandedSection,
                               color: Color = Theme.fg, enabled: Bool) -> some View {
        Button {
            guard enabled else { return }
            expanded = expanded == section ? nil : section
        } label: {
            HStack(spacing: 9) {
                Text(symbol).foregroundColor(enabled ? color : Theme.dim.opacity(0.45)).frame(width: 16)
                Text(title).foregroundColor(enabled ? Theme.fg : Theme.dim.opacity(0.45))
                Spacer()
                Text(expanded == section ? "▾" : "▸").foregroundColor(Theme.dim)
            }
            .font(Theme.mono).padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(ThemedMenuButtonStyle(enabled: enabled))
        .disabled(!enabled)
    }

    private func childRow(_ title: String, checked: Bool = false, color: Color = Theme.fg,
                          enabled: Bool = true, dismissAfter: Bool = true,
                          action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            if dismissAfter { dismiss() }
            action()
        } label: {
            HStack(spacing: 8) {
                Text(checked ? "✓" : " ").foregroundColor(color).frame(width: 16)
                Text(title).foregroundColor(enabled ? color : Theme.dim.opacity(0.45))
                Spacer()
            }
            .font(Theme.monoSmall).padding(.leading, 27).padding(.trailing, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(ThemedMenuButtonStyle(enabled: enabled, nested: true))
        .disabled(!enabled)
    }

    private func emptyRow(_ title: String) -> some View {
        Text(title).font(Theme.monoSmall).foregroundColor(Theme.dim)
            .padding(.leading, 51).padding(.vertical, 5)
    }

    private func quadrantName(_ quadrant: Int) -> String {
        switch quadrant {
        case 1: return "Do"
        case 2: return "Schedule"
        case 3: return "Delegate"
        default: return NSLocalizedString("Delete（象限）", comment: "Eisenhower quadrant name")
        }
    }

    private func date(daysFromToday days: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return RelativeDate.todayYMD(date)
    }

    private func copyRawTask() {
        guard let current = store.task(using: handle) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(current.raw, forType: .string)
    }
}

private struct ThemedMenuButtonStyle: ButtonStyle {
    let enabled: Bool
    var nested = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed && enabled
                        ? (nested ? Theme.panel : Theme.selBg) : Color.clear)
    }
}

// MARK: - ⌘3 Agent

struct AgentWorkspaceView: View {
    private enum Section {
        case schedule
        case chat
        case report
    }

    @State private var section: Section = .schedule
    @State private var schedulePrompt = ""
    @StateObject private var chatModel = AgentChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                sectionTab("排程", .schedule)
                sectionTab("Chat", .chat)
                sectionTab("報表", .report)
                Spacer()
                Text(sectionStatus)
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(Theme.panel)
            Rectangle().fill(Theme.border).frame(height: 1)

            switch section {
            case .schedule:
                ScrollView {
                    AgentView(prompt: $schedulePrompt)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .chat:
                AgentChatView(model: chatModel)
            case .report:
                ScrollView {
                    ReportView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func sectionTab(_ title: String, _ target: Section) -> some View {
        let selected = section == target
        return Button { section = target } label: {
            Text(Theme.isTerminal ? "[\(title)]" : title)
                .font(Theme.monoSmall)
                .foregroundColor(selected ? (Theme.isTerminal ? Theme.green : Theme.fg) : Theme.dim)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(selected ? (Theme.isTerminal ? Theme.green.opacity(0.08) : Theme.bg) : .clear)
                .overlay(Rectangle().stroke(selected ? (Theme.isTerminal ? Theme.green.opacity(0.45) : Theme.border) : .clear))
        }
        .buttonStyle(.plain)
    }

    private var sectionStatus: LocalizedStringKey {
        switch section {
        case .schedule: return "RESCHEDULE"
        case .chat: return "READ-ONLY"
        case .report: return "REPORT"
        }
    }
}

struct AgentView: View {
    @EnvironmentObject var store: TaskStore
    @Binding var prompt: String

    private enum DisclosureState {
        case ready(AgentDisclosure)
        case missingEndpoint
        case failure(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stateHeader
            stateBody
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: 760, minHeight: 420, alignment: .topLeading)
    }

    private var stateHeader: some View {
        HStack(spacing: 8) {
            Text("AGENT").font(Theme.monoSmall).tracking(1.8).foregroundColor(Theme.dim)
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(stateLabel).font(Theme.monoSmall).foregroundColor(stateColor)
        }
    }

    @ViewBuilder private var stateBody: some View {
        switch store.agentState {
        case .idle:
            idleView
        case .running:
            runningView
        case .review(let changes, _):
            reviewView(changes)
        case .error(let message):
            errorView(message)
        }
    }

    @ViewBuilder private var idleView: some View {
        let disclosure = disclosureState
        VStack(alignment: .leading, spacing: 14) {
            Text("告訴 Agent 要如何重新安排到期日")
                .font(Theme.mono).foregroundColor(Theme.fg)

            HStack(spacing: Theme.isTerminal ? 0 : 8) {
                Text(Theme.isTerminal ? "❯ " : ">")
                    .foregroundColor(Theme.isTerminal ? Theme.green : store.accent)
                ZStack(alignment: .leading) {
                    if prompt.isEmpty {
                        Text("把逾期的都排到這週五")
                            .font(Theme.mono).foregroundColor(Theme.dim.opacity(0.45))
                    }
                    TerminalInputField(
                        text: $prompt,
                        onSubmit: { if canSubmit(disclosure) { store.runAgentQuery(prompt: prompt) } },
                        onCancel: { prompt = "" }
                    )
                }
                .frame(height: 22)
                agentButton("送出", color: Theme.green) {
                    store.runAgentQuery(prompt: prompt)
                }
                .disabled(!canSubmit(disclosure))
                .opacity(canSubmit(disclosure) ? 1 : 0.4)
            }
            .padding(10)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.border))

            disclosureView(disclosure)
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在等待 Agent 回應…").foregroundColor(Theme.fg)
                Spacer()
                agentButton("取消", color: Theme.red) { store.cancelAgentQuery() }
            }
            Text("尚未寫入 tasks.txt；回應完成後會先顯示變更供你審核。")
                .font(Theme.monoSmall).foregroundColor(Theme.dim)
        }
        .padding(14)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.border))
    }

    private func reviewView(_ changes: [AgentReviewChange]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("檢查提議變更").foregroundColor(Theme.fg)
                Spacer()
                Text("\(changes.count) CHANGES").font(Theme.monoSmall).foregroundColor(Theme.yellow)
            }
            Text("只有按下「套用」才會寫入 tasks.txt。")
                .font(Theme.monoSmall).foregroundColor(Theme.dim)

            if changes.isEmpty {
                Text("Agent 沒有提議任何變更。")
                    .foregroundColor(Theme.dim)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(changes) { change in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(change.title).foregroundColor(Theme.fg)
                            HStack(spacing: 8) {
                                Text(change.oldDue ?? "—").foregroundColor(Theme.dim)
                                Text("→").foregroundColor(Theme.yellow)
                                Text(change.newDue).foregroundColor(Theme.green)
                                Spacer()
                                Text(change.taskID).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.7))
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                    }
                }
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.border))
            }

            HStack {
                Spacer()
                agentButton("捨棄", color: Theme.dim) { store.discardAgentReview() }
                agentButton("套用", color: Theme.green) { store.applyAgentReview() }
                    .disabled(changes.isEmpty)
                    .opacity(changes.isEmpty ? 0.4 : 1)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agent 執行失敗").foregroundColor(Theme.red)
            Text(message)
                .font(Theme.monoSmall).foregroundColor(Theme.fg)
                .textSelection(.enabled)
            HStack {
                Spacer()
                agentButton("返回", color: Theme.dim) { store.resetAgentState() }
            }
        }
        .padding(14)
        .background(Theme.red.opacity(0.08))
        .overlay(Rectangle().stroke(Theme.red.opacity(0.55)))
    }

    @ViewBuilder private func disclosureView(_ state: DisclosureState) -> some View {
        switch state {
        case .ready(let disclosure):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("將送出").foregroundColor(Theme.dim)
                    Text("\(disclosure.tasks.count)").foregroundColor(Theme.cyan)
                    Text("筆未完成任務的 id / title / due 到").foregroundColor(Theme.dim)
                    Text(disclosure.endpointHost).foregroundColor(Theme.cyan)
                }
                .font(Theme.monoSmall)

                if disclosure.tasks.isEmpty {
                    Text("目前沒有未完成任務。")
                        .font(Theme.monoSmall).foregroundColor(Theme.dim)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Text("ID").frame(width: 180, alignment: .leading)
                            Text("TITLE").frame(maxWidth: .infinity, alignment: .leading)
                            Text("DUE").frame(width: 90, alignment: .leading)
                        }
                        .font(Theme.monoSmall).foregroundColor(Theme.dim)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.panel)
                        ForEach(disclosure.tasks) { task in
                            HStack(alignment: .top, spacing: 10) {
                                Text(task.id).frame(width: 180, alignment: .leading)
                                    .lineLimit(1).truncationMode(.middle).foregroundColor(Theme.dim)
                                Text(task.title).frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundColor(Theme.fg)
                                Text(task.due ?? "—").frame(width: 90, alignment: .leading)
                                    .foregroundColor(task.due == nil ? Theme.dim : Theme.yellow)
                            }
                            .font(Theme.monoSmall)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        }
                    }
                    .overlay(Rectangle().stroke(Theme.border))
                }
            }
        case .missingEndpoint:
            HStack(spacing: 10) {
                Text("尚未設定 Agent Endpoint。請先到設定填入 Base URL、API Key 與 Model。")
                    .font(Theme.monoSmall).foregroundColor(Theme.yellow)
                Spacer()
                agentButton("前往設定", color: Theme.yellow) { store.view = .settings }
            }
            .padding(12)
            .background(Theme.yellow.opacity(0.08))
            .overlay(Rectangle().stroke(Theme.yellow.opacity(0.45)))
        case .failure(let message):
            Text(message)
                .font(Theme.monoSmall).foregroundColor(Theme.red)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.red.opacity(0.08))
                .overlay(Rectangle().stroke(Theme.red.opacity(0.45)))
        }
    }

    private var disclosureState: DisclosureState {
        do {
            return .ready(try store.agentDisclosure())
        } catch AgentCredentialStoreError.missingConfiguration {
            return .missingEndpoint
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func canSubmit(_ state: DisclosureState) -> Bool {
        guard case .ready(let disclosure) = state else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !disclosure.tasks.isEmpty
    }

    private func agentButton(_ title: LocalizedStringKey, color: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("[") + Text(title) + Text("]")
        }
        .buttonStyle(.plain)
        .font(Theme.monoSmall)
        .foregroundColor(color)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var stateLabel: LocalizedStringKey {
        switch store.agentState {
        case .idle: return "IDLE"
        case .running: return "RUNNING"
        case .review: return "REVIEW"
        case .error: return "ERROR"
        }
    }

    private var stateColor: Color {
        switch store.agentState {
        case .idle: return Theme.dim
        case .running: return Theme.cyan
        case .review: return Theme.yellow
        case .error: return Theme.red
        }
    }
}

struct ReportView: View {
    @EnvironmentObject var store: TaskStore

    @State private var templateID = ReportTemplate.builtIn[0].id
    @State private var tweak = ""
    @State private var isGenerating = false
    @State private var report: String?
    @State private var errorMessage: String?

    @State private var pluginReportType = ReportTemplate.builtIn[0].id
    @State private var pluginDoc: PluginPageDocument?
    @State private var pluginError: String?
    @State private var reviewsView = "weekly"
    @State private var reviewsDoc: PluginPageDocument?
    @State private var reviewsError: String?
    @State private var analyticsDoc: PluginPageDocument?
    @State private var analyticsError: String?
    @State private var methodologyView = "gtd"
    @State private var methodologyDoc: PluginPageDocument?
    @State private var methodologyError: String?

    private static let taskReportManifest = PluginManifest(
        id: "app.txtnimal.task-report", name: "Task Report", version: "0.1.0",
        apiVersion: 1, entry: "main.js", capabilities: [.tasksAllRead, .uiPage],
        pages: [PluginPageDeclaration(id: "task-report", title: "Task Report", entryFunction: "run")])
    private static let reviewsPackManifest = PluginManifest(
        id: "app.txtnimal.reviews-pack", name: "Reviews Pack", version: "0.1.0",
        apiVersion: 1, entry: "main.js", capabilities: [.tasksAllRead, .uiPage],
        pages: [PluginPageDeclaration(id: "reviews-pack", title: "Reviews Pack", entryFunction: "run")])
    private static let analyticsManifest = PluginManifest(
        id: "app.txtnimal.analytics", name: "Analytics", version: "0.1.0",
        apiVersion: 1, entry: "main.js", capabilities: [.tasksAllRead, .uiPage],
        pages: [PluginPageDeclaration(id: "analytics", title: "Analytics", entryFunction: "run")])
    private static let methodologyManifest = PluginManifest(
        id: "app.txtnimal.methodology", name: "Methodology", version: "0.1.0",
        apiVersion: 1, entry: "main.js", capabilities: [.tasksAllRead, .uiPage],
        pages: [PluginPageDeclaration(id: "methodology", title: "Methodology", entryFunction: "run")])

    var body: some View {
        let tasks = store.reportCandidateTasks()
        VStack(alignment: .leading, spacing: 16) {
            header
            controls
            taskSelection(tasks)
            actionBar(tasks)
            if isGenerating { progressView }
            if let message = errorMessage { errorView(message) }
            if let report { reportPanel(report) }
            Divider().background(Theme.border)
            pluginSection
            Divider().background(Theme.border)
            reviewsPackSection
            Divider().background(Theme.border)
            analyticsSection
            Divider().background(Theme.border)
            methodologySection
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: 760, minHeight: 420, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("REPORT").font(Theme.monoSmall).tracking(1.8).foregroundColor(Theme.dim)
            Rectangle().fill(Theme.border).frame(height: 1)
            Text("MARKDOWN").font(Theme.monoSmall).foregroundColor(Theme.cyan)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("選擇範本")
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
                Picker("", selection: $templateID) {
                    ForEach(ReportTemplate.builtIn) { template in
                        Text(LocalizedStringKey(template.name)).tag(template.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("補充要求")
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
                TextField(LocalizedStringKey("補充要求（可留空）"), text: $tweak)
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .foregroundColor(Theme.fg)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Theme.panel)
                    .overlay(Rectangle().stroke(Theme.border))
            }
        }
    }

    private func taskSelection(_ tasks: [PluginTaskSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("選擇任務").font(Theme.monoSmall).foregroundColor(Theme.dim)
                Spacer()
                if !store.reportSelection.isEmpty {
                    Text("\(store.reportSelection.count) SELECTED")
                        .font(Theme.monoSmall).foregroundColor(Theme.cyan)
                }
            }

            if tasks.isEmpty {
                Text("目前沒有可選任務。")
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.panel)
                    .overlay(Rectangle().stroke(Theme.border))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(tasks, id: \.id) { task in
                        HStack(alignment: .top, spacing: 10) {
                            Text(store.reportSelection.contains(task.id) ? "[✓]" : "[ ]")
                                .font(Theme.monoSmall)
                                .foregroundColor(store.reportSelection.contains(task.id) ? Theme.green : Theme.dim)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.title).foregroundColor(Theme.fg)
                                HStack(spacing: 8) {
                                    Text(task.due ?? "—")
                                        .font(Theme.monoSmall)
                                        .foregroundColor(task.due == nil ? Theme.dim : Theme.yellow)
                                    Text(task.id)
                                        .font(Theme.monoSmall)
                                        .foregroundColor(Theme.dim.opacity(0.7))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .background(store.reportSelection.contains(task.id) ? Theme.cursorBg.opacity(0.45) : .clear)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                        .onTapGesture { store.toggleReportSelection(task.id) }
                    }
                }
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.border))
            }
        }
    }

    private func actionBar(_ tasks: [PluginTaskSnapshot]) -> some View {
        HStack {
            if store.reportSelection.isEmpty {
                Text("尚未選取任務。")
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
            Spacer()
            reportButton("產生", color: Theme.green) { generateReport(from: tasks) }
                .disabled(isGenerating || tasksForReport(from: tasks).isEmpty)
                .opacity(isGenerating || tasksForReport(from: tasks).isEmpty ? 0.4 : 1)
            reportButton("匯出", color: Theme.yellow) { exportReport() }
                .disabled(report == nil)
                .opacity(report == nil ? 0.4 : 1)
        }
    }

    private var progressView: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在產生報表…").foregroundColor(Theme.fg)
        }
        .padding(14)
        .background(Theme.panel)
        .overlay(Rectangle().stroke(Theme.border))
    }

    private func reportPanel(_ report: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("報表預覽").font(Theme.monoSmall).foregroundColor(Theme.dim)
            ScrollView {
                Text(report)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 220)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.border))
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("報表產生失敗").foregroundColor(Theme.red)
            Text(message)
                .font(Theme.monoSmall)
                .foregroundColor(Theme.fg)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(Theme.red.opacity(0.08))
        .overlay(Rectangle().stroke(Theme.red.opacity(0.55)))
    }

    private func reportButton(_ title: LocalizedStringKey, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("[") + Text(title) + Text("]")
        }
        .buttonStyle(.plain)
        .font(Theme.monoSmall)
        .foregroundColor(color)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var selectedTemplate: ReportTemplate {
        ReportTemplate.builtIn.first { $0.id == templateID } ?? ReportTemplate.builtIn[0]
    }

    private func tasksForReport(from tasks: [PluginTaskSnapshot]) -> [ReportTask] {
        tasks.filter { store.reportSelection.contains($0.id) }
            .map { ReportTask(id: $0.id, title: $0.title, due: $0.due, completed: $0.completed) }
    }

    private func generateReport(from tasks: [PluginTaskSnapshot]) {
        let selectedTasks = tasksForReport(from: tasks)
        guard !selectedTasks.isEmpty else { return }

        isGenerating = true
        errorMessage = nil
        report = nil

        let template = selectedTemplate
        let tweak = tweak
        Task {
            do {
                let generated = try await ReportGenerator(
                    credentialStore: KeychainAgentCredentialStore()
                ).generate(template: template, tweak: tweak, tasks: selectedTasks)
                await MainActor.run {
                    report = generated
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    report = nil
                    isGenerating = false
                    errorMessage = readableMessage(for: error)
                }
            }
        }
    }

    private enum ExportOutcome { case cancelled, saved, failed(String) }

    /// Shared NSSavePanel .md export. Callers route the outcome into their own
    /// error state so the LLM report and the plugin page stay independent.
    private func saveMarkdown(_ content: String, reportType: String) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "report-\(exportDateString())-\(reportType).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        guard panel.runModal() == .OK else { return .cancelled }
        guard let url = panel.url else { return .failed("無法取得匯出位置。") }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return .saved
        } catch {
            return .failed(readableMessage(for: error))
        }
    }

    private func exportReport() {
        guard let report else {
            errorMessage = "請先產生報表。"
            return
        }
        switch saveMarkdown(report, reportType: templateID) {
        case .cancelled: break
        case .saved: errorMessage = nil
        case .failed(let message): errorMessage = message
        }
    }

    private var pluginSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("PLUGIN").font(Theme.monoSmall).tracking(1.8).foregroundColor(Theme.dim)
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("DETERMINISTIC").font(Theme.monoSmall).foregroundColor(Theme.green)
            }

            Picker("", selection: $pluginReportType) {
                ForEach(ReportTemplate.builtIn) { template in
                    Text(LocalizedStringKey(template.name)).tag(template.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                reportButton("用 plugin 產生", color: Theme.cyan) { generatePluginReport() }
                reportButton("匯出 .md", color: Theme.yellow) { exportPluginReport() }
                    .disabled(pluginDoc == nil)
                    .opacity(pluginDoc == nil ? 0.4 : 1)
            }

            if let pluginError {
                Text(pluginError)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.red)
                    .textSelection(.enabled)
            }

            if let pluginDoc {
                PluginPagePrototypeView(document: pluginDoc, manifest: Self.taskReportManifest,
                                        onIntent: { _ in })
                    .frame(minHeight: 260)
                    .overlay(Rectangle().stroke(Theme.border))
            }
        }
    }

    private func generatePluginReport() {
        do {
            pluginDoc = try store.taskReportPluginPage(reportType: pluginReportType)
            pluginError = nil
        } catch {
            pluginDoc = nil
            pluginError = readableMessage(for: error)
        }
    }

    private func exportPluginReport() {
        guard let pluginDoc else {
            pluginError = "請先用 plugin 產生報表。"
            return
        }
        switch saveMarkdown(pluginMarkdown(from: pluginDoc), reportType: pluginReportType) {
        case .cancelled: break
        case .saved: pluginError = nil
        case .failed(let message): pluginError = message
        }
    }

    private var reviewsPackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("REVIEWS").font(Theme.monoSmall).tracking(1.8).foregroundColor(Theme.dim)
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("GTD").font(Theme.monoSmall).foregroundColor(Theme.cyan)
            }

            Picker("", selection: $reviewsView) {
                Text("週回顧").tag("weekly")
                Text("日回顧").tag("daily")
                Text("停滯偵測").tag("stalled")
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                reportButton("產生回顧", color: Theme.cyan) { generateReviewsPack() }
                reportButton("匯出 .md", color: Theme.yellow) { exportReviewsPack() }
                    .disabled(reviewsDoc == nil)
                    .opacity(reviewsDoc == nil ? 0.4 : 1)
            }

            if let reviewsError {
                Text(reviewsError)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.red)
                    .textSelection(.enabled)
            }

            if let reviewsDoc {
                PluginPagePrototypeView(document: reviewsDoc, manifest: Self.reviewsPackManifest,
                                        onIntent: { _ in })
                    .frame(minHeight: 260)
                    .overlay(Rectangle().stroke(Theme.border))
            }
        }
    }

    private func generateReviewsPack() {
        do {
            reviewsDoc = try store.reviewsPackPluginPage(view: reviewsView)
            reviewsError = nil
        } catch {
            reviewsDoc = nil
            reviewsError = readableMessage(for: error)
        }
    }

    private func exportReviewsPack() {
        guard let reviewsDoc else {
            reviewsError = "請先產生回顧。"
            return
        }
        switch saveMarkdown(pluginMarkdown(from: reviewsDoc), reportType: "reviews-" + reviewsView) {
        case .cancelled: break
        case .saved: reviewsError = nil
        case .failed(let message): reviewsError = message
        }
    }

    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("ANALYTICS").font(Theme.monoSmall).tracking(1.8).foregroundColor(Theme.dim)
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("METRICS").font(Theme.monoSmall).foregroundColor(Theme.green)
            }

            HStack {
                Spacer()
                reportButton("產生分析", color: Theme.cyan) { generateAnalytics() }
                reportButton("匯出 .md", color: Theme.yellow) { exportAnalytics() }
                    .disabled(analyticsDoc == nil)
                    .opacity(analyticsDoc == nil ? 0.4 : 1)
            }

            if let analyticsError {
                Text(analyticsError)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.red)
                    .textSelection(.enabled)
            }

            if let analyticsDoc {
                PluginPagePrototypeView(document: analyticsDoc, manifest: Self.analyticsManifest,
                                        onIntent: { _ in })
                    .frame(minHeight: 260)
                    .overlay(Rectangle().stroke(Theme.border))
            }
        }
    }

    private func generateAnalytics() {
        do {
            analyticsDoc = try store.analyticsPluginPage()
            analyticsError = nil
        } catch {
            analyticsDoc = nil
            analyticsError = readableMessage(for: error)
        }
    }

    private func exportAnalytics() {
        guard let analyticsDoc else {
            analyticsError = "請先產生分析。"
            return
        }
        switch saveMarkdown(pluginMarkdown(from: analyticsDoc), reportType: "analytics") {
        case .cancelled: break
        case .saved: analyticsError = nil
        case .failed(let message): analyticsError = message
        }
    }

    private var methodologySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("方法論").font(Theme.monoSmall).tracking(1.8).foregroundColor(Theme.dim)
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("視圖").font(Theme.monoSmall).foregroundColor(Theme.green)
            }

            Picker("", selection: $methodologyView) {
                Text("艾森豪").tag("eisenhower")
                Text("PARA").tag("para")
                Text("GTD").tag("gtd")
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                reportButton("產生方法論視圖", color: Theme.cyan) { generateMethodology() }
                reportButton("匯出 .md", color: Theme.yellow) { exportMethodology() }
                    .disabled(methodologyDoc == nil)
                    .opacity(methodologyDoc == nil ? 0.4 : 1)
            }

            if let methodologyError {
                Text(methodologyError)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.red)
                    .textSelection(.enabled)
            }

            if let methodologyDoc {
                PluginPagePrototypeView(document: methodologyDoc, manifest: Self.methodologyManifest,
                                        onIntent: { _ in })
                    .frame(minHeight: 260)
                    .overlay(Rectangle().stroke(Theme.border))
            }
        }
    }

    private func generateMethodology() {
        do {
            methodologyDoc = try store.methodologyPluginPage(view: methodologyView)
            methodologyError = nil
        } catch {
            methodologyDoc = nil
            methodologyError = readableMessage(for: error)
        }
    }

    private func exportMethodology() {
        guard let methodologyDoc else {
            methodologyError = "請先產生方法論視圖。"
            return
        }
        switch saveMarkdown(pluginMarkdown(from: methodologyDoc), reportType: "methodology-" + methodologyView) {
        case .cancelled: break
        case .saved: methodologyError = nil
        case .failed(let message): methodologyError = message
        }
    }

    /// Flattens a plugin page document to markdown: sections → `##`, text → lines,
    /// statCard/barChart → `**label：** value`, `• ` task lines → `- ` bullets.
    private func pluginMarkdown(from document: PluginPageDocument) -> String {
        var lines: [String] = []
        func walk(_ node: PluginPageNode) {
            switch node.type {
            case .page:
                if let title = node.title { lines.append("# \(title)"); lines.append("") }
            case .section:
                if let title = node.title { lines.append(""); lines.append("## \(title)") }
            case .statCard:
                lines.append("**\(node.title ?? "")：** \(node.value ?? "")")
            case .barChart:
                if let title = node.title { lines.append("**\(title)：** \(node.value ?? "")") }
            case .text:
                let value = node.value ?? node.title ?? ""
                lines.append(value.hasPrefix("• ") ? "- " + value.dropFirst(2).description : value)
            case .emptyState:
                lines.append("_\(node.title ?? node.value ?? "")_")
            case .divider:
                lines.append("---")
            case .taskList, .button, .form, .textField, .picker, .toggle, .spacer:
                break
            }
            for child in node.children ?? [] { walk(child) }
        }
        walk(document.page)
        return lines.joined(separator: "\n") + "\n"
    }

    private func exportDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func readableMessage(for error: Error) -> String {
        switch error {
        case AgentCredentialStoreError.missingConfiguration:
            return "尚未設定 Agent Endpoint。請先到設定填入 Base URL、API Key 與 Model。"
        default:
            return error.localizedDescription
        }
    }
}

private struct AgentChatPendingReview: Identifiable {
    let id = UUID()
    let conversationID: String
    let actions: [AgentChatAction]
    let assistantNote: String?
    let context: AgentChatContext
}

private final class AgentChatViewModel: ObservableObject {
    @Published private(set) var conversations: [ChatConversation] = []
    @Published var current: ChatConversation?
    @Published var draft = ""
    @Published private(set) var isSending = false
    @Published private(set) var endpointIssue: String?
    @Published var errorMessage: String?
    @Published private(set) var pendingReview: AgentChatPendingReview?
    @Published private(set) var streamingText = ""      // assistant text as it streams in

    private let chatStore: ChatStore
    private let credentialStore: any AgentCredentialStore
    private var requestTask: Task<Void, Never>?
    private var requestID: UUID?

    init(
        chatStore: ChatStore = ChatStore(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/txtnimal", isDirectory: true)
        ),
        credentialStore: any AgentCredentialStore = KeychainAgentCredentialStore()
    ) {
        self.chatStore = chatStore
        self.credentialStore = credentialStore
        refreshEndpoint()
        reloadHistory()
        if current == nil { startNewConversation() }
    }

    var canSend: Bool {
        endpointIssue == nil && !isSending && pendingReview == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refreshEndpoint() {
        do {
            _ = try credentialStore.endpointConfig()
            endpointIssue = nil
        } catch AgentCredentialStoreError.missingConfiguration {
            endpointIssue = "尚未設定 Agent Endpoint。請先到 ⌘5 設定 Base URL、API Key 與 Model。"
        } catch {
            endpointIssue = error.localizedDescription
        }
    }

    func reloadHistory(selecting selectedID: String? = nil) {
        do {
            conversations = try chatStore.list()
            if let selectedID, let selected = conversations.first(where: { $0.id == selectedID }) {
                current = selected
            } else if current == nil {
                current = conversations.first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startNewConversation() {
        cancel()
        pendingReview = nil
        let now = Date()
        current = ChatConversation(id: UUID().uuidString, title: "新對話", messages: [], createdAt: now, updatedAt: now)
        draft = ""
        errorMessage = nil
    }

    func load(_ conversation: ChatConversation) {
        cancel()
        pendingReview = nil
        current = conversation
        draft = ""
        errorMessage = nil
    }

    func delete(_ conversation: ChatConversation) {
        cancel()
        pendingReview = nil
        do {
            try chatStore.delete(id: conversation.id)
            if current?.id == conversation.id { current = nil }
            reloadHistory()
            if current == nil { startNewConversation() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func show(error: Error) {
        errorMessage = error.localizedDescription
    }

    func send(context: AgentChatContext) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending, pendingReview == nil else { return }

        let config: AgentEndpointConfig
        do {
            config = try credentialStore.endpointConfig()
            endpointIssue = nil
        } catch {
            refreshEndpoint()
            errorMessage = error.localizedDescription
            return
        }

        var conversation = current ?? makeConversation()
        if conversation.messages.first(where: { $0.role == .user }) == nil {
            conversation.title = Self.title(for: text)
        }
        conversation.messages.append(AgentChatMessage(role: .user, content: text))
        conversation.updatedAt = Date()
        current = conversation
        draft = ""
        errorMessage = nil

        do {
            try persist(conversation)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let client = AgentChatClient(
            credentialStore: InMemoryAgentCredentialStore(config: config)
        )
        let messages = [context.systemMessage] + conversation.messages
        let conversationID = conversation.id
        let runID = UUID()
        requestID = runID
        isSending = true
        streamingText = ""
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in client.stream(messages: messages) {
                    guard self.requestID == runID, self.current?.id == conversationID else { return }
                    switch event {
                    case .textDelta(let piece):
                        self.streamingText += piece
                    case .completed(let reply):
                        try self.handleCompletedReply(reply, conversationID: conversationID,
                                                      context: context, runID: runID)
                    }
                }
                // Stream ended without a `.completed` (defensive): flush whatever text arrived.
                if self.requestID == runID, self.isSending {
                    let streamed = self.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !streamed.isEmpty { try? self.appendAssistant(streamed, to: conversationID) }
                    self.finish(runID: runID)
                }
            } catch {
                guard self.requestID == runID else { return }
                self.finish(runID: runID)
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    return
                }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func handleCompletedReply(_ reply: AgentChatReply, conversationID: String,
                                      context: AgentChatContext, runID: UUID) throws {
        switch reply {
        case .text(let content):
            try appendAssistant(content, to: conversationID)
            finish(runID: runID)
        case .actions(let actions, let assistantNote):
            let allowedTaskIDs = Set(context.tasks.map(\.id))
            let filtered = actions.filter { action in
                switch action {
                case .reschedule(let taskID, _), .complete(let taskID),
                     .delete(let taskID), .retitle(let taskID, _):
                    return allowedTaskIDs.contains(taskID)
                case .create:
                    return true
                }
            }
            if filtered.isEmpty {
                let prefix = assistantNote.map { $0 + "\n\n" } ?? ""
                try appendAssistant(prefix + "提議的任務不在本輪提供的任務背景中，未建立任何變更。",
                                    to: conversationID)
            } else {
                pendingReview = AgentChatPendingReview(
                    conversationID: conversationID,
                    actions: filtered,
                    assistantNote: assistantNote,
                    context: context
                )
            }
            finish(runID: runID)
        }
    }

    func discardPendingReview() {
        guard let review = pendingReview, current?.id == review.conversationID else { return }
        pendingReview = nil
        do {
            try appendAssistant(flatten(review: review, outcome: "已略過，未修改 tasks.txt。"),
                                to: review.conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyPendingReview(using store: TaskStore) {
        guard let review = pendingReview, current?.id == review.conversationID else { return }
        do {
            let count = try store.applyAgentChatActions(review.actions, context: review.context)
            pendingReview = nil
            try appendAssistant(flatten(review: review, outcome: "已套用 \(count) 項變更。"),
                                to: review.conversationID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        requestTask?.cancel()
        requestTask = nil
        requestID = nil
        isSending = false
        streamingText = ""
    }

    private func finish(runID: UUID) {
        guard requestID == runID else { return }
        requestTask = nil
        requestID = nil
        isSending = false
        streamingText = ""
    }

    private func persist(_ conversation: ChatConversation) throws {
        try chatStore.save(conversation)
        conversations = try chatStore.list()
        current = conversations.first(where: { $0.id == conversation.id }) ?? conversation
    }

    private func appendAssistant(_ content: String, to conversationID: String) throws {
        guard var conversation = current, conversation.id == conversationID else { return }
        conversation.messages.append(AgentChatMessage(role: .assistant, content: content))
        conversation.updatedAt = Date()
        current = conversation
        try persist(conversation)
    }

    private func flatten(review: AgentChatPendingReview, outcome: String) -> String {
        let tasksByID = Dictionary(uniqueKeysWithValues: review.context.tasks.map { ($0.id, $0) })
        let proposals = review.actions.map { action in
            switch action {
            case .reschedule(let taskID, let newDue):
                let task = tasksByID[taskID]
                return "- \(task?.title ?? taskID)：\(task?.due ?? "無期限") → \(newDue)"
            case .create(let title, let due):
                return "- ＋新增：\(title)（\(due ?? "無期限")）"
            case .complete(let taskID):
                return "- ✓ 完成：\(tasksByID[taskID]?.title ?? taskID)"
            case .delete(let taskID):
                return "- ✗ 刪除：\(tasksByID[taskID]?.title ?? taskID)"
            case .retitle(let taskID, let newTitle):
                return "- 改標題：\(tasksByID[taskID]?.title ?? taskID) → \(newTitle)"
            }
        }.joined(separator: "\n")
        let note = review.assistantNote.map { $0 + "\n\n" } ?? ""
        return "\(note)提議變更：\n\(proposals)\n\n\(outcome)"
    }

    private func makeConversation() -> ChatConversation {
        let now = Date()
        return ChatConversation(id: UUID().uuidString, title: "新對話", messages: [], createdAt: now, updatedAt: now)
    }

    private static func title(for text: String) -> String {
        let limit = 28
        let prefix = String(text.prefix(limit))
        return text.count > limit ? prefix + "…" : prefix
    }
}

private struct AgentChatView: View {
    @EnvironmentObject var store: TaskStore
    @ObservedObject var model: AgentChatViewModel

    var body: some View {
        HStack(spacing: 0) {
            historyPanel
                .frame(width: 190)
            Rectangle().fill(Theme.border).frame(width: 1)
            conversationPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.refreshEndpoint() }
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("HISTORY").font(Theme.monoSmall).tracking(1.2).foregroundColor(Theme.dim)
                Spacer()
                chatButton("新增", color: Theme.green) { model.startNewConversation() }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.conversations.isEmpty {
                        Text("尚無對話紀錄")
                            .font(Theme.monoSmall).foregroundColor(Theme.dim)
                            .padding(12)
                    }
                    ForEach(model.conversations) { conversation in
                        historyRow(conversation)
                    }
                }
            }
        }
        .background(Theme.panel.opacity(0.55))
    }

    private func historyRow(_ conversation: ChatConversation) -> some View {
        let selected = model.current?.id == conversation.id
        return HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title).lineLimit(2).foregroundColor(selected ? Theme.fg : Theme.dim)
                Text(Self.historyDate.string(from: conversation.updatedAt))
                    .font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.delete(conversation) } label: {
                Text("×").font(Theme.mono).foregroundColor(Theme.red.opacity(0.8))
            }
            .buttonStyle(.plain).help("刪除對話")
        }
        .font(Theme.monoSmall)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(selected ? Theme.selBg : .clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.cyan).frame(width: 2) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture { model.load(conversation) }
    }

    private var conversationPanel: some View {
        VStack(spacing: 0) {
            messagesView
            Rectangle().fill(Theme.border).frame(height: 1)
            if let endpointIssue = model.endpointIssue {
                HStack(spacing: 10) {
                    Text(endpointIssue).font(Theme.monoSmall).foregroundColor(Theme.yellow)
                    Spacer()
                    chatButton("前往設定", color: Theme.yellow) { store.view = .settings }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.yellow.opacity(0.07))
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            if let error = model.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Text("ERROR").foregroundColor(Theme.red)
                    Text(error).foregroundColor(Theme.fg).textSelection(.enabled)
                    Spacer()
                    Button { model.errorMessage = nil } label: { Text("×").foregroundColor(Theme.dim) }
                        .buttonStyle(.plain)
                }
                .font(Theme.monoSmall).padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.red.opacity(0.07))
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            inputBar
        }
    }

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let messages = model.current?.messages ?? []
                    if messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("開始一段關於任務的對話")
                                .foregroundColor(Theme.fg)
                            Text("Agent 會看到最多 50 筆未完成任務；重排與新增提議一律先顯示審核卡。")
                                .font(Theme.monoSmall).foregroundColor(Theme.dim)
                        }
                        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                        messageRow(message).id(index)
                    }
                    if let review = model.pendingReview,
                       review.conversationID == model.current?.id {
                        reviewCard(review).id(review.id)
                    }
                    if model.isSending {
                        if model.streamingText.isEmpty {
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.small)
                                Text("Agent 正在回應…").foregroundColor(Theme.cyan)
                            }
                            .font(Theme.monoSmall).padding(.horizontal, 18).padding(.vertical, 12)
                            .id(messages.count)
                        } else {
                            // Live-streamed assistant text, rendered like a normal assistant row.
                            messageRow(AgentChatMessage(role: .assistant, content: model.streamingText))
                                .id(messages.count)
                        }
                    }
                }
            }
            .onChange(of: model.current?.messages.count ?? 0) { count in
                withAnimation { proxy.scrollTo(max(0, count - 1), anchor: .bottom) }
            }
            .onChange(of: model.streamingText) { _ in
                proxy.scrollTo(model.current?.messages.count ?? 0, anchor: .bottom)
            }
            .onChange(of: model.isSending) { sending in
                if sending { withAnimation { proxy.scrollTo(model.current?.messages.count ?? 0, anchor: .bottom) } }
            }
            .onChange(of: model.pendingReview?.id) { reviewID in
                if let reviewID { withAnimation { proxy.scrollTo(reviewID, anchor: .bottom) } }
            }
        }
    }

    private func messageRow(_ message: AgentChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack(alignment: .top, spacing: 12) {
            Text(isUser ? "YOU" : "AGENT")
                .font(Theme.monoSmall).tracking(0.8)
                .foregroundColor(isUser ? Theme.blue : Theme.cyan)
                .frame(width: 48, alignment: .leading)
            Text(message.content)
                .font(Theme.mono).foregroundColor(Theme.fg)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .background(isUser ? Theme.blue.opacity(0.045) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func reviewCard(_ review: AgentChatPendingReview) -> some View {
        let tasksByID = Dictionary(uniqueKeysWithValues: review.context.tasks.map { ($0.id, $0) })
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("檢查提議變更").foregroundColor(Theme.fg)
                Spacer()
                Text("\(review.actions.count) CHANGES")
                    .font(Theme.monoSmall).foregroundColor(Theme.yellow)
            }
            if let note = review.assistantNote {
                Text(note).font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
            Text("只有按下「套用」才會寫入 tasks.txt。")
                .font(Theme.monoSmall).foregroundColor(Theme.dim)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(review.actions.enumerated()), id: \.offset) { _, action in
                    VStack(alignment: .leading, spacing: 5) {
                        switch action {
                        case .reschedule(let taskID, let newDue):
                            let task = tasksByID[taskID]
                            Text(task?.title ?? taskID).foregroundColor(Theme.fg)
                            HStack(spacing: 8) {
                                Text(task?.due ?? "無期限").foregroundColor(Theme.dim)
                                Text("→").foregroundColor(Theme.yellow)
                                Text(newDue).foregroundColor(Theme.green)
                                Spacer()
                                Text(taskID).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.7))
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        case .create(let title, let due):
                            Text("＋新增：\(title)").foregroundColor(Theme.fg)
                            Text(due ?? "無期限")
                                .font(Theme.monoSmall)
                                .foregroundColor(due == nil ? Theme.dim : Theme.green)
                        case .complete(let taskID):
                            Text("✓ 完成：\(tasksByID[taskID]?.title ?? taskID)").foregroundColor(Theme.fg)
                        case .delete(let taskID):
                            Text("✗ 刪除：\(tasksByID[taskID]?.title ?? taskID)").foregroundColor(Theme.red)
                        case .retitle(let taskID, let newTitle):
                            Text(tasksByID[taskID]?.title ?? taskID).foregroundColor(Theme.dim)
                            HStack(spacing: 8) {
                                Text("→").foregroundColor(Theme.yellow)
                                Text(newTitle).foregroundColor(Theme.green)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
                }
            }
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.border))

            HStack {
                Spacer()
                chatButton("捨棄", color: Theme.dim) { model.discardPendingReview() }
                chatButton("套用", color: Theme.green) { model.applyPendingReview(using: store) }
            }
        }
        .padding(14)
        .background(Theme.yellow.opacity(0.05))
        .overlay(Rectangle().stroke(Theme.yellow.opacity(0.55)))
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var inputBar: some View {
        HStack(spacing: Theme.isTerminal ? 0 : 8) {
            Text(Theme.isTerminal ? "❯ " : ">")
                .foregroundColor(Theme.isTerminal ? Theme.green : store.accent)
            ZStack(alignment: .leading) {
                if model.draft.isEmpty {
                    Text("詢問目前任務、優先順序或規劃建議…")
                        .font(Theme.mono).foregroundColor(Theme.dim.opacity(0.45))
                }
                TerminalInputField(
                    text: $model.draft,
                    onSubmit: { if model.canSend { send() } },
                    onCancel: { model.draft = "" }
                )
                .disabled(model.endpointIssue != nil || model.pendingReview != nil)
            }
            .frame(height: 22)
            if model.isSending {
                chatButton("取消", color: Theme.red) { model.cancel() }
            } else {
                chatButton("送出", color: Theme.green) { send() }
                    .disabled(!model.canSend)
                    .opacity(model.canSend ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Theme.panel)
    }

    private func send() {
        do {
            model.send(context: try store.agentChatContext())
        } catch {
            model.show(error: error)
        }
    }

    private func chatButton(_ title: LocalizedStringKey, color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Text("[") + Text(title) + Text("]") }
            .buttonStyle(.plain).font(Theme.monoSmall).foregroundColor(color)
            .padding(.horizontal, 4).padding(.vertical, 3).contentShape(Rectangle())
    }

    private static let historyDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}
