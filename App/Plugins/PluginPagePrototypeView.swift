import SwiftUI
import TasksTxtCore

/// Phase 0 renderer spike. It is intentionally not connected to App navigation.
/// Production code must call `PluginValidator.validate` before constructing this view.
struct PluginPagePrototypeView: View {
    let document: PluginPageDocument
    let manifest: PluginManifest
    var taskRows: [String: [String]] = [:]
    var taskRevisions: [String: String] = [:]
    var documentRevision: String?
    let onIntent: (ValidatedPluginIntent) -> Void
    var onValidationError: (Error) -> Void = { _ in }

    @State private var textValues: [String: String] = [:]
    @State private var toggleValues: [String: Bool] = [:]

    var body: some View {
        ScrollView {
            nodeView(document.page)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .background(Theme.bg)
        .foregroundColor(Theme.fg)
    }

    private func nodeView(_ node: PluginPageNode) -> AnyView {
        switch node.type {
        case .page:
            return AnyView(VStack(alignment: .leading, spacing: 16) {
                if let title = node.title { Text(title).font(Theme.monoBig) }
                children(node)
            })
        case .section:
            return AnyView(VStack(alignment: .leading, spacing: 10) {
                if let title = node.title { Text(title).font(Theme.mono).foregroundColor(Theme.cyan) }
                children(node)
            }
            .padding(14).background(Theme.panel).overlay(Rectangle().stroke(Theme.border)))
        case .text:
            return AnyView(Text(node.value ?? node.title ?? "").font(Theme.monoSmall))
        case .taskList:
            let rows = taskRows[node.id] ?? []
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.self) { Text("[ ] \($0)").font(Theme.monoSmall) }
                if rows.isEmpty { Text("No tasks").font(Theme.monoSmall).foregroundColor(Theme.dim) }
            })
        case .statCard:
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                Text(node.title ?? "").font(Theme.monoSmall).foregroundColor(Theme.dim)
                Text(node.value ?? "—").font(Theme.monoBig)
            }.padding(12).background(Theme.panel))
        case .barChart:
            let values = parseChart(node.value)
            return AnyView(VStack(alignment: .leading, spacing: 6) {
                if let title = node.title { Text(title).font(Theme.monoSmall) }
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    GeometryReader { proxy in
                        Rectangle().fill(Theme.green)
                            .frame(width: proxy.size.width * CGFloat(max(0, min(value, 1))))
                    }.frame(height: 8)
                }
            })
        case .button:
            return AnyView(Button(node.title ?? "Action") {
                guard let action = node.action else { return }
                do {
                    let intent = try PluginValidator.validate(action: action, manifest: manifest,
                                                              taskRevisions: taskRevisions,
                                                              documentRevision: documentRevision)
                    onIntent(intent)
                } catch {
                    onValidationError(error)
                }
            }.buttonStyle(.bordered).disabled(node.action == nil))
        case .form:
            return AnyView(VStack(alignment: .leading, spacing: 10) { children(node) })
        case .textField:
            let binding = Binding(get: { textValues[node.id, default: ""] },
                                  set: { textValues[node.id] = String($0.prefix(1_000)) })
            return AnyView(TextField(node.title ?? "", text: binding).textFieldStyle(.roundedBorder))
        case .picker:
            return AnyView(Text(node.title ?? "Picker").font(Theme.monoSmall).foregroundColor(Theme.dim))
        case .toggle:
            let binding = Binding(get: { toggleValues[node.id, default: false] },
                                  set: { toggleValues[node.id] = $0 })
            return AnyView(Toggle(node.title ?? "", isOn: binding))
        case .divider:
            return AnyView(Divider())
        case .spacer:
            return AnyView(Spacer().frame(height: 12))
        case .emptyState:
            return AnyView(Text(node.title ?? node.value ?? "No data")
                .font(Theme.monoSmall).foregroundColor(Theme.dim).padding(.vertical, 20))
        }
    }

    private func children(_ node: PluginPageNode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(node.children ?? []) { child in nodeView(child) }
        }
    }

    private func parseChart(_ value: String?) -> [Double] {
        (value ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}

#if DEBUG
struct PluginPagePrototypeView_Previews: PreviewProvider {
    static var previews: some View {
        PluginPagePrototypeView(document: .init(schemaVersion: 1, page: .init(
            type: .page, id: "preview-root", pageID: "preview", title: "Weekly Review", children: [
                .init(type: .section, id: "overdue", title: "Overdue", children: [
                    .init(type: .taskList, id: "tasks"),
                    .init(type: .button, id: "move", title: "Move all to today",
                          action: .init(type: .hostCommand, command: "tasks.rescheduleOverdue", expectedRevision: "rev-1"))
                ])
            ])), manifest: .init(id: "app.txtnimal.preview", name: "Preview", version: "1.0.0",
                                 apiVersion: 1, entry: "main.js", capabilities: [.tasksUpdate, .uiPage],
                                 pages: [.init(id: "preview", title: "Preview", entryFunction: "render")]),
                                 taskRows: ["tasks": ["Review Q3 numbers", "Reply to client"]],
                                 documentRevision: "rev-1", onIntent: { _ in })
        .frame(width: 640, height: 480)
    }
}
#endif
