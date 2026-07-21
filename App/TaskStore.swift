import SwiftUI
import ServiceManagement
import TasksTxtCore

enum AppView { case list, grid, pad, dash, settings }

struct InstalledPlugin: Identifiable, Hashable {
    let id: String
    let name: String
    let version: String
    let capabilities: [String]
}

enum Density: Int, CaseIterable, Hashable {
    case compact = 0, normal = 1, spacious = 2
    var rowPad: CGFloat { [CGFloat(3), 6, 11][rawValue] }       // 每列上下內距
    var sectionTop: CGFloat { [CGFloat(14), 22, 30][rawValue] } // 分組之間的呼吸
    var label: String { ["緊湊", "標準", "寬鬆"][rawValue] }
}

enum DashboardIconStyle: Int, CaseIterable, Hashable {
    case chronoOrb, terminalPulse, completionCompass, quietHorizon
    var label: String { ["時序光環", "終端脈衝", "完成羅盤", "安靜地平線"][rawValue] }
}

enum AppIconStyle: String, CaseIterable, Hashable {
    case flatGeometric, macOSGlass, retroCRTPixel
    private static let imageCache = NSCache<NSString, NSImage>()

    var label: String {
        switch self {
        case .flatGeometric: return "平面幾何"
        case .macOSGlass: return "macOS 玻璃"
        case .retroCRTPixel: return "復古 CRT 像素"
        }
    }

    private var resource: (name: String, extension: String) {
        switch self {
        case .flatGeometric: return ("AppIcon", "icns")
        case .macOSGlass: return ("txtnimal-icon-glass", "png")
        case .retroCRTPixel: return ("txtnimal-icon-crt", "png")
        }
    }

    func image(in bundle: Bundle = .main) -> NSImage? {
        let cacheKey = "\(bundle.bundlePath)|\(resource.name).\(resource.extension)" as NSString
        if let cached = Self.imageCache.object(forKey: cacheKey) { return cached }
        guard let url = bundle.url(forResource: resource.name, withExtension: resource.extension) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        Self.imageCache.setObject(image, forKey: cacheKey)
        return image
    }
}

