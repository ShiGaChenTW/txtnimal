import SwiftUI
import txtnimalCore

private enum PendingTaskAction {
    case archive(TaskHandle, String)
    case delete(TaskHandle, String)
}

struct ContentView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.isSidebarPanel) private var isSidebarPanel
    @State private var showingCapture = false
    @State private var captureText = ""
    @State private var showingAddProject = false
    @State private var showingAddContext = false
    @State private var showingScratch = false
    @State private var projectText = ""
    @State private var contextText = ""
    @State private var monitor: Any?
    @State private var hostWindow: NSWindow?
    @State private var showTabMenu = false
    @State private var pendingTaskAction: PendingTaskAction?

    /// 清單內容本身要的寬度,不含左側導覽欄。
    private static let contentMinWidth: CGFloat = 660

    /// 視窗寬度下限。導覽欄顯示時要整段加上它的寬度與 1pt 分隔線,否則視窗縮到底時
    /// 任務列會比沒有導覽欄時更擠;`s` 把它收起來後,下限就得跟著縮回 660 ——
    /// 不然「變回加導覽欄之前的樣子」只做到一半:欄不見了,視窗還是卡在寬版縮不回去。
    ///
    /// 寬度直接讀 `ListNavigationRail.width`,不再手抄第二份常數。
    /// (先前寫死的 840 比 660+172+1 多出 7pt,那 7pt 沒有出處,一併收斂掉。)
    ///
    /// 只看 `listRailVisible`,刻意不看 `ListNavigationRail` 的另外兩個顯示條件:
    /// - **不看「有沒有 list」**:那樣使用者建第一個 list 時,視窗會被硬拉寬,
    ///   而他只是新增了一筆資料,沒要求動視窗。
    /// - **不看目前在哪一頁**:那樣 ⌘1／⌘4 切頁會順手改視窗大小。
    /// 下限跟著使用者「按了 s」這個明示動作走,不跟著資料或頁面漂移。
    private var windowMinWidth: CGFloat {
        if isSidebarPanel { return 100 }   // 側邊面板不顯示導覽欄,維持 100
        return store.listRailVisible
            ? Self.contentMinWidth + ListNavigationRail.width + 1
            : Self.contentMinWidth
    }

    var body: some View {
        ZStack {
            // 側邊模式讓根背景層透明,露出面板後方的毛玻璃;一般視窗維持不透明。
            Theme.bg.opacity(isSidebarPanel ? store.sidebarOpacity : 1).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                hline
                // 滿版視圖自己管捲動:象限頁(上下 50/50)、統計頁(垂直置中)、Agent,
                // 以及清單頁 —— 它的左導覽欄必須固定不動,捲動框因此下放到 ListView 右欄。
                // 只剩設定頁走這層的整頁捲動。
                if store.view == .grid || store.view == .dash || store.view == .agent || store.view == .list {
                    body(for: store.view).frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let notice = store.reloadNotice {
                Text(notice)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.fg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.panel)
                    .overlay(Rectangle().stroke(Theme.border))
                    .padding(.top, 10)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if let notice = recurrenceNotice {
                recurrenceNoticeBanner(notice)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(minWidth: windowMinWidth, minHeight: 580)
        .background(WindowAccessor { hostWindow = $0 })
        .font(Theme.mono).foregroundColor(Theme.fg)
        .environment(\.locale, store.appLanguage.locale)
        .environment(\.taskContextActions, taskContextActions)
        .environment(\.recurrenceAnnouncer, recurrenceAnnouncer)
        .onAppear {
            installMonitor()
            store.applyAppearance()
            store.applyAppIcon()
            FocusHUD.shared.update(store: store)
        }
        .onChange(of: store.focusIndex) { _ in FocusHUD.shared.update(store: store) }
        .onChange(of: store.focusMode) { _ in FocusHUD.shared.update(store: store) }
        // 選單列的指令走這條回到 perform() —— 選單按鈕構不到 ContentView 的私有狀態,
        // 但 perform() 構得到,所以讓選單只負責「說要做什麼」,做什麼還是同一份實作。
        // 側邊模式下同時有兩個 ContentView,只有 key window 那個可以吃,否則會做兩次。
        .onChange(of: store.commandRequest) { request in
            guard let request, hostWindow?.isKeyWindow ?? true else { return }
            perform(request.identity)
        }
        .onDisappear { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
        .sheet(isPresented: $showingAddProject, onDismiss: { projectText = "" }) { addProjectSheet }
        .sheet(isPresented: $showingAddContext, onDismiss: { contextText = "" }) { addContextSheet }
        .sheet(isPresented: $showingScratch) { scratchSheet }
        .sheet(isPresented: $showingEdit) { editSheet }
        .sheet(isPresented: Binding(
            get: { if case .review = store.importReview { return true } else { return false } },
            set: { if !$0 { store.discardImportReview() } }
        )) {
            ImportReviewSheet(proposals: importReviewProposals).environmentObject(store)
        }
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
        .alert("偵測到外部編輯衝突", isPresented: Binding(
            get: { store.externalEditConflict != nil },
            set: { if !$0 { store.externalEditConflict = nil } }
        )) {
            Button("重新載入（捨棄我的變更）") { store.reloadAfterExternalConflict() }
            Button("強制覆蓋（以我的為準）", role: .destructive) { store.forceOverwriteExternalChanges() }
        } message: {
            Text("檔案已被外部修改。請選擇如何處理；在你選擇前不會再寫入檔案。")
        }
        .confirmationDialog("確認任務操作", isPresented: Binding(
            get: { pendingTaskAction != nil },
            set: { if !$0 { pendingTaskAction = nil } }
        ), titleVisibility: .visible) {
            if case .archive(let handle, _) = pendingTaskAction {
                Button("封存任務") { store.archiveTask(using: handle); pendingTaskAction = nil }
            }
            if case .delete(let handle, _) = pendingTaskAction {
                Button("刪除", role: .destructive) { store.deleteTask(using: handle); pendingTaskAction = nil }
            }
            Button("取消", role: .cancel) { pendingTaskAction = nil }
        } message: {
            switch pendingTaskAction {
            case .archive(_, let title):
                Text("「\(title)」將移至 archive.txt，可從封存檔找回。")
            case .delete(_, let title):
                Text("「\(title)」將移至垃圾桶，\(store.trashRetentionDays) 天後才永久刪除，期間可在垃圾桶還原。")
            case nil:
                EmptyView()
            }
        }
    }

    private var taskContextActions: TaskContextActions {
        TaskContextActions(
            edit: { openEdit($0) },
            confirmArchive: { pendingTaskAction = .archive($0, $1) },
            confirmDelete: { pendingTaskAction = .delete($0, $1) }
        )
    }

    private var importReviewProposals: [ImportProposal] {
        if case .review(let proposals) = store.importReview {
            return proposals
        }
        return []
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
                // 卸載 searchBar 本來就會把 @FocusState 清掉,但我們不要依賴那個隱式路徑。
                .onExitCommand { searchFocused = false; store.clearSearch() }
            if !store.searchQuery.isEmpty {
                Text("✕").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    .onTapGesture { searchFocused = false; store.clearSearch() }
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
        case .agent: AgentWorkspaceView()
        case .dash: DashboardView()
        case .settings: SettingsView()
        case .trash: TrashView()
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
            // 寬度夠 → 整排頁籤;太窄一行放不下 → 自動收成主題化下拉選單。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    tab("⌘1 清單", .list); tab("⌘2 象限", .grid); tab("⌘3 Agent", .agent)
                    tab("⌘4 統計", .dash); tab("⌘5 設定", .settings); tab("⌘6 垃圾桶", .trash)
                }
                tabMenu
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11).background(Theme.panel)
    }

    private static let headerTabs: [(String, AppView)] = [
        ("⌘1 清單", .list), ("⌘2 象限", .grid), ("⌘3 Agent", .agent), ("⌘4 統計", .dash),
        ("⌘5 設定", .settings), ("⌘6 垃圾桶", .trash)
    ]
    /// 窄版下拉選單:按鈕顯示目前頁面,展開的清單用 Theme 配色,與頁籤視覺一致。
    private var tabMenu: some View {
        let cur = Self.headerTabs.first { $0.1 == store.view }?.0 ?? "選單"
        let label = Theme.isTerminal
            ? Text("[") + Text(LocalizedStringKey(cur)) + Text(" ▾]")
            : Text(LocalizedStringKey(cur)) + Text(" ▾")
        return Button { showTabMenu.toggle() } label: {
            label.font(Theme.monoSmall)
                .foregroundColor(Theme.isTerminal ? Theme.green : Theme.fg)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Theme.isTerminal ? Theme.green.opacity(0.08) : Theme.bg)
                .overlay(Rectangle().stroke(Theme.isTerminal ? Theme.green.opacity(0.45) : Theme.border))
                .lineLimit(1).fixedSize()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTabMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.headerTabs, id: \.1) { it in
                    let on = store.view == it.1
                    Text(LocalizedStringKey(it.0)).font(Theme.monoSmall)
                        .foregroundColor(on ? (Theme.isTerminal ? Theme.green : Theme.fg) : Theme.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(on ? (Theme.isTerminal ? Theme.green.opacity(0.10) : Theme.bg) : .clear)
                        .overlay(Rectangle().stroke(on ? (Theme.isTerminal ? Theme.green.opacity(0.4) : Theme.border) : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { store.view = it.1; store.ensureCursor(); showTabMenu = false }
                }
            }
            .padding(6).frame(width: 156)
            .background(Theme.panel)
        }
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
                // 兩行放得下 → 完整指令;放不下 → 收成可點的「?查看指令」開啟指令面板。
                ViewThatFits(in: .vertical) {
                    Text(statusText).foregroundColor(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.appLanguage == .english ? "⌘K Commands" : "⌘K 指令")
                        .foregroundColor(Theme.isTerminal ? Theme.green : Theme.fg)
                        .contentShape(Rectangle())
                        .onTapGesture { paletteQuery = ""; paletteSel = 0; showingPalette = true }
                        .help(store.appLanguage == .english ? "Open commands (⌘K)" : "開啟指令面板（⌘K）")
                }
                .frame(maxHeight: 30, alignment: .leading)
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
            case .list: return "↑↓ Move   ⌘E Edit   x Done   f Focus   n Add   d Delete   t Due   p +List   @ Tag   s Rail   / Search   ⌘K Commands"
            case .grid: return "1–4 Assign   0 Unassign   f Focus   z Zen   ⌘K Commands   ⌘1 List"
            case .agent: return "Agent · review every proposal before applying   ⌘1 Back to list"
            case .dash: return "Read-only stats · calculated from done: dates   esc / ⌘1 Back to list"
            case .settings: return "Settings · applied instantly   esc / ⌘1 Back to list"
            case .trash: return "Trash · restore or delete for good   esc / ⌘1 Back to list"
            }
        }
        switch store.view {
        case .list: return "↑↓ 移動   ⌘E 編輯   x 完成   f Focus   n 新增   d 刪除   t 到期   p +List   @ Tag   s 導覽欄   / 搜尋   ⌘K 指令"
        case .grid: return "1–4 指派   0 回池   f Focus   z 專注   ⌘K 指令   ⌘1 清單"
        case .agent: return "Agent · 提議一律先審後套   ⌘1 回清單"
        case .dash: return "唯讀統計 · 依 done: 日期計算   esc / ⌘1 回清單"
        case .settings: return "設定 · 即時生效   esc / ⌘1 回清單"
        case .trash: return "垃圾桶 · 可還原或永久刪除   esc / ⌘1 回清單"
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
                    TerminalInputField(text: $captureText, onSubmit: commitCapture, onCancel: closeCapture,
                                       onFocusChange: { _ in })
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
        // rec: 同理 — 能解析才變黃,上色即時告訴使用者這個週期寫對了沒
        if p.hasPrefix("rec:") { return CaptureAssist.recurrenceLabel(for: String(p.dropFirst(4))) != nil ? Theme.yellow : Theme.fg }
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
    @State private var editRec = ""
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
        guard let i = store.cursor else { return }
        openEdit(store.handle(for: i))
    }
    /// `t`:同一個編輯彈窗,但一開就把日曆攤開、當前欄位設為「到期」——
    /// 走既有 popup 而不是另做一顆選擇器,是為了不讓日期有第二套寫入路徑。
    /// 焦點刻意留在 `openEdit` 既有的標題欄:此檔上方註解記著 sheet 內 @FocusState
    /// 不可靠(前兩次失敗主因),再排一個競爭的 asyncAfter 只會把它變成偶發 bug。
    private func openEditOnDueField() {
        guard let i = store.cursor else { return }
        openEdit(store.handle(for: i))
        guard showingEdit else { return }   // 已完成的任務 openEdit 會拒絕開啟
        editField = 1
        showProjectMenu = false; showContextMenu = false
        showDatePicker = true
    }
    /// `d`:不自己刪,只把待確認動作交給既有的 confirmationDialog —
    /// 破壞性操作只能有一條路徑,鍵盤捷徑不是繞過二次確認的理由。
    private func confirmDeleteCursor() {
        guard let i = store.cursor else { return }
        let handle = store.handle(for: i)
        guard let task = store.task(using: handle) else { return }
        pendingTaskAction = .delete(handle, task.title)
    }
    private func openEdit(_ handle: TaskHandle) {
        guard let t = store.task(using: handle), !t.isDone else { return }
        store.select(using: handle)
        editIndex = handle.index
        editTitle = t.title
        editDue = t.due ?? ""
        editProjects = t.projects.map { "+" + $0 }.joined(separator: " ")
        editContexts = t.contexts.map { "@" + $0 }.joined(separator: " ")
        editNote = t.note ?? ""
        editRec = CaptureAssist.recurrenceValue(inRawLine: t.raw) ?? ""
        editField = 0
        showingEdit = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { editTitleFocused = true }
    }
    private func commitEdit() {
        if let i = editIndex {
            store.applyEdit(i, title: editTitle, due: editDue, projects: editProjects,
                            contexts: editContexts, note: editNote, rec: editRec)
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
                // 週期:沒有下拉,改用即時標籤當回饋 — 打得出「每週」就是設定成功,
                // 空白清除,打不出標籤代表值無效(儲存時原樣保留舊值,不寫垃圾進檔案)。
                VStack(alignment: .leading, spacing: 4) {
                    Text("週期").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    HStack(spacing: 0) {
                        TextField("", text: $editRec,
                                  prompt: Text("1w · +1m").foregroundColor(Theme.dim.opacity(0.4)))
                            .textFieldStyle(.plain).font(Theme.mono).foregroundColor(Theme.yellow)
                        Text(CaptureAssist.recurrenceLabel(for: editRec.trimmingCharacters(in: .whitespaces)) ?? "")
                            .font(Theme.monoSmall).foregroundColor(Theme.dim).lineLimit(1)
                    }
                    .padding(7).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
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

    private var addContextSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("加入 @TAG 到選取任務").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.2)
            HStack(spacing: 8) {
                Text("@").foregroundColor(Theme.cyan)
                TextField("mac", text: $contextText)
                    .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced)).foregroundColor(Theme.fg)
                    .onSubmit { commitContext() }
            }
            HStack { Spacer()
                Button("取消") { showingAddContext = false }
                Button("加入") { commitContext() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 380).background(Theme.bg)
    }
    private func commitContext() {
        store.addContextToCursor(contextText); contextText = ""; showingAddContext = false
    }

    private var scratchSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("便箋").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.2)
                Spacer()
                Text(store.scratchURL.lastPathComponent).font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
            TextEditor(text: $store.scratch)
                .font(Theme.mono).foregroundColor(Theme.fg)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 280)
                .padding(4).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
                .onChange(of: store.scratch) { _ in store.saveScratch() }
            HStack {
                Text("esc 關閉 · 自動存入 scratch.txt").font(Theme.monoSmall).foregroundColor(Theme.dim)
                Spacer()
                Button("關閉") { showingScratch = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 560, alignment: .topLeading)
    }

    // MARK: ⌘K 指令面板 — 來源是 CommandCatalog,不是手抄清單

    @State private var showingPalette = false
    @State private var paletteQuery = ""
    @State private var paletteSel = 0
    @FocusState private var paletteFocused: Bool

    private var filteredPalette: [CommandSpec] {
        CommandPaletteAssembler.assemble(
            plugins: store.galleryPluginEntries(),
            context: CommandPaletteContext(page: store.view.palettePage, hasSelection: store.cursor != nil),
            query: paletteQuery
        )
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
                    ForEach(Array(cmds.enumerated()), id: \.element.id) { i, cmd in
                        HStack {
                            Text(LocalizedStringKey(cmd.name))
                            if case .plugin = cmd.identity {
                                Text("外掛").font(Theme.monoSmall).foregroundColor(Theme.dim)
                            }
                            Spacer()
                            Text(cmd.keyDisplay).foregroundColor(Theme.dim)
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
        DispatchQueue.main.async { perform(cmd.identity) }   // 面板收掉、焦點歸還後再執行
    }

    /// 切頁必須把「只在上一頁成立」的鍵盤狀態一起清掉。
    /// `searchFocused` 是 ContentView 的 @FocusState、`focusMode` 是 store 的旗標,
    /// 兩者都不會因為 store.view 改變而自動歸零 —— 不清就會在下一頁繼續吞掉按鍵。
    private func switchView(to target: AppView, ensureCursor: Bool = false) {
        store.view = target
        store.focusMode = false
        searchFocused = false
        if ensureCursor { store.ensureCursor() }
    }

    private func perform(_ identity: CommandIdentity) {
        switch identity {
        case .builtin(let command):
            switch command {
            case .toggleDone: animatedDone()
            case .editPopup: openEdit()
            case .inlineEdit: store.startEditing()
            case .toggleFocus: store.toggleFocus()
            case .focusMode: store.toggleFocusMode()
            case .inlineAdd: store.view = .list; store.requestInlineAdd = true
            case .openCapture: openCapture()
            case .addList: if store.cursor != nil { showingAddProject = true }
            case .addTag: if store.cursor != nil { showingAddContext = true }
            case .newList: store.view = .list; store.requestNewList = true
            case .deleteTask: confirmDeleteCursor()
            case .quickDue: openEditOnDueField()
            // 搜尋列已經開著但焦點在清單時（⏎ 之後的常態），再按一次 `/` 必須回到欄位；
            // 只設 searchActive 的話 searchBar 的 .onAppear 不會再觸發，按鍵等於沒反應。
            // 延一個 runloop：首次開啟時欄位還沒掛上，同步指派會被 SwiftUI 丟掉。
            case .search:
                store.searchActive = true
                DispatchQueue.main.async { searchFocused = true }
            case .rescheduleOverdue: store.rescheduleOverdue()
            case .densityTighter: store.cycleDensity(-1)
            case .densityLooser: store.cycleDensity(1)
            case .toggleListRail: store.listRailVisible.toggle()
            case .viewList: switchView(to: .list, ensureCursor: true)
            case .viewGrid: switchView(to: .grid, ensureCursor: true)
            case .viewAgent: switchView(to: .agent)
            case .viewDash: switchView(to: .dash)
            case .viewSettings: switchView(to: .settings)
            case .viewTrash: switchView(to: .trash)
            case .cycleAppearance: store.cycleAppearance()
            case .openPalette: openPalette()
            case .undo: store.undo()
            case .redo: store.redo()
            case .openScratch: showingScratch = true
            }
        case .plugin(let pluginID, let commandID):
            store.runCommandPlugin(pluginID: pluginID, commandID: commandID)
        }
    }

    // MARK: keyboard (macOS 13 無 onKeyPress，用 NSEvent local monitor)

    private func animatedDone() {
        guard let i = store.cursor, store.lines.indices.contains(i) else { return }
        let task = store.lines[i]
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            completeAnnouncingRecurrence(task, in: store, announcer: recurrenceAnnouncer) { store.toggleDone() }
        }
    }

    // MARK: 完成重複任務的短暫回饋

    @State private var recurrenceNotice: String?
    /// 每次回饋帶一個序號,收掉時只認自己那一次 —— 連續完成兩筆時,
    /// 前一個計時器不會把後一個的訊息提早收掉。
    @State private var recurrenceNoticeToken = 0

    private var recurrenceAnnouncer: RecurrenceAnnouncer {
        RecurrenceAnnouncer(announce: { announceRecurrence($0) })
    }

    /// `successor` 是 `recurringSuccessor` 實際回傳的那一筆,日期直接讀它的 `due`。
    private func announceRecurrence(_ successor: TaskLine) {
        guard let due = successor.due else { return }   // 沒有 due 就沒有可告知的日期
        recurrenceNoticeToken += 1
        let token = recurrenceNoticeToken
        withAnimation(.easeOut(duration: 0.18)) { recurrenceNotice = "↻ 下一筆已建立 · \(due)" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            guard recurrenceNoticeToken == token else { return }
            withAnimation(.easeOut(duration: 0.25)) { recurrenceNotice = nil }
        }
    }

    private func recurrenceNoticeBanner(_ text: String) -> some View {
        Text(text)
            .font(Theme.monoSmall)
            .foregroundColor(Theme.yellow)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.panel)
            .overlay(Rectangle().stroke(Theme.yellow.opacity(0.55)))
            .padding(.bottom, 52)   // 讓開底部的狀態列 / 捕捉列
            .transition(.opacity)
            .allowsHitTesting(false)
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
        }
        .overlay(SidebarEdgeBorder(edge: edge)
            .stroke(Theme.dim.opacity(0.28), lineWidth: 1))  // 只描露出的三邊(接縫側不畫)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func installMonitor() {
        // .onAppear 可能重跑(視窗重建、側邊模式切換),舊的 monitor 不拆掉就會留著,
        // 一次按鍵被處理兩次。與 Views.swift 的 RightClickView 同一個寫法。
        if let monitor { NSEvent.removeMonitor(monitor) }
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
        // 任何正在收文字的浮窗都要先放行,否則使用者打的字會被當成單鍵命令吃掉。
        // `listEditorActive` 是 ListView 的 List 編輯視窗 — `l` 讓它變成一個按鍵就到得了,
        // 沒有這道守門,在裡面打名稱會誤觸 d（刪除確認）等破壞性單鍵。
        if showingCapture || showingAddProject || showingAddContext
            || showingScratch || store.listEditorActive { return e }
        // 設定頁整頁放行（見下方守門）是因為它有可編輯欄位：使用者名稱、兩個熱鍵錄製器、
        // agent 端點與模型。但狀態列白紙黑字寫著「esc / ⌘1 回清單」，而整頁放行讓那句話
        // 變成謊言 —— 這裡只把 esc 這一顆鍵挑出來處理，其餘按鍵維持原樣放行給欄位。
        if store.view == .settings, e.keyCode == 53 {
            switchView(to: .list, ensureCursor: true); return nil
        }
        // NSTextField 的 field editor 也是 NSTextView，且切頁後可能短暫保留；只在確實
        // 顯示文字輸入介面時放行，避免它吞掉清單的 n/e/x 等單鍵命令。
        //
        // 搜尋看的是「欄位是不是真的有焦點」，不是「搜尋列在不在」：⏎ 之後篩選與搜尋列
        // 都還在（`store.searchActive` 仍為 true，這是刻意的），但鍵盤流已經交還清單，
        // 此時單鍵與 cmd 快捷鍵必須全部恢復作用。看 `searchActive` 會讓按過 ⏎ 的使用者
        // 卡在一個所有快捷鍵都失效、連 esc 都救不回來的狀態。
        if store.inlineAddActive || store.view == .agent || store.view == .settings || searchFocused { return e }
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        let chars = e.charactersIgnoringModifiers ?? ""
        if cmd {
            if let spec = CommandKeyMatcher.match(character: chars, command: true, shift: shift,
                                                  in: CommandCatalog.builtIns) {
                // cmd 分支排在唯讀頁守門之前,所以必須自己檢查可用性,否則 ⌘E 會在統計/垃圾桶頁
                // 作用到清單裡那個看不見的游標。`.always` 的 ⌘1–⌘6 不受影響。
                guard spec.availability.isAvailable(in: store.commandContext) else { return e }
                perform(spec.identity)
                return nil
            }
            return e
        }
        if store.focusMode {
            if chars == "z" || e.keyCode == 53 { store.focusMode = false }
            return nil
        }
        // 統計/設定/垃圾桶唯讀:單鍵動詞不得作用在看不見的游標上;esc 回清單
        // 垃圾桶特別重要——d(刪除)若在這裡生效,會作用到清單裡看不見的那個游標。
        if store.view == .dash || store.view == .settings || store.view == .trash {
            if e.keyCode == 53 { switchView(to: .list, ensureCursor: true) }
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
        case "1", "2", "3", "4": if store.view == .grid { store.setQuadrant(Int(chars)); return nil }; return e
        case "0": if store.view == .grid { store.setQuadrant(nil); return nil }; return e
        default:
            if let spec = CommandKeyMatcher.match(character: chars, command: false, shift: false,
                                                  in: CommandCatalog.builtIns) {
                perform(spec.identity)
                return nil
            }
            return e
        }
    }
}

