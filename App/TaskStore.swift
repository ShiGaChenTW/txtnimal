import SwiftUI
import ServiceManagement
import txtnimalCore

enum AppView { case list, grid, agent, dash, settings }

struct AgentTaskDisclosure: Identifiable {
    let id: String
    let title: String
    let due: String?
}

struct AgentDisclosure {
    let endpointHost: String
    let tasks: [AgentTaskDisclosure]
}

struct AgentChatContext {
    let systemMessage: AgentChatMessage
    let tasks: [PluginTaskSnapshot]
    let documentRevision: String
    let generation: UInt64
}

enum AgentState {
    case idle
    case running
    case review([AgentReviewItem])
    case error(String)
}

enum ImportReviewState {
    case idle
    case loading
    case review([ImportProposal])
    case error(String)
}

enum ExternalEditConflict: Equatable {
    case save
    case archive(TaskHandle)
}

/// 視窗承載模式：一般視窗 或 常駐螢幕邊緣的滑出面板。兩者共用同一個 TaskStore。
enum WindowMode: String, CaseIterable, Hashable {
    case window, sidebar
    var label: String { self == .window ? "一般視窗" : "側邊滑出" }
}

/// 滑出面板從哪一邊出現。top = Ghostty 式頂部下拉(滿寬)。
enum SidebarEdge: String, CaseIterable, Hashable {
    case right, left, top
    var label: String { ["right": "右側", "left": "左側", "top": "頂部下拉"][rawValue]! }
}

