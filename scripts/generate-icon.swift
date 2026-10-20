// Draws the Universal Display Magnet icon into an .iconset folder: three displays snapped
// together on a dark tile, the centre one glowing blue like the editor.
// Usage: swift scripts/generate-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.04, alpha: 1)])!.draw(in: tilePath, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    tilePath.lineWidth = max(1, s * 0.006)
    tilePath.stroke()

    let u = s * 0.8 / 10  // grid unit inside the tile
    let ox = tile.minX, oy = tile.minY
    func display(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, glow: Bool) {
        let r = NSRect(x: ox + x * u, y: oy + y * u, width: w * u, height: h * u)
        let p = NSBezierPath(roundedRect: r, xRadius: u * 0.22, yRadius: u * 0.22)
        if glow {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.systemBlue.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = u * 0.9
            shadow.set()
            NSColor.systemBlue.withAlphaComponent(0.35).setFill()
            p.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemBlue.setStroke()
        } else {
            NSColor(white: 0.22, alpha: 1).setFill()
            p.fill()
            NSColor(white: 1, alpha: 0.35).setStroke()
        }
        p.lineWidth = max(1, u * 0.12)
        p.stroke()
    }
    // Ultrawide on top, two displays snapped beneath it.
    display(1.2, 5.0, 7.6, 3.2, glow: true)
    display(1.6, 2.0, 3.4, 3.0, glow: false)
    display(5.0, 2.0, 3.4, 3.0, glow: false)
    // Menu bar strip on the main display.
    NSColor(white: 1, alpha: 0.8).setFill()
    NSBezierPath(roundedRect: NSRect(x: ox + 1.6 * u, y: oy + 7.75 * u, width: 6.8 * u, height: 0.18 * u), xRadius: u * 0.09, yRadius: u * 0.09).fill()
    // Yellow link where they meet.
    NSColor.systemYellow.withAlphaComponent(0.85).setFill()
    for cx in [3.3, 6.7] as [CGFloat] {
        NSBezierPath(ovalIn: NSRect(x: ox + cx * u - u * 0.28, y: oy + 5.0 * u - u * 0.28, width: u * 0.56, height: u * 0.56)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}
print(out)
