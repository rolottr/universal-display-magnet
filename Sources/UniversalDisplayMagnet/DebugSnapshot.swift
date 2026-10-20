import AppKit
import UniversalDisplayMagnetCore
import SwiftUI

/// `Universal Display Magnet --snapshot <dir>` renders every screen of the app to PNGs and
/// quits. Used to check the UI without Screen Recording permission (the app
/// draws its own views).
@MainActor
enum DebugSnapshot {
    static var directory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel.shared
        var steps: [(String, () -> NSView)] = []
        for section in AppSection.allCases {
            steps.append(
                (
                    section.rawValue,
                    {
                        Navigation.shared.section = section
                        return host(
                            MainView().environmentObject(model).environmentObject(Navigation.shared),
                            size: NSSize(width: 1060, height: 720))
                    }
                ))
        }
        steps.append(("menu", { host(MenuPanel().environmentObject(model), size: NSSize(width: 340, height: 640)) }))
        steps.append(
            (
                "save-workspace",
                {
                    let layout = model.windowLayouts.first { $0.isWorkspace } ?? model.windowLayouts.first
                    let form = SaveWorkspaceModel(editing: layout, includeArrangement: true, suggestedName: "Work")
                    return host(
                        SaveWorkspaceView(form: form) {}.environmentObject(model), size: NSSize(width: 520, height: 720))
                }
            ))
        steps.append(
            (
                "editor-selected",
                {
                    let editor = EditorModel()
                    editor.load(device: nil, model: model)
                    editor.selected = editor.items.first?.id
                    return host(
                        EditorPanel(editor: editor).environmentObject(model).environmentObject(Navigation.shared),
                        size: NSSize(width: 860, height: 560))
                }
            ))
        steps.append(
            (
                "editor-dragged",
                {
                    // Drop the second display roughly left of the first: it should snap flush.
                    let editor = EditorModel()
                    editor.load(device: nil, model: model)
                    if editor.items.count > 1 {
                        let a = editor.items[0].rect
                        let b = editor.items[1]
                        editor.drag(
                            b.id, to: IRect(x: a.x - b.rect.width - 150, y: a.y + 90, width: b.rect.width, height: b.rect.height),
                            threshold: 120)
                        editor.selected = b.id
                    }
                    return host(
                        EditorPanel(editor: editor).environmentObject(model).environmentObject(Navigation.shared),
                        size: NSSize(width: 860, height: 560))
                }
            ))

        func next(_ index: Int) {
            guard index < steps.count else {
                NSApp.terminate(nil)
                return
            }
            let (name, make) = steps[index]
            let view = make()
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: view.frame.size),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.appearance = NSAppearance(named: .darkAqua)
            window.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("\(name).png"))
                }
                window.orderOut(nil)
                next(index + 1)
            }
        }
        next(0)
    }

    private static func host<V: View>(_ view: V, size: NSSize) -> NSView {
        let v = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        v.frame = NSRect(origin: .zero, size: size)
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
}