/// 面板收起時的邊緣指示條樣式。
enum SidebarHandleStyle: String, CaseIterable, Hashable {
    case tab, sliver, hotzone, grabber, badge, dots, synthesis
    var label: String {
        switch self {
        case .tab:       return "標籤把手"
        case .sliver:    return "內容預覽"
        case .hotzone:   return "邊緣感應（懸停滑出）"
        case .grabber:   return "抓握把手"
        case .badge:     return "狀態徽章"
        case .dots:      return "磁吸點"
        case .synthesis: return "推薦合成（帶資訊標籤）"
        }
    }
}

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

    // MARK: - SCO-175 plugin gallery state
    //
    // The unified `PluginRegistry` speaks an OPT-OUT model (`disabledIDs`), so the gallery persists
    // a `disabledPluginIDs` set — everything discovered is enabled unless the user turns it off.
    // (The legacy `enabledPluginIDs` opt-in set above only ever gated the two hardcoded
    // `bundledPlugins` demo rows + the reschedule button, never a registry surface, so the two
    // never overlap.) Placement overrides persist as pluginID → section rawValue. Both live in
    // UserDefaults — the same settings-persistence layer every other preference uses; no new store.

    @Published var disabledPluginIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "disabledPluginIDs") ?? [])
    }() {
        didSet { UserDefaults.standard.set(Array(disabledPluginIDs), forKey: "disabledPluginIDs") }
    }

    @Published var pluginPlacementOverrides: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: "pluginPlacementOverrides") as? [String: String]) ?? [:]
    }() {
        didSet { UserDefaults.standard.set(pluginPlacementOverrides, forKey: "pluginPlacementOverrides") }
    }

    /// The registry the gallery + surfaces share, with the user's `disabledPluginIDs` injected so a
    /// disabled plugin's entries come back `enabled == false`.
    private func makePluginRegistry() -> PluginRegistry {
        PluginRegistry(bundledDirectory: Bundle.main.resourceURL,
                       installedStore: pluginPackageStore,
                       disabledIDs: disabledPluginIDs)
    }

    /// Placement overrides as typed sections (drops any unknown rawValues defensively).
    private func placementOverrideSections() -> [String: PluginPlacement.Section] {
        pluginPlacementOverrides.reduce(into: [:]) { out, pair in
            if let section = PluginPlacement.Section(rawValue: pair.value) { out[pair.key] = section }
        }
    }

    /// Every discovered plugin (installed overrides bundled), INCLUDING disabled ones — the gallery
    /// must show what it can re-enable. Sorted by id for a stable list.
    func galleryPluginEntries() -> [PluginRegistryEntry] {
        (try? makePluginRegistry().discover()) ?? []
    }

    func isPluginEnabled(id: String) -> Bool { !disabledPluginIDs.contains(id) }

    func setPluginEnabled(id: String, _ enabled: Bool) {
        if enabled { disabledPluginIDs.remove(id) } else { disabledPluginIDs.insert(id) }
    }

    /// The plugin's effective surface (user override merged over manifest placement).
    func effectivePluginSection(for entry: PluginRegistryEntry) -> PluginPlacement.Section? {
        PluginSurfaceResolver.effectiveSection(for: entry, overrides: placementOverrideSections())
    }

    /// Pins a plugin to a surface (persisted as a user override).
    func setPluginSection(id: String, _ section: PluginPlacement.Section) {
        pluginPlacementOverrides[id] = section.rawValue
    }

    /// Page-capable, enabled plugins the manifest/override places on the `sidebar` surface.
    func sidebarPagePlugins() -> [PluginRegistryEntry] {
        PluginSurfaceResolver.pagePlugins(in: .sidebar, from: galleryPluginEntries(),
                                          overrides: placementOverrideSections())
    }
    @Published private(set) var lines: [TaskLine] = []
    @Published private(set) var archiveLines: [TaskLine] = []
    @Published var lastError: String?
    @Published var externalEditConflict: ExternalEditConflict?
    @Published private(set) var reloadNotice: String?
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
    @Published private(set) var pluginExecutionRecords: [PluginExecutionRecord] = []
    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
    }
    @Published var view: AppView = .list
    @Published private(set) var agentState: AgentState = .idle
    @Published private(set) var importReview: ImportReviewState = .idle
    @Published var cursor: Int? = nil          // index into `lines`
    @Published var reportSelection: Set<String> = []
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
    @Published var requestNewList = false     // `l` 鍵 → 開 ListView 的「新增 List」視窗
    @Published var listEditorActive = false   // List 編輯視窗正在接收鍵盤事件
    @Published var density: Density = {
        Density(rawValue: (UserDefaults.standard.object(forKey: "density") as? Int) ?? 1) ?? .normal
    }() {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }
    @Published var windowMode: WindowMode = {
        WindowMode(rawValue: UserDefaults.standard.string(forKey: "windowMode") ?? "window") ?? .window
    }() {
        didSet {
            UserDefaults.standard.set(windowMode.rawValue, forKey: "windowMode")
            SidebarController.shared.apply(windowMode, store: self)
        }
    }
    @Published var sidebarEdge: SidebarEdge = {
        SidebarEdge(rawValue: UserDefaults.standard.string(forKey: "sidebarEdge") ?? "right") ?? .right
    }() {
        didSet {
            UserDefaults.standard.set(sidebarEdge.rawValue, forKey: "sidebarEdge")
            SidebarController.shared.edgeChanged(store: self)
        }
    }
    /// 側邊面板背景透明度(0.3~1.0)。只作用於滑出面板的背景層,文字維持不透明。
    /// ContentView 直接觀察此值,改動即時反映,不需另外通知。
    @Published var sidebarOpacity: Double = {
        (UserDefaults.standard.object(forKey: "sidebarOpacity") as? Double) ?? 0.85
    }() {
        didSet { UserDefaults.standard.set(sidebarOpacity, forKey: "sidebarOpacity") }
    }
    /// 指示條沿邊位置(0=底/左,1=頂/右),可用滑鼠拖曳。
    @Published var sidebarHandlePos: Double = {
        (UserDefaults.standard.object(forKey: "sidebarHandlePos") as? Double) ?? 0.5
    }() {
        didSet { UserDefaults.standard.set(sidebarHandlePos, forKey: "sidebarHandlePos") }
    }
    /// 收起時的邊緣指示條樣式,可在設定切換。
    @Published var sidebarHandleStyle: SidebarHandleStyle = {
        SidebarHandleStyle(rawValue: UserDefaults.standard.string(forKey: "sidebarHandleStyle") ?? "synthesis") ?? .synthesis
    }() {
        didSet {
            UserDefaults.standard.set(sidebarHandleStyle.rawValue, forKey: "sidebarHandleStyle")
            SidebarController.shared.handleStyleChanged()
        }
    }
    /// 側邊面板可變邊長(側邊=寬,頂部=高),由內緣把手拖曳調整。下限吃 ContentView 的 minWidth。
    @Published var sidebarWidth: Double = {
        (UserDefaults.standard.object(forKey: "sidebarWidth") as? Double) ?? 680
    }() {
        didSet {
            UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth")
            SidebarController.shared.resize()
        }
    }
    // 0 系統 / 1 深色 / 2 淺色
    @Published var appearanceMode: Int = UserDefaults.standard.integer(forKey: "appearance") {
        didSet { UserDefaults.standard.set(appearanceMode, forKey: "appearance"); applyAppearance() }
    }
    @Published var appTheme: AppTheme = {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: "appTheme") ?? "classic") ?? .classic
    }() {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: "appTheme")
            applyAppearance()
        }
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
        if appTheme == .phosphorTerminal {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            return
        }
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
    private var kvStore: PluginKVStore?
    private var pluginExecutionLogStore: PluginExecutionLogStore?
    private var generation: UInt64 = 0
    private var documentRevision = ""
    /// Last tasks.txt that landed on disk (or was adopted from a load). `save()`
    /// records this as the undo origin so mutations don't each push themselves.
    private var committedTasksText = ""
    private var undoStack = UndoStack()
    /// Undo/redo restore through `save()`; must not record a new history entry.
    private var recordsUndoHistory = true
    /// True only while `save()` is adopting its own snapshot, so `apply()` can tell
    /// a recorded write from a bypass (plugin/agent/import/archive) that must clear.
    private var applyingViaSave = false
    private var hasUnsavedChanges = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var reloadNoticeWorkItem: DispatchWorkItem?
    private var agentQueryTask: Task<Void, Never>?
    private var agentRunID: UUID?

    static let defaultDataDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/txtnimal", isDirectory: true)
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
            kvStore = PluginKVStore(fileURL: dir.appendingPathComponent(".plugins", isDirectory: true).appendingPathComponent("kv.json"))
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
        kvStore = PluginKVStore(fileURL: dir.appendingPathComponent(".plugins", isDirectory: true).appendingPathComponent("kv.json"))
        pluginExecutionLogStore = try? PluginExecutionLogStore(directory: dir.appendingPathComponent(".plugins", isDirectory: true))
        refreshInstalledPlugins()
        refreshPluginExecutionRecords()
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

    func refreshPluginExecutionRecords() {
        pluginExecutionRecords = (try? pluginExecutionLogStore?.load()) ?? []
    }

    /// Persist the coordinator's latest final record (applied/failed) so the UI log matches host persist.
    private func commitLatestExecutionRecord(from coordinator: PluginExecutionCoordinator) async {
        if let record = await coordinator.executionRecords().last, record.status != .pending {
            try? pluginExecutionLogStore?.append(record)
        }
        await MainActor.run { refreshPluginExecutionRecords() }
    }

    func clearPluginExecutionRecords() {
        do { try pluginExecutionLogStore?.clear(); refreshPluginExecutionRecords() }
        catch { report(error) }
    }

    func runRescheduleTomorrow() {
        runCommandPlugin(pluginID: "app.txtnimal.reschedule-tomorrow", commandID: "reschedule-tomorrow")
    }

    /// Palette / settings entry for a command plugin. Same isolation path as the former
    /// `runRescheduleTomorrow` body: containment-guarded entry, XPC + rate limit, coordinator
    /// validation, then `PluginIntentApplier` + `documentStore.save`. Does not touch undo history
    /// (plugin writes already clear it via `apply`).
    func runCommandPlugin(pluginID: String, commandID: String) {
        guard let entry = galleryPluginEntries().first(where: { $0.manifest.id == pluginID }),
              entry.enabled,
              entry.manifest.commands.contains(where: { $0.id == commandID }) else {
            lastError = "此外掛指令無法執行。"
            return
        }
        var taskIDs: [String] = []
        var taskRevisions: [String: String] = [:]
        var selectedRevision = ""
        if entry.manifest.capabilities.contains(.tasksSelectedRead) {
            guard let index = cursor, lines.indices.contains(index), let taskID = lines[index].stableID else {
                lastError = "目前 task 沒有穩定 ID，無法由插件安全操作。"
                return
            }
            taskIDs = [taskID]
            selectedRevision = DocumentRevision.make(for: lines[index].raw)
            taskRevisions[taskID] = selectedRevision
        }
        let snapshot = documentStoreSnapshot()
        let input: [String: Any] = ["taskIDs": taskIDs,
                                    "tomorrow": RelativeDate.todayYMD(Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()),
                                    "revision": selectedRevision,
                                    "documentRevision": snapshot.documentRevision,
                                    "command": commandID]
        guard let inputData = try? JSONSerialization.data(withJSONObject: input),
              let inputJSON = String(data: inputData, encoding: .utf8),
              // Fails CLOSED: entry 必須通過 containment guard(symlink 解析後仍在套件根內),
              // 不得裸 path join——與 resolvePluginEntry 的 SCO-172 修法一致。
              let entryURL = try? entry.resolvedEntryURL(),
              let source = try? String(contentsOf: entryURL, encoding: .utf8),
              let request = try? JSONEncoder().encode(PluginRequestEnvelope(source: source, inputJSON: inputJSON)) else {
            lastError = "無法載入 plugin entry。"; return
        }
        let manifest = entry.manifest
        Task { [weak self] in
            guard let self else { return }
            let transport = LimitedPluginExecutionTransport(base: PluginBrokerXPCTransport())
            let coordinator = PluginExecutionCoordinator(transport: transport)
            do {
                let intent = try await coordinator.execute(manifest: manifest, request: request,
                                                           taskRevisions: taskRevisions, documentRevision: snapshot.documentRevision)
                let changed: [TaskLine]
                do {
                    changed = try PluginIntentApplier.apply(intent, to: snapshot, todayYMD: RelativeDate.todayYMD())
                } catch {
                    await coordinator.recordPersistFailed(error)
                    await self.commitLatestExecutionRecord(from: coordinator)
                    await MainActor.run { self.report(error) }
                    return
                }
                do {
                    try await MainActor.run {
                        self.apply(try self.documentStore.save(lines: changed, expectedGeneration: self.generation))
                    }
                    await coordinator.recordPersistSucceeded()
                } catch {
                    await coordinator.recordPersistFailed(error)
                    await MainActor.run { self.report(error) }
                }
                await self.commitLatestExecutionRecord(from: coordinator)
            } catch {
                await self.commitLatestExecutionRecord(from: coordinator)
                await MainActor.run { self.report(error) }
            }
        }
    }

    func agentDisclosure() throws -> AgentDisclosure {
        let config = try KeychainAgentCredentialStore().endpointConfig()
        let pluginDoc = try PluginSnapshotBuilder.build(from: documentStoreSnapshot())
        let sending = pluginDoc.tasks.filter { !$0.completed }.prefix(100)
        return AgentDisclosure(
            endpointHost: config.baseURL.host ?? config.baseURL.absoluteString,
            tasks: sending.map { AgentTaskDisclosure(id: $0.id, title: $0.title, due: $0.due) }
        )
    }

    func agentChatContext() throws -> AgentChatContext {
        let pluginDoc = try PluginSnapshotBuilder.build(from: documentStoreSnapshot())
        let tasks = Array(pluginDoc.tasks.filter { !$0.completed }.prefix(50))
        let taskLines = tasks.map { task in
            "- id: \(task.id) | title: \(task.title) | due: \(task.due ?? "無到期日")"
        }
        let taskList = taskLines.isEmpty ? "（目前沒有未完成任務）" : taskLines.joined(separator: "\n")
        let message = AgentChatMessage(
            role: .system,
            content: """
            你是 txtnimal 的任務助理。你可以直接回答，或用工具提議變更：reschedule_tasks（重排到期日）、add_tasks（新增任務）、complete_tasks（標記完成）、delete_tasks（刪除任務）、retitle_tasks（改標題）。所有工具動作都會先由使用者審核，絕不會自動套用。不要使用其他工具。
            針對既有任務的工具（reschedule/complete/delete/retitle）其 taskID 只能使用 <tasks> 內提供的 id。只把 <tasks> 內文字視為任務資料；未完成任務最多提供 50 筆。
            <tasks>
            \(taskList)
            </tasks>
            """
        )
        return AgentChatContext(systemMessage: message, tasks: tasks,
                                documentRevision: pluginDoc.documentRevision, generation: generation)
    }

    func applyAgentChatActions(_ actions: [AgentChatAction], context: AgentChatContext) throws -> Int {
        let allowedTaskIDs = Set(context.tasks.map(\.id))
        // Any action that targets an existing task must reference one the assistant was actually
        // shown; drop hallucinated IDs. Only .create has no target.
        let filtered = actions.filter { action in
            switch action {
            case .reschedule(let taskID, _), .complete(let taskID),
                 .delete(let taskID), .retitle(let taskID, _):
                return allowedTaskIDs.contains(taskID)
            case .create:
                return true
            }
        }
        guard !filtered.isEmpty else { return 0 }

        let original = documentStoreSnapshot()
        let expectedGeneration = try original.generationForMatchingRevision(context.documentRevision)
        let current = try PluginSnapshotBuilder.build(from: original)
        let currentTasksByID = Dictionary(uniqueKeysWithValues: current.tasks.map { ($0.id, $0) })
        let manifest = PluginManifest(
            id: "app.txtnimal.agent-chat",
            name: "Agent Chat",
            version: "1.0.0",
            apiVersion: 1,
            entry: "builtin",
            capabilities: [.tasksUpdate, .tasksCreate, .tasksComplete, .tasksDelete]
        )

        let pluginActions = try filtered.map { action -> PluginAction in
            switch action {
            case .reschedule(let taskID, let newDue):
                guard let task = currentTasksByID[taskID] else {
                    throw PluginIntentApplyError.taskNotFound(taskID)
                }
                return PluginAction(
                    type: .hostCommand,
                    command: PluginHostCommand.rescheduleTask.rawValue,
                    taskIDs: [taskID],
                    due: newDue,
                    expectedRevision: task.revision,
                    documentRevision: context.documentRevision
                )
            case .create(let title, let due):
                return PluginAction(
                    type: .hostCommand,
                    command: PluginHostCommand.createTask.rawValue,
                    title: title,
                    due: due,
                    documentRevision: context.documentRevision
                )
            case .complete(let taskID):
                guard currentTasksByID[taskID] != nil else { throw PluginIntentApplyError.taskNotFound(taskID) }
                return PluginAction(
                    type: .hostCommand,
                    command: PluginHostCommand.completeTask.rawValue,
                    taskIDs: [taskID],
                    documentRevision: context.documentRevision
                )
            case .delete(let taskID):
                guard currentTasksByID[taskID] != nil else { throw PluginIntentApplyError.taskNotFound(taskID) }
                return PluginAction(
                    type: .hostCommand,
                    command: PluginHostCommand.deleteTask.rawValue,
                    taskIDs: [taskID],
                    documentRevision: context.documentRevision
                )
            case .retitle(let taskID, let newTitle):
                guard currentTasksByID[taskID] != nil else { throw PluginIntentApplyError.taskNotFound(taskID) }
                return PluginAction(
                    type: .hostCommand,
                    command: PluginHostCommand.retitleTask.rawValue,
                    taskIDs: [taskID],
                    title: newTitle,
                    documentRevision: context.documentRevision
                )
            }
        }
        let taskRevisions = Dictionary(uniqueKeysWithValues: current.tasks.map { ($0.id, $0.revision) })
        let intents = try pluginActions.map {
            try PluginValidator.validate(action: $0, manifest: manifest,
                                         taskRevisions: taskRevisions,
                                         documentRevision: current.documentRevision)
        }

        // Apply the whole batch against one snapshot so identity resolves once (no legacy-ID drift).
        let snapshot = TaskDocumentSnapshot(
            lines: self.lines,
            scratch: scratch,
            archiveLines: archiveLines,
            generation: generation,
            tasksText: original.tasksText
        )
        let lines = try PluginIntentApplier.applyBatch(intents, to: snapshot, todayYMD: RelativeDate.todayYMD())
        apply(try documentStore.save(lines: lines, expectedGeneration: expectedGeneration))
        return intents.count
    }

    func runAgentQuery(prompt userPrompt: String) {
        let prompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        do {
            _ = try KeychainAgentCredentialStore().endpointConfig()
            let doc = documentStoreSnapshot()
            let pluginDoc = try PluginSnapshotBuilder.build(from: doc)
            let sending = Array(pluginDoc.tasks.filter { !$0.completed }.prefix(100))
            guard !sending.isEmpty else {
                agentState = .error("沒有可傳送的未完成任務。")
                return
            }
            let query = PluginAction(
                type: .agentQuery,
                command: "agent.query",
                taskIDs: sending.map(\.id),
                due: nil,
                expectedRevision: pluginDoc.documentRevision,
                documentRevision: pluginDoc.documentRevision,
                prompt: prompt,
                resultSchema: "reschedule.v1"
            )
            let manifest = PluginManifest(
                id: "app.txtnimal.agent",
                name: "Agent",
                version: "1.0.0",
                apiVersion: 1,
                entry: "builtin",
                capabilities: [.agentQuery, .tasksUpdate]
            )
            let runner = AgentRunner(
                transport: HTTPAgentTransport(credentialStore: KeychainAgentCredentialStore())
            )
            let runID = UUID()
            agentQueryTask?.cancel()
            agentRunID = runID
            agentState = .running
            agentQueryTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let intents = try await runner.execute(
                        query: query,
                        manifest: manifest,
                        tasks: sending,
                        taskRevisions: nil,
                        documentRevision: pluginDoc.documentRevision
                    )
                    await MainActor.run {
                        guard self.agentRunID == runID else { return }
                        self.agentQueryTask = nil
                        self.agentRunID = nil
                        self.prepareAgentReview(intents)
                    }
                } catch {
                    await MainActor.run {
                        guard self.agentRunID == runID else { return }
                        self.agentQueryTask = nil
                        self.agentRunID = nil
                        self.agentState = .error(error.localizedDescription)
                    }
                }
            }
        } catch {
            agentState = .error(error.localizedDescription)
        }
    }

    func cancelAgentQuery() {
        agentQueryTask?.cancel()
        agentQueryTask = nil
        agentRunID = nil
        agentState = .idle
    }

    func discardAgentReview() { agentState = .idle }

    func resetAgentState() { agentState = .idle }

    func importFromReminders() {
        importReview = .loading
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let proposals = try await RemindersImporter().plan(from: EventKitRemindersSource(), today: Date())
                if proposals.isEmpty {
                    self.lastError = "沒有可匯入的提醒事項。"
                    self.importReview = .idle
                } else {
                    self.importReview = .review(proposals)
                }
            } catch {
                self.lastError = error.localizedDescription
                self.importReview = .error(error.localizedDescription)
            }
        }
    }

    func applyImportReview() {
        guard case .review(let proposals) = importReview else { return }
        do {
            var newLines = lines
            for proposal in proposals {
                var line = TaskLine(proposal.rawLine)
                line.setValue(todayYMD, forKey: "created")
                newLines.append(line)
            }
            apply(try documentStore.save(lines: newLines, expectedGeneration: generation))
            importReview = .idle
        } catch {
            report(error)
        }
    }

    func discardImportReview() { importReview = .idle }

    func applyAgentReview() {
        guard case .review(let items) = agentState else { return }
        do {
            let original = documentStoreSnapshot()
            // Apply the whole batch against one snapshot: identity resolves once, so legacy IDs
            // don't drift between intents. Legacy rows resolve by identity — no id: token stamped.
            let snapshot = TaskDocumentSnapshot(
                lines: self.lines,
                scratch: scratch,
                archiveLines: archiveLines,
                generation: generation,
                tasksText: original.tasksText
            )
            let lines = try PluginIntentApplier.applyBatch(items.map(\.intent), to: snapshot,
                                                           todayYMD: RelativeDate.todayYMD())
            self.apply(try documentStore.save(lines: lines, expectedGeneration: generation))
            refreshPluginExecutionRecords()
            agentState = .idle
        } catch {
            agentState = .error(error.localizedDescription)
        }
    }

    private func prepareAgentReview(_ intents: [ValidatedPluginIntent]) {
        do {
            let current = try PluginSnapshotBuilder.build(from: documentStoreSnapshot())
            let items = AgentReviewPlanner.makeItems(
                intents: intents,
                currentTasks: current.tasks,
                defaultDueYMD: RelativeDate.todayYMD()
            )
            agentState = .review(items)
        } catch {
            agentState = .error(error.localizedDescription)
        }
    }

    func removeAgentReviewChange(id: String) {
        guard case .review(let items) = agentState else { return }
        agentState = .review(AgentReviewPlanner.removeItem(id: id, from: items))
    }

    private struct PluginRequestEnvelope: Codable { let source: String; let inputJSON: String }

    private func documentStoreSnapshot() -> TaskDocumentSnapshot {
        TaskDocumentSnapshot(lines: lines, scratch: scratch, archiveLines: archiveLines, generation: generation,
                             tasksText: TasksDocument.serialize(lines))
    }

    /// Page plugin 按鈕的 tasks.* intent 統一套用路徑(與 reschedule-tomorrow / agent review 同一條):
    /// PluginIntentApplier 與 agent-chat 套用都以 documentRevision 判定 stale；save 用 revision 對上的當前 generation。
    func applyPluginPageIntent(_ intent: ValidatedPluginIntent) {
        do {
            let changed = try PluginIntentApplier.apply(intent, to: documentStoreSnapshot(), todayYMD: RelativeDate.todayYMD())
            apply(try documentStore.save(lines: changed, expectedGeneration: generation))
            ensureCursor()
        } catch { report(error) }
    }

    /// 供 page host 做 action 驗證用的當前 revision 上下文。
    func pluginPageValidationContext() -> (taskRevisions: [String: String], documentRevision: String) {
        let snapshot = documentStoreSnapshot()
        let tasks = (try? PluginSnapshotBuilder.build(from: snapshot))?.tasks ?? []
        return (Dictionary(tasks.map { ($0.id, $0.revision) }, uniquingKeysWith: { first, _ in first }),
                snapshot.documentRevision)
    }

    func reportCandidateTasks() -> [PluginTaskSnapshot] {
        (try? PluginSnapshotBuilder.build(from: documentStoreSnapshot()))?.tasks ?? []
    }

    func toggleReportSelection(_ id: String) {
        if reportSelection.contains(id) { reportSelection.remove(id) }
        else { reportSelection.insert(id) }
    }

    func clearReportSelection() { reportSelection.removeAll() }

    enum RunPluginPageError: LocalizedError {
        case pluginUnavailable(String)
        case installedRequiresAsync
        var errorDescription: String? {
            switch self {
            case .pluginUnavailable(let id): return "找不到外掛 \(id) 的程式碼。"
            case .installedRequiresAsync: return "已安裝外掛必須透過隔離 transport 非同步執行。"
            }
        }
    }

    /// Builds per-task {created, done, quadrant} keyed by the SAME plugin id scheme the
    /// snapshot uses, so page plugins can read fields PluginTaskSnapshot doesn't carry.
    private func taskMetadataByID(_ source: TaskDocumentSnapshot) -> [String: ReportPluginRunner.TaskMetadata] {
        var out: [String: ReportPluginRunner.TaskMetadata] = [:]
        for (id, index) in PluginSnapshotBuilder.identityMap(for: source.lines) {
            let line = source.lines[index]
            out[id] = ReportPluginRunner.TaskMetadata(created: line.created,
                                                      done: line.completedDate,
                                                      quadrant: line.quadrant)
        }
        return out
    }

    /// SCO-172: the single generic page entry that replaced the ten bespoke `*PluginPage`
    /// methods. Resolves `pluginId` → manifest + source via `PluginRegistry` (installed
    /// packages override bundled fixtures), then delegates capability-driven context
    /// injection + execution to the core `GenericPluginPageRunner`. `input` carries entry
    /// control values (e.g. ["reportType": "weekly"], ["view": "stalled"]); `agentResult`
    /// is injected only when the manifest declares `agent.query`.
    ///
    /// SCO-174 will call this directly from a generic host view; until then the ten thin
    /// wrappers below preserve the exact call sites in `App/Views.swift`.
    func runPluginPage(pluginId: String,
                       input: [String: String] = [:],
                       agentResult: String? = nil) throws -> PluginPageDocument {
        let resolved = try resolvePluginEntry(pluginId: pluginId)
        guard resolved.entry.source == .bundled else {
            throw RunPluginPageError.installedRequiresAsync
        }
        let document = documentStoreSnapshot()
        let snapshot = try PluginSnapshotBuilder.build(from: document)
        return try GenericPluginPageRunner().run(
            manifest: resolved.entry.manifest,
            source: resolved.source,
            snapshot: snapshot,
            todayYMD: Self.todayYMD(),
            metadata: taskMetadataByID(document),
            kvNamespace: kvStore?.namespace(for: pluginId) ?? [:],
            agentResult: agentResult,
            input: input)
    }

    /// Installed page plugins cross the XPC boundary. The core runner decodes and validates the
    /// response before this method returns a document to the App/UI process.
    func runPluginPage(entry: PluginRegistryEntry,
                       input: [String: String] = [:],
                       agentResult: String? = nil) async throws -> PluginPageDocument {
        let document = documentStoreSnapshot()
        let snapshot = try PluginSnapshotBuilder.build(from: document)
        let sourceURL = try entry.resolvedEntryURL()
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let transport = LimitedPluginExecutionTransport(base: PluginBrokerXPCTransport())
        return try await GenericPluginPageRunner().run(
            entry: entry,
            source: source,
            snapshot: snapshot,
            todayYMD: Self.todayYMD(),
            metadata: taskMetadataByID(document),
            kvNamespace: kvStore?.namespace(for: entry.manifest.id) ?? [:],
            agentResult: agentResult,
            input: input,
            transport: transport)
    }

    /// Resolves a plugin id to its manifest + entry source. Prefers the unified
    /// `PluginRegistry` (installed packages override bundled fixtures); falls back to the
    /// legacy `Bundle.main` subdirectory lookup the pre-SCO-172 loaders used.
    private func resolvePluginEntry(pluginId: String) throws -> (entry: PluginRegistryEntry, source: String) {
        let registry = PluginRegistry(bundledDirectory: Bundle.main.resourceURL,
                                      installedStore: pluginPackageStore)
        if let entry = (try? registry.discover())?.first(where: { $0.manifest.id == pluginId }) {
            // Fails CLOSED: `resolvedEntryURL()` applies the symlink-resolving containment guard, and a
            // rejection must not fall through to the legacy lookup below — doing so would silently
            // downgrade a security rejection into a success, and for an installed package would serve a
            // *different* (bundled) plugin's source under the attacker-supplied manifest id.
            let entryURL = try entry.resolvedEntryURL()
            return (entry: entry, source: try String(contentsOf: entryURL, encoding: .utf8))
        }
        let shortName = GenericPluginPageRunner.shortName(for: pluginId)
        if let manifestURL = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: shortName),
           let sourceURL = Bundle.main.url(forResource: "main", withExtension: "js", subdirectory: shortName),
           let manifestData = try? Data(contentsOf: manifestURL),
           let manifest = try? PluginValidator.decodeManifest(manifestData),
           let source = try? String(contentsOf: sourceURL, encoding: .utf8) {
            return (entry: PluginRegistryEntry(manifest: manifest, source: .bundled,
                                               packageRootURL: sourceURL.deletingLastPathComponent(),
                                               enabled: true), source: source)
        }
        throw RunPluginPageError.pluginUnavailable(pluginId)
    }

    /// SCO-174/175: page-capable plugins on the `reports` surface, sorted by `placement.order`
    /// (id as tiebreak). Drives the generic `PluginReportsList`. SCO-175 routes this through the
    /// registry built with the user's `disabledPluginIDs` and the shared `PluginSurfaceResolver`,
    /// so gallery toggles (disable) and pins (reports↔sidebar override) drop out of / into this
    /// list immediately — a disabled or sidebar-pinned plugin no longer renders here.
    func reportPagePlugins() -> [PluginRegistryEntry] {
        PluginSurfaceResolver.pagePlugins(in: .reports, from: galleryPluginEntries(),
                                          overrides: placementOverrideSections())
    }

    /// SCO-174: generic `agent.query` runner for the plugin page host. Brokers the query with the
    /// plugin's own manifest (the key never leaves the host), re-runs the page with the injected
    /// `agentResult`, and — for plugins that declare `tasks.create` (e.g. brain-dump) — routes any
    /// createTask buttons in the rendered page into the agent-review queue, preserving the exact
    /// behaviour of the former `applyPluginBrainDumpQuery`.
    @MainActor
    func runPluginPageWithAgentQuery(entry: PluginRegistryEntry,
                                     input: [String: String],
                                     query: ValidatedAgentQuery) async -> Result<PluginPageDocument, Error> {
        do {
            let manifest = entry.manifest
            let broker = AgentQueryBroker(credentialStore: KeychainAgentCredentialStore())
            let result = try await broker.query(prompt: query.prompt,
                                                resultSchema: query.resultSchema,
                                                manifest: manifest)
            let doc: PluginPageDocument
            if entry.source == .installed {
                doc = try await runPluginPage(entry: entry, input: input, agentResult: result.text)
            } else {
                doc = try runPluginPage(pluginId: manifest.id, input: input, agentResult: result.text)
            }

            if manifest.capabilities.contains(.tasksCreate) {
                let current = documentStoreSnapshot()
                let actions = createTaskActions(in: doc.page)
                let intents = try actions.map {
                    try PluginValidator.validate(action: $0, manifest: manifest,
                                                 documentRevision: current.documentRevision)
                }
                prepareAgentReview(intents)
            }
            return .success(doc)
        } catch {
            return .failure(error)
        }
    }

    private func createTaskActions(in node: PluginPageNode) -> [PluginAction] {
        let ownAction: [PluginAction]
        if node.type == .button,
           let action = node.action,
           action.type == .hostCommand,
           action.command == PluginHostCommand.createTask.rawValue {
            ownAction = [action]
        } else {
            ownAction = []
        }
        return ownAction + (node.children ?? []).flatMap(createTaskActions(in:))
    }

    func pluginKVNamespace(for pluginID: String) -> [String: String] {
        kvStore?.namespace(for: pluginID) ?? [:]
    }

    func applyPluginKVWrite(_ write: ValidatedPluginKVWrite) {
        guard let kvStore else { return }
        do {
            _ = try kvStore.applyWrite(write)
        } catch {
            report(error)
        }
    }

    static func todayYMD() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    func removeInstalledPlugin(_ package: InstalledPluginPackage) {
        do {
            try pluginPackageStore?.remove(id: package.manifest.id)
            enabledPluginIDs.remove(package.manifest.id)
            refreshInstalledPlugins()
        } catch { report(error) }
    }

    func installPluginPackage(from url: URL) {
        do {
            guard url.startAccessingSecurityScopedResource() else { throw PluginPackageStoreError.invalidPackage }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let installed = try pluginPackageStore?.install(from: url) else { throw PluginPackageStoreError.invalidPackage }
            enabledPluginIDs.insert(installed.manifest.id)
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
        do { apply(try documentStore.load()); hasUnsavedChanges = false; clearUndoHistory() } catch { report(error) }
    }

    private func save() {
        hasUnsavedChanges = true
        let previous = committedTasksText
        do {
            applyingViaSave = true
            defer { applyingViaSave = false }
            apply(try documentStore.save(lines: lines, expectedGeneration: generation))
            if recordsUndoHistory {
                recordUndoSnapshot(from: previous, to: committedTasksText)
            }
            hasUnsavedChanges = false
            externalEditConflict = nil
        } catch { handleWriteError(error, conflict: .save) }
    }

    /// Restore the previous committed tasks.txt through the normal `save()` path.
    /// Empty history is a silent no-op: no write, no error.
    func undo() { restoreHistory(undoStack.undo()) }

    /// Restore the snapshot discarded by the last `undo()`, same write path as `save()`.
    func redo() { restoreHistory(undoStack.redo()) }

    private func restoreHistory(_ text: String?) {
        guard let text else { return }
        recordsUndoHistory = false
        defer { recordsUndoHistory = true }
        lines = TasksDocument.parse(text)
        save()
        syncUndoAvailability()
    }

    private func recordUndoSnapshot(from previous: String, to new: String) {
        guard previous != new else { return }
        if undoStack.isEmpty { undoStack.push(previous) }
        undoStack.push(new)
        syncUndoAvailability()
    }

    private func clearUndoHistory() {
        undoStack.clear()
        syncUndoAvailability()
    }

    private func syncUndoAvailability() {
        canUndo = undoStack.canUndo
        canRedo = undoStack.canRedo
    }

    func saveScratch() {
        do { try documentStore.saveScratch(scratch) } catch { report(error) }
    }

    private func apply(_ snapshot: TaskDocumentSnapshot) {
        // Writes that bypass `save()` — plugin intents, agent/import review, archive —
        // land here with no history entry. Undoing past one would silently wipe it,
        // the same hazard external edits get cleared for. Same rule, one choke point.
        if !applyingViaSave && snapshot.tasksText != committedTasksText { clearUndoHistory() }
        lines = snapshot.lines; scratch = snapshot.scratch; archiveLines = snapshot.archiveLines
        generation = snapshot.generation; documentRevision = snapshot.documentRevision; lastError = nil
        committedTasksText = snapshot.tasksText
    }

    private func report(_ error: Error) {
        if let storeError = error as? TaskDocumentStoreError, case .staleSnapshot = storeError {
            externalEditConflict = .save
            hasUnsavedChanges = true
            return
        }
        lastError = error.localizedDescription
    }

    private func handleWriteError(_ error: Error, conflict: ExternalEditConflict) {
        if let storeError = error as? TaskDocumentStoreError, case .staleSnapshot = storeError {
            externalEditConflict = conflict
            hasUnsavedChanges = true
            lastError = nil
            return
        }
        report(error)
    }

    /// 放棄本次 App 內容，採用磁碟版本。這是明確的使用者選擇，不由 watcher 自動呼叫。
    func reloadAfterExternalConflict() {
        do {
            let oldIndex = cursor
            apply(try documentStore.load())
            hasUnsavedChanges = false
            externalEditConflict = nil
            clearUndoHistory()
            editingIndex = nil
            cursor = oldIndex.flatMap { lines.indices.contains($0) ? $0 : nil }
            ensureCursor()
            showReloadNotice()
        } catch { report(error) }
    }

    /// 先採用最新磁碟 generation，再用衝突發生前保留的 App 內容走正常 save/journal 交易。
    func forceOverwriteExternalChanges() {
        guard let conflict = externalEditConflict else { return }
        clearUndoHistory()
        let localLines = lines
        do {
            apply(try documentStore.load())
            lines = localLines
            recordsUndoHistory = false
            defer { recordsUndoHistory = true }
            switch conflict {
            case .save:
                save()
            case .archive(let oldHandle):
                guard localLines.indices.contains(oldHandle.index) else { throw TaskWorkspaceError.missingTask }
                let archivedRaw = localLines[oldHandle.index].raw
                guard let index = lines.indices.first(where: { lines[$0].raw == archivedRaw }) else {
                    throw TaskWorkspaceError.missingTask
                }
                apply(try documentStore.archiveTask(TaskHandle(generation: generation, index: index),
                                                     expectedGeneration: generation))
                hasUnsavedChanges = false
                externalEditConflict = nil
            }
            clearUndoHistory()
            editingIndex = nil
            ensureCursor()
        } catch { handleWriteError(error, conflict: conflict) }
    }

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
            guard snapshot.documentRevision != documentRevision else {
                generation = snapshot.generation
                return
            }
            guard !hasUnsavedChanges, externalEditConflict == nil else { return }
            let oldIndex = cursor
            apply(snapshot)
            clearUndoHistory()
            editingIndex = nil
            cursor = oldIndex.flatMap { lines.indices.contains($0) ? $0 : nil }
            ensureCursor()
            showReloadNotice()
        } catch { report(error) }
    }

    private func showReloadNotice() {
        reloadNoticeWorkItem?.cancel()
        reloadNotice = "已從檔案重新載入"
        let work = DispatchWorkItem { [weak self] in self?.reloadNotice = nil }
        reloadNoticeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: derived

    var todayYMD: String { RelativeDate.todayYMD() }
    var focusIndex: Int? { TasksDocument.focusIndex(in: lines) }

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
    func task(using handle: TaskHandle) -> TaskLine? {
        guard handle.generation == generation, lines.indices.contains(handle.index) else { return nil }
        return lines[handle.index]
    }
    func select(using handle: TaskHandle) {
        guard task(using: handle) != nil else { return }
        cursor = handle.index
    }
    func toggleDone(using handle: TaskHandle) { apply(.toggleDone(handle)) }
    func toggleFocus(using handle: TaskHandle) {
        let wasFocused = focusIndex == handle.index
        apply(.toggleFocus(handle))
        if wasFocused { focusMode = false }
    }
    func setDue(_ due: String?, using handle: TaskHandle) { apply(.setDue(handle, due)) }
    func setTag(_ tag: String, enabled: Bool, using handle: TaskHandle) {
        apply(.setTag(handle, tag, enabled))
    }
    func deleteTask(using handle: TaskHandle) {
        let nextCursor = cursorAfterRemoving(handle.index)
        do {
            lines = try TaskWorkspace.apply(.delete(handle), to: currentSnapshot, todayYMD: todayYMD)
            save(); editingIndex = nil; cursor = nextCursor; ensureCursor()
        } catch { report(error) }
    }
    func archiveTask(using handle: TaskHandle) {
        let nextCursor = cursorAfterRemoving(handle.index)
        do {
            apply(try documentStore.archiveTask(handle, expectedGeneration: generation))
            editingIndex = nil; cursor = nextCursor; ensureCursor()
            hasUnsavedChanges = false
            externalEditConflict = nil
        } catch { handleWriteError(error, conflict: .archive(handle)) }
    }
    private func apply(_ command: TaskCommand) {
        do {
            lines = try TaskWorkspace.apply(command, to: currentSnapshot, todayYMD: todayYMD)
            save(); ensureCursor()
        } catch { report(error) }
    }
    private func cursorAfterRemoving(_ removed: Int) -> Int? {
        let remaining = currentOrder().filter { $0 != removed }.map { $0 > removed ? $0 - 1 : $0 }
        guard !remaining.isEmpty else { return nil }
        let oldOrder = currentOrder()
        let position = oldOrder.firstIndex(of: removed) ?? 0
        return remaining[min(position, remaining.count - 1)]
    }
    func toggleFocus() {
        guard let i = cursor, lines.indices.contains(i) else { return }
        let already = focusIndex == i
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
    func applyEdit(_ index: Int, title: String, due: String, projects: String, contexts: String, note: String,
                   rec: String? = nil) {
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

        // 週期:`nil` = 這次編輯不碰(給沒有 rec 欄位的呼叫端),空字串才是清除。
        // 不可解析的輸入原樣保留既有 rec — 徽章與補全都認 RecurrenceRule.parse,
        // 把 `3x` 寫進檔案只會變成看不見也用不到的垃圾。
        if let recInput = rec?.trimmingCharacters(in: .whitespaces) {
            if recInput.isEmpty {
                lines[index].removeKey("rec")
            } else if RecurrenceRule.parse(recInput) != nil {
                lines[index].setValue(recInput, forKey: "rec")
            }
        }

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
    /// `addProjectToCursor` 的 @ 版本 — 同樣的清洗與守門,只有 sigil 不同。
    func addContextToCursor(_ name: String) {
        let clean = name.split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "@" }).joined()
        guard !clean.isEmpty, let i = cursor, lines.indices.contains(i) else { return }
        lines[i].addTag("@" + clean); save()
    }
}
