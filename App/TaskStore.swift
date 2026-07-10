import SwiftUI
import ServiceManagement
import TasksTxtCore

enum AppView { case list, grid, pad }

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
    @Published var view: AppView = .list
    @Published var cursor: Int? = nil          // index into `lines`
    @Published var focusMode = false
    @Published var overdueOpen = true
    @Published var scratch = ""
    @Published var tagFilter: String? = nil   // "+project" 或 "@context";nil = 不篩選
    @Published var editingIndex: Int? = nil   // 正在行內編輯的列
    @Published var searchQuery = ""           // `/` 即打即濾
    @Published var searchActive = false
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

    // 開機自啟（SMAppService, macOS 13+）
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    func setLaunchAtLogin(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        objectWillChange.send()
    }

    func clearSearch() { searchQuery = ""; searchActive = false; ensureCursor() }

    let fileURL: URL
    let scratchURL: URL
    let archiveURL: URL

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/tasks-txt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("tasks.txt")
        scratchURL = dir.appendingPathComponent("scratch.txt")
        archiveURL = dir.appendingPathComponent("archive.txt")
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
        let today = todayYMD
        let oldIdx = lines.indices.filter {
            lines[$0].isDone && (lines[$0].completedDate ?? today) < today
        }
        guard !oldIdx.isEmpty else { return }
        let moved = oldIdx.map { lines[$0].raw }.joined(separator: "\n")
        let existing = (try? String(contentsOf: archiveURL, encoding: .utf8)) ?? ""
        let archive = existing.isEmpty ? moved + "\n" : existing + (existing.hasSuffix("\n") ? "" : "\n") + moved + "\n"
        try? archive.write(to: archiveURL, atomically: true, encoding: .utf8)
        for i in oldIdx.reversed() { lines.remove(at: i) }
        editingIndex = nil
        save(); ensureCursor()
    }

    // MARK: file IO

    private func bootstrapIfMissing() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let sample = """
        Finish landing page due:\(RelativeDate.todayYMD()) note:"update colors" focus:true q:1
        Review Q3 numbers due:\(RelativeDate.todayYMD())
        Call design lead +freelance q:2
        Daily marketing distribution +marketing
        Set up portfolio limits
        """
        try? sample.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func load() {
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        lines = TasksDocument.parse(text)
        scratch = (try? String(contentsOf: scratchURL, encoding: .utf8)) ?? ""
    }

    private func save() {
        let text = TasksDocument.serialize(lines)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func saveScratch() {
        try? scratch.write(to: scratchURL, atomically: true, encoding: .utf8)
    }

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
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        guard text != TasksDocument.serialize(lines) else { return }
        lines = TasksDocument.parse(text)
        editingIndex = nil
        ensureCursor()
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
        let od = overdueOpen ? g.overdue : []
        return g.today + od + g.upcoming + g.noDate + g.done
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
        lines[i].setDone(!lines[i].isDone, date: todayYMD)
        save(); ensureCursor()
    }
    func toggleFocus() {
        guard let i = cursor, lines.indices.contains(i) else { return }
        let already = lines[i].isFocused
        lines = TasksDocument.setFocus(lines, onIndex: already ? nil : i)
        if already { focusMode = false }
        save()
    }
    func clearFocus() {
        lines = TasksDocument.setFocus(lines, onIndex: nil); focusMode = false; save()
    }
    func setQuadrant(_ q: Int?) {
        guard let i = cursor, lines.indices.contains(i) else { return }
        lines[i].setQuadrant(q); save(); ensureCursor()
    }
    func setQuadrantAt(_ index: Int, _ q: Int?) {   // 拖拉放置用
        guard lines.indices.contains(index), !lines[index].isDone else { return }
        lines[index].setQuadrant(q); save()
    }
    func rescheduleOverdue() {
        for i in lines.indices where !lines[i].isDone {
            if let due = lines[i].due, due < todayYMD { lines[i].setDue(todayYMD) }
        }
        save(); ensureCursor()
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
