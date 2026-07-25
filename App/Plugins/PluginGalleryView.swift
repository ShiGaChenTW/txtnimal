import SwiftUI
import txtnimalCore
import AppKit

/// SCO-175: the plugin management surface ("外掛 gallery"). Lists every plugin the unified
/// `PluginRegistry` discovers — bundled fixtures and installed packages alike — and lets the user
/// enable/disable, pin between the reports and sidebar surfaces, and install/remove packages.
///
/// It is a plain `VStack` (no scroll container of its own) so it drops straight into the Settings
/// `ScrollView`. Every mutation goes through `TaskStore`'s persisted, `@Published` gallery state,
/// so the dynamic surface lists (`PluginReportsList`, sidebar) re-render the instant a row changes.
struct PluginGalleryView: View {
    @EnvironmentObject var store: TaskStore

    var body: some View {
        // Read reactively: any change to disabledPluginIDs / overrides / installed packages
        // re-evaluates this body and re-asks the registry, so the list always reflects live state.
        let entries = store.galleryPluginEntries()
        let sidebarEntries = store.sidebarPagePlugins()

        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("外掛")

            if entries.isEmpty {
                Text("找不到任何外掛。")
                    .font(Theme.monoSmall).foregroundColor(Theme.dim)
            } else {
                ForEach(entries, id: \.manifest.id) { entry in
                    galleryRow(entry)
                    Rectangle().fill(Theme.border).frame(height: 1).opacity(0.5)
                }
            }

            HStack(spacing: 10) {
                actionButton("安裝外掛 package…", color: Theme.cyan) { presentInstallPanel() }
                actionButton("重新掃描", color: Theme.yellow) { store.refreshInstalledPlugins() }
                Spacer()
            }

            hint("停用會讓外掛從報表分頁與側欄消失；釘選可切換外掛出現的位置。變更即時生效。")
            hint("安裝的外掛沿用既有簽章與權限審查流程；設定持久化於 App 偏好設定。")

            if !sidebarEntries.isEmpty {
                sectionHeader("已釘選側欄")
                ForEach(sidebarEntries, id: \.manifest.id) { entry in
                    PluginPageHostView(entry: entry)
                    Rectangle().fill(Theme.border).frame(height: 1).opacity(0.5)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func galleryRow(_ entry: PluginRegistryEntry) -> some View {
        let manifest = entry.manifest
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(manifest.name).foregroundColor(Theme.fg)
                Text("v\(manifest.version)").font(Theme.monoSmall).foregroundColor(Theme.dim)
                sourceBadge(entry.source)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.isPluginEnabled(id: manifest.id) },
                    set: { store.setPluginEnabled(id: manifest.id, $0) }
                ))
                .labelsHidden()
                .help(store.isPluginEnabled(id: manifest.id) ? "已啟用" : "已停用")
            }

            Text(manifest.id).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.75))

            if !manifest.capabilities.isEmpty {
                Text(manifest.capabilities.map(\.rawValue).joined(separator: ", "))
                    .font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.75))
            }

            placementControls(entry)
        }
        .padding(.vertical, 6)
        .opacity(store.isPluginEnabled(id: manifest.id) ? 1 : 0.45)
    }

    /// Pin control (報表 / 側欄) plus a remove button for installed packages. Page-capable plugins
    /// only — plugins without `ui.page` never render on a surface, so pinning them is meaningless.
    @ViewBuilder
    private func placementControls(_ entry: PluginRegistryEntry) -> some View {
        let manifest = entry.manifest
        HStack(spacing: 10) {
            if manifest.capabilities.contains(.uiPage) {
                Text("位置").font(Theme.monoSmall).foregroundColor(Theme.dim)
                Picker("", selection: Binding(
                    get: { store.effectivePluginSection(for: entry) ?? .reports },
                    set: { store.setPluginSection(id: manifest.id, $0) }
                )) {
                    Text("報表").tag(PluginPlacement.Section.reports)
                    Text("側欄").tag(PluginPlacement.Section.sidebar)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                .disabled(!store.isPluginEnabled(id: manifest.id))
            }
            Spacer()
            if entry.source == .installed {
                Button("移除") { removeInstalled(manifest.id) }
                    .buttonStyle(.plain)
                    .font(Theme.monoSmall)
                    .foregroundColor(Theme.red)
            }
        }
    }

    private func sourceBadge(_ source: PluginRegistryEntry.Source) -> some View {
        let label: LocalizedStringKey = source == .bundled ? "內建" : "已安裝"
        let color = source == .bundled ? Theme.green : Theme.cyan
        return Text(label)
            .font(Theme.monoSmall)
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .overlay(Rectangle().stroke(color.opacity(0.5)))
    }

    // MARK: - Chrome

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.monoSmall).foregroundColor(Theme.dim).tracking(1.5)
            Rectangle().fill(Theme.border).frame(height: 1)
        }
        .padding(.top, 6)
    }

    private func actionButton(_ title: LocalizedStringKey, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) { Text("[") + Text(title) + Text("]") }
            .buttonStyle(.plain)
            .font(Theme.monoSmall)
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .contentShape(Rectangle())
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Theme.monoSmall).foregroundColor(Theme.dim.opacity(0.8))
    }

    // MARK: - Actions

    private func removeInstalled(_ id: String) {
        guard let package = store.installedPluginPackages.first(where: { $0.manifest.id == id }) else { return }
        store.removeInstalledPlugin(package)
    }

    private func presentInstallPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("安裝", comment: "install plugin package")
        if panel.runModal() == .OK, let url = panel.url {
            store.installPluginPackage(from: url)
        }
    }
}
