import AppKit
import CoreGraphics
import Foundation

// Private SkyLight (CoreGraphics Services) calls. Reading Space state works on
// every macOS version this targets. Writing it (CGSMoveWindowsToManagedSpace)
// stopped working for other apps' windows in macOS 14.5 — verified again on
// macOS 27 — so moving windows between Desktops uses the Mission Control
// keyboard shortcuts instead (see `SpaceService.carryWindow`).
private typealias CGSConnectionID = Int32
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray?
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ wids: CFArray) -> CFArray?
// WindowServer's live state of the system shortcuts ("symbolic hot keys").
// Writing com.apple.symbolichotkeys alone no longer activates them on macOS 27.
@_silgen_name("CGSIsSymbolicHotKeyEnabled") private func CGSIsSymbolicHotKeyEnabled(_ hk: Int32) -> Bool
@_silgen_name("CGSSetSymbolicHotKeyEnabled") private func CGSSetSymbolicHotKeyEnabled(_ hk: Int32, _ on: Bool) -> Int32
@_silgen_name("CGSGetSymbolicHotKeyValue")
private func CGSGetSymbolicHotKeyValue(
    _ hk: Int32, _ key: UnsafeMutablePointer<UInt16>, _ vk: UnsafeMutablePointer<UInt16>,
    _ mods: UnsafeMutablePointer<UInt32>) -> Int32
@_silgen_name("CGSSetSymbolicHotKeyValue")
private func CGSSetSymbolicHotKeyValue(_ hk: Int32, _ key: UInt16, _ vk: UInt16, _ mods: UInt32) -> Int32

/// One Space (Desktop or full-screen app) on a display.
struct SpaceInfo: Hashable {
    let id: UInt64
    /// 0 = regular Desktop, 4 = full-screen app.
    let type: Int
    var isDesktop: Bool { type == 0 }
}

/// Spaces of one display, in Mission Control order.
struct DisplaySpaces {
    /// CoreGraphics display UUID, or "Main" when "Displays have separate
    /// Spaces" is off and all displays share one set.
    let displayIdentifier: String
    let current: UInt64
    let spaces: [SpaceInfo]

    var desktops: [SpaceInfo] { spaces.filter(\.isDesktop) }
}

struct SpacesSnapshot {
    let displays: [DisplaySpaces]

    var separateSpaces: Bool { !displays.contains { $0.displayIdentifier == "Main" } }

    func display(containing space: UInt64) -> DisplaySpaces? {
        displays.first { $0.spaces.contains { $0.id == space } }
    }

    /// 1-based Desktop number on its own display.
    func desktopIndex(of space: UInt64) -> Int? {
        guard let d = display(containing: space), let i = d.desktops.firstIndex(where: { $0.id == space }) else {
            return nil
        }
        return i + 1
    }

    /// 1-based position among all of its display's Spaces (Desktops and full-screen apps).
    func position(of space: UInt64) -> Int? {
        guard let d = display(containing: space), let i = d.spaces.firstIndex(where: { $0.id == space }) else {
            return nil
        }
        return i + 1
    }

    func isFullscreenSpace(_ space: UInt64) -> Bool {
        displays.lazy.flatMap(\.spaces).first { $0.id == space }?.type == 4
    }

    /// Mission Control's global Desktop number (what ⌃1…⌃9 switch to):
    /// Desktops are numbered across all displays in order.
    func globalDesktopNumber(of space: UInt64) -> Int? {
        var n = 0
        for d in displays {
            for s in d.desktops {
                n += 1
                if s.id == space { return n }
            }
        }
        return nil
    }

    var currentSpaces: Set<UInt64> { Set(displays.map(\.current)) }

    /// Spaces of the display with this CoreGraphics UUID (or the shared set
    /// when "Displays have separate Spaces" is off).
    func spaces(forDisplayUUID uuid: String?) -> DisplaySpaces? {
        separateSpaces ? displays.first { $0.displayIdentifier == uuid } : displays.first
    }
}

enum SpaceService {
    private static let cid = CGSMainConnectionID()

