import Foundation

/// A rectangle on a grid laid over a display's usable area, in cells.
/// "Left half" on a 2×1 grid is (0,0,1,1); any custom size/position is just
/// a different selection, like Magnet's editor.
public struct GridRect: Codable, Hashable, Sendable {
    public var cols: Int
    public var rows: Int
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int

    public init(cols: Int, rows: Int, x: Int, y: Int, w: Int, h: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// The frame inside `area` (points), edges rounded to whole points so
    /// neighbouring regions tile without gaps.
    public func frame(in area: IRect) -> IRect {
        func edge(_ i: Int, _ n: Int, _ origin: Int, _ size: Int) -> Int {
            origin + Int((Double(size) * Double(i) / Double(n)).rounded())
        }
        let x0 = edge(x, cols, area.x, area.width)
        let x1 = edge(x + w, cols, area.x, area.width)
        let y0 = edge(y, rows, area.y, area.height)
        let y1 = edge(y + h, rows, area.y, area.height)
        return IRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// "½ × 1" style label of the selection's size.
    public var sizeLabel: String {
        func frac(_ a: Int, _ b: Int) -> String {
            let g = gcd(a, b)
            let (n, d) = (a / g, b / g)
            return d == 1 ? "\(n)" : "\(n)/\(d)"
        }
        return "\(frac(w, cols)) × \(frac(h, rows))"
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(a, 1) : gcd(b, a % b) }
}

/// One window-snapping command (Magnet-style).
public struct SnapCommand: Codable, Hashable, Sendable, Identifiable {
    public enum Action: Codable, Hashable, Sendable {
        /// Fill a grid region of the window's display.
        case region(GridRect)
        case nextDisplay
        case previousDisplay
        /// Same size, centred on its display.
        case center
        /// Back to where it was before the last snap.
        case restore
    }

    public var id: String
    public var name: String
    public var action: Action
    public var hotkey: HotkeySpec?
    public var hotkeyEnabled: Bool
    public var showInMenu: Bool
    /// Built-in commands can be turned off but not deleted.
    public var builtIn: Bool

    public init(
        id: String = UUID().uuidString, name: String, action: Action, hotkey: HotkeySpec? = nil,
        hotkeyEnabled: Bool = true, showInMenu: Bool = true, builtIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.action = action
        self.hotkey = hotkey
        self.hotkeyEnabled = hotkeyEnabled
        self.showInMenu = showInMenu
        self.builtIn = builtIn
    }

    public var region: GridRect? {
        if case .region(let r) = action { return r }
        return nil
    }
}

public enum SnapDefaults {
    // Carbon key codes and modifier masks (kept numeric so the core module
    // stays free of Carbon).
    static let ctrlOpt: UInt32 = 0x1000 | 0x0800
    static let ctrlOptCmd: UInt32 = 0x1000 | 0x0800 | 0x0100

    private static func key(_ code: UInt32, _ mods: UInt32, _ display: String) -> HotkeySpec {
        HotkeySpec(keyCode: code, modifiers: mods, display: display)
    }

    private static func region(_ id: String, _ name: String, _ r: GridRect, _ k: HotkeySpec) -> SnapCommand {
        SnapCommand(id: id, name: name, action: .region(r), hotkey: k, builtIn: true)
    }

    /// Magnet's halves and quarters, with Magnet's shortcuts. No thirds:
    /// those (and any other size) are custom commands.
    public static var commands: [SnapCommand] {
        [
            region("left", "Left", GridRect(cols: 2, rows: 1, x: 0, y: 0, w: 1, h: 1), key(123, ctrlOpt, "⌃⌥←")),
            region("right", "Right", GridRect(cols: 2, rows: 1, x: 1, y: 0, w: 1, h: 1), key(124, ctrlOpt, "⌃⌥→")),
            region("top", "Top", GridRect(cols: 1, rows: 2, x: 0, y: 0, w: 1, h: 1), key(126, ctrlOpt, "⌃⌥↑")),
            region("bottom", "Bottom", GridRect(cols: 1, rows: 2, x: 0, y: 1, w: 1, h: 1), key(125, ctrlOpt, "⌃⌥↓")),
            region("topLeft", "Top Left", GridRect(cols: 2, rows: 2, x: 0, y: 0, w: 1, h: 1), key(32, ctrlOpt, "⌃⌥U")),
            region("topRight", "Top Right", GridRect(cols: 2, rows: 2, x: 1, y: 0, w: 1, h: 1), key(34, ctrlOpt, "⌃⌥I")),
            region("bottomLeft", "Bottom Left", GridRect(cols: 2, rows: 2, x: 0, y: 1, w: 1, h: 1), key(38, ctrlOpt, "⌃⌥J")),
            region(
                "bottomRight", "Bottom Right", GridRect(cols: 2, rows: 2, x: 1, y: 1, w: 1, h: 1), key(40, ctrlOpt, "⌃⌥K")),
            SnapCommand(
                id: "nextDisplay", name: "Next Display", action: .nextDisplay, hotkey: key(124, ctrlOptCmd, "⌃⌥⌘→"),
                builtIn: true),
            SnapCommand(
                id: "previousDisplay", name: "Previous Display", action: .previousDisplay,
                hotkey: key(123, ctrlOptCmd, "⌃⌥⌘←"), builtIn: true),
            region("maximize", "Maximize", GridRect(cols: 1, rows: 1, x: 0, y: 0, w: 1, h: 1), key(36, ctrlOpt, "⌃⌥↩")),
            SnapCommand(id: "center", name: "Center", action: .center, hotkey: key(8, ctrlOpt, "⌃⌥C"), builtIn: true),
            SnapCommand(id: "restore", name: "Restore", action: .restore, hotkey: key(51, ctrlOpt, "⌃⌥⌫"), builtIn: true),
        ]
    }
}

public enum SnapGeometry {
    /// Where a snap command puts a window. `area` is the usable area (menu
    /// bar and Dock excluded) of the window's display; `areas` all displays'
    /// usable areas in order, for next/previous display.
    public static func target(
        for action: SnapCommand.Action, window: IRect, area: IRect, areas: [IRect], previous: IRect?
    ) -> IRect? {
        switch action {
        case .region(let r):
            return r.frame(in: area)
        case .center:
            let w = min(window.width, area.width)
            let h = min(window.height, area.height)
            return IRect(x: area.x + (area.width - w) / 2, y: area.y + (area.height - h) / 2, width: w, height: h)
        case .restore:
            return previous
        case .nextDisplay, .previousDisplay:
            guard areas.count > 1, let i = areas.firstIndex(of: area) else { return nil }
            let step = action == .nextDisplay ? 1 : areas.count - 1
            return carry(window, from: area, to: areas[(i + step) % areas.count])
        }
    }

    /// Same relative position and size on another display.
    public static func carry(_ w: IRect, from a: IRect, to b: IRect) -> IRect {
        let fx = Double(w.x - a.x) / Double(a.width)
        let fy = Double(w.y - a.y) / Double(a.height)
        let fw = Double(w.width) / Double(a.width)
        let fh = Double(w.height) / Double(a.height)
        let width = min(b.width, Int((fw * Double(b.width)).rounded()))
        let height = min(b.height, Int((fh * Double(b.height)).rounded()))
        let x = min(max(b.x + Int((fx * Double(b.width)).rounded()), b.x), b.maxX - width)
        let y = min(max(b.y + Int((fy * Double(b.height)).rounded()), b.y), b.maxY - height)
        return IRect(x: x, y: y, width: width, height: height)
    }

    /// Drag-to-edge snapping (Magnet's activation areas): which built-in
    /// command a pointer at `p` near the edges of `screen` (full frame) asks for.
    public static func dragZone(x: Double, y: Double, screen s: IRect, margin: Double = 6, corner: Double = 40)
        -> String?
    {
        let left = x - Double(s.minX) < margin
        let right = Double(s.maxX) - x < margin
        let top = y - Double(s.minY) < margin
        let bottom = Double(s.maxY) - y < margin
        let nearLeft = x - Double(s.minX) < corner
        let nearRight = Double(s.maxX) - x < corner
        let nearTop = y - Double(s.minY) < corner
        let nearBottom = Double(s.maxY) - y < corner
        if (left && nearTop) || (top && nearLeft) { return "topLeft" }
        if (right && nearTop) || (top && nearRight) { return "topRight" }
        if (left && nearBottom) || (bottom && nearLeft) { return "bottomLeft" }
        if (right && nearBottom) || (bottom && nearRight) { return "bottomRight" }
        if left { return "left" }
        if right { return "right" }
        if top { return "maximize" }
        if bottom { return "bottom" }
        return nil
    }
}
