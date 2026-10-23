import UniversalDisplayMagnetCore
import SwiftUI

extension SnapCommand {
    /// The name to show: built-in commands in the app's language, custom ones as named.
    var title: String {
        guard builtIn else { return name }
        switch id {
        case "left": return String(localized: "Left")
        case "right": return String(localized: "Right")
        case "top": return String(localized: "Top")
        case "bottom": return String(localized: "Bottom")
        case "topLeft": return String(localized: "Top Left")
        case "topRight": return String(localized: "Top Right")
        case "bottomLeft": return String(localized: "Bottom Left")
        case "bottomRight": return String(localized: "Bottom Right")
        case "nextDisplay": return String(localized: "Next Display")
        case "previousDisplay": return String(localized: "Previous Display")
        case "maximize": return String(localized: "Maximize")
        case "center": return String(localized: "Center")
        case "restore": return String(localized: "Restore")
        default: return name
        }
    }
}

/// Small icon of a command: its region filled inside a screen outline (like
/// Magnet's), or a symbol for display moves, centre and restore.
struct SnapGlyph: View {
    let command: SnapCommand
    var size = CGSize(width: 22, height: 14)
    var active = false

    var body: some View {
        Group {
            switch command.action {
            case .region(let r):
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 2.5).fill(Color.blue.opacity(active ? 0.45 : 0.3))
                    let cw = size.width / CGFloat(r.cols)
                    let ch = size.height / CGFloat(r.rows)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(active ? Color.white : Color.blue)
                        .frame(width: max(2, cw * CGFloat(r.w) - 1), height: max(2, ch * CGFloat(r.h) - 1))
                        .offset(x: cw * CGFloat(r.x) + 0.5, y: ch * CGFloat(r.y) + 0.5)
                }
            case .nextDisplay: symbol("arrow.right.to.line.compact")
            case .previousDisplay: symbol("arrow.left.to.line.compact")
            case .center: symbol("arrow.down.right.and.arrow.up.left")
            case .restore: symbol("arrow.uturn.backward")
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func symbol(_ name: String) -> some View {
        RoundedRectangle(cornerRadius: 2.5).fill(Color.blue.opacity(active ? 0.9 : 0.75))
            .overlay(Image(systemName: name).font(.system(size: size.height * 0.62, weight: .bold)).foregroundColor(.white))
    }
}

struct SnappingView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var selection: ViewState<String?>

    init(selection initial: String? = nil) {
        _selection = StateObject(wrappedValue: ViewState(initial))
    }

    private var selected: SnapCommand? {
        model.snapCommands.first { $0.id == selection.value } ?? model.snapCommands.first
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 250)
            Divider()
            ScrollView {
                if let c = selected {
                    CommandDetail(command: c).id(c.id)
                        .padding(20)
                }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Commands").font(.headline)
                Spacer()
                Button {
                    let custom = SnapCommand(
                        name: String(localized: "Custom \(model.snapCommands.filter { !$0.builtIn }.count + 1)"),
                        action: .region(GridRect(cols: 6, rows: 4, x: 1, y: 0, w: 4, h: 4)), hotkeyEnabled: true)
                    model.updateSnapCommand(custom)
                    selection.value = custom.id
                } label: { Image(systemName: "plus.circle.fill") }
                .buttonStyle(.plain)
                .help("Add a command with your own size and position")
            }
            .padding(14)
            List(selection: Binding(get: { selected?.id }, set: { selection.value = $0 })) {
                ForEach(model.snapCommands) { c in
                    HStack(spacing: 10) {
                        SnapGlyph(command: c)
                        Text(c.title)
                        Spacer()
                        if model.shortcutConflicts.contains(c.id) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("This shortcut is used by another app")
                        } else if c.hotkeyEnabled, let k = c.hotkey {
                            Text(k.display).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                    .tag(c.id)
                }
            }
            .listStyle(.sidebar)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Snap by dragging windows to screen edges", isOn: $model.settings.dragToSnap)
                    .toggleStyle(.switch)
                    .font(.callout)
                Button("Reset to Defaults") { model.resetSnapCommands() }
                    .controlSize(.small)
            }
            .padding(14)
        }
    }
}

