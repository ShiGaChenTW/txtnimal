import SwiftUI
import txtnimalCore
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared export / markdown support

/// Host-side export helpers shared by the generic plugin page host and the LLM report view.
/// Extracted from the ten bespoke `ReportView` sections (SCO-174) so a single flattening +
/// NSSavePanel / share implementation serves every plugin page.
enum PluginPageExport {
    enum Outcome { case cancelled, saved, failed(String) }

    /// Writes a validated `export.write` artifact to a user-picked file.
    static func saveArtifactToFile(_ artifact: PluginExportArtifact) -> Outcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.filename
        let ext = (artifact.filename as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? UTType(mimeType: artifact.mimeType) ?? .plainText
        panel.allowedContentTypes = [type, .plainText]
        guard panel.runModal() == .OK else { return .cancelled }
        guard let url = panel.url else { return .failed("無法取得匯出位置。") }
        do {
            try artifact.content.write(to: url, atomically: true, encoding: .utf8)
            return .saved
        } catch {
            return .failed(readableMessage(for: error))
        }
    }

    /// Routes a validated `export.write` to the system share sheet via a temp file.
    static func shareArtifact(_ export: ValidatedPluginExport) -> Outcome {
        guard let contentView = NSApp.keyWindow?.contentView else {
            return .failed("目前沒有可用視窗,無法開啟分享選單。")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(export.artifact.filename)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try export.artifact.content.write(to: url, atomically: true, encoding: .utf8)
            NSSharingServicePicker(items: [url]).show(relativeTo: contentView.bounds,
                                                      of: contentView,
                                                      preferredEdge: .minY)
            return .saved
        } catch {
            return .failed(readableMessage(for: error))
        }
    }

    static func exportArtifact(_ export: ValidatedPluginExport) -> Outcome {
        switch export.destination {
        case .file: return saveArtifactToFile(export.artifact)
        case .share: return shareArtifact(export)
        }
    }

    /// Shared NSSavePanel `.md` export used by both the LLM report and the plugin page host.
    static func saveMarkdown(_ content: String, reportType: String) -> Outcome {
        saveArtifactToFile(PluginExportArtifact(
            filename: "report-\(exportDateString())-\(reportType).md",
            mimeType: "text/markdown",
            content: content))
    }

    /// Flattens a plugin page document to markdown: sections → `##`, text → lines,
    /// statCard / barChart → `**label:** value`, `• ` task lines → `- ` bullets.
    static func markdown(from document: PluginPageDocument) -> String {
        var lines: [String] = []
        func walk(_ node: PluginPageNode) {
            switch node.type {
            case .page:
                if let title = node.title { lines.append("# \(title)"); lines.append("") }
            case .section:
                if let title = node.title { lines.append(""); lines.append("## \(title)") }
            case .statCard:
                lines.append("**\(node.title ?? ""):** \(node.value ?? "")")
            case .barChart:
                if let title = node.title { lines.append("**\(title):** \(node.value ?? "")") }
            case .text:
                let value = node.value ?? node.title ?? ""
                lines.append(value.hasPrefix("• ") ? "- " + value.dropFirst(2).description : value)
            case .emptyState:
                lines.append("_\(node.title ?? node.value ?? "")_")
            case .divider:
                lines.append("---")
            case .taskList, .button, .form, .textField, .picker, .toggle, .spacer:
                break
            }
            for child in node.children ?? [] { walk(child) }
        }
        walk(document.page)
        return lines.joined(separator: "\n") + "\n"
    }

