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

/// 完成一筆重複任務、引擎真的生出後繼時的回饋管道。
/// 帶的是 `recurringSuccessor` 實際回傳的那一筆,顯示端只讀它的 due,不重算日期。
struct RecurrenceAnnouncer {
    var announce: (TaskLine) -> Void = { _ in }
}

private struct RecurrenceAnnouncerKey: EnvironmentKey {
    static let defaultValue = RecurrenceAnnouncer()
}

extension EnvironmentValues {
    var recurrenceAnnouncer: RecurrenceAnnouncer {
        get { self[RecurrenceAnnouncerKey.self] }
        set { self[RecurrenceAnnouncerKey.self] = newValue }
    }
}

/// 完成任務,並在引擎確實追加了後繼任務時發出回饋。
///
/// 後繼由 `recurringSuccessor` 產生 —— 與 `TaskWorkspace.toggleDone` 同一支、同一個
/// completionYMD,所以回饋裡的日期就是實際寫進檔案的那一筆,不是另外算的。
/// 只在 open → done 的方向判斷(取消完成不生後繼),且要求行數真的增加,
/// 這樣 stale handle 之類讓 toggle 失敗的情況不會誤報。
func completeAnnouncingRecurrence(
    _ task: TaskLine,
    in store: TaskStore,
    announcer: RecurrenceAnnouncer,
    complete: () -> Void
) {
    let successor = task.isDone ? nil : task.recurringSuccessor(completionYMD: store.todayYMD)
    let countBefore = store.lines.count
    complete()
    guard let successor, store.lines.count > countBefore else { return }
    announcer.announce(successor)
}

/// 重複徽章 —— 清單列與象限列共用。
/// 只有 `rec:` 值能被 `RecurrenceRule.parse` 解析時才出現;無效值不顯示徽章,
/// 也不顯示錯誤、不改寫該行文字(渲染層從不回寫 raw)。
struct RecurrenceBadge: View {
    let task: TaskLine

    var body: some View {
        if let label = CaptureAssist.recurrenceLabel(inRawLine: task.raw) {
            Text("↻ \(label)")
                .font(Theme.monoSmall)
                .foregroundColor(Theme.yellow)
                .help("重複任務：\(label)")
        }
    }
}

// MARK: - ⌘1 主清單