private struct CommandDetail: View {
    @EnvironmentObject var model: AppModel
    let command: SnapCommand

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if command.builtIn {
                    Text(command.title).font(.title2.weight(.semibold))
                } else {
                    TextField(
                        "Name",
                        text: Binding(
                            get: { command.name },
                            set: { v in update { $0.name = v } })
                    )
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                }
                Spacer()
                Button("Try It") { model.runSnap(command) }
                    .help("Apply to the front window of the app you used last")
                if !command.builtIn {
                    Button(role: .destructive) {
                        model.deleteSnapCommand(command.id)
                    } label: { Image(systemName: "trash") }
                }
            }

            if let region = command.region {
                card("Intended window size and position") {
                    GridEditor(region: region, editable: true) { r in
                        update { $0.action = .region(r) }
                    }
                }
            }

            card("Keyboard shortcut") {
                HStack {
                    ShortcutRecorder(
                        hotkey: Binding(get: { command.hotkey }, set: { k in update { $0.hotkey = k } }))
                    Spacer()
                    Toggle(
                        "", isOn: Binding(get: { command.hotkeyEnabled }, set: { v in update { $0.hotkeyEnabled = v } })
                    )
                    .toggleStyle(.switch).labelsHidden()
                }
                if model.shortcutConflicts.contains(command.id) {
                    Label(
                        "Another app already uses \(command.hotkey?.display ?? String(localized: "this shortcut")) (Magnet?). Quit it or pick a different shortcut.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption).foregroundStyle(.orange)
                }
            }

            card("Menu bar") {
                Toggle(
                    "Show in the menu bar menu",
                    isOn: Binding(get: { command.showInMenu }, set: { v in update { $0.showInMenu = v } })
                )
                .toggleStyle(.switch)
            }
        }
    }

    private func update(_ change: (inout SnapCommand) -> Void) {
        var c = command
        change(&c)
        model.updateSnapCommand(c)
    }

    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.callout.weight(.medium))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Magnet-style grid: drag across cells to choose the window's size and
/// position. Steppers change the grid's resolution.
private struct GridEditor: View {
    let region: GridRect
    let editable: Bool
    let onChange: (GridRect) -> Void
    @StateObject private var dragStart = ViewState<(Int, Int)?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let cw = geo.size.width / CGFloat(region.cols)
                let ch = geo.size.height / CGFloat(region.rows)
                ZStack(alignment: .topLeading) {
                    ForEach(0..<(region.cols * region.rows), id: \.self) { i in
                        let cx = i % region.cols
                        let cy = i / region.cols
                        let on = cx >= region.x && cx < region.x + region.w && cy >= region.y && cy < region.y + region.h
                        RoundedRectangle(cornerRadius: 3)
                            .fill(on ? Color.blue : Color.white.opacity(0.12))
                            .frame(width: cw - 3, height: ch - 3)
                            .offset(x: CGFloat(cx) * cw + 1.5, y: CGFloat(cy) * ch + 1.5)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard editable else { return }
                            let cell = { (p: CGPoint) -> (Int, Int) in
                                (
                                    min(region.cols - 1, max(0, Int(p.x / cw))),
                                    min(region.rows - 1, max(0, Int(p.y / ch)))
                                )
                            }
                            if dragStart.value == nil { dragStart.value = cell(v.startLocation) }
                            let (sx, sy) = dragStart.value!
                            let (ex, ey) = cell(v.location)
                            onChange(
                                GridRect(
                                    cols: region.cols, rows: region.rows, x: min(sx, ex), y: min(sy, ey),
                                    w: abs(ex - sx) + 1, h: abs(ey - sy) + 1))
                        }
                        .onEnded { _ in dragStart.value = nil }
                )
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .frame(maxWidth: 460)
            HStack(spacing: 16) {
                Stepper("Columns: \(region.cols)", value: Binding(get: { region.cols }, set: { resize(cols: $0) }), in: 1...24)
                Stepper("Rows: \(region.rows)", value: Binding(get: { region.rows }, set: { resize(rows: $0) }), in: 1...24)
                Spacer()
                Text(region.sizeLabel).font(.system(.callout, design: .rounded)).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    /// Change the grid resolution while keeping the same area as closely as possible.
    private func resize(cols: Int? = nil, rows: Int? = nil) {
        let c = cols ?? region.cols
        let r = rows ?? region.rows
        func scale(_ v: Int, _ from: Int, _ to: Int) -> Int { Int((Double(v) * Double(to) / Double(from)).rounded()) }
        let x = min(scale(region.x, region.cols, c), c - 1)
        let y = min(scale(region.y, region.rows, r), r - 1)
        let w = max(1, min(scale(region.w, region.cols, c), c - x))
        let h = max(1, min(scale(region.h, region.rows, r), r - y))
        onChange(GridRect(cols: c, rows: r, x: x, y: y, w: w, h: h))
    }
}
