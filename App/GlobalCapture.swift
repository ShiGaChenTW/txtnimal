import SwiftUI
import AppKit
import KeyboardShortcuts
import txtnimalCore

extension KeyboardShortcuts.Name {
    /// 全域捕捉，預設 ⌥Space;可在「設定」重綁。
    static let capture = Self("globalCapture", default: .init(.space, modifiers: [.option]))
}

/// 借過鍵盤焦點的無邊框浮窗（borderless 預設不能成為 key window，要覆寫）。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 全域熱鍵 → 螢幕上方浮出一行捕捉框。任何 app 裡都能叫出來。
final class GlobalCapture {
    static let shared = GlobalCapture()
    private var panel: NSPanel?
    private weak var store: TaskStore?

    func install(store: TaskStore) {
        self.store = store
        KeyboardShortcuts.onKeyUp(for: .capture) { [weak self] in self?.toggle() }
    }

    func toggle() {
        if panel?.isVisible == true { hide(); return }
        show()
    }

    private func show() {
        guard let store else { return }
        if panel == nil {
            let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 92),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: GlobalCaptureView(
                onCommit: { [weak self] text in
                    store.addFromCapture(text)
                    self?.hide()
                },
                onCancel: { [weak self] in self?.hide() }
            ).environmentObject(store))
            host.frame = p.contentView?.bounds ?? .zero
            host.autoresizingMask = [.width, .height]
            p.contentView?.addSubview(host)
            panel = p
        }
        if let f = NSScreen.main?.visibleFrame, let p = panel {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - f.height * 0.22))
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    private func hide() { panel?.orderOut(nil) }
}

private struct GlobalCaptureView: View {
    @EnvironmentObject var store: TaskStore
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(">").foregroundColor(Theme.green)
                TextField("Call bank due:fri +personal", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(Theme.fg)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { text = ""; onCancel() }
            }
            preview
            CaptureHelp()
        }
        .padding(16)
        .background(Theme.bg)
        .overlay(Rectangle().stroke(Theme.border))
        .clipShape(Rectangle())
        .onAppear { text = ""; focused = true }
    }

    @ViewBuilder private var preview: some View {
        let parts = text.split(separator: " ").map(String.init)
        let dueTok = parts.first { $0.hasPrefix("due:") }?.dropFirst(4)
        HStack(spacing: 12) {
            if let d = dueTok, let norm = DueDateParser.parse(String(d), today: Date()) {
                Text("due:\(norm)").foregroundColor(Theme.blue)
            }
            ForEach(parts.filter { $0.hasPrefix("+") && $0.count > 1 }, id: \.self) { Text($0).foregroundColor(Theme.mag) }
            ForEach(parts.filter { $0.hasPrefix("@") && $0.count > 1 }, id: \.self) { Text($0).foregroundColor(Theme.cyan) }
            Spacer()
            Text("⏎ 加入 · esc 取消").foregroundColor(Theme.dim)
        }
        .font(Theme.monoSmall).frame(height: 15)
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        text = ""
        if t.isEmpty { onCancel() } else { onCommit(t) }
    }
}

/// 新增視窗共用的「語法說明」摺疊區：預設縮起,點擊或 ⌘/ 展開。
struct CaptureHelp: View {
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(open ? "▾" : "▸").foregroundColor(Theme.dim)
                Text("? 語法說明").foregroundColor(Theme.dim)
                Spacer()
                Text("⌘/").foregroundColor(Theme.dim).opacity(0.7)
            }
            .font(Theme.monoSmall)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    row("due:", "due:fri · due:tomorrow · due:3d · due:2026-07-25", Theme.blue)
                    row("+List", "+business +side（可多個）", Theme.mag)
                    row("@Tag", "@mac @calls @home（可多個）", Theme.cyan)
                    row("note:", "note:\"含空格要加引號\"", Theme.dim)
                    Text("例：寄出報價單給王經理 due:fri +business @mac note:\"附上7月折扣方案\"")
                        .foregroundColor(Theme.fg).padding(.top, 3)
                    Text("例：繳房租 due:tomorrow +personal ／ 只打一句話也行 → 落「無期限」")
                        .foregroundColor(Theme.dim)
                }
                .font(Theme.monoSmall)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(Theme.border))
            }
            // 隱形按鈕承接 ⌘/ 快捷鍵
            Button("") { open.toggle() }
                .keyboardShortcut("/", modifiers: .command)
                .buttonStyle(.plain).frame(width: 0, height: 0).opacity(0)
        }
    }

    private func row(_ k: LocalizedStringKey, _ v: LocalizedStringKey, _ c: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).foregroundColor(c).frame(width: 52, alignment: .leading)
            Text(v).foregroundColor(Theme.dim)
        }
    }
}

