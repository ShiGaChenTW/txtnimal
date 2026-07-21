import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var store: TaskStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 18) {
                Text("txtnimal").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(4).foregroundColor(store.accent)
                Text("歡迎使用 txtnimal")
                    .font(.system(size: 27, weight: .bold, design: .monospaced))
                Text("純文字任務管理，保留你的資料、節奏與選擇。")
                    .font(Theme.mono).foregroundColor(Theme.dim)
            }
            .padding(.top, 34).padding(.bottom, 28)

            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 18) {
                feature("⌨", "鍵盤優先", "按 n 新增、方向鍵移動、x 完成；不離開工作流。")
                feature("TXT", "檔案由你掌握", "任務保存在純文字文件，可用任何編輯器或 Git 管理。")
                feature("◎", "一次專注一件事", "Focus、四象限與統計幫你決定現在要做什麼。")
            }
            .padding(.horizontal, 34).padding(.vertical, 26)

            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Text("語言").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    Picker("", selection: $store.appLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
                    }.labelsHidden().frame(width: 150)
                    Spacer()
                    Button("開始使用") { store.completeOnboarding() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent).tint(store.accent)
                }
                Toggle("下次啟動時顯示歡迎頁", isOn: $store.showWelcomeOnLaunch)
                    .toggleStyle(.checkbox)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(22).background(Theme.panel)
        }
        .frame(width: 560)
        .background(Theme.bg).foregroundColor(Theme.fg)
        .environment(\.locale, store.appLanguage.locale)
        .id(store.appLanguage)
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(icon).font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(store.accent).frame(width: 42, height: 42)
                .overlay(Rectangle().stroke(Theme.border))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.mono).fontWeight(.semibold)
                Text(detail).font(Theme.monoSmall).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
