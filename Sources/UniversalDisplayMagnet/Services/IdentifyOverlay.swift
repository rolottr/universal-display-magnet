import AppKit
import SwiftUI

/// Shows each display's name in large type on that display, like the
/// "Identify" button System Settings used to have.
enum IdentifyOverlay {
    private static var windows: [NSWindow] = []

    static func show(names: [CGDirectDisplayID: String]) {
        hide()
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = n.uint32Value
            let name = names[id] ?? screen.localizedName
            let frame = screen.frame
            let size = NSSize(width: min(640, frame.width * 0.8), height: 180)
            let window = NSWindow(
                contentRect: NSRect(
                    x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.contentView = NSHostingView(
                rootView: IdentifyCard(name: name, detail: "\(Int(frame.width))×\(Int(frame.height))"))
            window.orderFrontRegardless()
            windows.append(window)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { hide() }
    }

    static func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private struct IdentifyCard: View {
    let name: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.black.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.blue.opacity(0.8), lineWidth: 2))
                .shadow(color: .blue.opacity(0.45), radius: 24)
        )
        .padding(16)
    }
}
