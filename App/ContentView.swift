import SwiftUI
import txtnimalCore

struct ContentView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.isSidebarPanel) private var isSidebarPanel
    @State private var showingCapture = false
    @State private var captureText = ""
    @State private var showingAddProject = false
    @State private var projectText = ""
    @State private var monitor: Any?
    @State private var hostWindow: NSWindow?

    var body: some View {
        ZStack {
            // 側邊模式讓根背景層透明,露出面板後方的毛玻璃;一般視窗維持不透明。
            Theme.bg.opacity(isSidebarPanel ? store.sidebarOpacity : 1).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                hline
                // 象限頁滿版(上下 50/50)、統計頁滿版垂直置中,其餘視圖走捲動
                if store.view == .grid {
                    QuadrantView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.view == .dash {
                    DashboardView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { body(for: store.view).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: .infinity)
                }
                hline
                if store.searchActive { searchBar; hline }
                if store.hasTags { tagBar; hline }
                // vim 式：捕捉命令列與狀態列同槽互換 — 開啟時零高度變化、輸入永遠在底部
                if showingCapture { captureBar } else { statusBar }
            }
            if store.focusMode { focusOverlay }   // 技法 B：純變暗
            if showingPalette { paletteOverlay }  // ⌘K:條件掛載,不常駐樹中(焦點教訓)
            if isSidebarPanel { sidebarInnerEdge }  // 內緣外框 + 柔和陰影
        }
        .frame(minWidth: 660, minHeight: 580)
        .background(WindowAccessor { hostWindow = $0 })
        .font(Theme.mono).foregroundColor(Theme.fg)
        .environment(\.locale, store.appLanguage.locale)
        .onAppear {
            installMonitor()
            store.applyAppearance()
            store.applyAppIcon()
            FocusHUD.shared.update(store: store)
        }
        .onChange(of: store.focusIndex) { _ in FocusHUD.shared.update(store: store) }
        .onChange(of: store.focusMode) { _ in FocusHUD.shared.update(store: store) }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) } }
        .sheet(isPresented: $showingAddProject, onDismiss: { projectText = "" }) { addProjectSheet }
        .sheet(isPresented: $showingEdit) { editSheet }
        .sheet(isPresented: Binding(
            get: { !store.hasCompletedOnboarding },
            set: { _ in }
        )) { WelcomeView().environmentObject(store).interactiveDismissDisabled() }
        .alert("檔案操作失敗", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) { Button("好") { store.lastError = nil } } message: {
            Text(store.lastError ?? "未知錯誤")
        }
    }

    private var hline: some View { Rectangle().fill(Theme.border).frame(height: 1) }

    // MARK: `/` 搜尋列

    @FocusState private var searchFocused: Bool
    private var searchBar: some View {
        HStack(spacing: 8) {
            Text(Theme.isTerminal ? "find >" : "/").foregroundColor(Theme.isTerminal ? Theme.green : store.accent)
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
        VStack(alignment: .leading, spacing: 7) {
            if !store.allProjects().isEmpty {
                FlowLayout(spacing: 8) {
                    tagGroupLabel("LIST", Theme.mag)
                    ForEach(store.allProjects(), id: \.self) { tagChip("+" + $0, Theme.mag) }
                }
            }
            if !store.allContexts().isEmpty {
                FlowLayout(spacing: 8) {
                    tagGroupLabel("TAG", Theme.cyan)
                    ForEach(store.allContexts(), id: \.self) { tagChip("@" + $0, Theme.cyan) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.panel)
    }
    private func tagGroupLabel(_ label: String, _ color: Color) -> some View {
        Text(label).font(Theme.monoSmall).foregroundColor(color.opacity(0.75))
            .frame(minWidth: 38, alignment: .leading)
    }
    private func tagChip(_ tag: String, _ color: Color) -> some View {
        let active = store.tagFilter == tag
        return Text(tag).font(store.tagFont)
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
        case .dash: DashboardView()
        case .settings: SettingsView()
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            if !Theme.isTerminal {
                Image(nsImage: headerAppIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
            }
            Group {
                if Theme.isTerminal {
                    Text("●").foregroundColor(Theme.green).accessibilityHidden(true)
                    Text("txtnimal").foregroundColor(Theme.fg).fontWeight(.semibold)
                    Text("//").foregroundColor(Theme.dim)
                    Text(store.fileURL.lastPathComponent).foregroundColor(Theme.fg)
                    if let filter = store.tagFilter {
                        Text(filter).foregroundColor(tagColor(filter))
                    }
                } else {
                    Text((store.fileURL.path as NSString).abbreviatingWithTildeInPath)
                        .foregroundColor(Theme.dim)
                }
            }
                .font(Theme.monoSmall)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            tab("⌘1 清單", .list); tab("⌘2 象限", .grid); tab("⌘3 便箋", .pad); tab("⌘4 統計", .dash)
            tab("⌘5 設定", .settings)
        }
        .padding(.horizontal, 14).padding(.vertical, 11).background(Theme.panel)
    }
    private var headerAppIcon: NSImage {
        store.appIconStyle.image() ?? AppIconStyle.flatGeometric.image() ?? NSApp.applicationIconImage
    }
    private func tab(_ label: String, _ v: AppView) -> some View {
        let on = store.view == v
        let localized = Text(LocalizedStringKey(label))
        let rendered = Theme.isTerminal ? Text("[") + localized + Text("]") : localized
        return rendered.font(Theme.monoSmall)
            .foregroundColor(on ? (Theme.isTerminal ? Theme.green : Theme.fg) : Theme.dim)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(on ? (Theme.isTerminal ? Theme.green.opacity(0.08) : Theme.bg) : .clear)
            .overlay(Rectangle().stroke(on ? (Theme.isTerminal ? Theme.green.opacity(0.45) : Theme.border) : .clear))
            .onTapGesture { store.view = v; store.ensureCursor() }
    }

    // MARK: status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if Theme.isTerminal {
                Text("NORMAL").foregroundColor(Theme.bg)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.green)
                Text("file:").foregroundColor(Theme.dim)
                Text(store.fileURL.lastPathComponent).foregroundColor(Theme.fg)
                Text("open:").foregroundColor(Theme.dim)
                Text("\(store.lines.filter { !$0.isDone }.count)").foregroundColor(Theme.cyan)
                Text("|").foregroundColor(Theme.border)
            }
            Group {
            if store.focusMode {
                Text("● Focus 模式 — 其他變暗；z / esc 離開").foregroundColor(Theme.focus)
            } else if let f = store.tagFilter {
                Text(store.appLanguage == .english ? "Filter \(f) — esc to clear" : "篩選 \(f) — esc 清除")
                    .foregroundColor(tagColor(f))
            } else {
                Text(statusText).foregroundColor(Theme.dim)
            }
            }
        }
        .font(Theme.monoSmall)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)   // 高度加倍,文字垂直置中
        .padding(.horizontal, 16).background(Theme.panel)
    }
    private var statusText: String {
        if store.appLanguage == .english {
            switch store.view {
            case .list: return "↑↓ Move   ⌘E Edit   x Done   f Focus   n Add   / Search   ⌘K Commands"
            case .grid: return "1–4 Assign   0 Unassign   f Focus   z Zen   ⌘K Commands   ⌘1 List"
            case .pad: return "Plain-text scratchpad · scratch.txt   ⌘1 Back to list"
            case .dash: return "Read-only stats · calculated from done: dates   esc / ⌘1 Back to list"
            case .settings: return "Settings · applied instantly   esc / ⌘1 Back to list"
            }
        }
        switch store.view {
        case .list: return "↑↓ 移動   ⌘E 編輯   x 完成   f Focus   n 新增   / 搜尋   ⌘K 指令"
        case .grid: return "1–4 指派   0 回池   f Focus   z 專注   ⌘K 指令   ⌘1 清單"
        case .pad:  return "純文字便箋 · scratch.txt   ⌘1 回清單"
        case .dash: return "唯讀統計 · 依 done: 日期計算   esc / ⌘1 回清單"
        case .settings: return "設定 · 即時生效   esc / ⌘1 回清單"
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
                    Text(t.title).font(.system(size: max(22, store.taskTextSize + 8), weight: .bold, design: .monospaced)).foregroundColor(Theme.fg)
                    HStack(spacing: 14) {
                        ForEach(t.projects, id: \.self) { p in Text("+\(p)").font(store.tagFont).foregroundColor(Theme.mag) }
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
        HStack(spacing: Theme.isTerminal ? 0 : 8) {
            if Theme.isTerminal {
                Text("\(store.fileURL.lastPathComponent) ")
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.dim)
                Text("❯ ")
                    .foregroundColor(Theme.green)
                    .fontWeight(.bold)
                ZStack(alignment: .leading) {
                    if captureText.isEmpty {
                        Text("輸入任務指令  due:fri  +List  @Tag")
                            .foregroundColor(Theme.dim.opacity(0.62))
                    }
                    TerminalInputField(text: $captureText, onSubmit: commitCapture, onCancel: closeCapture)
                        .frame(height: 20)
                }
            } else {
                Text(">").foregroundColor(Theme.green)
                // 行內上色：彩色 Text 墊底、透明字 TextField 疊上 — 等寬字體讓兩層逐字對齊
                ZStack(alignment: .leading) {
                    if captureText.isEmpty {
                        Text("新任務…  due:fri  +List  @Tag")
                            .foregroundColor(Theme.dim.opacity(0.3))
                    }
                    colorized(captureText)
                    TextField("", text: $captureText)
                        .textFieldStyle(.plain).foregroundColor(.clear).tint(Theme.green)
                        .focused($captureFocused)
                        .onSubmit { commitCapture() }
                        .onExitCommand { closeCapture() }
                }
            }
            if !Theme.isTerminal {
                Text("⏎ 新增 · esc 取消").font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
        }
        .font(Theme.mono)
        .frame(minHeight: 40)                              // 與 statusBar 同高,互換零跳動
        .padding(.horizontal, 16)
        .background(Theme.isTerminal ? Theme.bg : Theme.panel)
        .overlay(alignment: .leading) {
            if !Theme.isTerminal { Rectangle().fill(Theme.green).frame(width: 3) }
        }
    }
    /// 逐 token 上色,以空格切分後原樣重組 — 與 TextField 內容位元組級一致才能對齊
    private func colorized(_ s: String) -> Text {
        let parts = s.components(separatedBy: " ")
        var out = Text("")
        for (i, p) in parts.enumerated() {
            let piece = Text(p).foregroundColor(tokenColor(p))
            out = i == 0 ? piece : out + Text(" ") + piece
        }
        return out
    }
    private func tokenColor(_ p: String) -> Color {
        // due: 只在可解析時變藍 — 上色本身就是即時驗證回饋
        if p.hasPrefix("due:") { return DueDateParser.parse(String(p.dropFirst(4)), today: Date()) != nil ? Theme.blue : Theme.fg }
        if p.hasPrefix("+"), p.count > 1 { return Theme.mag }
        if p.hasPrefix("@"), p.count > 1 { return Theme.cyan }
        if p.hasPrefix("note:") { return Theme.dim }
        return Theme.fg
    }
    private func openCapture() {
        showingCapture = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { captureFocused = true }
    }
    private func closeCapture() {
        captureText = ""
        captureFocused = false
        showingCapture = false
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }   // 把鍵盤還給 handle()
    }
    private func commitCapture() {
        let t = captureText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { store.addFromCapture(t) }
        closeCapture()
    }

    // MARK: ⌘E 編輯彈窗（標題 / 到期+專案 / 便箋）

    @State private var showingEdit = false
    @State private var editIndex: Int? = nil
    @State private var editTitle = ""
    @State private var editDue = ""
    @State private var editProjects = ""
    @State private var editContexts = ""
    @State private var editNote = ""
    @FocusState private var editTitleFocused: Bool
    // 下拉層:游標在欄位時按 ↓ 展開。
    // @FocusState 在 sheet 內的 .plain TextField 上不可靠(前兩次失敗主因),
    // 改用點擊記錄「目前欄位」— simultaneousGesture 連點在文字區也收得到。
    @State private var editField = 0        // 0 無 / 1 到期 / 2 專案 / 3 情境
    @State private var showDatePicker = false
    @State private var showProjectMenu = false
    @State private var showContextMenu = false
    @State private var calMonth = Date()
    @FocusState private var editDueFocused: Bool
    @FocusState private var editProjectsFocused: Bool
    @FocusState private var editContextsFocused: Bool

    /// 下拉層外框:方角 + 邊線 + 陰影,浮在欄位下方
    private func dropdownPanel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .background(Theme.bg)
            .overlay(Rectangle().stroke(Theme.border))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
    }

    /// TUI 風日曆:等寬數字格、方角、終端色票 — 取代系統 DatePicker 的圓角膠囊感
    private var datePickerPopover: some View {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month], from: calMonth)
        let first = cal.date(from: comps)!
        let lead = (cal.component(.weekday, from: first) + 5) % 7          // 週一=0
        let days = cal.range(of: .day, in: .month, for: first)!.count
        let selected = RelativeDate.parse(editDue).map { RelativeDate.todayYMD($0) }
        return VStack(spacing: 6) {
            // 不用 Spacer():會把面板撐到父容器滿寬(先前破圖主因),改固定間距
            HStack(spacing: 10) {
                Button { calMonth = cal.date(byAdding: .month, value: -1, to: calMonth)! } label: {
                    Text("◀").foregroundColor(Theme.dim)
                }.buttonStyle(.plain)
                Text(String(format: "%04d / %02d", comps.year!, comps.month!))
                    .foregroundColor(Theme.fg).frame(width: 90)
                Button { calMonth = cal.date(byAdding: .month, value: 1, to: calMonth)! } label: {
                    Text("▶").foregroundColor(Theme.dim)
                }.buttonStyle(.plain)
            }.font(Theme.monoSmall)

            HStack(spacing: 2) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(Theme.monoSmall).foregroundColor(Theme.dim).frame(width: 26)
                }
            }
            ForEach(0..<((lead + days + 6) / 7), id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { col in
                        let dayNum = row * 7 + col - lead + 1
                        if dayNum >= 1 && dayNum <= days {
                            let d = cal.date(byAdding: .day, value: dayNum - 1, to: first)!
                            let ymd = RelativeDate.todayYMD(d)
                            dayCell(dayNum, ymd: ymd, isSelected: ymd == selected, isToday: ymd == store.todayYMD)
                        } else {
                            Text("").frame(width: 26, height: 21)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                calAction("今天") { editDue = store.todayYMD; showDatePicker = false }
                calAction("明天") {
                    editDue = RelativeDate.todayYMD(cal.date(byAdding: .day, value: 1, to: Date())!)
                    showDatePicker = false
                }
                calAction("清除") { editDue = ""; showDatePicker = false }
            }.padding(.top, 2)
        }
        .padding(10).frame(width: 218).background(Theme.bg)   // 固定寬:不隨父容器撐開
        .onAppear { calMonth = RelativeDate.parse(editDue) ?? Date() }
    }
    private func dayCell(_ n: Int, ymd: String, isSelected: Bool, isToday: Bool) -> some View {
        Text("\(n)").font(Theme.mono)
            .foregroundColor(isSelected ? Theme.bg : (isToday ? store.accent : Theme.fg))
            .frame(width: 26, height: 21)
            .background(isSelected ? store.accent : .clear)
            .overlay(Rectangle().stroke(isToday && !isSelected ? store.accent : .clear))
            .contentShape(Rectangle())
            .onTapGesture { editDue = ymd; showDatePicker = false }
    }
    private func calAction(_ label: String, _ run: @escaping () -> Void) -> some View {
        Text(label).font(Theme.monoSmall).foregroundColor(Theme.dim)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Rectangle().stroke(Theme.border))
            .contentShape(Rectangle())
            .onTapGesture(perform: run)
    }

    /// TUI 風專案選單:點欄位即展開,✓ 標示已套用
    private var projectMenuPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.allProjects().isEmpty {
                Text("尚無 List — 直接輸入 +名稱").font(Theme.monoSmall).foregroundColor(Theme.dim).padding(10)
            }
            ForEach(store.allProjects(), id: \.self) { p in
                HStack(spacing: 8) {
                    Text(hasProject(p) ? "✓" : " ").foregroundColor(Theme.mag)
                    Text("+" + p).foregroundColor(Theme.mag)
                    Spacer()
                }
                .font(Theme.mono)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture { toggleEditProject(p) }
            }
        }
        .frame(width: 200).padding(.vertical, 4).background(Theme.bg)
    }

    /// TUI 風情境選單
    private var contextMenuPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.allContexts().isEmpty {
                Text("尚無 Tag — 直接輸入 @名稱").font(Theme.monoSmall).foregroundColor(Theme.dim).padding(10)
            }
            ForEach(store.allContexts(), id: \.self) { c in
                HStack(spacing: 8) {
                    Text(hasContext(c) ? "✓" : " ").foregroundColor(Theme.cyan)
                    Text("@" + c).foregroundColor(Theme.cyan)
                    Spacer()
                }
                .font(Theme.mono)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture { toggleEditContext(c) }
            }
        }
        .frame(width: 200).padding(.vertical, 4).background(Theme.bg)
    }
    private func hasProject(_ p: String) -> Bool { tagList(editProjects, "+").contains(p) }
    private func hasContext(_ c: String) -> Bool { tagList(editContexts, "@").contains(c) }
    private func tagList(_ s: String, _ sigil: Character) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == sigil }).map(String.init)
    }
    private func toggleEditProject(_ p: String) {
        var list = tagList(editProjects, "+")
        if let i = list.firstIndex(of: p) { list.remove(at: i) } else { list.append(p) }
        editProjects = list.map { "+" + $0 }.joined(separator: " ")
    }
    private func toggleEditContext(_ c: String) {
        var list = tagList(editContexts, "@")
        if let i = list.firstIndex(of: c) { list.remove(at: i) } else { list.append(c) }
        editContexts = list.map { "@" + $0 }.joined(separator: " ")
    }

    private func openEdit() {
        guard let i = store.cursor, store.lines.indices.contains(i) else { return }
        let t = store.lines[i]
        editIndex = i
        editTitle = t.title
        editDue = t.due ?? ""
        editProjects = t.projects.map { "+" + $0 }.joined(separator: " ")
        editContexts = t.contexts.map { "@" + $0 }.joined(separator: " ")
        editNote = t.note ?? ""
        editField = 0
        showingEdit = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { editTitleFocused = true }
    }
    private func commitEdit() {
        if let i = editIndex {
            store.applyEdit(i, title: editTitle, due: editDue, projects: editProjects,
                            contexts: editContexts, note: editNote)
        }
        closeEdit()
    }
    private func closeEdit() {
        showingEdit = false; editIndex = nil
        DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }   // 鍵盤還給 handle()
    }

    private var editSheet: some View {
        // 下拉層掛在彈窗最上層(ZStack 末位):zIndex 只在同層有效,掛欄位上會被便箋欄蓋住
        ZStack(alignment: .topLeading) {
            editSheetBody
            if showDatePicker {
                dropdownPanel { datePickerPopover }.offset(x: 20, y: 162)
            }
            if showProjectMenu {
                dropdownPanel { projectMenuPopover }.offset(x: 203, y: 162)
            }
            if showContextMenu {
                dropdownPanel { contextMenuPopover }.offset(x: 360, y: 162)   // 靠右緣內縮,不溢出
            }
        }
        // 固定尺寸:下拉層是浮層,彈窗大小不隨它開合變動
        .frame(width: 580, height: 400, alignment: .topLeading).background(Theme.bg)
    }

    private var editSheetBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("編輯任務").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.2)

            // 第一行:項目內容
            VStack(alignment: .leading, spacing: 4) {
                Text("內容").font(Theme.monoSmall).foregroundColor(Theme.dim)
                TextField("", text: $editTitle)
                    .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.fg)
                    .focused($editTitleFocused)
                    .padding(7).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }

            // 第二行:到期時間(可打字 + 日曆選擇) + 專案(可打字 + 下拉選單)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("到期").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    HStack(spacing: 0) {
                        TextField("", text: $editDue,
                                  prompt: Text("fri · tomorrow · 3d").foregroundColor(Theme.dim.opacity(0.4)))
                            .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.blue)
                            .focused($editDueFocused)
                        Text("↓").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    }
                    .padding(7).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        editField = 1; showProjectMenu = false; showContextMenu = false
                        showDatePicker = true; editDueFocused = true
                    })
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("List").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    HStack(spacing: 0) {
                        TextField("", text: $editProjects,
                                  prompt: Text("+work +side").foregroundColor(Theme.dim.opacity(0.4)))
                            .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.mag)
                            .focused($editProjectsFocused)
                        Text("↓").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    }
                    .padding(7).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        editField = 2; showDatePicker = false; showContextMenu = false
                        showProjectMenu = true; editProjectsFocused = true
                    })
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tag").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    HStack(spacing: 0) {
                        TextField("", text: $editContexts,
                                  prompt: Text("@mac @home").foregroundColor(Theme.dim.opacity(0.4)))
                            .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.cyan)
                            .focused($editContextsFocused)
                        Text("↓").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    }
                    .padding(7).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded {
                        editField = 3; showDatePicker = false; showProjectMenu = false
                        showContextMenu = true; editContextsFocused = true
                    })
                }
            }

            // 第三行:便箋
            VStack(alignment: .leading, spacing: 4) {
                Text("備註").font(Theme.monoSmall).foregroundColor(Theme.dim)
                TextEditor(text: $editNote)
                    .font(Theme.mono).foregroundColor(Theme.fg)
                    .scrollContentBackground(.hidden)
                    .frame(height: 72)
                    .padding(4).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }

            HStack {
                Text("↓ 開選單 · ⌘⏎ 儲存 · esc 取消").font(Theme.monoSmall).foregroundColor(Theme.dim)
                Spacer()
                Button("取消") { closeEdit() }.keyboardShortcut(.cancelAction)
                Button("儲存") { commitEdit() }.keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20).frame(width: 580, alignment: .topLeading)
    }

    private var addProjectSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("加入 +LIST 到選取任務").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.2)
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
            .init(name: "編輯任務", alias: "edit popup", keys: "⌘E", run: { openEdit() }),
            .init(name: "行內編輯", alias: "inline edit rename", keys: "e", run: { store.startEditing() }),
            .init(name: "Focus 這一件", alias: "focus", keys: "f", run: { store.toggleFocus() }),
            .init(name: "專注模式", alias: "zen focus mode", keys: "z", run: { store.toggleFocusMode() }),
            .init(name: "新增捕捉", alias: "new capture add", keys: "n", run: { openCapture() }),
            .init(name: "加 +List", alias: "project list", keys: "p", run: { if store.cursor != nil { showingAddProject = true } }),
            .init(name: "搜尋", alias: "search find filter", keys: "/", run: { store.searchActive = true }),
            .init(name: "逾期全改今天", alias: "reschedule overdue today", keys: "R", run: { store.rescheduleOverdue() }),
            .init(name: "行距更緊", alias: "density compact tighter", keys: "[", run: { store.cycleDensity(-1) }),
            .init(name: "行距更鬆", alias: "density relaxed looser", keys: "]", run: { store.cycleDensity(1) }),
            .init(name: "清單視圖", alias: "list view", keys: "⌘1", run: { store.view = .list; store.ensureCursor() }),
            .init(name: "便箋", alias: "scratch pad notes", keys: "⌘3", run: { store.view = .pad }),
            .init(name: "象限視圖", alias: "quadrant grid matrix", keys: "⌘2", run: { store.view = .grid; store.ensureCursor() }),
            .init(name: "統計", alias: "stats dashboard charts", keys: "⌘4", run: { store.view = .dash }),
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
                    Text("⌘K").font(Theme.monoSmall).foregroundColor(store.accent)
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
                            Text(LocalizedStringKey(cmd.name))
                            Spacer()
                            Text(cmd.keys).foregroundColor(Theme.dim)
                        }
                        .font(Theme.mono)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(i == paletteSel ? Theme.selBg : .clear)
                        .overlay(alignment: .leading) {
                            if i == paletteSel { Rectangle().fill(store.accent).frame(width: 3) }
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

    /// 側邊面板內緣(朝螢幕中央那側)的外框線 + 柔和陰影,給浮出的面板立體邊界。
    @ViewBuilder private var sidebarInnerEdge: some View {
        let edge = store.sidebarEdge
        let horizontal = edge == .top          // top 模式外框在底邊(水平線)
        let align: Alignment = edge == .right ? .leading : (edge == .left ? .trailing : .bottom)
        ZStack(alignment: align) {
            Color.clear
            LinearGradient(colors: [Color.black.opacity(0.28), .clear],
                           startPoint: edge == .right ? .leading : (edge == .left ? .trailing : .bottom),
                           endPoint:   edge == .right ? .trailing : (edge == .left ? .leading : .top))
                .frame(width: horizontal ? nil : 16, height: horizontal ? 16 : nil)
            Rectangle().fill(Theme.dim.opacity(0.55))
                .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in handle(e) }
    }
    private func handle(_ e: NSEvent) -> NSEvent? {
        // 本地 monitor 是 app 層級的:側邊模式下有兩個 ContentView(主視窗+側邊面板),
        // 各裝一個。只讓事件目標視窗的那個實例處理,否則另一個會吞掉 capture 的按鍵。
        if let hw = hostWindow, let ew = e.window, ew !== hw { return e }
        if showingPalette {
            switch e.keyCode {
            case 125: paletteSel = min(paletteSel + 1, max(0, filteredPalette.count - 1)); return nil  // ↓
            case 126: paletteSel = max(paletteSel - 1, 0); return nil                                  // ↑
            case 36:  runPalette(); return nil                                                          // ⏎
            case 53:  closePalette(); return nil                                                        // esc
            default:  return e   // 其餘給輸入框
            }
        }
        if showingEdit {
            // ↓ 在欄位內展開該欄位的選單;esc 先收選單再談關閉彈窗
            if e.keyCode == 125 {
                switch editField {
                case 1: showDatePicker = true; return nil
                case 2: showProjectMenu = true; return nil
                case 3: showContextMenu = true; return nil
                default: break
                }
            }
            if e.keyCode == 53, showDatePicker || showProjectMenu || showContextMenu {
                showDatePicker = false; showProjectMenu = false; showContextMenu = false
                return nil
            }
            if e.keyCode == 48 {   // Tab:收選單並跟著彈窗順序推進(標題→到期→專案→情境→便箋)
                showDatePicker = false; showProjectMenu = false; showContextMenu = false
                editField = e.modifierFlags.contains(.shift)
                    ? max(0, editField - 1) : (editField >= 3 ? 0 : editField + 1)
            }
            return e
        }
        if showingCapture || showingAddProject { return e }
        // NSTextField 的 field editor 也是 NSTextView，且切頁後可能短暫保留；只在確實
        // 顯示文字輸入介面時放行，避免它吞掉清單的 n/e/x 等單鍵命令。
        if store.inlineAddActive || store.view == .pad || store.view == .settings || store.searchActive { return e }
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        let chars = e.charactersIgnoringModifiers ?? ""
        if cmd {
            switch chars.lowercased() {
            case "1": store.view = .list; store.ensureCursor(); return nil
            case "2": store.view = .grid; store.ensureCursor(); return nil
            case "3": store.view = .pad; return nil
            case "4": store.view = .dash; return nil
            case ",", "5": store.view = .settings; return nil
            case "b": store.view = .list; store.requestInlineAdd = true; return nil
            case "k": openPalette(); return nil
            case "e": openEdit(); return nil
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
        // 統計視圖唯讀:單鍵動詞不得作用在看不見的游標上;esc 回清單
        if store.view == .dash || store.view == .settings {
            if e.keyCode == 53 { store.view = .list; store.ensureCursor() }
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
        case "n": store.view = .list; store.requestInlineAdd = true; return nil
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

/// Variable-width chips that wrap onto additional rows instead of scrolling horizontally.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + (x == 0 ? 0 : spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? max(0, x), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 回報承載此 View 的 NSWindow(用來把 app 層級鍵盤 monitor 限定在自己的視窗)。
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onResolve(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}
