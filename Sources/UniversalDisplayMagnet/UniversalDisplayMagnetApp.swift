import AppKit
import UniversalDisplayMagnetCore
import SwiftUI

@main
struct UniversalDisplayMagnetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(model)
        } label: {
            Image(systemName: model.activity == nil ? "rectangle.3.group" : "rectangle.3.group.fill")
        }
        .menuBarExtraStyle(.window)
        .commands { AppCommands(model: model) }
    }
}

/// The app's menu bar menus, shown while its window is open (closed, it lives
/// in the status-bar panel only).
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Task { await UpdateChecker.shared.checkAndReport() } }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { MainWindow.show(.settings) }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Universal Display Magnet Window") { MainWindow.show() }
                .keyboardShortcut("0")
        }
        CommandMenu("Displays") {
            Button("Snap Displays Together") { model.snapAllTogether() }
                .keyboardShortcut("j")
            Button("Edit Arrangement…") { MainWindow.show(.displays) }
                .keyboardShortcut("3")
            Button("Save Current Arrangement…") {
                if let name = Prompt.text("Save arrangement", defaultValue: "My Setup") { model.saveArrangement(name: name) }
            }
            Button("Arrange Displays Across Macs…") { MainWindow.show(.linked) }
                .keyboardShortcut("4")
            Button("Window Snapping…") { MainWindow.show(.snapping) }
                .keyboardShortcut("2")
            Button("Wake Other Mac") { model.wakeOtherMacs() }
            Button("Reset Universal Control") { model.resetUniversalControl() }
                .disabled(model.resettingUniversalControl)
            Button("Activity…") { MainWindow.show(.activity) }
                .keyboardShortcut("6")
            Button("Identify Displays") {
                IdentifyOverlay.show(names: Dictionary(uniqueKeysWithValues: model.displays.map { ($0.id, $0.identity.name) }))
            }
            Divider()
            ForEach(model.profiles(forSetup: model.setupKey)) { p in
                Button("Apply “\(p.name)”") { model.activate(p) }
            }
        }
        CommandMenu("Workspaces") {
            Button("Save Workspace…") { MenuActions.saveWorkspace() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save Window Layout…") { MenuActions.saveWindowLayout() }
            Button("Restore Latest Windows") { model.quickRestoreWindows() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            ForEach(model.workspaces) { w in
                Button("Restore “\(w.name)”") { model.restoreWorkspace(w) }
            }
            Divider()
            Button("All Workspaces & Layouts…") { MainWindow.show(.windows) }
                .keyboardShortcut("1")
            Button("Macs & Sync…") { MainWindow.show(.sync) }
                .keyboardShortcut("5")
        }
    }
}

/// Actions shared by the app menu, Dock menu and status-bar panel.
@MainActor
enum MenuActions {
    static func saveWorkspace() { SaveWorkspaceWindow.show() }

    /// Windows only, without the monitor arrangement.
    static func saveWindowLayout() { SaveWorkspaceWindow.show(includeArrangement: false) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened by hand: Dock icon and window. Opened at login: menu bar only.
        NSApp.setActivationPolicy(launchedAsLoginItem ? .accessory : .regular)
        if runDiagnostics() { return }
        if let dir = DemoRenderer.outputDirectory {
            DemoRenderer.prepareData()
            DemoRenderer.run(into: dir)
            return
        }
        if let dir = DebugSnapshot.directory {
            AppModel.shared.refreshDisplays()
            DebugSnapshot.run(into: dir)
            return
        }
        AppModel.shared.start()
        UpdateChecker.shared.startAutomaticChecks()
        observeAppWindows()
        if !launchedAsLoginItem { MainWindow.show() }
    }

