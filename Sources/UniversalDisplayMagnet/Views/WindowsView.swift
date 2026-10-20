import UniversalDisplayMagnetCore
import SwiftUI

struct WindowsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var expandedState = ViewState<Set<String>>([])
    private var expanded: Set<String> {
        get { expandedState.value }
        nonmutating set { expandedState.value = newValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                banners
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Workspaces & window layouts").font(.title2.weight(.semibold))
                        Text(
                            "A workspace saves everything: the monitor arrangement and resolutions, and every app's windows with their monitor and Desktop. Restoring it re-arranges the monitors, opens any apps that aren't running and puts each window back. Window layouts save just the windows."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            MenuActions.saveWorkspace()
                        } label: { Label("Save Workspace…", systemImage: "square.stack.3d.up") }
                        .buttonStyle(.borderedProminent)
                        Button {
                            MenuActions.saveWindowLayout()
                        } label: { Label("Save Windows Only…", systemImage: "macwindow") }
                    }
                    .disabled(!model.accessibilityTrusted)
                }

                group(
                    "This setup — \(model.setupLabel)",
                    layouts: model.layouts(forSetup: model.setupKey, device: model.deviceID))
                let others = model.windowLayouts.filter { !($0.setupKey == model.setupKey && $0.deviceID == model.deviceID) }
                let byDevice = Dictionary(grouping: others, by: \.deviceName)
                ForEach(byDevice.keys.sorted(), id: \.self) { device in
                    group(
                        device == model.deviceName ? "Other setups on this Mac" : "From \(device)",
                        layouts: byDevice[device]!.sorted { $0.updatedAt > $1.updatedAt })
                }
            }
            .padding(22)
        }
    }

    @ViewBuilder
    private var banners: some View {
        if !model.accessibilityTrusted {
            PermissionBanner(
                icon: "lock.shield", title: "Permission needed to see and move windows",
                detail:
                    "Turn on Universal Display Magnet in System Settings › Privacy & Security › Device Control and Data Access (called Accessibility on older macOS). If it's already on but this still shows, remove it with − and turn it on again.",
                action: "Open Settings"
            ) {
                model.requireAccessibility()
                model.openAccessibilitySettings()
            }
        }
        if model.settings.moveBetweenDesktops && model.desktopShortcuts == 0 {
            PermissionBanner(
                icon: "rectangle.stack", title: "Desktop shortcuts are off",
                detail:
                    "macOS no longer lets apps move other apps' windows between Desktops directly. Universal Display Magnet carries them using the “Switch to Desktop N” shortcuts (⌃1…⌃0), which are disabled. Enable them to restore windows onto the right Desktop.",
                action: "Enable ⌃1…⌃0"
            ) { model.enableDesktopShortcuts() }
        }
    }

    private func group(_ title: String, layouts: [WindowLayout]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
            if layouts.isEmpty {
                Text(
                    model.settings.autosaveWindows
                        ? "Nothing yet. An automatic snapshot appears after a couple of minutes."
                        : "Nothing saved yet."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(layouts) { layout in
                card(layout)
            }
        }
    }

    private func card(_ layout: WindowLayout) -> some View {
        let isOpen = expanded.contains(layout.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                LayoutPreview(displays: layout.displays, windows: layout.windows, compact: true)
                    .frame(width: 150, height: 84)
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.7)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(layout.name).font(.headline)
                        if layout.isWorkspace {
                            Text("MONITORS + DESKTOPS + APPS").font(.system(size: 8, weight: .bold)).tracking(0.8)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.blue.opacity(0.2)))
                        }
                        if let key = layout.hotkey {
                            Text(key.display).font(.system(size: 11, weight: .medium, design: .rounded))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                        }
                    }
                    Text(
                        "\(layout.windows.count) windows · \(Set(layout.windows.map(\.bundleID)).count) apps · \(layout.updatedAt.formatted(.relative(presentation: .named))) · \(DisplaySetup.label(for: layout.displays.map(\.identity)))"
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 4) {
                        ForEach(Array(Set(layout.windows.map(\.bundleID))).sorted().prefix(10), id: \.self) { id in
                            Image(nsImage: AppLook.icon(id)).resizable().frame(width: 16, height: 16)
                        }
                    }
                }
                Spacer()
                Button("Restore") {
                    if layout.isWorkspace { model.restoreWorkspace(layout) } else { model.restore(layout) }
                }
                    .disabled(!model.accessibilityTrusted || model.activity != nil)
                Menu {
                    Button(layout.isAutosave ? "Save as Workspace…" : "Edit…") { SaveWorkspaceWindow.show(editing: layout) }
                    Button(isOpen ? "Hide Windows" : "Show Windows") { toggle(layout.id) }
                    Button(layout.isAutosave ? "Keep as Named Layout…" : "Rename…") {
                        if let n = Prompt.text("Name this layout", defaultValue: layout.isAutosave ? "" : layout.name) {
                            model.rename(layout, to: n)
                        }
                    }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete(layout) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(layout.windows.enumerated()), id: \.offset) { _, w in
                        HStack(spacing: 8) {
                            Text(w.appName).font(.system(size: 11, weight: .medium)).frame(width: 130, alignment: .leading)
                                .lineLimit(1)
                            Text(w.title.isEmpty ? "—" : w.title).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Text(displayName(w, in: layout)).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(
                                w.isFullscreen ? "Full screen" : w.spaceIndex.map { "Desktop \($0)" } ?? "All Desktops"
                            )
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                        }
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { toggle(layout.id) }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func displayName(_ w: WindowSnapshot, in layout: WindowLayout) -> String {
        layout.displays.first { $0.identity.hardwareKey == w.displayKey }?.identity.name ?? "?"
    }
}
