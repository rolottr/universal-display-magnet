import AppKit
import UniversalDisplayMagnetCore
import SwiftUI

/// `Universal Display Magnet --demo-frames <dir>` renders the README animations frame by
/// frame from scripted demo data (no personal data, nothing real touched),
/// then quits. `scripts/make-readme-animations.sh` turns the frames into
/// animated WebP. Run it with UDM_DATA_DIR pointing at an empty folder.
@MainActor
enum DemoRenderer {
    nonisolated static var isActive: Bool { CommandLine.arguments.contains("--demo-frames") }

    static var outputDirectory: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo-frames"), i + 1 < a.count else { return nil }
        return URL(fileURLWithPath: a[i + 1], isDirectory: true)
    }

    // MARK: - Demo data

    /// Made-up displays for this Mac (never the real ones: no serials or IDs).
    nonisolated static let localDisplays: [LiveDisplay] = [
        LiveDisplay(
            id: 1,
            identity: DisplayIdentity(
                vendor: 7789, model: 30001, serial: 1001, alphanumericSerial: "DEMO0001", name: "LG UltraWide",
                uuid: "A0A0A0A0-0000-4000-8000-0000000000D1"),
            frame: IRect(x: 0, y: 0, width: 3440, height: 1440), isMain: true,
            mode: DisplayModeSpec(width: 3440, height: 1440, pixelWidth: 3440, pixelHeight: 1440, refreshRate: 60),
            ordinal: 0),
        LiveDisplay(
            id: 2,
            identity: DisplayIdentity(
                vendor: 4321, model: 1100, serial: 1002, name: "Portable", uuid: "A0A0A0A0-0000-4000-8000-0000000000D2"),
            frame: IRect(x: 1199, y: 1440, width: 1920, height: 1200), isMain: false,
            mode: DisplayModeSpec(width: 1920, height: 1200, pixelWidth: 1920, pixelHeight: 1200, refreshRate: 60),
            ordinal: 0),
    ]

    private static let remoteUC = "B0B0B0B0-0000-4000-8000-00000000000B"
    private static let selfUC = "A0A0A0A0-0000-4000-8000-00000000000A"
    private static let remoteDisplays = [
        DisplayPlacement(
            identity: DisplayIdentity(
                vendor: 7789, model: 30000, serial: 1, name: "LG HDR 4K", uuid: "B0B0B0B0-0000-4000-8000-0000000000D1"),
            frame: IRect(x: 0, y: 0, width: 3008, height: 1692), isMain: true),
        DisplayPlacement(
            identity: DisplayIdentity(
                vendor: 4321, model: 1234, serial: 2, name: "Portable", uuid: "B0B0B0B0-0000-4000-8000-0000000000D2"),
            frame: IRect(x: 1100, y: 1692, width: 1920, height: 1200), isMain: false),
    ]

    nonisolated(unsafe) private static var wallpapers: [Int: Data] = [:]

    /// A soft two-colour gradient standing in for a wallpaper.
    nonisolated static func wallpaper(seed: Int) -> Data? {
        if let w = wallpapers[seed] { return w }
        let palettes: [(NSColor, NSColor)] = [
            (.systemIndigo, .systemTeal), (.systemPurple, .systemPink), (.systemBlue, .systemMint),
            (.systemOrange, .systemPurple),
        ]
        let (a, b) = palettes[abs(seed) % palettes.count]
        let size = NSSize(width: 320, height: 200)
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [a.blended(withFraction: 0.35, of: .black)!, b])?.draw(
            in: NSRect(origin: .zero, size: size), angle: 35)
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        wallpapers[seed] = data
        return data
    }

    /// Write the demo records before AppModel loads them.
    static func prepareData() {
        let local = DisplayService.activeDisplays()
        let device = Persistence.deviceID()
        var store = RecordStore()
        let mini = DeviceStatus(
            deviceID: "DEMO-MAC-MINI", name: "Mac mini", model: "Mac14,12", displays: remoteDisplays,
            setupKey: DisplaySetup.key(for: remoteDisplays.map(\.identity)),
            wallpapers: [wallpaper(seed: 100), wallpaper(seed: 101)])
        store.put(mini, id: "device:DEMO-MAC-MINI", kind: .device, device: "DEMO-MAC-MINI")

        let placements = local.map(\.placement)
        let setup = DisplaySetup.key(for: placements.map(\.identity))
        store.put(
            ArrangementProfile(
                id: "demo-arrangement", name: "Desk", setupKey: setup, displays: placements, deviceID: device,
                deviceName: "Mac Studio"),
            id: "demo-arrangement", kind: .arrangement, device: device)

        guard let main = local.first(where: \.isMain) ?? local.first else { return }
        let second = local.first { $0.id != main.id }
        func win(
            _ bundle: String, _ name: String, on d: LiveDisplay?, _ r: GridRect, desktop: Int?, position: Int?,
            visible: Bool, fullscreen: Bool = false, z: Int
        ) -> WindowSnapshot? {
            guard let d else { return nil }
            let area = IRect(x: 0, y: d.isMain ? 25 : 0, width: d.frame.width, height: d.frame.height - (d.isMain ? 25 : 0))
            return WindowSnapshot(
                bundleID: bundle, appName: name, title: name, windowNumber: nil, displayKey: d.identity.hardwareKey,
                displayOrdinal: d.ordinal, frame: fullscreen ? IRect(x: 0, y: 0, width: d.frame.width, height: d.frame.height) : r.frame(in: area),
                spaceIndex: fullscreen ? nil : desktop, isFullscreen: fullscreen, z: z, spacePosition: position,
                onVisibleSpace: visible, onAllDesktops: false)
        }
        let coding = [
            win("com.apple.Safari", "Safari", on: main, GridRect(cols: 2, rows: 1, x: 0, y: 0, w: 1, h: 1), desktop: 1, position: 1, visible: true, z: 0),
            win("com.apple.Terminal", "Terminal", on: main, GridRect(cols: 2, rows: 2, x: 1, y: 0, w: 1, h: 1), desktop: 1, position: 1, visible: true, z: 1),
            win("com.apple.Notes", "Notes", on: main, GridRect(cols: 2, rows: 2, x: 1, y: 1, w: 1, h: 1), desktop: 1, position: 1, visible: true, z: 2),
            win("com.apple.mail", "Mail", on: main, GridRect(cols: 1, rows: 1, x: 0, y: 0, w: 1, h: 1), desktop: 2, position: 2, visible: false, z: 3),
            win("com.apple.Music", "Music", on: second, GridRect(cols: 1, rows: 1, x: 0, y: 0, w: 1, h: 1), desktop: nil, position: 1, visible: true, fullscreen: true, z: 4),
            win("com.apple.finder", "Finder", on: second, GridRect(cols: 6, rows: 4, x: 1, y: 0, w: 4, h: 4), desktop: 1, position: 2, visible: false, z: 5),
        ].compactMap { $0 }
        let meetings = [
            win("com.apple.iCal", "Calendar", on: main, GridRect(cols: 3, rows: 1, x: 0, y: 0, w: 2, h: 1), desktop: 1, position: 1, visible: true, z: 0),
            win("com.apple.MobileSMS", "Messages", on: main, GridRect(cols: 3, rows: 1, x: 2, y: 0, w: 1, h: 1), desktop: 1, position: 1, visible: true, z: 1),
            win("com.apple.Notes", "Notes", on: second, GridRect(cols: 1, rows: 1, x: 0, y: 0, w: 1, h: 1), desktop: 1, position: 1, visible: true, z: 2),
        ].compactMap { $0 }
        let d = Date().addingTimeInterval(-3600 * 26)
        for (id, name, windows, key, autosave) in [
            ("demo-coding", "Coding", coding, HotkeySpec(keyCode: 8, modifiers: 0x0800 | 0x0100, display: "⌥⌘C"), false),
            ("demo-meetings", "Meetings", meetings, HotkeySpec(keyCode: 46, modifiers: 0x0800 | 0x0100, display: "⌥⌘M"), false),
            (WindowLayout.autosaveID(deviceID: device, setupKey: setup), "Automatic snapshot", coding, nil, true),
        ] {
            let layout = WindowLayout(
                id: id, name: name, setupKey: setup, deviceID: device, deviceName: "Mac Studio", isAutosave: autosave,
                arrangementID: autosave ? nil : "demo-arrangement", hotkey: key, windows: windows,
                displays: placements, updatedAt: autosave ? Date().addingTimeInterval(-120) : d)
            store.put(layout, id: id, kind: .windowLayout, device: device)
        }
        Persistence.saveRecords(store)
    }

    /// Universal Control as if the Mac mini were linked to this Mac.
    private static func demoUniversalControl(_ model: AppModel) -> UCBridge.State {
        let mine = Set(model.displays.compactMap(\.identity.uuid))
        let theirs = Set(remoteDisplays.compactMap(\.identity.uuid))
        let main = model.displays.first(where: \.isMain)?.identity.uuid ?? ""
        let link = UCLink(
            device1: remoteUC, display1: remoteDisplays[0].identity.uuid!, device2: selfUC, display2: main, edge: .right,
            offset1: 32767, offset2: 32767)
        return UCBridge.State(
            selfDevice: selfUC, devices: [selfUC: mine, remoteUC: theirs], links: [link], enabled: true)
    }

    // MARK: - Rendering

    static func run(into dir: URL) {
        let model = AppModel.shared
        model.reloadRecords()
        model.refreshDisplays()
        model.enterDemo(universalControl: demoUniversalControl(model))
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        renderShowcase(model, into: dir.appendingPathComponent("showcase"))
        renderMenuBar(model, into: dir.appendingPathComponent("menubar"))
        NSApp.terminate(nil)
    }

    /// Renders views into numbered PNGs through a real (off-screen) window,
    /// so AppKit-backed controls draw too.
    @MainActor private final class FrameWriter {
        let dir: URL
        let window: NSWindow
        let host: NSHostingView<AnyView>
        var index = 0

        init(dir: URL, size: NSSize) {
            self.dir = dir
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            host = NSHostingView(rootView: AnyView(EmptyView()))
            host.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -6000, y: -6000), size: size), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .darkAqua)
            // Transparent outside the rounded corners.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.orderFrontRegardless()
        }

        func frame<V: View>(_ view: V, hold: Int = 1, settle: TimeInterval = 0.04) {
            host.rootView = AnyView(
                view.environment(\.colorScheme, .dark)
                    .environmentObject(AppModel.shared)
                    .environmentObject(Navigation.shared))
            RunLoop.current.run(until: Date().addingTimeInterval(settle))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            for _ in 0..<hold {
                index += 1
                try? png.write(to: dir.appendingPathComponent(String(format: "frame-%04d.png", index)))
            }
        }

        func close() { window.orderOut(nil) }
    }

    private static func ease(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

    private static func lerp(_ a: IRect, _ b: IRect, _ t: Double) -> IRect {
        func m(_ x: Int, _ y: Int) -> Int { Int((Double(x) + Double(y - x) * t).rounded()) }
        return IRect(x: m(a.x, b.x), y: m(a.y, b.y), width: m(a.width, b.width), height: m(a.height, b.height))
    }

    // MARK: Showcase (main window)

    private static let windowSize = NSSize(width: 1120, height: 720)

    private static func renderShowcase(_ model: AppModel, into dir: URL) {
        let w = FrameWriter(dir: dir, size: windowSize)
        let nav = Navigation.shared

        // 1. Displays: drag a display; it snaps flush and aligns.
        let editor = EditorModel()
        editor.load(device: nil, model: model)
        if let main = editor.items.first(where: { $0.id == editor.mainID }),
            let other = editor.items.first(where: { $0.id != editor.mainID })
        {
            let m = main.rect
            let o = other.rect
            let path = [
                o.rect(x: m.maxX + 40, y: m.y + 260),  // right of the main display
                o.rect(x: m.maxX + 120, y: m.maxY - 60),
                o.rect(x: m.midXInt + 300, y: m.maxY + 80),  // below it…
                o.rect(x: m.midXInt - o.width / 2 + 25, y: m.maxY + 30),  // …centred
            ]
            editor.selected = other.id
            editor.drag(other.id, to: path[0], threshold: 160)
            let scene = { DemoWindow(section: .displays) { DisplaysView.Demo(editor: editor) } }
            w.frame(scene(), hold: 12, settle: 0.4)
            for leg in 0..<(path.count - 1) {
                for f in 1...14 {
                    let p = lerp(path[leg], path[leg + 1], ease(Double(f) / 14))
                    editor.drag(other.id, to: p, threshold: 160)
                    w.frame(scene())
                }
            }
            w.frame(scene(), hold: 18, settle: 0.4)
        }

        // 2. Universal Control: both Macs, snapped together and applied live.
        let local = model.displays.map(\.frame)
        let remote = remoteDisplays.map(\.frame)
        if let lb = LayoutEngine.boundingBox(local), let rb = LayoutEngine.boundingBox(remote) {
            let end = IPoint(x: lb.minX - rb.width, y: lb.minY)
            let start = IPoint(x: end.x - 900, y: end.y - 700)
            let mid = IPoint(x: end.x - 200, y: end.y + 500)
            let all = local + remote.map { $0.offsetBy(dx: start.x, dy: start.y) }
                + remote.map { $0.offsetBy(dx: end.x, dy: end.y) } + remote.map { $0.offsetBy(dx: mid.x, dy: mid.y) }
            let t = CanvasTransform.fit(all, in: CGSize(width: 843, height: 400), fill: 0.82)
            func at(_ o: IPoint, snap: Bool) -> some View {
                let shown = snap ? LayoutEngine.snapGroup(remote, proposed: o, others: local, threshold: 220) : o
                return DemoWindow(section: .linked) {
                    // A fresh identity per frame: the view's state holds the offset.
                    LinkedMacsView(demoOffset: shown, demoTransform: t).id(UUID())
                }
            }
            w.frame(at(start, snap: false), hold: 8, settle: 0.4)
            for (a, b) in [(start, mid), (mid, end)] {
                for f in 1...16 {
                    let k = ease(Double(f) / 16)
                    let o = IPoint(x: a.x + Int(Double(b.x - a.x) * k), y: a.y + Int(Double(b.y - a.y) * k))
                    w.frame(at(o, snap: f > 4 || a.x == mid.x))
                }
            }
            w.frame(at(end, snap: true), hold: 20, settle: 0.3)
        }

        // 3. Workspaces: previews, then saving one and choosing its apps.
        nav.section = .windows
        w.frame(DemoWindow(section: .windows) { WindowsView() }, hold: 22, settle: 0.6)
        if let snapshot = model.windowLayouts.first(where: \.isAutosave) {
            let form = SaveWorkspaceModel(editing: snapshot, includeArrangement: true, suggestedName: "Deep Work")
            form.hotkey = HotkeySpec(keyCode: 2, modifiers: 0x0800 | 0x0100, display: "⌥⌘D")
            func sheet() -> some View {
                DemoWindow(section: .windows) {
                    WindowsView()
                }
                .overlay {
                    ZStack {
                        Color.black.opacity(0.45)
                        SaveWorkspaceView(form: form) {}
                            .background(Color(nsColor: .windowBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(radius: 30)
                            .scaleEffect(0.86)
                    }
                    .padding(16)
                }
            }
            w.frame(sheet(), hold: 16, settle: 0.6)
            for app in ["com.apple.Notes", "com.apple.Terminal"] {
                form.selectedApps.remove(app)
                w.frame(sheet(), hold: 10, settle: 0.3)
            }
            form.selectedApps.insert("com.apple.Terminal")
            w.frame(sheet(), hold: 12, settle: 0.3)
        }

        // 4. Window snapping: draw a custom size on the grid.
        var custom = SnapCommand(
            id: "demo-custom", name: "Centre Two Thirds",
            action: .region(GridRect(cols: 6, rows: 4, x: 1, y: 0, w: 1, h: 1)),
            hotkey: HotkeySpec(keyCode: 15, modifiers: 0x1000 | 0x0800, display: "⌃⌥R"))
        model.updateSnapCommand(custom)
        let steps = [(1, 1), (2, 2), (3, 3), (4, 4), (4, 4)]
        func snapping() -> some View {
            DemoWindow(section: .snapping) {
                SnappingView(selection: "demo-custom")
            }
        }
        w.frame(snapping(), hold: 8, settle: 0.6)
        for (cw, ch) in steps {
            custom.action = .region(GridRect(cols: 6, rows: 4, x: 1, y: 0, w: cw, h: ch))
            model.updateSnapCommand(custom)
            w.frame(snapping(), hold: 4, settle: 0.15)
        }
        w.frame(snapping(), hold: 18, settle: 0.2)
        model.deleteSnapCommand("demo-custom")
        w.close()
    }

    // MARK: Menu bar

    private static func renderMenuBar(_ model: AppModel, into dir: URL) {
        let w = FrameWriter(dir: dir, size: NSSize(width: 1080, height: 640))
        let commands = SnapDefaults.commands
        let script: [(String, String)] = [
            ("left", "⌃⌥←"), ("right", "⌃⌥→"), ("topLeft", "⌃⌥U"), ("bottomRight", "⌃⌥K"), ("maximize", "⌃⌥↩"),
            ("center", "⌃⌥C"), ("left", "⌃⌥←"),
        ]
        let area = IRect(x: 0, y: 0, width: 1000, height: 600)
        func frame(of id: String, current: IRect) -> IRect {
            guard let c = commands.first(where: { $0.id == id }) else { return current }
            if case .center = c.action {
                return IRect(x: 200, y: 100, width: 600, height: 400)
            }
            return c.region?.frame(in: area) ?? current
        }
        var rect = IRect(x: 220, y: 120, width: 560, height: 380)
        w.frame(MenuBarDemo(window: rect, keys: nil, label: nil), hold: 10, settle: 0.6)
        for (id, keys) in script {
            let target = frame(of: id, current: rect)
            let name = commands.first { $0.id == id }?.title
            for f in 1...6 {
                w.frame(MenuBarDemo(window: lerp(rect, target, ease(Double(f) / 6)), keys: keys, label: name))
            }
            rect = target
            w.frame(MenuBarDemo(window: rect, keys: keys, label: name), hold: 12)
        }
        w.close()
    }
}

private extension IRect {
    var midXInt: Int { x + width / 2 }
    func rect(x: Int, y: Int) -> IRect { IRect(x: x, y: y, width: width, height: height) }
}

/// The app window as it looks on screen (sidebar + content), on a backdrop,
/// with a slim margin and rounded corners, Recordly style.
private struct DemoWindow<Content: View>: View {
    let section: AppSection
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            WaveBackdrop()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { c in
                            Circle().fill(c.opacity(0.85)).frame(width: 11, height: 11)
                        }
                    }
                    .padding(.bottom, 14)
                    ForEach(AppSection.allCases) { s in
                        Label(s.title, systemImage: s.icon)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(s == section ? Color.white.opacity(0.12) : .clear))
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                        Text("Synced with Mac mini").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(width: 200)
                .background(Color(white: 0.13))
                Divider()
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .environmentObject(AppModel.shared)
        .environmentObject(Navigation.shared)
    }
}

