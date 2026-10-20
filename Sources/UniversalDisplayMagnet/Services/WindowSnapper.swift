import AppKit
import ApplicationServices
import UniversalDisplayMagnetCore

/// Magnet-style window snapping: commands move the front window into a
/// region of its display (or onto the next display), and dragging a window
/// against a screen edge or corner snaps it there on release, with a preview.
@MainActor
final class WindowSnapper {
    static let shared = WindowSnapper()

    /// Frame before the last snap, per window, for "Restore".
    private var previous: [CGWindowID: IRect] = [:]
    /// The last app that wasn't Universal Display Magnet: menu clicks act on its window.
    private var lastApp: NSRunningApplication?
    private var monitors: [Any] = []
    private var drag: DragState?
    private let overlay = SnapOverlay()

    /// Commands looked up by id for drag-to-edge zones.
    var commands: () -> [SnapCommand] = { SnapDefaults.commands }

    private struct DragState {
        let element: AXUIElement
        let startFrame: IRect
        var moving = false
        var checks = 0
        var zone: String?
    }

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            MainActor.assumeIsolated { WindowSnapper.shared.lastApp = app }
        }
        lastApp = NSWorkspace.shared.frontmostApplication
    }

    // MARK: - Commands

    func run(_ command: SnapCommand) {
        guard let window = focusedWindow(), let frame = WindowService.frame(of: window) else { return }
        let areas = Self.usableAreas()
        guard let area = Self.area(containing: frame, in: areas) else { return }
        let wid = WindowService.windowNumber(window)
        guard
            let target = SnapGeometry.target(
                for: command.action, window: frame, area: area, areas: areas, previous: wid.flatMap { previous[$0] })
        else { return }
        if let wid {
            if case .restore = command.action { previous[wid] = nil } else { previous[wid] = frame }
        }
        WindowService.setFrame(window, target, pid: pid(of: window))
    }

    private func focusedWindow() -> AXUIElement? {
        let front = NSWorkspace.shared.frontmostApplication
        let app =
            front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastApp : front
        guard let pid = app?.processIdentifier else { return nil }
        let el = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &value) == .success,
            let v = value, CFGetTypeID(v) == AXUIElementGetTypeID()
        else { return nil }
        return (v as! AXUIElement)
    }

    private func pid(of el: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return pid
    }

    // MARK: - Screens (top-left global coordinates, like CoreGraphics)

    /// Usable area (no menu bar / Dock) of every screen, left to right.
    static func usableAreas() -> [IRect] {
        screens(\.visibleFrame)
    }

    static func fullFrames() -> [IRect] {
        screens(\.frame)
    }

    private static func screens(_ key: KeyPath<NSScreen, NSRect>) -> [IRect] {
        guard let primary = NSScreen.screens.first?.frame.height else { return [] }
        return NSScreen.screens.map { s in
            let f = s[keyPath: key]
            return IRect(
                x: Int(f.origin.x.rounded()), y: Int((primary - f.origin.y - f.height).rounded()),
                width: Int(f.width.rounded()), height: Int(f.height.rounded()))
        }
        .sorted { ($0.x, $0.y) < ($1.x, $1.y) }
    }

    /// The area under the window's centre, else the one it overlaps most.
    static func area(containing w: IRect, in areas: [IRect]) -> IRect? {
        areas.first { $0.contains(x: w.midX, y: w.midY) }
            ?? areas.max { $0.intersectionArea(w) < $1.intersectionArea(w) }
    }

    // MARK: - Drag to edges

    func setDragSnapping(_ on: Bool) {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        drag = nil
        overlay.hide()
        guard on else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp], handler: {
            event in
            let type = event.type
            MainActor.assumeIsolated { WindowSnapper.shared.handle(type) }
        }) {
            monitors.append(m)
        }
    }

    /// Pointer position in top-left global coordinates.
    private static var pointer: (x: Double, y: Double) {
        let p = NSEvent.mouseLocation
        let primary = NSScreen.screens.first?.frame.height ?? 0
        return (Double(p.x), Double(primary - p.y))
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            drag = nil
            let p = Self.pointer
            // The window under the pointer, if the press is on one.
            var hit: AXUIElement?
            guard
                AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) == .success,
                let hit, let window = Self.window(of: hit), let frame = WindowService.frame(of: window)
            else { return }
            drag = DragState(element: window, startFrame: frame)
        case .leftMouseDragged:
            guard var d = drag else { return }
            if !d.moving {
                // Only a moving window counts (not a resize or text selection).
                d.checks += 1
                if d.checks % 3 == 0, let now = WindowService.frame(of: d.element) {
                    if now.width == d.startFrame.width && now.height == d.startFrame.height
                        && (now.x != d.startFrame.x || now.y != d.startFrame.y)
                    {
                        d.moving = true
                    } else if now != d.startFrame {
                        drag = nil  // resizing
                        return
                    }
                }
                drag = d
                if !d.moving { return }
            }
            let p = Self.pointer
            guard let screen = Self.fullFrames().first(where: { $0.contains(x: p.x, y: p.y) }) else { return }
            let zone = SnapGeometry.dragZone(x: p.x, y: p.y, screen: screen)
            d.zone = zone
            drag = d
            if let zone, let target = target(zone: zone, screen: screen) {
                overlay.show(target)
            } else {
                overlay.hide()
            }
        case .leftMouseUp:
            defer {
                drag = nil
                overlay.hide()
            }
            guard let d = drag, d.moving, let zone = d.zone else { return }
            let p = Self.pointer
            guard let screen = Self.fullFrames().first(where: { $0.contains(x: p.x, y: p.y) }),
                let target = target(zone: zone, screen: screen)
            else { return }
            if let wid = WindowService.windowNumber(d.element) { previous[wid] = d.startFrame }
            // Let the window server finish the drag before moving the window.
            let element = d.element
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                WindowService.setFrame(element, target, pid: self.pid(of: element))
            }
        default:
            break
        }
    }

    private func target(zone: String, screen: IRect) -> IRect? {
        guard let command = commands().first(where: { $0.id == zone }), let region = command.region,
            let area = Self.usableAreas().first(where: { $0.intersectionArea(screen) > 0 })
        else { return nil }
        return region.frame(in: area)
    }

    private static func window(of el: AXUIElement) -> AXUIElement? {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        if (role as? String) == kAXWindowRole { return el }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &value) == .success, let v = value,
            CFGetTypeID(v) == AXUIElementGetTypeID()
        else { return nil }
        return (v as! AXUIElement)
    }
}

/// The translucent preview of where a dragged window will land.
@MainActor
final class SnapOverlay {
    private var window: NSWindow?

    func show(_ rect: IRect) {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(
            x: CGFloat(rect.x), y: primary - CGFloat(rect.y) - CGFloat(rect.height), width: CGFloat(rect.width),
            height: CGFloat(rect.height)
        ).insetBy(dx: 4, dy: 4)
        if window == nil {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .floating
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .transient]
            let view = NSView()
            view.wantsLayer = true
            view.layer?.cornerRadius = 12
            view.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
            view.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
            view.layer?.borderWidth = 2
            w.contentView = view
            window = w
        }
        guard let window else { return }
        if window.frame != frame {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                window.animator().setFrame(frame, display: true)
            }
        }
        window.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }
}