private struct ImportReviewSheet: View {
    @EnvironmentObject var store: TaskStore
    let proposals: [ImportProposal]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("檢查匯入內容").foregroundColor(Theme.fg)
                Spacer()
                Text("\(proposals.count) ITEMS").font(Theme.monoSmall).foregroundColor(Theme.yellow)
            }
            Text("只有按下「套用」才會寫入 tasks.txt。")
                .font(Theme.monoSmall).foregroundColor(Theme.dim)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(proposals.enumerated()), id: \.offset) { entry in
                        let proposal = entry.element
                        VStack(alignment: .leading, spacing: 5) {
                            Text(proposal.title).foregroundColor(Theme.fg)
                            HStack(spacing: 8) {
                                Text(proposal.due ?? "—").foregroundColor(Theme.green)
                                Spacer()
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
                importReviewButton("捨棄", color: Theme.dim) { store.discardImportReview() }
                importReviewButton("套用", color: Theme.green) { store.applyImportReview() }
                    .disabled(proposals.isEmpty)
                    .opacity(proposals.isEmpty ? 0.4 : 1)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 320, alignment: .topLeading)
        .background(Theme.bg)
        .font(Theme.mono)
    }

    private func importReviewButton(_ title: LocalizedStringKey, color: Color,
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

/// 只描側邊面板「露出的三邊」,接縫側(貼螢幕邊那側)不畫線;圓角只在內側兩角。
private struct SidebarEdgeBorder: Shape {
    let edge: SidebarEdge
    var r: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let (minX, minY, maxX, maxY) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        switch edge {
        case .right:   // 略過右(外)緣;圓左上、左下
            p.move(to: CGPoint(x: maxX, y: minY))
            p.addLine(to: CGPoint(x: minX + r, y: minY))
            p.addQuadCurve(to: CGPoint(x: minX, y: minY + r), control: CGPoint(x: minX, y: minY))
            p.addLine(to: CGPoint(x: minX, y: maxY - r))
            p.addQuadCurve(to: CGPoint(x: minX + r, y: maxY), control: CGPoint(x: minX, y: maxY))
            p.addLine(to: CGPoint(x: maxX, y: maxY))
        case .left:    // 略過左(外)緣;圓右上、右下
            p.move(to: CGPoint(x: minX, y: minY))
            p.addLine(to: CGPoint(x: maxX - r, y: minY))
            p.addQuadCurve(to: CGPoint(x: maxX, y: minY + r), control: CGPoint(x: maxX, y: minY))
            p.addLine(to: CGPoint(x: maxX, y: maxY - r))
            p.addQuadCurve(to: CGPoint(x: maxX - r, y: maxY), control: CGPoint(x: maxX, y: maxY))
            p.addLine(to: CGPoint(x: minX, y: maxY))
        case .top:     // 略過上(外)緣;圓左下、右下
            p.move(to: CGPoint(x: minX, y: minY))
            p.addLine(to: CGPoint(x: minX, y: maxY - r))
            p.addQuadCurve(to: CGPoint(x: minX + r, y: maxY), control: CGPoint(x: minX, y: maxY))
            p.addLine(to: CGPoint(x: maxX - r, y: maxY))
            p.addQuadCurve(to: CGPoint(x: maxX, y: maxY - r), control: CGPoint(x: maxX, y: maxY))
            p.addLine(to: CGPoint(x: maxX, y: minY))
        }
        return p
    }
}