/// The menu bar panel beside a mock screen where a window snaps around.
private struct MenuBarDemo: View {
    let window: IRect
    let keys: String?
    let label: String?

    var body: some View {
        ZStack {
            WaveBackdrop()
            HStack(alignment: .top, spacing: 28) {
                MenuPanel()
                    .environmentObject(AppModel.shared)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                VStack(spacing: 14) {
                    screen
                    HStack(spacing: 10) {
                        if let keys {
                            Text(keys)
                                .font(.system(size: 18, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.14)))
                        }
                        if let label { Text(label).font(.system(size: 15, weight: .medium)) }
                    }
                    .foregroundColor(.white)
                    .frame(height: 34)
                }
            }
            .padding(20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var screen: some View {
        let scale: CGFloat = 0.6
        return ZStack(alignment: .topLeading) {
            if let data = DemoRenderer.wallpaper(seed: 7), let image = NSImage(data: data) {
                Image(nsImage: image).resizable()
            }
            Rectangle().fill(Color.black.opacity(0.35)).frame(height: 12)
            mockWindow
                .frame(width: CGFloat(window.width) * scale - 6, height: CGFloat(window.height) * scale - 6)
                .offset(x: CGFloat(window.x) * scale + 3, y: 12 + CGFloat(window.y) * scale + 3)
        }
        .frame(width: 600, height: 372)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.25), lineWidth: 2))
    }

    private var mockWindow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in Circle().fill(c).frame(width: 7, height: 7) }
                Spacer()
                Image(nsImage: AppLook.icon("com.apple.Safari")).resizable().frame(width: 12, height: 12)
                Text("Safari").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.8))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color(white: 0.24))
            ZStack {
                Color(white: 0.12)
                Image(nsImage: AppLook.icon("com.apple.Safari")).resizable().frame(width: 44, height: 44).opacity(0.85)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.4), radius: 8)
    }
}

