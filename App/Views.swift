import SwiftUI
import txtnimalCore
import UniformTypeIdentifiers

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

// MARK: - ⌘3 Agent

struct AgentView: View {
    @EnvironmentObject var store: TaskStore
    @State private var prompt = ""

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
