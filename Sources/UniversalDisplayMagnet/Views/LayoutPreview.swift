import AppKit
import UniversalDisplayMagnetCore
import SwiftUI

/// App icons and a representative colour per app, cached.
enum AppLook {
    private static var icons: [String: NSImage] = [:]
    private static var colors: [String: Color] = [:]

    static func icon(_ bundleID: String) -> NSImage {
        if let i = icons[bundleID] { return i }
        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .application)
        }
        icons[bundleID] = icon
        return icon
    }

    /// The icon's average colour, saturated a little, so each app's windows
    /// read at a glance (like Arc orange, VS Code blue).
    static func color(_ bundleID: String) -> Color {
        if let c = colors[bundleID] { return c }
        var result = Color(white: 0.35)
        let size = 12
        if let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon(bundleID).draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for x in 0..<size {
                for y in 0..<size {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                    // Skip near-white/near-black pixels (icon backgrounds, outlines).
                    let lum = 0.3 * c.redComponent + 0.59 * c.greenComponent + 0.11 * c.blueComponent
                    guard lum > 0.08, lum < 0.92 else { continue }
                    r += c.redComponent
                    g += c.greenComponent
                    b += c.blueComponent
                    n += 1
                }
            }
            if n > 0 {
                let ns = NSColor(red: r / n, green: g / n, blue: b / n, alpha: 1)
                var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
                ns.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
                result = Color(hue: h, saturation: min(1, s * 1.25), brightness: min(0.8, max(0.45, v)))
            }
        }
        colors[bundleID] = result
        return result
    }
}

/// A drawn picture of a window layout: each display, and the windows on
/// one of its Spaces in their app's colour with the app's icon, front-most
/// on top. By default each display shows the Space it was showing when the
/// layout was saved; chips switch between a display's Desktops and
/// full-screen apps.
struct LayoutPreview: View {
    let displays: [DisplayPlacement]
    let windows: [WindowSnapshot]
    /// Small thumbnails skip labels and the Space chips.
    var compact = false

    /// Display index → chosen page.
    @StateObject private var chosen = ViewState<[Int: Int]>([:])

    struct Page: Hashable {
        let key: Int
        let label: String
        let fullscreen: Bool
    }

    /// Which page (Space) of its display a window is on; nil = none (hidden
    /// windows) or every page (on all Desktops).
    private func pageKey(_ w: WindowSnapshot, index: Int) -> Int? {
        if w.onAllDesktops == true { return nil }
        if let p = w.spacePosition { return p }
        // Snapshots that record Spaces: no position means no Space (hidden).
        if recordsSpaces { return nil }
        // Layouts saved before Space positions were recorded.
        if w.isFullscreen { return 1000 + index }
        return w.spaceIndex.map { 2000 + $0 }
    }

    private var recordsSpaces: Bool { windows.contains { $0.spacePosition != nil || $0.onVisibleSpace != nil } }

    private var entries: [(window: WindowSnapshot, display: Int, page: Int?)] {
        windows.enumerated().compactMap { i, w in
            guard !w.isMinimized, let d = displayIndex(for: w) else { return nil }
            let page = pageKey(w, index: i)
            // Not on any Space (hidden helper windows): nothing to draw.
            if page == nil && w.onAllDesktops != true { return nil }
            return (w, d, page)
        }
    }

    private func pages(of display: Int) -> [Page] {
        var seen: [Int: Page] = [:]
        for e in entries where e.display == display {
            guard let key = e.page, seen[key] == nil || e.window.isFullscreen else { continue }
            let label =
                e.window.isFullscreen
                ? "\(e.window.appName) (full screen)" : "Desktop \(e.window.spaceIndex.map(String.init) ?? "?")"
            seen[key] = Page(key: key, label: label, fullscreen: e.window.isFullscreen)
        }
        return seen.values.sorted { $0.key < $1.key }
    }

