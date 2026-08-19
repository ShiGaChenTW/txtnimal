import SwiftUI
import txtnimalCore

@main
struct txtnimalApp: App {
    @StateObject private var store = TaskStore()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
                .onAppear {
                    GlobalCapture.shared.install(store: store)
                    SidebarController.shared.install(store: store)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 740, height: 660)
        .commands {
            // 選單項目全部由 CommandCatalog 生成 —— 手抄的那五顆 ⌘1–⌘5 曾經跟 handle() 走散過
            // (見 CHANGELOG 的 ⌘2/⌘4 事故)。改成單一來源後,catalog 加一個帶 ⌘ 的綁定,
            // 選單就自動多一個後備入口,不需要有人記得同步。
            CommandGroup(replacing: .newItem) {
                ForEach(CommandMenuModel.items) { item in
                    menuButton(item)
                }
                Divider()
                Button("從 Reminders 匯入") { store.importFromReminders() }
            }
        }

        // 選單列常駐：顯示目前 Focus。全域熱鍵 / 開機自啟為 v2。
        MenuBarExtra {
            if let i = store.focusIndex {
                Text("▶ \(store.lines[i].title)")
                Divider()
            }
            Picker("行距", selection: $store.density) {
                ForEach(Density.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
            }
            Picker("外觀", selection: $store.appearanceMode) {
                Text("跟隨系統").tag(0); Text("深色").tag(1); Text("淺色").tag(2)
            }
            .disabled(store.appTheme == .phosphorTerminal)
            Picker("介面主題", selection: $store.appTheme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in Text(LocalizedStringKey(theme.label)).tag(theme) }
            }
            Divider()
            Button("快速捕捉") {
                // Menu-bar-only launches may not have created ContentView yet.
                // Install here as a defensive guarantee before presenting.
                GlobalCapture.shared.install(store: store)
                GlobalCapture.shared.toggle()
            }
            Toggle("開機自啟", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
            Divider()
            Button("開啟 tasks.txt 視窗") { NSApp.activate(ignoringOtherApps: true) }
            Button("結束") { NSApp.terminate(nil) }
        } label: {
            Text(store.focusIndex.map { "▶ \(store.lines[$0].title)" } ?? "◉ tasks.txt")
                .onAppear {
                    // The menu extra outlives every WindowGroup window, so it owns
                    // installation of the truly global capture shortcut/panel.
                    GlobalCapture.shared.install(store: store)
                }
        }
        .environment(\.locale, store.appLanguage.locale)
    }

    /// 選單只負責派工,實際動作一律回到 ContentView.perform —— 兩條路徑共用同一份實作。
    @ViewBuilder private func menuButton(_ item: CommandMenuModel.Item) -> some View {
        let available = specAvailability(item.identity)
        let button = Button(LocalizedStringKey(item.title)) { store.requestCommand(item.identity) }
            .disabled(!available)
        if let key = item.key, let ch = Self.keyEquivalent(for: key) {
            button.keyboardShortcut(ch, modifiers: item.shift ? [.command, .shift] : .command)
        } else {
            button
        }
    }

    /// catalog 的 character 是字串,SwiftUI 要 KeyEquivalent;⏎ 與空白要轉成具名鍵。
    private static func keyEquivalent(for character: String) -> KeyEquivalent? {
        switch character {
        case "\r": return .return
        case " ": return .space
        default: return character.first.map { KeyEquivalent($0) }
        }
    }

    /// 目前這一頁不適用的指令要 disable,不然選單會讓 ⌘E 在統計頁生效 —— 那正是
    /// handle() 那邊剛補起來的漏洞,不要從選單再開一個。
    private func specAvailability(_ identity: CommandIdentity) -> Bool {
        guard let spec = CommandCatalog.builtIns.first(where: { $0.identity == identity })
        else { return true }
        return spec.availability.isAvailable(in: store.commandContext)
    }
}
