import AppKit
import ApplicationServices
import UniversalDisplayMagnetCore

// Private but long-stable Accessibility helpers (used by Rectangle, AltTab,
// Amethyst, Hammerspoon…).
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// A window of a running app, reachable through Accessibility.
struct LiveWindow {
    let element: AXUIElement
    let pid: pid_t
    let bundleID: String
    let appName: String
    let windowNumber: CGWindowID?
    let title: String
    let frame: IRect
    let isMinimized: Bool
    let isFullscreen: Bool
    let spaces: [UInt64]
}

struct RestoreReport {
    var moved = 0
    var alreadyInPlace = 0
    var desktopMoves = 0
    var missingApps: Set<String> = []
    var unmatched = 0
    var desktopFailures = 0
    var notes: [String] = []

    var summary: String {
        var parts = ["Restored \(moved) window\(moved == 1 ? "" : "s")"]
        if alreadyInPlace > 0 { parts.append("\(alreadyInPlace) already in place") }
        if desktopMoves > 0 { parts.append("\(desktopMoves) moved to their Desktop") }
        if unmatched > 0 { parts.append("\(unmatched) not open") }
        if desktopFailures > 0 { parts.append("\(desktopFailures) couldn't change Desktop") }
        return parts.joined(separator: " · ")
    }
}

struct RestoreOptions {
    var moveBetweenDesktops = true
    var launchMissingApps = false
}

enum WindowService {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: - Enumeration

