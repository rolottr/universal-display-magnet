import AppKit

/// Small wallpaper thumbnails, so the shared canvas shows each display the
/// way System Settings' "Arrange Displays" does (other Macs' displays too).
enum Wallpaper {
    private static var cache: [String: Data] = [:]

    static func thumbnail(for displayID: CGDirectDisplayID) -> Data? {
        if DemoRenderer.isActive { return DemoRenderer.wallpaper(seed: Int(displayID)) }
        guard
            let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
            }),
            let url = NSWorkspace.shared.desktopImageURL(for: screen)
        else { return nil }
        if let hit = cache[url.path] { return hit }
        guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return nil }
        let width: CGFloat = 320
        let size = NSSize(width: width, height: (width * image.size.height / image.size.width).rounded())
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        if let data { cache[url.path] = data }
        return data
    }
}