struct ListView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.isSidebarPanel) private var isSidebarPanel
    @State private var addText = ""
    @State private var addVisible = false
    @State private var showingListEditor = false
    @State private var editingListOriginal: String?
    @State private var listName = ""
    @State private var listDescription = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        // 左導覽欄固定、只有右欄捲動 —— 所以捲動框在這裡,不在 ContentView 外層。
        HStack(spacing: 0) {
            if showsRail {
                ListNavigationRail()
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            ScrollView { taskColumn.frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store.requestInlineAdd) { req in   // n 鍵:顯示並聚焦輸入列,游標移到此
            if req { activateInlineAdd() }
        }
        .onChange(of: store.requestNewList) { req in    // l 鍵:開「新增 List」視窗
            if req { activateNewList() }
        }
        // 從其他頁切回清單時，request 可能在 ListView 掛載前已變成 true；
        // onChange 不會對初始值觸發，所以掛載時也必須消費一次。
        .onAppear {
            if store.requestInlineAdd { activateInlineAdd() }
            if store.requestNewList { activateNewList() }
        }
        .onDisappear { store.inlineAddActive = false; store.listEditorActive = false }
        .sheet(isPresented: $showingListEditor, onDismiss: { store.listEditorActive = false }) { listEditor }
    }

    /// 側邊面板模式最窄只有 100pt,塞不下導覽欄;一個 list 都還沒有時它也只是一格空裝飾。
    /// `s` 鍵(`listRailVisible`)是使用者的明示意願,擺在最後 —— 前兩個條件是「放不下 / 沒東西放」,
    /// 這個是「我不想看」,三者任一成立都不顯示。
    private var showsRail: Bool {
        !isSidebarPanel && !store.allProjects().isEmpty && store.listRailVisible
    }

    private var taskColumn: some View {
        let g = store.groups()
        return VStack(alignment: .leading, spacing: 0) {
            if selectedList != nil { listInfoBar }
            if let i = store.focusIndex { focusBar(store.lines[i]) }
            section("Today", g.today, group: "today", color: store.accent)    // 當下=強調色(設定頁可換)
            overdueSection(g.overdue)                                          // 逾期=紅(獨佔)
            section("Upcoming", g.upcoming, group: "up", color: Theme.yellow) // 未來=黃(呼應 q2 Schedule)
            // No date 區塊 + 尾端新增列;帶 due: 的新任務由重新分組自動跳到對應區塊
            if !g.noDate.isEmpty { sectionHeader("No date", g.noDate.count, color: Theme.dim, neutral: true) }
            ForEach(g.noDate, id: \.self) { rowOrEdit($0, "nd") }
            if addVisible { addRow }   // 預設隱藏,按 n 才出現
            section("Done", g.done, group: "done", color: Theme.green)        // 完成=綠(色彩契約)
        }
        .padding(.top, 4).padding(.bottom, 14)
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
        store.listEditorActive = true
    }

    /// `l` 走的是「新增」語意:即使目前正篩著某個 +list,也開空白表單,
    /// 否則按 l 會變成在編輯那個既有 list — 與指令名稱不符。
    private func activateNewList() {
        editingListOriginal = nil
        listName = ""
        listDescription = ""
        showingListEditor = true
        store.listEditorActive = true
        store.requestNewList = false
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
                    TerminalInputField(text: $addText, onSubmit: submitInlineAdd, onCancel: closeInlineAdd,
                                       onFocusChange: { focused in
                                           store.inlineAddActive = focused
                                           if !focused { store.ensureCursor() }   // 新增列會把 cursor 清成 nil
                                       })
                        .frame(height: 20)
                }
            } else {
                Text("+").foregroundColor(Theme.green)
                TextField("", text: $addText,
                          prompt: Text("新增任務…  due:fri  +List  @Tag").foregroundColor(Theme.dim.opacity(0.35)))
                    .textFieldStyle(.plain).font(store.taskFont).foregroundColor(Theme.fg)
                    .focused($addFocused)
                    // 焦點是唯一真相。原本只有 esc（closeInlineAdd）與 ListView 消失會清掉
                    // inlineAddActive，使用者若改用滑鼠點走，旗標會永遠停在 true，
                    // ContentView 的鍵盤守門就一路吃掉所有快捷鍵。改成跟著焦點兩邊同步：
                    // submitInlineAdd 送出後會 addFocused = true，連打流程照舊不受影響。
                    .onChange(of: addFocused) { focused in
                        store.inlineAddActive = focused
                        if !focused { store.ensureCursor() }   // 新增列會把 cursor 清成 nil，交還鍵盤前補回
                    }
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

// MARK: - ⌘1 左側 List 導覽欄

/// 清單頁左欄:一列 All tasks + 每個 List 一列,各自帶 done/total。
///
/// **純導覽層。** 點一列只是換 `store.tagFilter`,實際篩選仍走 `TaskStore.matches`
/// 那條唯一路徑 —— 這裡不自己過濾任何東西,也不新增任何持久化狀態。
/// 名稱來源 `allProjects()` 已含只存在於 List metadata、零任務的清單。
struct ListNavigationRail: View {
    @EnvironmentObject var store: TaskStore

    /// 視窗 `minWidth` 直接讀這個值(見 `ContentView.windowMinWidth`),改這裡那邊會自己跟上。
    static let width: CGFloat = 172

    var body: some View {
        let lists = store.allProjects()
        // 單趟掃完全部計數;每次重繪重算,不做快取 —— 個人任務清單的量級下這比維護
        // 快取失效規則便宜得多,也不會有「數字沒跟上編輯」這類 bug。
        let tallies = ListTallying.tally(store.lines, lists: lists)
        return VStack(alignment: .leading, spacing: 0) {
            Text("LIST").font(Theme.monoSmall).foregroundColor(Theme.mag.opacity(0.75))
                .tracking(1)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // All tasks 用強調色而非 mag:它不是一個 +List token,不該假裝是。
                    row("All tasks", tallies.all, color: store.accent, selected: store.tagFilter == nil) {
                        store.tagFilter = nil
                    }
                    ForEach(lists, id: \.self) { name in
                        row("+" + name, tallies[name], color: Theme.mag,
                            selected: store.tagFilter == "+" + name) {
                            store.tagFilter = "+" + name
                        }
                    }
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    /// 選中的一列刻意**不**做 toggle:導覽欄自己有 All tasks 那一列可以清篩選,
    /// 再讓「點已選中的列」等於取消,會出現點一下高亮就跳走的怪行為。
    private func row(_ title: String, _ tally: ListTally, color: Color,
                     selected: Bool, activate: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(store.tagFont)
                .foregroundColor(color.opacity(selected ? 1 : 0.8))
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            // 名稱可以被截斷,數字不行 —— 數字是這一列存在的理由。
            Text(tally.label)
                .font(Theme.monoSmall)
                .foregroundColor(selected ? Theme.fg : Theme.dim)
                .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, store.density.rowPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? color.opacity(0.14) : Color.clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(color).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            activate()
            store.ensureCursor()   // 可見集合換了,游標必須落回還看得到的一列
        }
        .help("\(title)：\(tally.done)/\(tally.total) 已完成")
    }
}

// MARK: - 單列

struct RowView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.taskContextActions) private var contextActions
    @Environment(\.recurrenceAnnouncer) private var recurrenceAnnouncer
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
            RecurrenceBadge(task: t)
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
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                completeAnnouncingRecurrence(t, in: store, announcer: recurrenceAnnouncer) { store.toggleDone() }
            }
        }
        .onTapGesture { store.cursor = index }
        .background {
            ThemedTaskContextMenuPresenter(handle: store.handle(for: index), task: t,
                                           actions: contextActions, announcer: recurrenceAnnouncer,
                                           store: store)
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
    private let compact: Bool

    init(index: Int, initial: String, compact: Bool = false) {
        self.index = index
        _draft = State(initialValue: initial)
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: compact ? 7 : 10) {
            Text("[ ]").foregroundColor(Theme.dim)
            TextField("", text: $draft)
                .textFieldStyle(.plain).font(compact ? store.taskFont : Theme.mono).foregroundColor(Theme.fg)
                .focused($focused)
                .onSubmit { store.updateTitle(index, draft) }
                .onExitCommand { store.editingIndex = nil }
        }
        .padding(.horizontal, compact ? 4 : 16).padding(.vertical, compact ? 2 : store.density.rowPad)
        .background(Theme.selBg)
        .overlay(alignment: .leading) {
            if !compact { Rectangle().fill(Theme.blue).frame(width: 3) }
        }
        .onAppear { focused = true }
    }
}