enum AppLanguage: String, CaseIterable, Hashable {
    case traditionalChinese = "zh-Hant"
    case english = "en"
    var label: String { self == .traditionalChinese ? "繁體中文" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
}

enum LatinFontChoice: String, CaseIterable, Hashable {
    case systemMonospaced, menlo, monaco, courierNew
    var label: String {
        switch self {
        case .systemMonospaced: return "系統等寬"
        case .menlo: return "Menlo"
        case .monaco: return "Monaco"
        case .courierNew: return "Courier New"
        }
    }
    var fontName: String? {
        switch self {
        case .systemMonospaced: return nil
        case .menlo: return "Menlo"
        case .monaco: return "Monaco"
        case .courierNew: return "Courier New"
        }
    }
}

enum ChineseFontChoice: String, CaseIterable, Hashable {
    case pingFangTC, heitiTC, songtiTC, kaitiTC
    var label: String {
        switch self {
        case .pingFangTC: return "蘋方繁體"
        case .heitiTC: return "黑體繁體"
        case .songtiTC: return "宋體繁體"
        case .kaitiTC: return "楷體繁體"
        }
    }
    var fontName: String {
        switch self {
        case .pingFangTC: return "PingFang TC"
        case .heitiTC: return "Heiti TC"
        case .songtiTC: return "Songti TC"
        case .kaitiTC: return "Kaiti TC"
        }
    }
}

/// 全部狀態的家：檔案內容 + UI 狀態（游標 / 視圖 / Focus 模式）。
/// v1 每次變更即存檔;FSEvents 外部監看為 v2。
final class TaskStore: ObservableObject {
    static let bundledPlugins: [InstalledPlugin] = [
        InstalledPlugin(id: "app.txtnimal.reschedule-tomorrow", name: "Reschedule Tomorrow", version: "1.0.0", capabilities: ["tasks.update"]),
        InstalledPlugin(id: "app.txtnimal.weekly-review", name: "Weekly Review", version: "1.0.0", capabilities: ["tasks.all.read", "ui.page"])
    ]
    @Published var enabledPluginIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "enabledPluginIDs") ?? bundledPlugins.map(\.id))
    }() {
        didSet { UserDefaults.standard.set(Array(enabledPluginIDs), forKey: "enabledPluginIDs") }
    }

    func isPluginEnabled(_ plugin: InstalledPlugin) -> Bool { enabledPluginIDs.contains(plugin.id) }
    func setPluginEnabled(_ plugin: InstalledPlugin, _ enabled: Bool) {
        if enabled { enabledPluginIDs.insert(plugin.id) } else { enabledPluginIDs.remove(plugin.id) }
    }
    @Published private(set) var lines: [TaskLine] = []
    @Published private(set) var archiveLines: [TaskLine] = []
    @Published var lastError: String?
    @Published var appLanguage: AppLanguage = {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hant") ?? .traditionalChinese
    }() {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "appLanguage") }
    }
    @Published var latinFontChoice: LatinFontChoice = {
        let saved = UserDefaults.standard.string(forKey: "latinFontChoice")
            ?? UserDefaults.standard.string(forKey: "appFontChoice")
            ?? "systemMonospaced"
        return LatinFontChoice(rawValue: saved) ?? .systemMonospaced
    }() {
        didSet { UserDefaults.standard.set(latinFontChoice.rawValue, forKey: "latinFontChoice") }
    }
    @Published var chineseFontChoice: ChineseFontChoice = {
        ChineseFontChoice(rawValue: UserDefaults.standard.string(forKey: "chineseFontChoice") ?? "pingFangTC") ?? .pingFangTC
    }() {
        didSet { UserDefaults.standard.set(chineseFontChoice.rawValue, forKey: "chineseFontChoice") }
    }
    @Published var showWelcomeOnLaunch = UserDefaults.standard.bool(forKey: "showWelcomeOnLaunch") {
        didSet { UserDefaults.standard.set(showWelcomeOnLaunch, forKey: "showWelcomeOnLaunch") }
    }
    @Published var hasCompletedOnboarding: Bool = {
        if UserDefaults.standard.bool(forKey: "showWelcomeOnLaunch") { return false }
        return UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }()
    @Published private(set) var installedPluginPackages: [InstalledPluginPackage] = []
    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }
    @Published var view: AppView = .list
    @Published var cursor: Int? = nil          // index into `lines`
    @Published var focusMode = false
    @Published var scratch = ""
    @Published var tagFilter: String? = nil   // "+project" 或 "@context";nil = 不篩選
    @Published private(set) var listDescriptions: [String: String] = {
        guard let data = UserDefaults.standard.data(forKey: "listDescriptions"),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }()
    @Published var editingIndex: Int? = nil   // 正在行內編輯的列
    @Published var searchQuery = ""           // `/` 即打即濾
    @Published var searchActive = false
    @Published var requestInlineAdd = false   // `n` 鍵 → 聚焦清單尾端新增列
    @Published var inlineAddActive = false    // 新增列正在接收鍵盤事件
    @Published var density: Density = {
        Density(rawValue: (UserDefaults.standard.object(forKey: "density") as? Int) ?? 1) ?? .normal
    }() {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }
    // 0 系統 / 1 深色 / 2 淺色
    @Published var appearanceMode: Int = UserDefaults.standard.integer(forKey: "appearance") {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: "appearance"); applyAppearance() }
    }
    @Published var appIconStyle: AppIconStyle = {
        let defaults = UserDefaults.standard
        guard let saved = defaults.string(forKey: "appIconStyle"),
              let style = AppIconStyle(rawValue: saved) else {
            defaults.set(AppIconStyle.flatGeometric.rawValue, forKey: "appIconStyle")
            return .flatGeometric
        }
        return style
    }() {
        didSet {
            UserDefaults.standard.set(appIconStyle.rawValue, forKey: "appIconStyle")
            applyAppIcon()
        }
    }
    func applyAppIcon() {
        if let image = appIconStyle.image() {
            NSApp.applicationIconImage = image
            return
        }
        let failedStyle = appIconStyle
        if failedStyle != .flatGeometric {
            appIconStyle = .flatGeometric
            UserDefaults.standard.set(AppIconStyle.flatGeometric.rawValue, forKey: "appIconStyle")
        }
        let message: String
        if let fallback = AppIconStyle.flatGeometric.image() {
            NSApp.applicationIconImage = fallback
            message = appLanguage == .english
                ? "Could not load the selected app icon. The default icon has been restored."
                : "無法載入「\(failedStyle.label)」App 圖示，已恢復預設圖示。"
        } else if let systemFallback = NSImage(named: NSImage.applicationIconName) {
            NSApp.applicationIconImage = systemFallback
            message = appLanguage == .english
                ? "Could not load the selected or default app icon. A system fallback is being used."
                : "無法載入選用及預設 App 圖示，目前使用系統備援圖示。"
        } else {
            message = appLanguage == .english
                ? "Could not load or restore the app icon."
                : "無法載入或恢復 App 圖示。"
        }
        lastError = message
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

    /// 內容與標籤分開調整，數值持久化並限制在可讀範圍。
    @Published var taskTextSize: Double = {
        let saved = UserDefaults.standard.double(forKey: "taskTextSize")
        return saved == 0 ? 13.5 : max(10, min(24, saved))
    }() {
        didSet {
            taskTextSize = max(10, min(24, taskTextSize))
            UserDefaults.standard.set(taskTextSize, forKey: "taskTextSize")
        }
    }
    @Published var tagTextSize: Double = {
        let saved = UserDefaults.standard.double(forKey: "tagTextSize")
        return saved == 0 ? 11.5 : max(9, min(20, saved))
    }() {
        didSet {
            tagTextSize = max(9, min(20, tagTextSize))
            UserDefaults.standard.set(tagTextSize, forKey: "tagTextSize")
        }
    }
    var taskFont: Font { Theme.appFont(size: taskTextSize) }
    var taskSmallFont: Font { Theme.appFont(size: max(9, taskTextSize - 2)) }
    var tagFont: Font { Theme.appFont(size: tagTextSize) }
    @Published var dashboardIconStyle: DashboardIconStyle = {
        DashboardIconStyle(rawValue: UserDefaults.standard.integer(forKey: "dashboardIconStyle")) ?? .chronoOrb
    }() {
        didSet { UserDefaults.standard.set(dashboardIconStyle.rawValue, forKey: "dashboardIconStyle") }
    }

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
    private var pluginPackageStore: PluginPackageStore?
    private var generation: UInt64 = 0

    static let defaultDataDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/tasks-txt", isDirectory: true)
    private static func storedTaskFile() -> URL {
        if let path = UserDefaults.standard.string(forKey: "activeTaskFile") {
            return URL(fileURLWithPath: path)
        }
        return storedDataDir().appendingPathComponent("tasks.txt")
    }
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
            UserDefaults.standard.set(documentStore.tasksURL.path, forKey: "activeTaskFile")
            fileURL = documentStore.tasksURL; scratchURL = documentStore.scratchURL; archiveURL = documentStore.archiveURL
        } catch { report(error); return }
        bootstrapIfMissing()
        load()
        cursor = listOrder().first
        ensureCursor()
        startWatching()
    }

    init() {
        let selectedFile = Self.storedTaskFile()
        let dir = selectedFile.deletingLastPathComponent()
        fileURL = selectedFile
        scratchURL = dir.appendingPathComponent("scratch.txt")
        archiveURL = dir.appendingPathComponent("archive.txt")
        do { documentStore = try FileSystemTaskDocumentStore(directory: dir, tasksFilename: selectedFile.lastPathComponent) }
        catch { fatalError("Cannot initialize task document store: \(error)") }
        pluginPackageStore = try? PluginPackageStore(directory: dir.appendingPathComponent(".plugins", isDirectory: true))
        refreshInstalledPlugins()
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

    func refreshInstalledPlugins() {
        installedPluginPackages = (try? pluginPackageStore?.list()) ?? []
    }

    func removeInstalledPlugin(_ package: InstalledPluginPackage) {
        do {
            try pluginPackageStore?.remove(id: package.manifest.id)
            enabledPluginIDs.remove(package.manifest.id)
            refreshInstalledPlugins()
        } catch { report(error) }
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

    // MARK: task files

    var pinnedTaskFiles: [URL] {
        let paths = UserDefaults.standard.stringArray(forKey: "pinnedTaskFiles") ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }

    func isPinned(_ url: URL) -> Bool {
        pinnedTaskFiles.contains { $0.standardizedFileURL == url.standardizedFileURL }
    }

    func togglePinned(_ url: URL) {
        var paths = pinnedTaskFiles.map(\.path)
        if let index = paths.firstIndex(of: url.path) { paths.remove(at: index) }
        else { paths.append(url.path) }
        UserDefaults.standard.set(paths, forKey: "pinnedTaskFiles")
        objectWillChange.send()
    }

    func openTaskFile(_ url: URL) {
        let target = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: target.path) else {
            lastError = "找不到檔案：\(target.path)"; return
        }
        stopWatching()
        do {
            let next = try FileSystemTaskDocumentStore(
                directory: target.deletingLastPathComponent(), tasksFilename: target.lastPathComponent)
            documentStore = next
            fileURL = next.tasksURL; scratchURL = next.scratchURL; archiveURL = next.archiveURL
            UserDefaults.standard.set(fileURL.path, forKey: "activeTaskFile")
            UserDefaults.standard.set(fileURL.deletingLastPathComponent().path, forKey: "dataDir")
            load(); archiveOldDone(); cursor = listOrder().first; ensureCursor(); startWatching()
        } catch { report(error); startWatching() }
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
    func allProjects() -> [String] {
        Array(Set(lines.flatMap { $0.projects }).union(listDescriptions.keys)).sorted()
    }
    func allContexts() -> [String] { Array(Set(lines.flatMap { $0.contexts })).sorted() }
    var hasTags: Bool { !listDescriptions.isEmpty || lines.contains { !$0.projects.isEmpty || !$0.contexts.isEmpty } }

    func listDescription(_ name: String) -> String { listDescriptions[name] ?? "" }

    /// List metadata 存在 app 設定中；重新命名時同步更新 todo.txt 內的 +List token。
    func saveList(originalName: String?, name: String, description: String) {
        let clean = name.split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "@" }).joined()
        guard !clean.isEmpty else { return }
        let original = originalName?.trimmingCharacters(in: .whitespaces)
        if let original, !original.isEmpty, original != clean {
            for i in lines.indices where lines[i].projects.contains(original) {
                lines[i].removeTag("+" + original)
                lines[i].addTag("+" + clean)
            }
            listDescriptions.removeValue(forKey: original)
            if tagFilter == "+" + original { tagFilter = "+" + clean }
            save()
        }
        listDescriptions[clean] = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = try? JSONEncoder().encode(listDescriptions) {
            UserDefaults.standard.set(data, forKey: "listDescriptions")
        }
        tagFilter = "+" + clean
        ensureCursor()
    }

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