    /// The page shown for a display: the user's choice, else what was on
    /// screen when saved, else the busiest Desktop.
    private func shownPage(of display: Int) -> Int? {
        let available = pages(of: display)
        if let c = chosen.value[display], available.contains(where: { $0.key == c }) { return c }
        let mine = entries.filter { $0.display == display && $0.page != nil }
        if let visible = mine.first(where: { $0.window.onVisibleSpace == true })?.page { return visible }
        let counts = Dictionary(grouping: mine.compactMap(\.page), by: { $0 }).mapValues(\.count)
        return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let t = CanvasTransform.fit(displays.map(\.frame), in: geo.size, fill: compact ? 0.94 : 0.86)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(displays.enumerated()), id: \.offset) { _, d in
                        let r = t.rect(d.frame)
                        RoundedRectangle(cornerRadius: compact ? 2 : 4)
                            .fill(Color(white: 0.14))
                            .overlay(RoundedRectangle(cornerRadius: compact ? 2 : 4).stroke(Color.white.opacity(0.18)))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                        if d.isMain && !compact {
                            Label("Main", systemImage: "display")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.blue))
                                .fixedSize()
                                .position(x: r.midX, y: r.minY - 9)
                        }
                    }
                    ForEach(Array(visibleWindows.enumerated()), id: \.offset) { _, item in
                        windowBlock(item.window, in: displays[item.display], t: t)
                    }
                }
            }
            if !compact {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(displays.enumerated()), id: \.offset) { i, d in
                        let list = pages(of: i)
                        if list.count > 1 {
                            HStack(spacing: 4) {
                                Text(d.identity.name).font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: 92, alignment: .trailing).lineLimit(1)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 4) {
                                        ForEach(list, id: \.key) { page in
                                            chip(page, selected: page.key == shownPage(of: i)) {
                                                chosen.value[i] = page.key
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func chip(_ page: Page, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if page.fullscreen { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 8)) }
                Text(page.label).lineLimit(1)
            }
            .font(.system(size: 10, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(selected ? Color.blue.opacity(0.4) : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    /// Windows on each display's shown Space (plus all-Desktops ones),
    /// back-most first so the front-most draws on top.
    private var visibleWindows: [(window: WindowSnapshot, display: Int)] {
        let shown = Dictionary(uniqueKeysWithValues: displays.indices.map { ($0, shownPage(of: $0)) })
        return entries
            .filter { $0.page == nil || $0.page == shown[$0.display] ?? nil }
            .sorted { a, b in
                // Full-screen windows cover everything; otherwise by stacking order.
                if a.window.isFullscreen != b.window.isFullscreen { return !a.window.isFullscreen }
                return (a.window.z ?? Int.max) > (b.window.z ?? Int.max)
            }
            .map { ($0.window, $0.display) }
    }

    private func displayIndex(for w: WindowSnapshot) -> Int? {
        let same = displays.indices.filter { displays[$0].identity.hardwareKey == w.displayKey }
        return same.indices.contains(w.displayOrdinal) ? same[w.displayOrdinal] : same.first
    }

    private func display(for w: WindowSnapshot) -> DisplayPlacement? {
        let same = displays.filter { $0.identity.hardwareKey == w.displayKey }
        return same.indices.contains(w.displayOrdinal) ? same[w.displayOrdinal] : same.first
    }

    @ViewBuilder
    private func windowBlock(_ w: WindowSnapshot, in d: DisplayPlacement, t: CanvasTransform) -> some View {
        let frame = w.isFullscreen ? IRect(x: 0, y: 0, width: d.frame.width, height: d.frame.height) : w.frame
        let abs = IRect(x: d.frame.x + frame.x, y: d.frame.y + frame.y, width: frame.width, height: frame.height)
        // Keep the block inside its display.
        let clipped = IRect(
            x: max(abs.x, d.frame.minX), y: max(abs.y, d.frame.minY),
            width: max(1, min(abs.maxX, d.frame.maxX) - max(abs.x, d.frame.minX)),
            height: max(1, min(abs.maxY, d.frame.maxY) - max(abs.y, d.frame.minY)))
        let r = t.rect(clipped)
        let color = AppLook.color(w.bundleID)
        let iconSize = max(8, min(compact ? 14 : 34, min(r.width, r.height) * 0.42))
        RoundedRectangle(cornerRadius: compact ? 1.5 : 3)
            .fill(color.opacity(0.92))
            .overlay(RoundedRectangle(cornerRadius: compact ? 1.5 : 3).stroke(Color.black.opacity(0.35), lineWidth: 0.75))
            .overlay {
                VStack(spacing: 3) {
                    Image(nsImage: AppLook.icon(w.bundleID))
                        .resizable()
                        .frame(width: iconSize, height: iconSize)
                    if !compact && r.height > 46 && r.width > 50 {
                        Text(w.appName)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                }
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .help("\(w.appName) — \(w.title)")
    }
}
