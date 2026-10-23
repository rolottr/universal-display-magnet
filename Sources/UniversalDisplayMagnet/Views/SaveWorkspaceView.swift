import AppKit
import Carbon.HIToolbox
import UniversalDisplayMagnetCore
import SwiftUI

/// State of the Save Workspace window (new workspace, or editing one).
@MainActor
final class SaveWorkspaceModel: ObservableObject {
    @Published var name: String
    @Published var hotkey: HotkeySpec?
    @Published var includeArrangement: Bool
    @Published private(set) var windows: [WindowSnapshot] = []
    @Published private(set) var displays: [DisplayPlacement] = []
    @Published var selectedApps: Set<String> = []
    @Published private(set) var capturing = false
    let existing: WindowLayout?

    /// `source` pre-fills the form. Editing the automatic snapshot creates a
    /// new workspace (the next snapshot would overwrite it otherwise).
    init(editing source: WindowLayout?, includeArrangement: Bool, suggestedName: String) {
        let editable = source.flatMap { $0.isAutosave ? nil : $0 }
        existing = editable
        name = editable?.name ?? suggestedName
        hotkey = editable?.hotkey
        self.includeArrangement = editable.map(\.isWorkspace) ?? includeArrangement
        if let source {
            windows = source.windows
            displays = source.displays
            selectedApps = Set(source.windows.map(\.bundleID))
        }
    }

    var prefilled: Bool { !windows.isEmpty }

    /// Apps with windows, most windows first.
    var apps: [(bundleID: String, name: String, count: Int)] {
        Dictionary(grouping: windows, by: \.bundleID)
            .map { ($0.key, $0.value[0].appName, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    var chosenWindows: [WindowSnapshot] { windows.filter { selectedApps.contains($0.bundleID) } }

    /// Read every window's position again ("Update Positions").
    func capture(_ model: AppModel) {
        capturing = true
        model.captureWindows { [weak self] windows, displays in
            guard let self else { return }
            let known = Set(self.windows.map(\.bundleID))
            let previouslyOff = known.subtracting(self.selectedApps)
            self.windows = windows
            self.displays = displays
            // Keep the user's choices; new apps start selected.
            self.selectedApps = Set(windows.map(\.bundleID)).subtracting(previouslyOff)
            self.capturing = false
        }
    }
}

struct SaveWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var form: SaveWorkspaceModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(form.existing == nil ? "Save Workspace" : "Edit Workspace")
                        .font(.title2.weight(.semibold))
                    information
                    preview
                    applications
                }
                .padding(20)
            }
            Divider()
            HStack {
                if !model.accessibilityTrusted {
                    Label("Needs Device Control permission", systemImage: "lock.shield").font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button(form.existing == nil ? "Save Workspace" : "Save Changes") {
                    model.saveWorkspace(
                        name: form.name.trimmingCharacters(in: .whitespaces), windows: form.chosenWindows,
                        displays: form.displays, hotkey: form.hotkey, includeArrangement: form.includeArrangement,
                        replacing: form.existing)
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty || form.chosenWindows.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 520, height: 720)
        .onAppear { if !form.prefilled { form.capture(model) } }
    }

    // MARK: - Sections

    private var information: some View {
        section("Workspace Information") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Name", text: $form.name)
                        .textFieldStyle(.roundedBorder)
                    ShortcutRecorder(hotkey: $form.hotkey)
                }
                Text("Name this workspace and optionally set a shortcut to restore it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Also restore the monitor arrangement and resolutions", isOn: $form.includeArrangement)
                    .font(.callout)
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Button {
                    form.capture(model)
                } label: {
                    Label("Update Positions", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(form.capturing)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35))
                if form.capturing {
                    ProgressView("Reading window positions…").controlSize(.small)
                } else if form.windows.isEmpty {
                    Text("No windows found").foregroundStyle(.secondary)
                } else {
                    LayoutPreview(displays: form.displays, windows: form.chosenWindows)
                        .padding(.top, 18)
                        .padding([.horizontal, .bottom], 10)
                }
            }
            .frame(height: 210)
        }
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applications").font(.headline)
            Text("Choose which apps to include. Only selected apps will be restored, and opened if they aren't running.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(form.apps, id: \.bundleID) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: AppLook.icon(app.bundleID)).resizable().frame(width: 20, height: 20)
                        Circle().fill(AppLook.color(app.bundleID)).frame(width: 7, height: 7)
                        Text(app.name)
                        if app.count > 1 {
                            Text("\(app.count) windows").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { form.selectedApps.contains(app.bundleID) },
                                set: { on in
                                    if on { form.selectedApps.insert(app.bundleID) } else {
                                        form.selectedApps.remove(app.bundleID)
                                    }
                                })
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    Divider().opacity(0.4)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            HStack {
                Text("Selected: \(form.apps.filter { form.selectedApps.contains($0.bundleID) }.count) of \(form.apps.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Select All") { form.selectedApps = Set(form.apps.map(\.bundleID)) }
                Button("Deselect All") { form.selectedApps = [] }
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

/// Click, then press a key combination (with ⌘, ⌥ or ⌃). Esc cancels.
struct ShortcutRecorder: View {
    @Binding var hotkey: HotkeySpec?
    @StateObject private var recording = ViewState(false)
    @StateObject private var monitor = ViewState<Any?>(nil)

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording.value ? stop() : start()
            } label: {
                (recording.value ? Text("Type shortcut…") : hotkey.map { Text($0.display) } ?? Text("Record Shortcut"))
                    .font(.system(size: 12, weight: hotkey == nil ? .regular : .semibold, design: .rounded))
                    .frame(minWidth: 110)
            }
            .controlSize(.regular)
            if hotkey != nil {
                Button {
                    hotkey = nil
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording.value = true
        monitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
            var carbon: UInt32 = 0
            var symbols = ""
            if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
            if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
            if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
            let key = (event.charactersIgnoringModifiers ?? "?").uppercased()
            hotkey = HotkeySpec(keyCode: UInt32(event.keyCode), modifiers: carbon, display: symbols + key)
            stop()
            return nil
        }
    }

    private func stop() {
        recording.value = false
        if let m = monitor.value { NSEvent.removeMonitor(m) }
        monitor.value = nil
    }
}

/// Hosts the Save Workspace window.
@MainActor
enum SaveWorkspaceWindow {
    private static var window: NSWindow?

    static func show(editing layout: WindowLayout? = nil, includeArrangement: Bool = true) {
        let model = AppModel.shared
        let suggested =
            model.workspaces.isEmpty ? String(localized: "Work") : String(localized: "Workspace \(model.workspaces.count + 1)")
        let form = SaveWorkspaceModel(editing: layout, includeArrangement: includeArrangement, suggestedName: suggested)
        window?.close()
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        w.title = form.existing == nil ? String(localized: "Save Workspace") : String(localized: "Edit Workspace")
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(
            rootView: SaveWorkspaceView(form: form) { [weak w] in w?.close() }
                .environmentObject(model))
        w.center()
        w.releaseContentOnClose { [weak w] in if window === w { window = nil } }
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