extension DisplaysView {
    /// The arrangement editor alone, driven by a scripted EditorModel.
    struct Demo: View {
        @ObservedObject var editor: EditorModel
        var body: some View {
            EditorPanel(editor: editor)
                .padding(18)
        }
    }
}

/// A macOS-style wallpaper drawn in code: deep blue with an orange and
/// peach wave sweeping across (the look of Recordly's backgrounds, no assets).
private struct WaveBackdrop: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.05, green: 0.12, blue: 0.38), Color(red: 0.12, green: 0.32, blue: 0.75)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                // Violet glow behind the waves.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.38, y: 0))
                    p.addCurve(
                        to: CGPoint(x: w * 0.5, y: h), control1: CGPoint(x: w * 0.68, y: h * 0.28),
                        control2: CGPoint(x: w * 0.2, y: h * 0.7))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w, y: 0))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [Color(red: 0.45, green: 0.3, blue: 0.85).opacity(0.75), Color(red: 0.2, green: 0.3, blue: 0.85).opacity(0.2)],
                    startPoint: .top, endPoint: .bottom))
                .blur(radius: 18)
                // Orange wave.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.5, y: 0))
                    p.addCurve(
                        to: CGPoint(x: w * 0.64, y: h), control1: CGPoint(x: w * 0.82, y: h * 0.3),
                        control2: CGPoint(x: w * 0.36, y: h * 0.68))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w, y: 0))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [Color(red: 0.98, green: 0.45, blue: 0.2), Color(red: 0.95, green: 0.3, blue: 0.35)],
                    startPoint: .topTrailing, endPoint: .bottomLeading))
                // Peach highlight inside it.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.66, y: 0))
                    p.addCurve(
                        to: CGPoint(x: w * 0.8, y: h), control1: CGPoint(x: w * 0.95, y: h * 0.32),
                        control2: CGPoint(x: w * 0.55, y: h * 0.66))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w, y: 0))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [Color(red: 1, green: 0.78, blue: 0.55), Color(red: 1, green: 0.58, blue: 0.4)],
                    startPoint: .top, endPoint: .bottom))
                .blur(radius: 2)
                // Soft sheen along the wave's edge.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.5, y: 0))
                    p.addCurve(
                        to: CGPoint(x: w * 0.64, y: h), control1: CGPoint(x: w * 0.82, y: h * 0.3),
                        control2: CGPoint(x: w * 0.36, y: h * 0.68))
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 3)
                .blur(radius: 4)
            }
        }
    }
}
