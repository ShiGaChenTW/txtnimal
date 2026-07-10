import SwiftUI
import TasksTxtCore

struct ContentView: View {
    @EnvironmentObject var store: TaskStore
    @State private var showingCapture = false
    @State private var captureText = ""
    @State private var showingAddProject = false
    @State private var projectText = ""
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                hline
                ScrollView { body(for: store.view).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
                hline
                if store.searchActive { searchBar; hline }
                if store.hasTags { tagBar; hline }
                statusBar
            }
            if store.focusMode { focusOverlay }   // 技法 B：純變暗
        }
        .frame(minWidth: 660, minHeight: 580)
        .font(Theme.mono).foregroundColor(Theme.fg)
        .onAppear {
            installMonitor()
            store.applyAppearance()
            FocusHUD.shared.update(store: store)
        }
        .onChange(of: store.focusIndex) { _ in FocusHUD.shared.update(store: store) }
        .onChange(of: store.focusMode) { _ in FocusHUD.shared.update(store: store) }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) } }
        .sheet(isPresented: $showingCapture, onDismiss: { captureText = "" }) { captureSheet }
        .sheet(isPresented: $showingAddProject, onDismiss: { projectText = "" }) { addProjectSheet }
    }

    private var hline: some View { Rectangle().fill(Theme.border).frame(height: 1) }

    // MARK: `/` 搜尋列

    @FocusState private var searchFocused: Bool
    private var searchBar: some View {
        HStack(spacing: 8) {
            Text("/").foregroundColor(Theme.blue)
            TextField("搜尋標題 / +project / @context…", text: $store.searchQuery)
                .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.fg)
                .focused($searchFocused)
                .onSubmit { searchFocused = false; store.ensureCursor() }   // ⏎ 保留篩選、回鍵盤流
                .onExitCommand { store.clearSearch() }
            if !store.searchQuery.isEmpty {
                Text("✕").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    .onTapGesture { store.clearSearch() }
            }
        }
        .font(Theme.mono)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.panel)
        .onAppear { searchFocused = true }
    }

    // MARK: 底部標籤列（全部 +project / @context，可點篩選）

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.allProjects(), id: \.self) { tagChip("+" + $0, Theme.mag) }
                ForEach(store.allContexts(), id: \.self) { tagChip("@" + $0, Theme.cyan) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Theme.panel)
    }
    private func tagChip(_ tag: String, _ color: Color) -> some View {
        let active = store.tagFilter == tag
        return Text(tag).font(Theme.monoSmall)
            .foregroundColor(active ? Theme.bg : color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Rectangle().fill(active ? color : color.opacity(0.13)))
            .contentShape(Rectangle())
            .onTapGesture { store.toggleTagFilter(tag) }
    }
    private func tagColor(_ f: String) -> Color { f.hasPrefix("@") ? Theme.cyan : Theme.mag }

    @ViewBuilder private func body(for v: AppView) -> some View {
        switch v {
        case .list: ListView()
        case .grid: QuadrantView()
        case .pad:  ScratchView()
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Text("~/Documents/tasks-txt/tasks.txt").font(Theme.monoSmall).foregroundColor(Theme.dim)
            Spacer()
            tab("⌘1 清單", .list); tab("⌘4 象限", .grid); tab("⌘3 便箋", .pad)
        }
        .padding(.horizontal, 14).padding(.vertical, 11).background(Theme.panel)
    }
    private func tab(_ label: String, _ v: AppView) -> some View {
        let on = store.view == v
        return Text(label).font(Theme.monoSmall)
            .foregroundColor(on ? Theme.fg : Theme.dim)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(on ? Theme.bg : .clear)
            .overlay(Rectangle().stroke(on ? Theme.border : .clear))
            .onTapGesture { store.view = v; store.ensureCursor() }
    }

    // MARK: status bar

    private var statusBar: some View {
        Group {
            if store.focusMode {
                Text("● Focus 模式 — 其他變暗;z / esc 離開").foregroundColor(Theme.focus)
            } else if let f = store.tagFilter {
                Text("篩選 \(f) — esc 清除").foregroundColor(tagColor(f))
            } else {
                Text(statusText).foregroundColor(Theme.dim)
            }
        }
        .font(Theme.monoSmall)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.panel)
    }
    private var statusText: String {
        switch store.view {
        case .list: return "↑↓ 移動   ⏎ 編輯   x 完成   f Focus   p +專案   n 新增   / 搜尋   ⌘4 象限"
        case .grid: return "1–4 指派   0 回池   f Focus   z 專注   ⌘1 清單"
        case .pad:  return "純文字便箋 · scratch.txt   ⌘1 回清單"
        }
    }

    // MARK: focus mode overlay (技法 B：純變暗，不模糊)

    private var focusOverlay: some View {
        ZStack {
            Theme.bg.opacity(0.9).ignoresSafeArea().onTapGesture { store.focusMode = false }
            if let i = store.focusIndex {
                let t = store.lines[i]
                VStack(alignment: .leading, spacing: 12) {
                    Text("▶ FOCUS · 現在只做這一件").font(Theme.monoSmall)
                        .foregroundColor(Theme.focus).tracking(1.5)
                    Text(t.title).font(Theme.monoBig).foregroundColor(Theme.fg)
                    HStack(spacing: 14) {
                        ForEach(t.projects, id: \.self) { p in Text("+\(p)").foregroundColor(Theme.mag) }
                        if let due = t.due, let r = RelativeDate.label(due) {
                            Text("\(due) · \(r.text)\(r.overdue ? " ⚠" : "")")
                                .foregroundColor(r.overdue ? Theme.red : Theme.dim)
                        }
                    }.font(Theme.monoSmall)
                    if let note = t.note {
                        Text("note:\"\(note)\"").font(Theme.monoSmall).foregroundColor(Theme.dim).italic()
                    }
                }
                .padding(22).frame(maxWidth: 440, alignment: .leading)
                .background(Theme.bg)
                .overlay(Rectangle().stroke(Theme.focus))
                .shadow(color: Theme.focusBg, radius: 8)
            }
        }
    }

    // MARK: capture

    private var captureSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CAPTURE — 快速捕捉").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.2)
            TextField("Call bank due:fri +personal", text: $captureText)
                .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced))
                .foregroundColor(Theme.fg)
                .onSubmit { commitCapture() }
            capturePreview
            HStack {
                Spacer()
                Button("取消") { showingCapture = false }
                Button("加入") { commitCapture() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 460).background(Theme.bg)
    }
    @ViewBuilder private var capturePreview: some View {
        let parts = captureText.split(separator: " ").map(String.init)
        let dueTok = parts.first { $0.hasPrefix("due:") }?.dropFirst(4)
        HStack(spacing: 12) {
            if let d = dueTok, let norm = DueDateParser.parse(String(d), today: Date()) {
                Text("due:\(norm)").foregroundColor(Theme.blue)
            }
            ForEach(parts.filter { $0.hasPrefix("+") && $0.count > 1 }, id: \.self) { Text($0).foregroundColor(Theme.mag) }
            ForEach(parts.filter { $0.hasPrefix("@") && $0.count > 1 }, id: \.self) { Text($0).foregroundColor(Theme.cyan) }
        }.font(Theme.monoSmall).frame(height: 16)
    }
    private func commitCapture() {
        store.addFromCapture(captureText); captureText = ""; showingCapture = false
    }

    private var addProjectSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("加入 +PROJECT 到選取任務").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.2)
            HStack(spacing: 8) {
                Text("+").foregroundColor(Theme.mag)
                TextField("marketing", text: $projectText)
                    .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced)).foregroundColor(Theme.fg)
                    .onSubmit { commitProject() }
            }
            HStack { Spacer()
                Button("取消") { showingAddProject = false }
                Button("加入") { commitProject() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 380).background(Theme.bg)
    }
    private func commitProject() {
        store.addProjectToCursor(projectText); projectText = ""; showingAddProject = false
    }

    // MARK: keyboard (macOS 13 無 onKeyPress，用 NSEvent local monitor)

    private func animatedDone() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { store.toggleDone() }
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in handle(e) }
    }
    private func handle(_ e: NSEvent) -> NSEvent? {
        if showingCapture || showingAddProject { return e }
        if NSApp.keyWindow?.firstResponder is NSTextView { return e }   // 便箋/捕捉輸入時放行
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        let chars = e.charactersIgnoringModifiers ?? ""
        if cmd {
            switch chars.lowercased() {
            case "1": store.view = .list; store.ensureCursor(); return nil
            case "4": store.view = .grid; store.ensureCursor(); return nil
            case "3": store.view = .pad; return nil
            case "b": showingCapture = true; return nil
            case "f" where shift: store.toggleFocus(); return nil
            case "f": store.searchActive = true; return nil
            case "t" where shift: store.cycleAppearance(); return nil
            case "\r": animatedDone(); return nil
            default: return e
            }
        }
        if store.focusMode {
            if chars == "z" || e.keyCode == 53 { store.focusMode = false }
            return nil
        }
        switch e.keyCode {
        case 126: store.move(-1); return nil     // ↑
        case 125: store.move(1); return nil      // ↓
        case 36:  store.startEditing(); return nil // ⏎ 行內編輯
        case 53:                                 // esc：搜尋 → 標籤篩選 → Focus,逐層清
            if store.searchActive { store.clearSearch() }
            else if store.tagFilter != nil { store.tagFilter = nil; store.ensureCursor() }
            else { store.clearFocus() }
            return nil
        default: break
        }
        switch chars {
        case "k": store.move(-1); return nil
        case "j": store.move(1); return nil
        case "e": store.startEditing(); return nil
        case "x", " ": animatedDone(); return nil
        case "f": store.toggleFocus(); return nil
        case "z": store.toggleFocusMode(); return nil
        case "n": showingCapture = true; return nil
        case "p": if store.cursor != nil { showingAddProject = true }; return nil
        case "/": store.searchActive = true; return nil
        case "R": store.rescheduleOverdue(); return nil
        case "[": store.cycleDensity(-1); return nil
        case "]": store.cycleDensity(1); return nil
        case "1", "2", "3", "4": if store.view == .grid { store.setQuadrant(Int(chars)); return nil }; return e
        case "0": if store.view == .grid { store.setQuadrant(nil); return nil }; return e
        default: return e
        }
    }
}
