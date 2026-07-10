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
                // 常駐於樹中,用高度 0↔自然高做滑動 — 底色跟內容一起動,不會先展開
                VStack(spacing: 0) { captureBar; hline }
                    .frame(height: showingCapture ? nil : 0, alignment: .bottom)
                    .clipped()
                ScrollView { body(for: store.view).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
                hline
                if store.searchActive { searchBar; hline }
                if store.hasTags { tagBar; hline }
                statusBar
            }
            if store.focusMode { focusOverlay }   // 技法 B：純變暗
            if showingPalette { paletteOverlay }  // ⌘K:條件掛載,不常駐樹中(焦點教訓)
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
        case .list: return "↑↓ 移動   ⏎ 編輯   x 完成   f Focus   p +專案   n 新增   / 搜尋   ⌘K 指令   ⌘4 象限"
        case .grid: return "1–4 指派   0 回池   f Focus   z 專注   ⌘K 指令   ⌘1 清單"
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

    @FocusState private var captureFocused: Bool
    private var captureBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(">").foregroundColor(Theme.green)
                TextField("", text: $captureText,
                          prompt: Text("寄出報價單 due:fri +business @mac")
                            .foregroundColor(Theme.dim.opacity(0.45)))
                    .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.fg)
                    .focused($captureFocused)
                    .disabled(!showingCapture)   // 常駐樹中:隱藏時不得成為 first responder,否則吞掉全部按鍵
                    .onSubmit { commitCapture() }
                    .onExitCommand { closeCapture() }
                Text("⌘⏎ 新增 · esc 取消").font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
            capturePreview
            CaptureHelp()
            // 無按鈕:⌘⏎ 由隱形按鈕承接
            Button("") { commitCapture() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(ZStack { Theme.bg; Theme.green.opacity(0.09) })   // 新增=綠,和 panel 灰區隔
        .overlay(Rectangle().fill(Theme.green).frame(width: 3), alignment: .leading)
    }
    private func openCapture() {
        withAnimation(.easeOut(duration: 0.2)) { showingCapture = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { captureFocused = true }
    }
    private func closeCapture() {
        captureText = ""
        captureFocused = false
        withAnimation(.easeOut(duration: 0.15)) { showingCapture = false }
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }   // 把鍵盤還給 handle()
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
        let t = captureText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { store.addFromCapture(t) }
        closeCapture()
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

    // MARK: ⌘K 指令面板(SPEC 7.5:模糊搜尋 + 快捷鍵教學)

    @State private var showingPalette = false
    @State private var paletteQuery = ""
    @State private var paletteSel = 0
    @FocusState private var paletteFocused: Bool

    private struct PaletteCmd {
        let name: String, alias: String, keys: String
        let run: () -> Void
    }
    private var paletteCommands: [PaletteCmd] {
        [
            .init(name: "完成 / 取消完成", alias: "done toggle", keys: "x", run: { animatedDone() }),
            .init(name: "行內編輯", alias: "edit", keys: "e", run: { store.startEditing() }),
            .init(name: "Focus 這一件", alias: "focus", keys: "f", run: { store.toggleFocus() }),
            .init(name: "專注模式", alias: "zen focus mode", keys: "z", run: { store.toggleFocusMode() }),
            .init(name: "新增捕捉", alias: "new capture add", keys: "n", run: { openCapture() }),
            .init(name: "加 +專案", alias: "project tag", keys: "p", run: { if store.cursor != nil { showingAddProject = true } }),
            .init(name: "搜尋", alias: "search find filter", keys: "/", run: { store.searchActive = true }),
            .init(name: "逾期全改今天", alias: "reschedule overdue today", keys: "R", run: { store.rescheduleOverdue() }),
            .init(name: "行距更緊", alias: "density compact tighter", keys: "[", run: { store.cycleDensity(-1) }),
            .init(name: "行距更鬆", alias: "density relaxed looser", keys: "]", run: { store.cycleDensity(1) }),
            .init(name: "清單視圖", alias: "list view", keys: "⌘1", run: { store.view = .list; store.ensureCursor() }),
            .init(name: "便箋", alias: "scratch pad notes", keys: "⌘3", run: { store.view = .pad }),
            .init(name: "象限視圖", alias: "quadrant grid matrix", keys: "⌘4", run: { store.view = .grid; store.ensureCursor() }),
            .init(name: "深 / 淺主題", alias: "theme dark light appearance", keys: "⌘⇧T", run: { store.cycleAppearance() }),
        ]
    }
    /// 子序列模糊比對:query 每字元依序出現於 target 即中
    private func fuzzy(_ query: String, _ target: String) -> Bool {
        var rest = Substring(query.lowercased())
        for ch in target.lowercased() where ch == rest.first { rest = rest.dropFirst() }
        return rest.isEmpty
    }
    private var filteredPalette: [PaletteCmd] {
        paletteCommands.filter { fuzzy(paletteQuery, $0.name + " " + $0.alias) }
    }
    private var paletteOverlay: some View {
        ZStack(alignment: .top) {
            Theme.bg.opacity(0.55).ignoresSafeArea().onTapGesture { closePalette() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("⌘K").font(Theme.monoSmall).foregroundColor(Theme.blue)
                    TextField("", text: $paletteQuery,
                              prompt: Text("輸入指令…").foregroundColor(Theme.dim.opacity(0.45)))
                        .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.fg)
                        .focused($paletteFocused)
                    Text("⏎ 執行 · esc 關閉").font(Theme.monoSmall).foregroundColor(Theme.dim)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                hline
                let cmds = filteredPalette
                if cmds.isEmpty {
                    Text("沒有符合的指令").font(Theme.monoSmall).foregroundColor(Theme.dim)
                        .padding(.vertical, 14)
                } else {
                    ForEach(Array(cmds.enumerated()), id: \.element.name) { i, cmd in
                        HStack {
                            Text(cmd.name)
                            Spacer()
                            Text(cmd.keys).foregroundColor(Theme.dim)
                        }
                        .font(Theme.mono)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(i == paletteSel ? Theme.selBg : .clear)
                        .overlay(alignment: .leading) {
                            if i == paletteSel { Rectangle().fill(Theme.blue).frame(width: 3) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { paletteSel = i; runPalette() }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(width: 440)
            .background(Theme.bg)
            .overlay(Rectangle().stroke(Theme.border))
            .shadow(color: .black.opacity(0.35), radius: 12)
            .padding(.top, 90)
            .onChange(of: paletteQuery) { _ in paletteSel = 0 }
        }
    }
    private func openPalette() {
        paletteQuery = ""; paletteSel = 0; showingPalette = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { paletteFocused = true }
    }
    private func closePalette() {
        showingPalette = false; paletteQuery = ""
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }   // 鍵盤還給 handle()
    }
    private func runPalette() {
        let cmds = filteredPalette
        guard cmds.indices.contains(paletteSel) else { closePalette(); return }
        let cmd = cmds[paletteSel]
        closePalette()
        DispatchQueue.main.async { cmd.run() }   // 面板收掉、焦點歸還後再執行
    }

    // MARK: keyboard (macOS 13 無 onKeyPress，用 NSEvent local monitor)

    private func animatedDone() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { store.toggleDone() }
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in handle(e) }
    }
    private func handle(_ e: NSEvent) -> NSEvent? {
        if showingPalette {
            switch e.keyCode {
            case 125: paletteSel = min(paletteSel + 1, max(0, filteredPalette.count - 1)); return nil  // ↓
            case 126: paletteSel = max(paletteSel - 1, 0); return nil                                  // ↑
            case 36:  runPalette(); return nil                                                          // ⏎
            case 53:  closePalette(); return nil                                                        // esc
            default:  return e   // 其餘給輸入框
            }
        }
        if showingCapture || showingAddProject { return e }
        if NSApp.keyWindow?.firstResponder is NSTextView { return e }   // 便箋/捕捉輸入時放行
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        let chars = e.charactersIgnoringModifiers ?? ""
        if cmd {
            switch chars.lowercased() {
            case "1": store.view = .list; store.ensureCursor(); return nil
            case "4": store.view = .grid; store.ensureCursor(); return nil
            case "3": store.view = .pad; return nil
            case "b": openCapture(); return nil
            case "k": openPalette(); return nil
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
        case "n": openCapture(); return nil
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
