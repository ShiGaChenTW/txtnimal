import SwiftUI
import TasksTxtCore

@main
struct TasksTxtApp: App {
    @StateObject private var store = TaskStore()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
                .onAppear { GlobalCapture.shared.install(store: store) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 740, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("切到清單") { store.view = .list; store.ensureCursor() }.keyboardShortcut("1", modifiers: .command)
                Button("切到象限") { store.view = .grid; store.ensureCursor() }.keyboardShortcut("4", modifiers: .command)
                Button("切到便箋") { store.view = .pad }.keyboardShortcut("3", modifiers: .command)
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
            Divider()
            Button("快速捕捉") { GlobalCapture.shared.toggle() }
            Toggle("開機自啟", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }))
            Divider()
            Button("開啟 tasks.txt 視窗") { NSApp.activate(ignoringOtherApps: true) }
            Button("結束") { NSApp.terminate(nil) }
        } label: {
            Text(store.focusIndex.map { "▶ \(store.lines[$0].title)" } ?? "◉ tasks.txt")
        }
        .environment(\.locale, store.appLanguage.locale)
    }
}