    static func exportDateString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func readableMessage(for error: Error) -> String {
        switch error {
        case AgentCredentialStoreError.missingConfiguration:
            return "尚未設定 Agent Endpoint。請先到設定填入 Base URL、API Key 與 Model。"
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - Generic plugin page host

/// SCO-174: one generic host that renders ANY plugin page from its manifest. It builds the
/// entry controls declared in `manifest.entryControls` (picker / toggle / textField), collects
/// their values into `input`, runs the plugin through `store.runPluginPage`, and renders the
/// resulting document with the existing `PluginPagePrototypeView` — wiring its kvSet / export /
/// import / agentQuery buttons back to the host. This replaces the ten bespoke `*Section`
/// views that used to be hand-written per plugin in `ReportView`.
struct PluginPageHostView: View {
    @EnvironmentObject var store: TaskStore
    let entry: PluginRegistryEntry

    /// entry-control id → current value (picker `value` token / "true"/"false" / free text).
    @State private var input: [String: String] = [:]
    @State private var document: PluginPageDocument?
    @State private var errorMessage: String?
    @State private var agentLoading = false
    @State private var didSeed = false

    private var manifest: PluginManifest { entry.manifest }
    private var controls: [PluginEntryControl] { manifest.entryControls ?? [] }
    private var canExportMarkdown: Bool { manifest.capabilities.contains(.uiPage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !controls.isEmpty { controlBar }
            actionBar
            if agentLoading { loadingRow }
            if let errorMessage { errorRow(errorMessage) }
            if let document {
                let context = store.pluginPageValidationContext()
                PluginPagePrototypeView(
                    document: document,
                    manifest: manifest,
                    taskRevisions: context.taskRevisions,
                    documentRevision: context.documentRevision,
                    onIntent: { store.applyPluginPageIntent($0) },
                    onKVWrite: handleKVWrite,
                    onExport: handleExport,
                    onImport: handleImport,
                    onAgentQuery: handleAgentQuery,
                    onValidationError: { errorMessage = PluginPageExport.readableMessage(for: $0) }
                )
                .frame(minHeight: 220)
                .overlay(Rectangle().stroke(Theme.border))
            }
        }
        .onAppear(perform: seedInputIfNeeded)
    }

    // MARK: chrome

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = manifest.placement?.icon {
                Image(systemName: icon).font(Theme.monoSmall).foregroundColor(Theme.green)
            }
            Text(manifest.name).font(Theme.monoSmall).tracking(1.4).foregroundColor(Theme.dim)
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(sectionTag).font(Theme.monoSmall).foregroundColor(Theme.green)
        }
    }

    /// Reflects where the plugin ACTUALLY renders, so the header cannot contradict the surface:
    /// a user pin (placement override) wins over the manifest, same as `PluginSurfaceResolver`.
    private var sectionTag: String {
        switch store.effectivePluginSection(for: entry) {
        case .sidebar: return "SIDEBAR"
        case .reports, .none: return "PLUGIN"
        }
    }

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(controls, id: \.id) { control in
                controlView(control)
            }
        }
    }

    @ViewBuilder
    private func controlView(_ control: PluginEntryControl) -> some View {
        switch control.type {
        case .picker:
            Picker("", selection: pickerBinding(control)) {
                ForEach(control.options ?? [], id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        case .toggle:
            Toggle(control.label, isOn: toggleBinding(control))
                .font(Theme.monoSmall)
                .foregroundColor(Theme.fg)
        case .textField:
            VStack(alignment: .leading, spacing: 6) {
                Text(control.label).font(Theme.monoSmall).foregroundColor(Theme.dim)
                TextField(control.label, text: textBinding(control))
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .foregroundColor(Theme.fg)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Theme.panel)
                    .overlay(Rectangle().stroke(Theme.border))
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Spacer()
            hostButton("產生", color: Theme.cyan) { generate() }
            if canExportMarkdown {
                hostButton("匯出 .md", color: Theme.yellow) { exportMarkdown() }
                    .disabled(document == nil)
                    .opacity(document == nil ? 0.4 : 1)
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在請 AI 產生…").font(Theme.monoSmall).foregroundColor(Theme.dim)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(Theme.monoSmall)
            .foregroundColor(Theme.red)
            .textSelection(.enabled)
    }

    private func hostButton(_ title: LocalizedStringKey, color: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Text("[") + Text(title) + Text("]") }
            .buttonStyle(.plain)
            .font(Theme.monoSmall)
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .contentShape(Rectangle())
    }

    // MARK: bindings

    private func pickerBinding(_ control: PluginEntryControl) -> Binding<String> {
        Binding(
            get: { input[control.id] ?? defaultValue(for: control) },
            set: { input[control.id] = $0; rerunIfGenerated() }
        )
    }

    private func toggleBinding(_ control: PluginEntryControl) -> Binding<Bool> {
        Binding(
            get: { (input[control.id] ?? defaultValue(for: control)) == "true" },
            set: { input[control.id] = $0 ? "true" : "false"; rerunIfGenerated() }
        )
    }

    private func textBinding(_ control: PluginEntryControl) -> Binding<String> {
        Binding(
            get: { input[control.id] ?? defaultValue(for: control) },
            set: { input[control.id] = String($0.prefix(1_000)); rerunIfGenerated() }
        )
    }

    /// Initial value for a control: its declared default, else the first picker option,
    /// else "false" for a toggle, else empty text.
    private func defaultValue(for control: PluginEntryControl) -> String {
        if let value = control.defaultValue { return value }
        switch control.type {
        case .picker: return control.options?.first?.value ?? ""
        case .toggle: return "false"
        case .textField: return ""
        }
    }

    private func seedInputIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        for control in controls where input[control.id] == nil {
            input[control.id] = defaultValue(for: control)
        }
    }

    // MARK: run + callbacks

    private func generate() {
        do {
            document = try store.runPluginPage(pluginId: manifest.id, input: input)
            errorMessage = nil
        } catch {
            document = nil
            errorMessage = PluginPageExport.readableMessage(for: error)
        }
    }

    /// A control changed: re-run only if the user already generated a page, so the surface
    /// stays lazy until first use but tracks the controls live thereafter.
    private func rerunIfGenerated() {
        guard document != nil else { return }
        generate()
    }

    private func handleKVWrite(_ write: ValidatedPluginKVWrite) {
        store.applyPluginKVWrite(write)
        generate() // reflect the storage.kv change in the re-rendered page
    }

    private func handleExport(_ export: ValidatedPluginExport) {
        switch PluginPageExport.exportArtifact(export) {
        case .cancelled: break
        case .saved: errorMessage = nil
        case .failed(let message): errorMessage = message
        }
    }

    private func handleImport(_ request: ValidatedImportRequest) {
        store.importFromReminders()
    }

    private func handleAgentQuery(_ query: ValidatedAgentQuery) {
        agentLoading = true
        errorMessage = nil
        Task { @MainActor in
            let result = await store.runPluginPageWithAgentQuery(entry: entry, input: input, query: query)
            agentLoading = false
            switch result {
            case .success(let doc): document = doc
            case .failure(let error): errorMessage = PluginPageExport.readableMessage(for: error)
            }
        }
    }

    private func exportMarkdown() {
        guard let document else { return }
        switch PluginPageExport.saveMarkdown(PluginPageExport.markdown(from: document),
                                             reportType: markdownReportType()) {
        case .cancelled: break
        case .saved: errorMessage = nil
        case .failed(let message): errorMessage = message
        }
    }

    /// Filename slug: the plugin short id plus any selected entry-control values.
    private func markdownReportType() -> String {
        let short = manifest.id.components(separatedBy: ".").last ?? manifest.id
        let suffix = controls.compactMap { input[$0.id] }
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return suffix.isEmpty ? short : "\(short)-\(suffix)"
    }
}

// MARK: - Dynamic reports list

/// Renders every page-capable plugin whose effective placement is the `reports` surface,
/// sorted by `placement.order`. Replaces the ten hand-wired plugin sections in `ReportView`.
///
/// SCO-175: recomputes whenever the gallery changes `disabledPluginIDs`, the placement overrides,
/// or the set of installed packages — so disabling / pinning / installing / removing a plugin adds
/// or removes its host view here live, without an app relaunch.
struct PluginReportsList: View {
    @EnvironmentObject var store: TaskStore
    @State private var entries: [PluginRegistryEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(entries, id: \.manifest.id) { entry in
                Divider().background(Theme.border)
                PluginPageHostView(entry: entry)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: store.disabledPluginIDs) { _ in reload() }
        .onChange(of: store.pluginPlacementOverrides) { _ in reload() }
        .onChange(of: store.installedPluginPackages.map(\.manifest.id)) { _ in reload() }
    }

    private func reload() { entries = store.reportPagePlugins() }
}
