import SwiftUI
import ServiceManagement
import TasksTxtCore

enum AppView { case list, grid, pad, dash, settings }

enum Density: Int, CaseIterable, Hashable {
    case compact = 0, normal = 1, spacious = 2
    var rowPad: CGFloat { [CGFloat(3), 6, 11][rawValue] }       // 每列上下內距
    var sectionTop: CGFloat { [CGFloat(14), 22, 30][rawValue] } // 分組之間的呼吸
    var label: String { ["緊湊", "標準", "寬鬆"][rawValue] }
}

/// 全部狀態的家：檔案內容 + UI 狀態（游標 / 視圖 / Focus 模式）。
/// v1 每次變更即存檔;FSEvents 外部監看為 v2。
final class TaskStore: ObservableObject {
    @Published private(set) var lines: [TaskLine] = []
    @Published private(set) var archiveLines: [TaskLine] = []
    @Published var lastError: String?
    @Published var view: AppView = .list
    @Published var cursor: Int? = nil          // index into `lines`
    @Published var focusMode = false
    @Published var scratch = ""
    @Published var tagFilter: String? = nil   // "+project" 或 "@context";nil = 不篩選
    @Published var editingIndex: Int? = nil   // 正在行內編輯的列
    @Published var searchQuery = ""           // `/` 即打即濾
    @Published var searchActive = false
    @Published var requestInlineAdd = false   // `n` 鍵 → 聚焦清單尾端新增列
    @Published var density: Density = {
        Density(rawValue: (UserDefaults.standard.object(forKey: "density") as? Int) ?? 1) ?? .normal
    }() {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }
    // 0 系統 / 1 深色 / 2 淺色
    @Published var appearanceMode: Int = UserDefaults.standard.integer(forKey: "appearance") {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: "appearance"); applyAppearance() }
    }
    func applyAppearance() {
        switch appearanceMode {
        case 1: NSApp.appearance = NSAppearance(named: .darkAqua)
        case 2: NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
    func cycleAppearance() { appearanceMode = (appearanceMode + 1) % 3 }

    /// 使用者名稱:統計頁問候語用。空白則回退成通用問候。
    @Published var userName: String = UserDefaults.standard.string(forKey: "userName") ?? "" {
        didSet { UserDefaults.standard.set(userName, forKey: "userName") }
    }
    /// 強調色索引(見 Theme.accentPalette):游標/當日/選取等中性強調用色
    @Published var accentIndex: Int = UserDefaults.standard.integer(forKey: "accent") {
        didSet { UserDefaults.standard.set(accentIndex, forKey: "accent") }
    }
    var accent: Color { Theme.accentPalette[max(0, min(accentIndex, Theme.accentPalette.count - 1))].color }

    // 開機自啟（SMAppService, macOS 13+）
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { report(error) }
        objectWillChange.send()
    }

    func clearSearch() { searchQuery = ""; searchActive = false; ensureCursor() }

    private(set) var fileURL: URL
    private(set) var scratchURL: URL
    private(set) var archiveURL: URL
    private var documentStore: FileSystemTaskDocumentStore
    private var generation: UInt64 = 0

    static let defaultDataDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/tasks-txt", isDirectory: true)
    private static func storedDataDir() -> URL {
        guard let p = UserDefaults.standard.string(forKey: "dataDir") else { return defaultDataDir }
        return URL(fileURLWithPath: p, isDirectory: true)
    }
    var dataDirPath: String { fileURL.deletingLastPathComponent().path }

    /// 換資料夾:存檔 → 空目標帶檔(複製,原檔保留)→ 持久化 → 重指三檔 → 重載 → 重掛監看。
    func setDataDir(_ dir: URL) {
        let current = fileURL.deletingLastPathComponent()
        guard dir.standardizedFileURL != current.standardizedFileURL else { return }
        save(); saveScratch()
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: dir.appendingPathComponent("tasks.txt").path) {
                for name in ["tasks.txt", "scratch.txt", "archive.txt"] {
                    let src = current.appendingPathComponent(name)
                    if fm.fileExists(atPath: src.path) {
                        try fm.copyItem(at: src, to: dir.appendingPathComponent(name))
                    }
                }
            }
            documentStore = try FileSystemTaskDocumentStore(directory: dir)
            UserDefaults.standard.set(dir.path, forKey: "dataDir")
            fileURL = documentStore.tasksURL; scratchURL = documentStore.scratchURL; archiveURL = documentStore.archiveURL
        } catch { report(error); return }
        bootstrapIfMissing()
        load()
        cursor = listOrder().first
        ensureCursor()
        startWatching()
    }

    init() {
        let dir = Self.storedDataDir()
        fileURL = dir.appendingPathComponent("tasks.txt")
        scratchURL = dir.appendingPathComponent("scratch.txt")
        archiveURL = dir.appendingPathComponent("archive.txt")
        do { documentStore = try FileSystemTaskDocumentStore(directory: dir) }
        catch { fatalError("Cannot initialize task document store: \(error)") }
        bootstrapIfMissing()
        load()
        archiveOldDone()
        cursor = listOrder().first
        startWatching()
        // 換日(含跨夜掛著)即歸檔
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            self?.archiveOldDone()
        }
    }

    /// 每日歸檔：把「非今天完成」的已完成任務搬到 archive.txt（保留歷史、不擋今天）。
    private func archiveOldDone() {
        do {
            apply(try documentStore.archiveCompleted(before: todayYMD, expectedGeneration: generation))
            editingIndex = nil; ensureCursor()
        } catch { report(error) }
    }

    // MARK: file IO

    private func bootstrapIfMissing() {
        let sample = """
        Finish landing page due:\(RelativeDate.todayYMD()) note:"update colors" focus:true q:1
        Review Q3 numbers due:\(RelativeDate.todayYMD())
        Call design lead +freelance q:2
        Daily marketing distribution +marketing
        Set up portfolio limits
        """
        do { try documentStore.bootstrap(sample: sample) } catch { report(error) }
    }

    func load() {
        do { apply(try documentStore.load()) } catch { report(error) }
    }

    private func save() {
        do { apply(try documentStore.save(lines: lines, expectedGeneration: generation)) }
        catch {
            let message = error.localizedDescription
            load()
            lastError = message
        }
    }

    func saveScratch() {
        do { try documentStore.saveScratch(scratch) } catch { report(error) }
    }

    private func apply(_ snapshot: TaskDocumentSnapshot) {
        lines = snapshot.lines; scratch = snapshot.scratch; archiveLines = snapshot.archiveLines
        generation = snapshot.generation; lastError = nil
    }

    private func report(_ error: Error) { lastError = error.localizedDescription }

    // MARK: 外部編輯即時重載（FSEvents/DispatchSource）

    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1

    private func startWatching() {
        stopWatching()
        watchFD = open(fileURL.path, O_EVTONLY)
        guard watchFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD, eventMask: [.write, .delete, .rename, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // 原子寫入會 rename 換 inode → 重新掛 watch
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.reloadIfChanged(); self.startWatching()
            } else {
                self.reloadIfChanged()
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.watchFD, fd >= 0 { close(fd) }
            self?.watchFD = -1
        }
        watchSource = src
        src.resume()
    }
    private func stopWatching() { watchSource?.cancel(); watchSource = nil }

    /// 外部檔案內容若和目前記憶體不同就重載（自己 save 造成的變動會被 no-op 掉）。
    private func reloadIfChanged() {
        do {
            let snapshot = try documentStore.load()
            guard snapshot.lines != lines else { generation = snapshot.generation; return }
            apply(snapshot); editingIndex = nil; ensureCursor()
        } catch { report(error) }
    }

    // MARK: derived

    var todayYMD: String { RelativeDate.todayYMD() }
    var focusIndex: Int? { lines.firstIndex(where: { $0.isFocused }) }

    /// 某列是否通過目前的標籤篩選 + 搜尋。
    func matches(_ i: Int) -> Bool {
        guard lines.indices.contains(i) else { return true }
        let t = lines[i]
        if let f = tagFilter {
            if f.hasPrefix("+"), !t.projects.contains(String(f.dropFirst())) { return false }
            if f.hasPrefix("@"), !t.contexts.contains(String(f.dropFirst())) { return false }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let hay = ([t.title] + t.projects.map { "+" + $0 } + t.contexts.map { "@" + $0 })
                .joined(separator: " ").lowercased()
            if !hay.contains(q) { return false }
        }
        return true
    }
    private var filtering: Bool { tagFilter != nil || !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }
    func groups() -> TaskGroups {
        var g = ListGrouping.group(lines, todayYMD: todayYMD)
        guard filtering else { return g }
        g.today = g.today.filter(matches); g.overdue = g.overdue.filter(matches)
        g.upcoming = g.upcoming.filter(matches); g.noDate = g.noDate.filter(matches); g.done = g.done.filter(matches)
        return g
    }
    func board() -> QuadrantBoard {
        var b = QuadrantBucketing.board(lines)
        guard filtering else { return b }
        b.q1 = b.q1.filter(matches); b.q2 = b.q2.filter(matches); b.q3 = b.q3.filter(matches)
        b.q4 = b.q4.filter(matches); b.unplaced = b.unplaced.filter(matches)
        return b
    }

    // 全檔出現過的標籤（給底部標籤列）。
    func allProjects() -> [String] { Array(Set(lines.flatMap { $0.projects })).sorted() }
    func allContexts() -> [String] { Array(Set(lines.flatMap { $0.contexts })).sorted() }
    var hasTags: Bool { lines.contains { !$0.projects.isEmpty || !$0.contexts.isEmpty } }

    func toggleTagFilter(_ tag: String) {
        tagFilter = (tagFilter == tag) ? nil : tag
        ensureCursor()
    }

    /// 目前視圖的可見順序（游標依此移動）。
    func listOrder() -> [Int] {
        let g = groups()
        return g.today + g.overdue + g.upcoming + g.noDate + g.done
    }
    func gridOrder() -> [Int] {
        let b = board()
        return b.q1 + b.q2 + b.q3 + b.q4 + b.unplaced
    }
    func currentOrder() -> [Int] { view == .grid ? gridOrder() : listOrder() }

    // MARK: ops (全部即時存檔)

    func move(_ delta: Int) {
        let o = currentOrder(); guard !o.isEmpty else { cursor = nil; return }
        let i = max(0, min(o.count - 1, (o.firstIndex(of: cursor ?? o[0]) ?? 0) + delta))
        cursor = o[i]
    }
    func ensureCursor() {
        let o = currentOrder()
        if cursor == nil || !o.contains(cursor!) { cursor = o.first }
    }

    func toggleDone() {
        guard let i = cursor, lines.indices.contains(i) else { return }
        do { lines = try TaskWorkspace.apply(.toggleDone(handle(for: i)), to: currentSnapshot, todayYMD: todayYMD); save(); ensureCursor() }
        catch { report(error) }
    }
    func toggleFocus() {
        guard let i = cursor, lines.indices.contains(i) else { return }
        let already = lines[i].isFocused
        do { lines = try TaskWorkspace.apply(.toggleFocus(handle(for: i)), to: currentSnapshot, todayYMD: todayYMD) }
        catch { report(error); return }
        if already { focusMode = false }
        save()
    }
    func clearFocus() {
        lines = TasksDocument.setFocus(lines, onIndex: nil); focusMode = false; save()
    }
    func setQuadrant(_ q: Int?) {
        guard let i = cursor, lines.indices.contains(i) else { return }
        do { lines = try TaskWorkspace.apply(.setQuadrant(handle(for: i), q), to: currentSnapshot, todayYMD: todayYMD); save(); ensureCursor() }
        catch { report(error) }
    }
    func setQuadrantAt(_ index: Int, _ q: Int?) {   // 拖拉放置用
        guard lines.indices.contains(index), !lines[index].isDone else { return }
        lines[index].setQuadrant(q); save()
    }
    func handle(for index: Int) -> TaskHandle { TaskHandle(generation: generation, index: index) }
    func dragPayload(for index: Int) -> String { "\(generation):\(index)" }
    func handle(from payload: String) -> TaskHandle? {
        let parts = payload.split(separator: ":"); guard parts.count == 2,
              let generation = UInt64(parts[0]), let index = Int(parts[1]) else { return nil }
        return TaskHandle(generation: generation, index: index)
    }
    func setQuadrant(_ q: Int?, using handle: TaskHandle) {
        do { lines = try TaskWorkspace.apply(.setQuadrant(handle, q), to: currentSnapshot, todayYMD: todayYMD); save(); ensureCursor() }
        catch { report(error) }
    }
    private var currentSnapshot: TaskDocumentSnapshot {
        TaskDocumentSnapshot(lines: lines, scratch: scratch, archiveLines: archiveLines, generation: generation)
    }
    func rescheduleOverdue() {
        do { lines = try TaskWorkspace.apply(.rescheduleOverdue, to: currentSnapshot, todayYMD: todayYMD); save(); ensureCursor() }
        catch { report(error) }
    }
    func addFromCapture(_ input: String) {
        guard let raw = Capture.makeTaskLine(from: input, today: Date(), createdYMD: todayYMD) else { return }
        lines.append(TaskLine(raw))
        view = .list; cursor = lines.count - 1; ensureCursor(); save()
    }
    func toggleFocusMode() {
        guard focusIndex != nil else { return }
        focusMode.toggle()
    }
    func cycleDensity(_ delta: Int) {
        density = Density(rawValue: max(0, min(2, density.rawValue + delta))) ?? density
    }
    func startEditing() {
        guard view == .list, let i = cursor, lines.indices.contains(i), !lines[i].isDone else { return }
        editingIndex = i
    }

    /// ⌘E 編輯彈窗:一次寫回標題 / 到期 / 專案 / 便箋(逐欄最小變更,未動的 token 原樣保留)。
    func applyEdit(_ index: Int, title: String, due: String, projects: String, contexts: String, note: String) {
        guard lines.indices.contains(index) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != lines[index].title { lines[index].setTitle(t) }

        let dueInput = due.trimmingCharacters(in: .whitespaces)
        if dueInput.isEmpty {
            lines[index].setDue(nil)
        } else if let norm = DueDateParser.parse(dueInput, today: Date()), norm != lines[index].due {
            lines[index].setDue(norm)
        }

        // 專案:以輸入為準做增刪(輸入格式 "+a +b" 或 "a b")
        let wanted = Set(projects.split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init))
        for p in Set(lines[index].projects).subtracting(wanted) { lines[index].removeTag("+" + p) }
        for p in wanted.subtracting(Set(lines[index].projects)) { lines[index].addTag("+" + p) }

        // 情境:同樣以輸入為準做增刪
        let wantedCtx = Set(contexts.split(whereSeparator: { $0 == " " || $0 == "@" }).map(String.init))
        for c in Set(lines[index].contexts).subtracting(wantedCtx) { lines[index].removeTag("@" + c) }
        for c in wantedCtx.subtracting(Set(lines[index].contexts)) { lines[index].addTag("@" + c) }

        lines[index].setNote(note)
        save(); ensureCursor()
    }
    func updateTitle(_ index: Int, _ text: String) {
        if lines.indices.contains(index), !text.trimmingCharacters(in: .whitespaces).isEmpty {
            lines[index].setTitle(text); save()
        }
        editingIndex = nil
    }
    func addProjectToCursor(_ name: String) {
        let clean = name.split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "@" }).joined()
        guard !clean.isEmpty, let i = cursor, lines.indices.contains(i) else { return }
        lines[i].addTag("+" + clean); save()
    }
}