    static func snapshot() -> SpacesSnapshot {
        let raw = (CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]]) ?? []
        return SpacesSnapshot(
            displays: raw.map { d in
                let current = ((d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0
                let spaces = ((d["Spaces"] as? [[String: Any]]) ?? []).map { s in
                    SpaceInfo(
                        id: (s["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0,
                        type: (s["type"] as? NSNumber)?.intValue ?? 0)
                }
                return DisplaySpaces(
                    displayIdentifier: d["Display Identifier"] as? String ?? "Main", current: current, spaces: spaces)
            })
    }

    static func spaces(forWindow wid: CGWindowID) -> [UInt64] {
        let arr = [NSNumber(value: wid)] as CFArray
        return ((CGSCopySpacesForWindows(cid, 0x7, arr) as? [NSNumber]) ?? []).map(\.uint64Value)
    }

    // MARK: - Mission Control shortcuts

    /// Symbolic hotkey ids for "Switch to Desktop 1…16".
    private static func hotkeyID(desktop n: Int) -> Int { 117 + n }
    private static let defaultKeyCodes: [Int] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]  // 1…9, 0

    struct Shortcut {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    /// The live, enabled shortcut for "Switch to Desktop n" (as WindowServer
    /// has it, which is what actually responds to the keys).
    static func desktopShortcut(_ n: Int) -> Shortcut? {
        let hk = Int32(hotkeyID(desktop: n))
        guard CGSIsSymbolicHotKeyEnabled(hk) else { return nil }
        var key: UInt16 = 0
        var vk: UInt16 = 0
        var mods: UInt32 = 0
        guard CGSGetSymbolicHotKeyValue(hk, &key, &vk, &mods) == 0, vk != 0xFFFF else { return nil }
        return Shortcut(keyCode: CGKeyCode(vk), flags: CGEventFlags(rawValue: UInt64(mods)))
    }

    /// How many leading Desktops have a working shortcut.
    static func availableDesktopShortcuts() -> Int {
        var n = 0
        while n < 16, desktopShortcut(n + 1) != nil { n += 1 }
        return n
    }

    /// Turn on ⌃1…⌃9 and ⌃0 for "Switch to Desktop 1…10" (System Settings ›
    /// Keyboard › Shortcuts › Mission Control): live in WindowServer right
    /// away, and in the preferences so they survive logging out.
    static func enableDesktopShortcuts() throws {
        for n in 1...defaultKeyCodes.count where desktopShortcut(n) == nil {
            let hk = Int32(hotkeyID(desktop: n))
            let ascii = n == 10 ? 48 : 48 + n
            // Keep a key the user already chose; otherwise ⌃<digit>.
            var key: UInt16 = 0
            var vk: UInt16 = 0
            var mods: UInt32 = 0
            if CGSGetSymbolicHotKeyValue(hk, &key, &vk, &mods) != 0 || vk == 0xFFFF || vk == 0 {
                vk = UInt16(defaultKeyCodes[n - 1])
                mods = 0x40000  // control
                _ = CGSSetSymbolicHotKeyValue(hk, 0xFFFF, vk, mods)
            }
            _ = CGSSetSymbolicHotKeyEnabled(hk, true)
            let dict = "{enabled = 1; value = { parameters = (\(ascii), \(vk), \(mods)); type = standard; }; }"
            try run(
                "/usr/bin/defaults",
                ["write", "com.apple.symbolichotkeys", "AppleSymbolicHotKeys", "-dict-add", String(hk), dict])
        }
    }

    private static func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
    }

    // MARK: - Moving between Desktops

    /// Time for the Space-switch animation to finish.
    static var switchDelay: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.35 : 0.75
    }

    static func switchToDesktop(_ number: Int) -> Bool {
        guard let s = desktopShortcut(number) else { return false }
        postKey(s)
        return true
    }

    /// Carry a window to Desktop `number` the way a person would: hold its
    /// title bar and press the "Switch to Desktop" shortcut. The window must
    /// be visible on the current Desktop of its display. Blocks; call off main.
    static func carryWindow(titleBarPoint p: CGPoint, toDesktop number: Int) -> Bool {
        guard let shortcut = desktopShortcut(number) else { return false }
        let original = CGEvent(source: nil)?.location ?? p
        func mouse(_ type: CGEventType, _ at: CGPoint) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
            e?.flags = []
            e?.post(tap: .cghidEventTap)
        }
        mouse(.mouseMoved, p)
        mouse(.leftMouseDown, p)
        Thread.sleep(forTimeInterval: 0.05)
        mouse(.leftMouseDragged, CGPoint(x: p.x + 1, y: p.y))
        Thread.sleep(forTimeInterval: 0.05)
        postKey(shortcut)
        Thread.sleep(forTimeInterval: switchDelay)
        mouse(.leftMouseUp, CGPoint(x: p.x + 1, y: p.y))
        Thread.sleep(forTimeInterval: 0.1)
        mouse(.mouseMoved, original)
        return true
    }

    private static func postKey(_ s: Shortcut) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: s.keyCode, keyDown: down)
            e?.flags = s.flags
            e?.post(tap: .cghidEventTap)
        }
    }
}
