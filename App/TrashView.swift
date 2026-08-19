import SwiftUI
import txtnimalCore

// MARK: - ⌘6 垃圾桶
// 刪除的任務落在 trash.txt,超過保留天數(設定頁 7/15/30)才永久刪除。
// 這一頁是刪除的救援入口 —— 自從 deleteTask 改走 bypass 路徑,⌘Z 不再撤銷刪除,
// 「還原」就是取代它的那條路。唯讀單鍵在此頁一律不生效(見 ContentView.handle)。

struct TrashView: View {
    @EnvironmentObject var store: TaskStore
    @State private var confirmingEmpty = false
    @State private var pendingPurge: (index: Int, title: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.trashTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.trashTasks.enumerated()), id: \.offset) { entry in
                            row(index: entry.offset, line: entry.element)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("清空垃圾桶", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("永久刪除全部", role: .destructive) { store.emptyTrash() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("垃圾桶內的 \(store.trashTasks.count) 筆任務將永久刪除，無法還原。")
        }
        .confirmationDialog("永久刪除", isPresented: Binding(
            get: { pendingPurge != nil },
            set: { if !$0 { pendingPurge = nil } }
        ), titleVisibility: .visible) {
            if let pending = pendingPurge {
                Button("永久刪除", role: .destructive) {
                    store.permanentlyDeleteTask(at: pending.index); pendingPurge = nil
                }
            }
            Button("取消", role: .cancel) { pendingPurge = nil }
        } message: {
            Text("「\(pendingPurge?.title ?? "")」將永久刪除，無法還原。")
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("垃圾桶").foregroundColor(Theme.fg)
                Text("刪除的任務保留 \(store.trashRetentionDays) 天，到期自動永久刪除")
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
            }
            Spacer()
            if !store.trashTasks.isEmpty {
                Button("清空垃圾桶") { confirmingEmpty = true }
                    .buttonStyle(.plain).font(Theme.monoSmall).foregroundColor(Theme.red)
            }
        }
        .font(Theme.mono)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("垃圾桶是空的").foregroundColor(Theme.dim)
            Text("在清單按 d 刪除任務，會先落在這裡").font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.7))
        }
        .font(Theme.mono)
        .padding(.horizontal, 16).padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: row

    private func row(index: Int, line: TaskLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(line.title).font(store.taskFont).foregroundColor(Theme.fg)
                    .strikethrough(color: Theme.dim.opacity(0.6))
                HStack(spacing: 8) {
                    Text(countdown(for: line)).foregroundColor(countdownColor(for: line))
                    ForEach(line.projects, id: \.self) { Text("+\($0)").foregroundColor(Theme.mag) }
                    ForEach(line.contexts, id: \.self) { Text("@\($0)").foregroundColor(Theme.cyan) }
                    if let due = line.due { Text("due:\(due)").foregroundColor(Theme.dim) }
                }
                .font(Theme.monoSmall)
            }
            Spacer(minLength: 12)
            Button("還原") { store.restoreTask(at: index) }
                .buttonStyle(.plain).font(Theme.monoSmall).foregroundColor(Theme.green)
            Button("永久刪除") { pendingPurge = (index, line.title) }
                .buttonStyle(.plain).font(Theme.monoSmall).foregroundColor(Theme.red)
        }
        .padding(.horizontal, 16).padding(.vertical, store.density.rowPad + 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border.opacity(0.55)).frame(height: 1) }
    }

    /// `deleted:` 讀不出來時不猜 —— 顯示無日期而不是一個錯的倒數。
    private func countdown(for line: TaskLine) -> String {
        guard let days = store.trashDaysRemaining(line) else { return "無刪除日期" }
        return days == 0 ? "今天永久刪除" : "\(days) 天後永久刪除"
    }

    private func countdownColor(for line: TaskLine) -> Color {
        guard let days = store.trashDaysRemaining(line) else { return Theme.dim }
        return days <= 3 ? Theme.red : Theme.dim
    }
}
