import SwiftUI
import TasksTxtCore
import UniformTypeIdentifiers

// MARK: - ⌘1 主清單

struct ListView: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        let g = store.groups()
        VStack(alignment: .leading, spacing: 0) {
            if let i = store.focusIndex { focusBar(store.lines[i]) }
            section("Today", g.today, group: "today")
            overdueSection(g.overdue)
            section("Upcoming", g.upcoming, group: "up")
            section("No date", g.noDate, group: "nd")
            section("Done", g.done, group: "done")
            if store.listOrder().isEmpty {
                Text("沒有任務").font(Theme.monoSmall).foregroundColor(Theme.dim).padding(20)
            }
        }
        .padding(.top, 4).padding(.bottom, 14)
    }

    private func focusBar(_ t: TaskLine) -> some View {
        HStack(spacing: 10) {
            Text("▶ FOCUS").font(Theme.monoSmall)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.focus))
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

    @ViewBuilder private func section(_ title: String, _ idx: [Int], group: String) -> some View {
        if !idx.isEmpty {
            sectionHeader(title, idx.count, red: false)
            ForEach(idx, id: \.self) { rowOrEdit($0, group) }
        }
    }

    @ViewBuilder private func rowOrEdit(_ i: Int, _ group: String) -> some View {
        if store.editingIndex == i { EditRow(index: i, initial: store.lines[i].title) }
        else { RowView(index: i, group: group) }
    }

    @ViewBuilder private func overdueSection(_ idx: [Int]) -> some View {
        if !idx.isEmpty {
            HStack(spacing: 8) {
                Text("Overdue").foregroundColor(Theme.red)
                Text("\(idx.count)").foregroundColor(Theme.dim)
                Text(store.overdueOpen ? "▾" : "▸ 收合中").foregroundColor(Theme.dim)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            .font(Theme.monoSmall).tracking(1)
            .padding(.horizontal, 16).padding(.top, store.density.sectionTop).padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { store.overdueOpen.toggle(); store.ensureCursor() }
            if store.overdueOpen {
                ForEach(idx, id: \.self) { rowOrEdit($0, "overdue") }
            }
        }
    }

    private func sectionHeader(_ title: String, _ count: Int, red: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(red ? Theme.red : Theme.dim)
            Text("\(count)").foregroundColor(Theme.dim)
            Rectangle().fill(Theme.border).frame(height: 1)
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

    var body: some View {
        let t = store.lines[index]
        let isCursor = store.cursor == index
        HStack(spacing: 10) {
            Text(t.isDone ? "[✓]" : "[ ]").foregroundColor(t.isDone ? Theme.green : Theme.dim)
            Text(t.title)
                .foregroundColor(t.isFocused ? Theme.focus : (t.isDone ? Theme.dim : Theme.fg))
                .fontWeight(t.isFocused ? .semibold : .regular)
                .strikethrough(t.isDone, color: Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 8)
            ForEach(t.projects, id: \.self) { p in
                Text("+\(p)").foregroundColor(Theme.mag)
                    .onTapGesture { store.toggleTagFilter("+" + p) }
            }
            ForEach(t.contexts, id: \.self) { c in
                Text("@\(c)").foregroundColor(Theme.cyan)
                    .onTapGesture { store.toggleTagFilter("@" + c) }
            }
            if let note = t.note { Text("note:\"\(note)\"").foregroundColor(Theme.dim).lineLimit(1) }
            dueBadge(t)
        }
        .font(Theme.mono)
        .padding(.horizontal, 16).padding(.vertical, store.density.rowPad)
        .background(isCursor ? Theme.selBg : (t.isFocused ? Theme.focusBg : .clear))
        .overlay(alignment: .leading) {
            if isCursor { Rectangle().fill(t.isFocused ? Theme.focus : Theme.blue).frame(width: 3) }
            else if t.isFocused { Rectangle().fill(Theme.focus).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.cursor = index
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { store.toggleDone() }
        }
        .onTapGesture { store.cursor = index }
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
            Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                GridRow { cell(meta[0], indices(b, 1)); cell(meta[1], indices(b, 2)) }
                GridRow { cell(meta[2], indices(b, 3)); cell(meta[3], indices(b, 4)) }
            }
            .background(Theme.border).padding(.horizontal, 14)
            poolView(b.unplaced)
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
            ForEach(idx, id: \.self) { qRow($0) }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(11)
        .background(ZStack { Theme.bg; m.3.opacity(0.13) })   // 各象限不同底色，低透明度保持 TUI
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { handleDrop($0, q: m.0) }
    }

    private func handleDrop(_ providers: [NSItemProvider], q: Int?) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            if let s = obj as? String, let idx = Int(s) {
                DispatchQueue.main.async { store.setQuadrantAt(idx, q); store.cursor = idx }
            }
        }
        return true
    }

    private func qRow(_ i: Int) -> some View {
        let t = store.lines[i]
        return HStack(spacing: 7) {
            Text("[ ]").foregroundColor(Theme.dim)
            Text(t.title).foregroundColor(t.isFocused ? Theme.focus : Theme.fg).lineLimit(1)
        }
        .font(Theme.mono).padding(.horizontal, 4).padding(.vertical, 2)
        .background(store.cursor == i ? Theme.selBg : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            store.cursor = i
            withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { store.toggleDone() }
        }
        .onTapGesture { store.cursor = i }
        .onDrag { NSItemProvider(object: String(i) as NSString) }
    }

    private func poolView(_ idx: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("未歸位池 — 選取後按 1–4 指派").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1)
            if idx.isEmpty { Text("（空）").font(Theme.monoSmall).foregroundColor(Theme.dim) }
            ForEach(idx, id: \.self) { qRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).padding(.horizontal, 4)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, style: StrokeStyle(dash: [4])))
        .contentShape(Rectangle())
        .onDrop(of: [.text], isTargeted: nil) { handleDrop($0, q: nil) }
        .padding(14)
    }
}

// MARK: - ⌘3 便箋

struct ScratchView: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        TextEditor(text: Binding(get: { store.scratch }, set: { store.scratch = $0; store.saveScratch() }))
            .font(Theme.mono).foregroundColor(Theme.fg)
            .scrollContentBackground(.hidden)
            .padding(10).frame(minHeight: 380)
    }
}