    /// Windows of all regular apps. With `allDesktops`, also windows parked on
    /// other Desktops, which Accessibility normally hides (AltTab's
    /// remote-token technique).
    static func liveWindows(allDesktops: Bool) -> [LiveWindow] {
        let me = ProcessInfo.processInfo.processIdentifier
        var result: [LiveWindow] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me && !app.isTerminated {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.5)
            var elements: [AXUIElement] = attribute(appElement, kAXWindowsAttribute) ?? []
            if allDesktops {
                let known = Set(elements.compactMap(windowNumber))
                elements += hiddenWindows(pid: app.processIdentifier).filter {
                    windowNumber($0).map { !known.contains($0) } ?? false
                }
            }
            for element in elements {
                guard let w = describe(element, app: app) else { continue }
                result.append(w)
            }
        }
        return result
    }

    private static func describe(_ element: AXUIElement, app: NSRunningApplication) -> LiveWindow? {
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        guard subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole else { return nil }
        guard let origin = point(element), let size = size(element), size.width > 1, size.height > 1 else {
            return nil
        }
        let wid = windowNumber(element)
        return LiveWindow(
            element: element, pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? app.localizedName ?? "?",
            appName: app.localizedName ?? "?", windowNumber: wid, title: attribute(element, kAXTitleAttribute) ?? "",
            frame: IRect(CGRect(origin: origin, size: size)),
            isMinimized: attribute(element, kAXMinimizedAttribute) ?? false,
            isFullscreen: attribute(element, "AXFullScreen") ?? false,
            spaces: wid.map(SpaceService.spaces(forWindow:)) ?? [])
    }

    private static func hiddenWindows(pid: pid_t) -> [AXUIElement] {
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        var found: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(0.1)
        for elementID: UInt64 in 0..<1000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            if let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() {
                let subrole: String? = attribute(el, kAXSubroleAttribute)
                if subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole { found.append(el) }
            }
            if Date() > deadline { break }
        }
        return found
    }

    /// Diagnostics: per app, windows found by Accessibility (current Spaces),
    /// by the remote-token probe (with timing), and on Spaces per the window server.
    static func diagnosticReport() -> String {
        var lines = ["trusted: \(AXIsProcessTrusted())"]
        let spaces = SpaceService.snapshot()
        let cg = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            let el = AXUIElementCreateApplication(pid)
            let visible: [AXUIElement] = attribute(el, kAXWindowsAttribute) ?? []
            let t0 = Date()
            var probed = 0
            var maxID: UInt64 = 0
            var token = Data(count: 20)
            token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
            token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
            var found: [CGWindowID] = []
            for id: UInt64 in 0..<5000 {
                token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
                if let e = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() {
                    let sub: String? = attribute(e, kAXSubroleAttribute)
                    if sub == kAXStandardWindowSubrole || sub == kAXDialogSubrole, let w = windowNumber(e) {
                        found.append(w)
                        maxID = id
                    }
                }
                probed += 1
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let onSpaces = cg.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
                .compactMap { w -> String? in
                    guard let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
                    let sp = SpaceService.spaces(forWindow: n)
                    guard !sp.isEmpty else { return nil }
                    return "\(n)@\(sp.map { spaces.position(of: $0).map(String.init) ?? "?" }.joined(separator: "+"))"
                }
            lines.append(
                "\(app.localizedName ?? "?"): ax=\(visible.compactMap(windowNumber)) probe=\(found) (maxElementID \(maxID), \(ms) ms for 5000) spaces=\(onSpaces)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Capture

    /// Snapshot every window relative to the display (and Desktop) it's on.
    /// A window as the window server reports it (every Space, no Accessibility).
    struct ServerWindow {
        let number: CGWindowID
        let pid: pid_t
        let frame: IRect
        let spaces: [UInt64]
        let onscreen: Bool
    }

    /// App windows the window server places on a Space, minus invisible
    /// strips and windows that aren't actually drawn on a Desktop you can see
    /// (apps keep closed windows around that way).
    static func serverWindows(pids: Set<pid_t>, visibleSpaces: Set<UInt64>) -> [ServerWindow] {
        let list = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
                let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.01,
                let b = info[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: b as CFDictionary), rect.width >= 160, rect.height >= 120
            else { return nil }
            let spaces = SpaceService.spaces(forWindow: number)
            let onscreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
            guard !spaces.isEmpty else { return nil }
            if spaces.contains(where: visibleSpaces.contains) && !onscreen { return nil }
            return ServerWindow(number: number, pid: pid, frame: IRect(rect), spaces: spaces, onscreen: onscreen)
        }
    }

    /// Where every app window is, from the window server alone (cheap, no
    /// Accessibility): changes whenever a capture's placements could, except
    /// titles and minimized windows, which only Accessibility sees.
    static func serverSignature() -> String {
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
                .map(\.processIdentifier))
        let spaces = SpaceService.snapshot()
        let desktops = spaces.displays.map { "\($0.displayIdentifier) \($0.spaces.map(\.id))" }
        let windows = serverWindows(pids: pids, visibleSpaces: spaces.currentSpaces)
            .map { "\($0.pid) \($0.number) \($0.frame) \($0.spaces)" }.sorted()
        return (desktops + windows).joined(separator: "\n")
    }

    /// Snapshot every window relative to the display and Space it's on.
    /// Positions and Spaces come from the window server (Accessibility can't
    /// see most windows on other Desktops); Accessibility adds titles and
    /// minimized/full-screen state where it can. Never switches Desktops.
    static func capture(displays: [LiveDisplay], allDesktops: Bool) -> [WindowSnapshot] {
        let spaces = SpaceService.snapshot()
        // Front-to-back order of on-screen windows, for drawing previews.
        let order = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]) ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = Dictionary(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
                .map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        let ax = Dictionary(
            liveWindows(allDesktops: allDesktops).compactMap { w in w.windowNumber.map { ($0, w) } },
            uniquingKeysWith: { a, _ in a })

        func snapshot(
            app: NSRunningApplication, number: CGWindowID, frame: IRect, windowSpaces: [UInt64], title: String,
            minimized: Bool, axFullscreen: Bool
        ) -> WindowSnapshot? {
            guard let display = display(frame: frame, spaces: windowSpaces, displays: displays, snapshot: spaces) else {
                return nil
            }
            let onlySpace = windowSpaces.count == 1 ? windowSpaces[0] : nil
            let fullscreen = axFullscreen || (onlySpace.map(spaces.isFullscreenSpace) ?? false)
            return WindowSnapshot(
                bundleID: app.bundleIdentifier ?? app.localizedName ?? "?", appName: app.localizedName ?? "?",
                title: title, windowNumber: number, displayKey: display.identity.hardwareKey,
                displayOrdinal: display.ordinal, frame: frame.offsetBy(dx: -display.frame.x, dy: -display.frame.y),
                spaceIndex: fullscreen ? nil : onlySpace.flatMap(spaces.desktopIndex(of:)), isFullscreen: fullscreen,
                isMinimized: minimized, z: rank[number], spacePosition: onlySpace.flatMap(spaces.position(of:)),
                onVisibleSpace: windowSpaces.contains(where: spaces.currentSpaces.contains),
                onAllDesktops: windowSpaces.count > 1)
        }

        var result: [WindowSnapshot] = []
        var taken = Set<CGWindowID>()
        var seen = Set<String>()
        for w in serverWindows(pids: Set(apps.keys), visibleSpaces: spaces.currentSpaces) {
            guard let app = apps[w.pid] else { continue }
            let a = ax[w.number]
            // Identical stacked copies (helper windows) count once.
            let key = "\(w.pid)|\(w.frame)|\(w.spaces)"
            guard a != nil || seen.insert(key).inserted else { continue }
            guard
                let s = snapshot(
                    app: app, number: w.number, frame: w.frame, windowSpaces: w.spaces, title: a?.title ?? "",
                    minimized: a?.isMinimized ?? false, axFullscreen: a?.isFullscreen ?? false)
            else { continue }
            result.append(s)
            taken.insert(w.number)
        }
        // Minimized windows sit on no Space; Accessibility still reports them.
        for (number, w) in ax where !taken.contains(number) && w.isMinimized {
            guard let app = apps[w.pid],
                let s = snapshot(
                    app: app, number: number, frame: w.frame, windowSpaces: w.spaces, title: w.title, minimized: true,
                    axFullscreen: false)
            else { continue }
            result.append(s)
        }
        return result
    }

    /// The display a window belongs to: by its Space when Spaces are per
    /// display, otherwise by geometry.
    static func display(for w: LiveWindow, displays: [LiveDisplay], spaces: SpacesSnapshot) -> LiveDisplay? {
        display(frame: w.frame, spaces: w.spaces, displays: displays, snapshot: spaces)
    }

    static func display(frame: IRect, spaces windowSpaces: [UInt64], displays: [LiveDisplay], snapshot spaces: SpacesSnapshot)
        -> LiveDisplay?
    {
        if spaces.separateSpaces, let space = windowSpaces.first, let ds = spaces.display(containing: space),
            let d = displays.first(where: { $0.identity.uuid == ds.displayIdentifier })
        {
            return d
        }
        if let best = displays.max(by: { $0.frame.intersectionArea(frame) < $1.frame.intersectionArea(frame) }),
            best.frame.intersectionArea(frame) > 0
        {
            return best
        }
        let cx = frame.midX
        let cy = frame.midY
        return displays.min {
            hypot($0.frame.midX - cx, $0.frame.midY - cy) < hypot($1.frame.midX - cx, $1.frame.midY - cy)
        }
    }

    // MARK: - Restore

    /// Put every window of `layout` back. Blocking (windows are moved one by
    /// one with short waits); call from a background queue.
    static func restore(
        _ layout: WindowLayout, displays: [LiveDisplay], options: RestoreOptions, progress: (String) -> Void
    ) -> RestoreReport {
        var report = RestoreReport()

        if options.launchMissingApps {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            let missing = Set(layout.windows.map(\.bundleID)).subtracting(running)
            var launched: [String] = []
            for id in missing {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
                progress("Opening \(url.deletingPathExtension().lastPathComponent)…")
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                NSWorkspace.shared.openApplication(at: url, configuration: config)
                launched.append(id)
            }
            // Wait (up to 15 s) until every opened app has finished launching
            // and shows at least one window, then give windows a moment to settle.
            let deadline = Date().addingTimeInterval(15)
            while !launched.isEmpty && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                launched.removeAll { id in
                    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
                        app.isFinishedLaunching
                    else { return false }
                    let el = AXUIElementCreateApplication(app.processIdentifier)
                    let windows: [AXUIElement]? = attribute(el, kAXWindowsAttribute)
                    return !(windows ?? []).isEmpty
                }
            }
            if !missing.isEmpty { Thread.sleep(forTimeInterval: 1.5) }
        }

        progress("Finding windows…")
        let startSpaces = SpaceService.snapshot()

        // Windows already exactly where the layout has them are left alone.
        let pending = windowsToRestore(layout, displays: displays, spaces: startSpaces)
        report.alreadyInPlace = layout.windows.count - pending.count
        guard !pending.isEmpty else { return report }

        // Candidates: windows on a Space (or minimized). Apps keep hidden
        // helper windows that must never stand in for a real one.
        var live = liveWindows(allDesktops: true).filter { !$0.spaces.isEmpty || $0.isMinimized }
        if options.moveBetweenDesktops {
            live += collectFromOtherDesktops(for: pending, known: live, start: startSpaces, progress: progress)
        }
        let candidates = live.enumerated().map {
            WindowCandidate(key: $0.offset, bundleID: $0.element.bundleID, title: $0.element.title, windowNumber: $0.element.windowNumber)
        }
        let matches = WindowMatcher.assign(saved: pending, candidates: candidates)
        report.unmatched = pending.count - matches.count
        let running = Set(live.map(\.bundleID))
        report.missingApps = Set(layout.windows.map(\.bundleID)).subtracting(running)

        var desktopMoves: [(saved: WindowSnapshot, window: LiveWindow, target: IRect, display: LiveDisplay)] = []

        for m in matches {
            let saved = pending[m.savedIndex]
            let window = live[m.candidateKey]
            // Full screen is only changed for the very same window (or an exact
            // title match), never for "some window of that app".
            let confident = m.kind == .windowNumber || m.kind == .exactTitle
            let display = targetDisplay(for: saved, in: displays)
            let target = clamped(saved.frame.offsetBy(dx: display.frame.x, dy: display.frame.y), to: display.frame)

            if saved.isFullscreen && window.isFullscreen {
                // Already a full-screen Space of its own; macOS won't move those.
                report.moved += 1
                continue
            }
            if window.isFullscreen {
                guard confident else { continue }
                setBool(window.element, "AXFullScreen", false)
                Thread.sleep(forTimeInterval: 1.0)
            }
            if window.isMinimized && !saved.isMinimized { setBool(window.element, kAXMinimizedAttribute, false) }

            if options.moveBetweenDesktops, !saved.isFullscreen, let wantedIndex = saved.spaceIndex,
                let ds = startSpaces.spaces(forDisplayUUID: display.identity.uuid),
                wantedIndex <= ds.desktops.count, !window.spaces.contains(ds.desktops[wantedIndex - 1].id)
            {
                desktopMoves.append((saved, window, target, display))
                continue
            }

            if window.frame == target && window.isMinimized == saved.isMinimized
                && window.isFullscreen == saved.isFullscreen
            {
                report.alreadyInPlace += 1
                continue
            }
            progress("Moving \(window.appName)…")
            setFrame(window.element, target, pid: window.pid)
            if saved.isFullscreen && !window.isFullscreen && confident {
                Thread.sleep(forTimeInterval: 0.2)
                setBool(window.element, "AXFullScreen", true)
            }
            if saved.isMinimized && !window.isMinimized { setBool(window.element, kAXMinimizedAttribute, true) }
            report.moved += 1
        }

        if !desktopMoves.isEmpty {
            moveAcrossDesktops(desktopMoves, displays: displays, start: startSpaces, report: &report, progress: progress)
        }
        if options.moveBetweenDesktops { returnToDesktops(of: startSpaces) }
        return report
    }

    /// The layout's windows that aren't already exactly where it has them
    /// (same window, frame and Space, per the window server). The rest are
    /// left alone: no Accessibility, no Desktop switching.
    static func windowsToRestore(_ layout: WindowLayout, displays: [LiveDisplay], spaces startSpaces: SpacesSnapshot)
        -> [WindowSnapshot]
    {
        let allPids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let server = Dictionary(
            serverWindows(pids: allPids, visibleSpaces: []).map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        return layout.windows.filter { saved in
            guard let n = saved.windowNumber, let w = server[n] else { return true }
            let display = targetDisplay(for: saved, in: displays)
            let expected = saved.isFullscreen
                ? display.frame : clamped(saved.frame.offsetBy(dx: display.frame.x, dy: display.frame.y), to: display.frame)
            let sameFrame = abs(w.frame.x - expected.x) <= 2 && abs(w.frame.y - expected.y) <= 2
                && abs(w.frame.width - expected.width) <= 2 && abs(w.frame.height - expected.height) <= 2
            let sameSpace = saved.spacePosition == nil || w.spaces.count != 1
                || startSpaces.position(of: w.spaces[0]) == saved.spacePosition
                || (saved.isFullscreen && startSpaces.isFullscreenSpace(w.spaces[0]))
            return !(sameFrame && sameSpace)
        }
    }

    /// Accessibility only sees windows on the Desktops being shown. Visit
    /// each other Desktop holding windows of the layout's apps (per the
    /// window server), and pick those windows up while they're visible.
    private static func collectFromOtherDesktops(
        for saved: [WindowSnapshot], known: [LiveWindow], start: SpacesSnapshot, progress: (String) -> Void
    ) -> [LiveWindow] {
        let wanted = Set(saved.map(\.bundleID))
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && wanted.contains($0.bundleIdentifier ?? "")
        }
        let pids = Set(apps.map(\.processIdentifier))
        let knownNumbers = Set(known.compactMap(\.windowNumber))
        // The saved windows' own numbers, when they're still open; apps whose
        // saved windows are all gone (relaunched) may match any of theirs.
        let savedNumbers = Set(saved.compactMap(\.windowNumber))
        let all = serverWindows(pids: pids, visibleSpaces: start.currentSpaces)
        let openNumbers = Set(all.map(\.number))
        let relaunched = Set(saved.filter { $0.windowNumber.map { !openNumbers.contains($0) } ?? true }.map(\.bundleID))
        let hidden = all.filter { w in
            guard !knownNumbers.contains(w.number), w.spaces.count == 1, !start.currentSpaces.contains(w.spaces[0])
            else { return false }
            let bundle = apps.first { $0.processIdentifier == w.pid }?.bundleIdentifier ?? ""
            return savedNumbers.contains(w.number) || relaunched.contains(bundle)
        }
        guard !hidden.isEmpty else { return [] }
        let available = SpaceService.availableDesktopShortcuts()
        // Desktops only: full-screen Spaces have no "Switch to Desktop" shortcut.
        let bySpace = Dictionary(grouping: hidden) { $0.spaces[0] }
            .compactMap { space, windows in start.globalDesktopNumber(of: space).map { ($0, windows) } }
            .filter { $0.0 <= available }
            .sorted { $0.0 < $1.0 }
        var found: [LiveWindow] = []
        for (number, windows) in bySpace {
            progress("Looking for windows on Desktop \(number)…")
            _ = SpaceService.switchToDesktop(number)
            Thread.sleep(forTimeInterval: SpaceService.switchDelay)
            let numbers = Set(windows.map(\.number))
            for app in apps where windows.contains(where: { $0.pid == app.processIdentifier }) {
                let el = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(el, 0.5)
                let elements: [AXUIElement] = attribute(el, kAXWindowsAttribute) ?? []
                for e in elements {
                    guard let n = windowNumber(e), numbers.contains(n), let w = describe(e, app: app) else { continue }
                    found.append(w)
                }
            }
        }
        return found
    }

    /// Leave every display on the Space it was showing before a restore. A
    /// Desktop is reached with its shortcut; a full-screen app's Space (which
    /// has none) by bringing that app forward.
    private static func returnToDesktops(of start: SpacesSnapshot) {
        let available = SpaceService.availableDesktopShortcuts()
        let end = SpaceService.snapshot()
        for space in start.displays.map(\.current) where !end.currentSpaces.contains(space) {
            if let number = end.globalDesktopNumber(of: space), number <= available {
                _ = SpaceService.switchToDesktop(number)
                Thread.sleep(forTimeInterval: SpaceService.switchDelay)
            } else if end.isFullscreenSpace(space) {
                let pids = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
                if let owner = serverWindows(pids: pids, visibleSpaces: []).first(where: { $0.spaces.contains(space) }) {
                    NSRunningApplication(processIdentifier: owner.pid)?.activate()
                    Thread.sleep(forTimeInterval: SpaceService.switchDelay)
                }
            }
        }
    }

    private static func moveAcrossDesktops(
        _ moves: [(saved: WindowSnapshot, window: LiveWindow, target: IRect, display: LiveDisplay)],
        displays: [LiveDisplay], start: SpacesSnapshot, report: inout RestoreReport, progress: (String) -> Void
    ) {
        let available = SpaceService.availableDesktopShortcuts()
        for move in moves {
            let w = move.window
            progress("Moving \(w.appName) to Desktop \(move.saved.spaceIndex ?? 0)…")
            var spaces = SpaceService.snapshot()

            // 1. Make the window visible: switch to the Desktop it's on now.
            //    If that's impossible, leave it alone: dragging at its
            //    position would grab whatever visible window is there.
            if !w.spaces.contains(where: spaces.currentSpaces.contains) {
                guard let current = w.spaces.first, let number = spaces.globalDesktopNumber(of: current),
                    number <= available
                else {
                    report.desktopFailures += 1
                    continue
                }
                _ = SpaceService.switchToDesktop(number)
                Thread.sleep(forTimeInterval: SpaceService.switchDelay)
                let visible = SpaceService.snapshot().currentSpaces
                guard (w.windowNumber.map(SpaceService.spaces(forWindow:)) ?? []).contains(where: visible.contains) else {
                    report.desktopFailures += 1
                    continue
                }
            }

            // 2. Put it on the right display (it joins that display's current
            //    Desktop) and bring it to the front so nothing covers the grip.
            setFrame(w.element, move.target, pid: w.pid)
            AXUIElementPerformAction(w.element, kAXRaiseAction as CFString)
            NSRunningApplication(processIdentifier: w.pid)?.activate()
            Thread.sleep(forTimeInterval: 0.3)

            // 3. Carry it to the saved Desktop.
            spaces = SpaceService.snapshot()
            guard let ds = spaces.spaces(forDisplayUUID: move.display.identity.uuid),
                let index = move.saved.spaceIndex, index <= ds.desktops.count
            else {
                report.desktopFailures += 1
                continue
            }
            let targetSpace = ds.desktops[index - 1].id
            let nowOn = w.windowNumber.map(SpaceService.spaces(forWindow:)) ?? []
            if !nowOn.contains(targetSpace) {
                guard let number = spaces.globalDesktopNumber(of: targetSpace), number <= available,
                    let grip = titleBarPoint(w.element), let wid = w.windowNumber,
                    topmostWindow(at: grip) == wid
                else {
                    report.desktopFailures += 1
                    report.moved += 1
                    continue
                }
                _ = SpaceService.carryWindow(titleBarPoint: grip, toDesktop: number)
                let after = w.windowNumber.map(SpaceService.spaces(forWindow:)) ?? []
                if after.contains(targetSpace) { report.desktopMoves += 1 } else { report.desktopFailures += 1 }
            }
            if move.saved.isMinimized { setBool(w.element, kAXMinimizedAttribute, true) }
            report.moved += 1
        }

    }

    /// The live display a saved window should go to.
    static func targetDisplay(for saved: WindowSnapshot, in displays: [LiveDisplay]) -> LiveDisplay {
        let sameKey = displays.filter { $0.identity.hardwareKey == saved.displayKey }
        return sameKey.first { $0.ordinal == saved.displayOrdinal } ?? sameKey.first
            ?? displays.first(where: \.isMain) ?? displays[0]
    }

    /// Keep the window on its display: shrink to fit, then pull inside.
    static func clamped(_ r: IRect, to d: IRect) -> IRect {
        let w = min(r.width, d.width)
        let h = min(r.height, d.height)
        let x = min(max(r.x, d.minX), d.maxX - w)
        let y = min(max(r.y, d.minY), d.maxY - h)
        return IRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - AX primitives

    /// Size → position → size: the second resize lands correctly when the
    /// window crosses onto a display with different dimensions. Enhanced UI
    /// (enabled by VoiceOver-ish clients) makes some apps animate and ignore
    /// moves, so it's switched off for the duration.
    static func setFrame(_ element: AXUIElement, _ frame: IRect, pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        let enhanced: Bool = attribute(app, "AXEnhancedUserInterface") ?? false
        if enhanced { setBool(app, "AXEnhancedUserInterface", false) }
        var size = CGSize(width: frame.width, height: frame.height)
        var origin = CGPoint(x: frame.x, y: frame.y)
        if let sizeValue = AXValueCreate(.cgSize, &size), let pointValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pointValue)
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }
        if enhanced { setBool(app, "AXEnhancedUserInterface", true) }
    }

    /// Front-most normal window under a global point.
    static func topmostWindow(at p: CGPoint) -> CGWindowID? {
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = info[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: b as CFDictionary), rect.contains(p)
            else { continue }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }

    /// A point in the title bar just left of the close button — the grip
    /// Amethyst uses to carry windows between Spaces.
    static func titleBarPoint(_ element: AXUIElement) -> CGPoint? {
        guard let origin = point(element) else { return nil }
        return CGPoint(x: origin.x + 5, y: origin.y + 12)
    }

    /// A window's frame in top-left global coordinates.
    static func frame(of element: AXUIElement) -> IRect? {
        guard let p = point(element), let s = size(element) else { return nil }
        return IRect(CGRect(origin: p, size: s))
    }

    static func windowNumber(_ element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(element, &wid) == .success && wid != 0 ? wid : nil
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func point(_ element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
            let v = value, CFGetTypeID(v) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
            let v = value, CFGetTypeID(v) == AXValueGetTypeID()
        else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    private static func setBool(_ element: AXUIElement, _ name: String, _ value: Bool) {
        AXUIElementSetAttributeValue(element, name as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }
}