// MARK: - ⌘2 四象限（v1：鍵盤 1–4 指派;拖拉為 v2）

struct QuadrantView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.taskContextActions) private var contextActions
    @Environment(\.recurrenceAnnouncer) private var recurrenceAnnouncer
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
            if store.editingIndex == i {
                // 編輯中的那一列換成輸入框:點擊 / 拖曳 / 右鍵選單這時候都不該再攔按鍵。
                EditRow(index: i, initial: t.title, compact: true)
            } else {
                HStack(spacing: 7) {
                    Text("[ ]").foregroundColor(Theme.dim)
                    Text(t.title).foregroundColor(t.isFocused ? Theme.focus : Theme.fg).lineLimit(1)
                        .font(store.taskFont)
                    RecurrenceBadge(task: t)
                }
                .font(Theme.mono).padding(.horizontal, 4).padding(.vertical, 2)
                .background(store.cursor == i ? Theme.selBg : .clear)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    store.cursor = i
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                        completeAnnouncingRecurrence(t, in: store, announcer: recurrenceAnnouncer) { store.toggleDone() }
                    }
                }
                .onTapGesture { store.cursor = i }
                .onDrag { NSItemProvider(object: store.dragPayload(for: i) as NSString) }
                .background {
                    ThemedTaskContextMenuPresenter(handle: store.handle(for: i), task: t,
                                                   actions: contextActions, announcer: recurrenceAnnouncer,
                                                   store: store)
                }
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
    // NSHostingController 會開一棵新的 SwiftUI 樹,@Environment 不會跨過去,
    // 所以回饋管道跟 actions 一樣用明傳的方式帶進 popover。
    let announcer: RecurrenceAnnouncer
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
                             actions: actions, announcer: announcer, store: store)
        }
    }

    final class Coordinator {
        private var popover: NSPopover?

        func show(from view: NSView, point: NSPoint, handle: TaskHandle, task: TaskLine,
                  actions: TaskContextActions, announcer: RecurrenceAnnouncer, store: TaskStore) {
            popover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            let menu = ThemedTaskContextMenu(
                handle: handle, task: task, actions: actions, announcer: announcer,
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
    let announcer: RecurrenceAnnouncer
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
                    completeAnnouncingRecurrence(task, in: store, announcer: announcer) {
                        store.toggleDone(using: handle)
                    }
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
    @EnvironmentObject var store: TaskStore

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
        // 對話紀錄跟著目前資料夾走:換資料夾/任務檔就換 ChatStore,不再寫死預設目錄。
        .onAppear { chatModel.syncDirectory(store.dataDirPath) }
        .onChange(of: store.dataDirPath) { chatModel.syncDirectory($0) }
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
        case .review(let items):
            reviewView(items)
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
                        onCancel: { prompt = "" },
                        onFocusChange: { _ in }
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

    private func reviewView(_ items: [AgentReviewItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("檢查提議變更").foregroundColor(Theme.fg)
                Spacer()
                Text("\(items.count) CHANGES").font(Theme.monoSmall).foregroundColor(Theme.yellow)
            }
            Text("只有按下「套用」才會寫入 tasks.txt。")
                .font(Theme.monoSmall).foregroundColor(Theme.dim)

            if items.isEmpty {
                Text("沒有可審核的提議。")
                    .foregroundColor(Theme.dim)
                    .padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).foregroundColor(Theme.fg)
                                HStack(spacing: 8) {
                                    Text(item.oldDue ?? "—").foregroundColor(Theme.dim)
                                    Text("→").foregroundColor(Theme.yellow)
                                    Text(item.newDue).foregroundColor(Theme.green)
                                    Spacer()
                                    Text(item.taskID).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.7))
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            Button(action: { store.removeAgentReviewChange(id: item.id) }) {
                                Text("✕").foregroundColor(Theme.red)
                            }
                            .buttonStyle(.plain)
                            .help("移除這筆")
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
                    .disabled(items.isEmpty)
                    .opacity(items.isEmpty ? 0.4 : 1)
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
            PluginReportsList()
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
                    errorMessage = PluginPageExport.readableMessage(for: error)
                }
            }
        }
    }

    private func exportReport() {
        guard let report else {
            errorMessage = "請先產生報表。"
            return
        }
        switch PluginPageExport.saveMarkdown(report, reportType: templateID) {
        case .cancelled: break
        case .saved: errorMessage = nil
        case .failed(let message): errorMessage = message
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

    private var chatStore: ChatStore
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

    /// 對話紀錄目錄與目前任務檔資料夾同步;切換時重載該資料夾的歷史。
    func syncDirectory(_ path: String) {
        let dir = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard dir != chatStore.directory else { return }
        cancel()
        pendingReview = nil
        chatStore = ChatStore(directory: dir)
        conversations = []
        current = nil
        reloadHistory()
        if current == nil { startNewConversation() }
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
                    onCancel: { model.draft = "" },
                    onFocusChange: { _ in }
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