/// 設定視窗(⌘,)：個人 / 快速鍵 / 外觀 / 檔案。
struct SettingsView: View {
    @EnvironmentObject var store: TaskStore
    @State private var showingTaskFiles = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            section("個人")
            HStack(spacing: 8) {
                Text("語言").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(LocalizedStringKey(language.label)).tag(language)
                    }
                }.labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("使用者名稱").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                TextField("", text: $store.userName,
                          prompt: Text("留空則用通用問候").foregroundColor(Theme.dim.opacity(0.4)))
                    .textFieldStyle(.plain).foregroundColor(Theme.fg)
                    .padding(8).background(Theme.panel).overlay(Rectangle().stroke(Theme.border))
            }
            hint("統計頁問候語會用這個名字")

            section("快速鍵")
            HStack(spacing: 8) {
                Text("全域捕捉").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                KeyboardShortcuts.Recorder("", name: .capture)
            }
            hint("在任何 app 按此熱鍵即可快速記一筆")
            hint("app 內快速鍵固定：⌘1 清單 · ⌘2 象限 · ⌘3 便箋 · ⌘4 統計 · ⌘E 編輯 · ⌘K 指令")

            section("外觀")
            HStack(spacing: 8) {
                Text("主題").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.appearanceMode) {
                    Text("跟隨系統").tag(0); Text("深色").tag(1); Text("淺色").tag(2)
                }.labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("強調色").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                ForEach(Array(Theme.accentPalette.enumerated()), id: \.offset) { i, item in
                    Rectangle().fill(item.color).frame(width: 22, height: 22)
                        .overlay(Rectangle().stroke(store.accentIndex == i ? Theme.fg : Theme.border,
                                                    lineWidth: store.accentIndex == i ? 2 : 1))
                        .contentShape(Rectangle())
                        .onTapGesture { store.accentIndex = i }
                        .help(item.name)
                }
            }
            hint("逾期紅 · Focus teal · 完成綠 為語意固定色，不受此設定影響")
            HStack(spacing: 8) {
                Text("App 圖示").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.appIconStyle) {
                    ForEach(AppIconStyle.allCases, id: \.self) { style in
                        Text(LocalizedStringKey(style.label)).tag(style)
                    }
                }.labelsHidden().frame(width: 180)
                Image(nsImage: appIconPreview(store.appIconStyle))
                    .resizable().frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            hint("選擇後會立即更新 Dock 圖示，並保留至下次啟動")
            HStack(spacing: 8) {
                Text("行距").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.density) {
                    ForEach(Density.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("英數字體").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.latinFontChoice) {
                    ForEach(LatinFontChoice.allCases, id: \.self) { choice in
                        Text(LocalizedStringKey(choice.label)).tag(choice)
                    }
                }.labelsHidden().frame(width: 180)
            }
            HStack(spacing: 8) {
                Text("中文字體").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.chineseFontChoice) {
                    ForEach(ChineseFontChoice.allCases, id: \.self) { choice in
                        Text(LocalizedStringKey(choice.label)).tag(choice)
                    }
                }.labelsHidden().frame(width: 180)
            }
            hint("中英文字體可分別選擇，並會套用至全 app")
            fontSizeRow("Task 內容", value: $store.taskTextSize, range: 10...24)
            fontSizeRow("List／Tag", value: $store.tagTextSize, range: 9...20)
            hint("兩種文字大小可分開設定，並會即時套用")
            HStack(spacing: 8) {
                Text("統計圖示").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Picker("", selection: $store.dashboardIconStyle) {
                    ForEach(DashboardIconStyle.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
                }.labelsHidden().frame(width: 150)
            }
            HStack(spacing: 8) {
                Text("開機自啟").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Toggle("", isOn: Binding(get: { store.launchAtLogin },
                                         set: { store.setLaunchAtLogin($0) })).labelsHidden()
            }

            section("檔案")
            HStack(spacing: 8) {
                Text("資料夾").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Text((store.dataDirPath as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
                    .lineLimit(1).truncationMode(.middle)
                Button("更改…") { pickFolder() }
            }
            hint("tasks.txt / scratch.txt / archive.txt 所在資料夾；搬到空資料夾會自動帶檔（複製，原檔保留）")
            HStack(spacing: 8) {
                Text("任務檔案").frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
                Text(store.fileURL.lastPathComponent)
                    .font(Theme.monoSmall).foregroundColor(Theme.fg)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("選擇／釘選…") { showingTaskFiles = true }
            }
            hint("開啟其他 .txt 文件，或管理已釘選的常用文件")
            section("插件")
            ForEach(TaskStore.bundledPlugins) { plugin in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).foregroundColor(Theme.fg)
                        Text("\(plugin.id) · v\(plugin.version)").font(Theme.monoSmall).foregroundColor(Theme.dim)
                        Text(plugin.capabilities.joined(separator: ", ")).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.75))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { store.isPluginEnabled(plugin) },
                                             set: { store.setPluginEnabled(plugin, $0) })).labelsHidden()
                }
                .padding(.vertical, 4)
            }
            hint("插件目前採內建 registry；正式公開插件前仍需簽章與權限驗證")
            ForEach(store.installedPluginPackages, id: \.manifest.id) { package in
                HStack {
                    Text(package.manifest.name)
                    Text("v\(package.manifest.version)").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    Spacer()
                    Button("移除") { store.removeInstalledPlugin(package) }.buttonStyle(.plain)
                }
            }
            Button("重新掃描已安裝插件") { store.refreshInstalledPlugins() }
            Button("安裝插件 package…") { installPluginPackage() }
            }
            .font(Theme.mono)
            .padding(.horizontal, 28).padding(.vertical, 24).frame(maxWidth: 600, alignment: .leading)
        }
        .sheet(isPresented: $showingTaskFiles) { TaskFileBrowserView().environmentObject(store) }
    }

    private func section(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.5)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.top, 14).padding(.bottom, 4)
    }
    private func hint(_ s: LocalizedStringKey) -> some View {
        Text(s).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.75))
            .padding(.leading, 104).padding(.top, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func fontSizeRow(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 96, alignment: .trailing).foregroundColor(Theme.dim)
            Stepper(value: value, in: range, step: 1) {
                Text("\(Int(value.wrappedValue)) pt")
                    .frame(width: 54, alignment: .leading).foregroundColor(Theme.fg)
            }
            .frame(width: 150)
        }
    }

    private func appIconPreview(_ style: AppIconStyle) -> NSImage {
        style.image() ?? AppIconStyle.flatGeometric.image() ?? NSApp.applicationIconImage
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.prompt = store.appLanguage == .english ? "Choose Folder" : "選這個資料夾"
        if p.runModal() == .OK, let url = p.url { store.setDataDir(url) }
    }

    private func installPluginPackage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = store.appLanguage == .english ? "Install" : "安裝"
        if panel.runModal() == .OK, let url = panel.url { store.installPluginPackage(from: url) }
    }
}
