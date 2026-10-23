import UniversalDisplayMagnetCore
import SwiftUI

/// The menu bar popover: workspaces first. Display arrangement is set up
/// once in the app window, so it isn't here.
struct MenuPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let release = updates.available {
                Button {
                    updates.download(release)
                } label: {
                    Label("Universal Display Magnet \(release.version) is available — Download", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
            }

            if !model.accessibilityTrusted {
                Button {
                    model.requireAccessibility()
                    model.openAccessibilitySettings()
                } label: {
                    Label("Allow Device Control to save windows", systemImage: "lock.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
            }

            Button {
                MenuActions.saveWorkspace()
            } label: {
                Label("Save Workspace…", systemImage: "square.stack.3d.up.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.accessibilityTrusted)

            snapping
            Divider()
            workspaces
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Universal Display Magnet").font(.headline)
                (model.setupLabel.isEmpty ? Text("No displays") : Text(model.setupLabel))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let activity = model.activity {
                ProgressView().controlSize(.mini)
                    .help(activity)
            }
        }
    }

    /// Magnet-style snap buttons; they act on the app you used last.
    private var snapping: some View {
        let commands = model.snapCommands.filter(\.showInMenu)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SNAP WINDOW").font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    MainWindow.show(.snapping)
                } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Window Snapping settings")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(commands) { c in
                    Button {
                        model.runSnap(c)
                    } label: {
                        SnapGlyph(command: c, size: CGSize(width: 30, height: 19))
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(c.title + (c.hotkeyEnabled ? c.hotkey.map { "  \($0.display)" } ?? "" : ""))
                }
            }
        }
    }

    /// Up to four, two per row: saved workspaces first, then the latest snapshot.
    private var workspaces: some View {
        let layouts = model.layouts(forSetup: model.setupKey, device: model.deviceID)
        let shown = Array((layouts.filter { !$0.isAutosave } + layouts.filter(\.isAutosave)).prefix(4))
        return VStack(alignment: .leading, spacing: 6) {
            Text("WORKSPACES").font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
            if shown.isEmpty {
                Text("Arrange your windows, then Save Workspace. Restore it any time from here or with its shortcut.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(shown) { tile($0) }
            }
        }
    }

    private func tile(_ l: WindowLayout) -> some View {
        Button {
            if l.isWorkspace { model.restoreWorkspace(l) } else { model.restore(l) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                LayoutPreview(displays: l.displays, windows: l.windows, compact: true)
                    .frame(height: 62)
                    .frame(maxWidth: .infinity)
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6)))
                HStack(spacing: 4) {
                    (l.isAutosave ? Text("Latest snapshot") : Text(l.name)).font(.callout).lineLimit(1)
                    Spacer(minLength: 0)
                    if let key = l.hotkey {
                        Text(key.display)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    }
                }
                Text("\(Set(l.windows.map(\.bundleID)).count) apps").font(.caption).foregroundStyle(.secondary)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l.isWorkspace ? "Restore monitors, apps and windows" : "Restore windows")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.message.isEmpty || model.activity != nil {
                Text(model.activity ?? model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button {
                    MainWindow.show(.windows)
                } label: { Label("Settings", systemImage: "gearshape") }
                Spacer()
                if model.canWakeOtherMac {
                    Button {
                        model.wakeOtherMacs()
                    } label: { Label("Wake Other Mac", systemImage: "sun.max") }
                    .help("Your other Mac's screens are asleep: turn them on")
                }
                Button {
                    NSApp.terminate(nil)
                } label: { Label("Quit", systemImage: "power") }
            }
            .controlSize(.small)
        }
    }
}

/// SwiftUI keeps a `.window` menu bar panel's views alive after it closes,
/// laying them out on every model change. While closed, the panel holds a
/// blank of the same size instead.
struct PanelHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @StateObject private var open = ViewState(true)
    @StateObject private var size = ViewState(CGSize.zero)

    var body: some View {
        // A ZStack, not a Group: a Group would hand onAppear to each child.
        ZStack {
            if open.value {
                content().onGeometryChange(for: CGSize.self, of: \.size) { size.value = $0 }
            } else {
                Color.clear.frame(width: size.value.width, height: size.value.height)
            }
        }
        .onAppear { open.value = true }
        .onDisappear { open.value = false }
    }
}