    /// Like most menu bar apps: while a window is open the app has a Dock icon
    /// and menus; once the last one closes it steps back to the menu bar (no
    /// Dock icon, not in ⌘-Tab) and keeps running.
    private func observeAppWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, Self.isAppWindow(window),
                    NSApp.activationPolicy() != .regular
                else { return }
                NSApp.setActivationPolicy(.regular)
                // Coming back from the menu bar, the app must be active again for its menus to show.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, Self.isAppWindow(closing) else { return }
                let othersOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isAppWindow($0) }
                if !othersOpen { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    /// The main and Save Workspace windows; not the menu bar panel, overlays or alerts.
    private static func isAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && !window.isSheet && window.styleMask.contains(.titled) && window.canBecomeMain
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running for the menu bar, shortcuts, sync and window snapping.
        false
    }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let model = AppModel.shared
        let menu = NSMenu()
        menu.addItem(DockItem("Save Workspace…") { MenuActions.saveWorkspace() })
        let workspaces = model.workspaces
        if !workspaces.isEmpty {
            menu.addItem(.separator())
            for w in workspaces.prefix(8) {
                menu.addItem(DockItem("Restore “\(w.name)”") { model.restoreWorkspace(w) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(DockItem("Restore Latest Windows") { model.quickRestoreWindows() })
        menu.addItem(DockItem("Wake Other Mac") { model.wakeOtherMacs() })
        menu.addItem(DockItem("Snap Displays Together") { model.snapAllTogether() })
        return menu
    }

    // MARK: - Diagnostics (command-line flags)

    /// `--uc-status [--uc-reapply]` and `--uc-move <display-uuid> <x> <y>`.
    /// Returns true when a diagnostic ran (the process exits).
    private func runDiagnostics() -> Bool {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--purge-records") {
            // Delete records on every connected Mac: connect, tombstone, wait.
            let ids = Array(a[(i + 1)...])
            let model = AppModel.shared
            model.refreshUniversalControl()
            model.startSync()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                print("connected:", model.peers.map(\.name))
                model.purge(ids: ids)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    model.flush()
                    print("purged", ids)
                    exit(0)
                }
            }
            return true
        }
        if let i = a.firstIndex(of: "--uc-move"), i + 3 < a.count {
            // Move one of this Mac's displays (by CoreGraphics UUID) to x,y
            // exactly as a drop on the Universal Control canvas does.
            let model = AppModel.shared
            model.refreshDisplays()
            model.refreshUniversalControl()
            guard let d = model.displays.first(where: { $0.identity.uuid == a[i + 1] }),
                let x = Int(a[i + 2]), let y = Int(a[i + 3]), let me = model.universalControl?.selfDevice,
                let remote = model.devices.first(where: { $0.deviceID != model.deviceID && model.ucDevice(for: $0) != nil }),
                let uc = model.ucDevice(for: remote)
            else {
                print("can't resolve display / Universal Control / other Mac")
                exit(1)
            }
            let theirs = remote.displays.compactMap { p in p.identity.uuid.map { UCDisplay(uuid: $0, frame: p.frame) } }
            let mine = model.displays.compactMap { p in p.identity.uuid.map { UCDisplay(uuid: $0, frame: p.frame) } }
            guard let link = model.universalControl?.link(from: uc, to: me),
                let offset = UCGeometry.offset(of: link, displays1: theirs, displays2: mine)
            else {
                print("Macs not linked yet")
                exit(1)
            }
            model.moveLocalDisplay(
                d.id, to: IRect(x: x, y: y, width: d.frame.width, height: d.frame.height), remoteDevice: uc,
                remoteDisplays: theirs, remoteOffset: offset)
            model.flush()
            print(model.message)
            exit(0)
        }
        if let i = a.firstIndex(of: "--restore-plan"), i + 2 < a.count {
            // Which windows restoring a layout would touch (read-only).
            let model = AppModel.shared
            model.refreshDisplays()
            var out = ""
            if let layout = model.windowLayouts.first(where: { $0.name == a[i + 1] }) {
                let pending = WindowService.windowsToRestore(layout, displays: model.displays, spaces: SpaceService.snapshot())
                let ids = Set(pending.map { "\($0.windowNumber ?? 0)|\($0.bundleID)|\($0.frame)" })
                for w in layout.windows {
                    let needs = ids.contains("\(w.windowNumber ?? 0)|\(w.bundleID)|\(w.frame)")
                    out += "\(needs ? "RESTORE " : "in place") \(w.appName) desktop=\(w.spaceIndex.map(String.init) ?? "-") position=\(w.spacePosition.map(String.init) ?? "-") fullscreen=\(w.isFullscreen)\n"
                }
            } else {
                out = "no layout named \(a[i + 1])\n"
            }
            try? out.write(toFile: a[i + 2], atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = a.firstIndex(of: "--windows-report"), i + 1 < a.count {
            // Compare what Accessibility finds with what the window server
            // reports, per app and Space (read-only).
            var out = WindowService.diagnosticReport()
            // What a capture records now (read-only).
            let displays = DisplayService.activeDisplays()
            for w in WindowService.capture(displays: displays, allDesktops: true) {
                out += "\ncapture: \(w.appName) display=\(w.displayKey.prefix(9)) desktop=\(w.spaceIndex.map(String.init) ?? "-") position=\(w.spacePosition.map(String.init) ?? "-") fullscreen=\(w.isFullscreen) visible=\(w.onVisibleSpace ?? false) frame=\(w.frame)"
            }
            try? out.write(toFile: a[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if a.contains("--uc-status") {
            // What Universal Display Magnet reads from Universal Control.
            guard let state = UCBridge.read() else {
                print("Universal Control: unavailable (framework missing)")
                exit(1)
            }
            print("Universal Control enabled:", state.enabled)
            print("This Mac:", state.selfDevice ?? "not identified")
            for (device, displays) in state.devices.sorted(by: { $0.key < $1.key }) {
                print("  device", device, device == state.selfDevice ? "(this Mac)" : "", "displays:", displays.sorted())
            }
            for l in state.links {
                print("  link", l.device1.prefix(8), l.display1.prefix(8), l.summary, l.device2.prefix(8), l.display2.prefix(8))
            }
            if a.contains("--uc-reapply"), let link = state.links.first {
                // Re-write the current link through the full apply path
                // (read-back verification, backup, save).
                do {
                    try UCBridge.apply(link)
                    print("re-applied:", link.summary, "→ ok")
                } catch {
                    print("re-apply failed:", error.localizedDescription)
                    exit(1)
                }
            }
            exit(0)
        }
        return false
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    // Sidebar order.
    case windows, snapping, displays, linked, sync, activity, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .displays: return "Displays"
        case .linked: return "Universal Control"
        case .windows: return "Workspaces"
        case .snapping: return "Window Snapping"
        case .sync: return "Macs & Sync"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .displays: return "rectangle.3.group"
        case .linked: return "display.2"
        case .windows: return "macwindow.on.rectangle"
        case .snapping: return "rectangle.split.2x2"
        case .sync: return "arrow.triangle.2.circlepath"
        case .activity: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
}

/// Shared navigation so menus can open a specific section.
@MainActor
final class Navigation: ObservableObject {
    static let shared = Navigation()
    @Published var section: AppSection = .windows
    /// Device whose arrangement the editor should show (nil = this Mac).
    @Published var editorDevice: String?
}

/// Dock-menu item that runs a closure.
private final class DockItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// The main window (hosted in AppKit so the Dock icon and menus can reopen it).
@MainActor
enum MainWindow {
    private static var window: NSWindow?

    static func show(_ section: AppSection? = nil, device: String? = nil) {
        if let section { Navigation.shared.section = section }
        if section == .displays { Navigation.shared.editorDevice = device }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "Universal Display Magnet"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 860, height: 600)
            w.contentViewController = NSHostingController(
                rootView: MainView()
                    .environmentObject(AppModel.shared)
                    .environmentObject(Navigation.shared))
            w.center()
            w.setFrameAutosaveName("Universal Display MagnetMain")
            window = w
        }
        // The app drops its Dock icon while no window is open; bring it back with the window.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Small modal text prompt (names for profiles and layouts).
@MainActor
enum Prompt {
    static func text(_ title: String, message: String = "", defaultValue: String = "", confirm: String = "Save") -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func confirm(_ title: String, message: String, confirm: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
