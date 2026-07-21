import SwiftUI
import UniformTypeIdentifiers

struct TaskFileBrowserView: View {
    @EnvironmentObject private var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("開啟 Task 文件").font(Theme.mono).fontWeight(.semibold)
                Spacer()
                Button("關閉") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("已釘選").font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.2)
                    Spacer()
                    Button {
                        store.togglePinned(store.fileURL)
                    } label: {
                        Text(store.isPinned(store.fileURL) ? LocalizedStringKey("取消釘選目前檔案") : LocalizedStringKey("釘選目前檔案"))
                    }
                    .buttonStyle(.plain).font(Theme.monoSmall).foregroundColor(store.accent)
                }

                if store.pinnedTaskFiles.isEmpty {
                    Text("尚無釘選檔案。開啟常用文件後，可將它固定在這裡。")
                        .font(Theme.monoSmall).foregroundColor(Theme.dim)
                        .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                        .overlay(Rectangle().stroke(Theme.border))
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.pinnedTaskFiles, id: \.path) { url in pinnedRow(url) }
                    }
                    .overlay(Rectangle().stroke(Theme.border))
                }

                Button(action: browse) {
                    HStack {
                        Text("瀏覽…").font(Theme.mono)
                        Spacer()
                        Text("選擇 .txt 檔案").font(Theme.monoSmall).foregroundColor(Theme.dim)
                    }
                    .padding(12).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Theme.panel)
                .overlay(Rectangle().stroke(store.accent))
            }
            .padding(18)
        }
        .frame(width: 560)
        .frame(minHeight: 260)
        .background(Theme.bg)
        .foregroundColor(Theme.fg)
    }

    private func pinnedRow(_ url: URL) -> some View {
        HStack(spacing: 10) {
            Text(url.standardizedFileURL == store.fileURL.standardizedFileURL ? "●" : "○")
                .foregroundColor(url.standardizedFileURL == store.fileURL.standardizedFileURL ? store.accent : Theme.dim)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(Theme.mono).lineLimit(1)
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(Theme.monoSmall).foregroundColor(Theme.dim).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("開啟") { store.openTaskFile(url); dismiss() }.buttonStyle(.plain).foregroundColor(store.accent)
            Button("×") { store.togglePinned(url) }.buttonStyle(.plain).foregroundColor(Theme.dim)
                .help("取消釘選")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.openTaskFile(url); dismiss() }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.title = store.appLanguage == .english ? "Open Task File" : "開啟 Task 文件"
        panel.prompt = store.appLanguage == .english ? "Open" : "開啟"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = store.fileURL.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            store.openTaskFile(url)
            dismiss()
        }
    }
}
