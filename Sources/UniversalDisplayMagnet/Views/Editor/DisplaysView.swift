import UniversalDisplayMagnetCore
import SwiftUI

struct DisplaysView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigation
    @StateObject private var editor = EditorModel()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                EditorPanel(editor: editor)
                profilesStrip
            }
            .padding(18)
        }
        .onAppear { editor.load(device: nav.editorDevice, model: model) }
        .onChange(of: nav.editorDevice) { _, d in editor.load(device: d, model: model) }
        .onChange(of: model.displays) { _, _ in
            // Follow live changes unless the user is mid-edit.
            if !editor.isRemote && !editor.isDirty { editor.load(device: nil, model: model) }
        }
        .onChange(of: model.devices) { _, _ in
            if editor.isRemote && !editor.isDirty { editor.load(device: nav.editorDevice, model: model) }
        }
    }

    // MARK: - Saved arrangements for this setup

    private var setupKey: String {
        if let d = nav.editorDevice, let s = model.devices.first(where: { $0.deviceID == d }) { return s.setupKey }
        return model.setupKey
    }

    private var profilesStrip: some View {
        let profiles = model.profiles(forSetup: setupKey)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SAVED ARRANGEMENTS FOR THIS SETUP")
                    .font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let name = Prompt.text(
                        String(localized: "Save arrangement"), message: String(localized: "Name this arrangement."),
                        defaultValue: suggestedName)
                    {
                        save(as: name, replacing: nil)
                    }
                } label: { Label("Save as New…", systemImage: "plus") }
                .controlSize(.small)
            }
            if profiles.isEmpty {
                Text(
                    "Nothing saved yet. Arrange the displays above and press Apply; that arrangement is then restored automatically whenever these displays connect, and whenever macOS shuffles them."
                )
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(profiles.enumerated()), id: \.element.id) { index, p in
                            ProfileCard(profile: p, isActive: index == 0, editor: editor)
                        }
                    }
                }
            }
        }
    }

    private var suggestedName: String {
        let count = model.profiles(forSetup: setupKey).count
        return count == 0 ? String(localized: "My Setup") : String(localized: "Arrangement \(count + 1)")
    }

    private func save(as name: String, replacing: ArrangementProfile?) {
        let device = editor.isRemote ? model.devices.first { $0.deviceID == nav.editorDevice } : nil
        model.saveArrangement(
            name: name, placements: editor.placements, setupKey: device?.setupKey, device: device,
            autoApply: replacing?.autoApply ?? true, restoreModes: replacing?.restoreModes ?? false, replacing: replacing)
        editor.markClean()
    }
}

private struct ProfileCard: View {
    @EnvironmentObject var model: AppModel
    let profile: ArrangementProfile
    let isActive: Bool
    @ObservedObject var editor: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MiniMap(
                rects: profile.displays.enumerated().map { i, d in
                    (id: "\(i)", rect: d.frame, name: d.identity.name, isMain: d.isMain)
                }
            )
            .frame(width: 170, height: 70)
            HStack(spacing: 4) {
                Text(profile.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if isActive {
                    Text("ACTIVE").font(.system(size: 8, weight: .bold)).tracking(1)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.25)))
                }
            }
            Text("\(profile.deviceName) · \(profile.updatedAt.formatted(.relative(presentation: .named)))")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                Button("Apply") { model.activate(profile) }
                    .controlSize(.small)
                Button("Edit") { editor.loadProfile(profile) }
                    .controlSize(.small)
                Menu {
                    Toggle("Auto-apply", isOn: binding(\.autoApply))
                    Toggle("Restore resolutions", isOn: binding(\.restoreModes))
                    Divider()
                    Button("Rename…") {
                        if let n = Prompt.text(String(localized: "Rename arrangement"), defaultValue: profile.name) {
                            var p = profile
                            p.name = n
                            model.update(p)
                        }
                    }
                    Button("Delete", role: .destructive) { model.delete(profile) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isActive ? Color.blue.opacity(0.6) : Color.primary.opacity(0.08)))
        )
    }

    private func binding(_ key: WritableKeyPath<ArrangementProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { profile[keyPath: key] },
            set: { value in
                var p = profile
                p[keyPath: key] = value
                model.update(p)
            })
    }
}

/// The dark, display-align-style editing surface.
struct EditorPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigation
    @ObservedObject var editor: EditorModel

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.92)

            VStack(spacing: 0) {
                header
                    .padding(.top, 16)

                ArrangementCanvas(editor: editor, snapThreshold: model.settings.snapThreshold)
                    .padding(.horizontal, 30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let id = editor.selected, let item = editor.item(id) {
                    Inspector(editor: editor, item: item)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 10)
                }

                bottomBar
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
            }

            HStack {
                targetPicker
                Spacer()
            }
            .padding(14)

            if let pending = model.pendingRevert {
                CountdownBanner(deadline: pending.deadline) {
                    model.keepArrangement()
                    saveKept()
                } revert: {
                    model.revertArrangement()
                    editor.load(device: nil, model: model)
                }
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06)))
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: model.pendingRevert?.deadline)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard let id = editor.selected else { return .ignored }
            let step = press.modifiers.contains(.shift) ? 50 : 10
            switch press.key {
            case .leftArrow: editor.nudge(id, dx: -step, dy: 0)
            case .rightArrow: editor.nudge(id, dx: step, dy: 0)
            case .upArrow: editor.nudge(id, dx: 0, dy: -step)
            default: editor.nudge(id, dx: 0, dy: step)
            }
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text(editor.selected == nil ? "ARRANGEMENT" : "EDITING")
                .font(.system(size: 10, weight: .medium))
                .tracking(1.5)
                .foregroundColor(.white.opacity(0.4))
            Text(editor.selected.flatMap { editor.item($0)?.name } ?? title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(editor.selected == nil ? .white.opacity(0.75) : .blue)
            Text(chip)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.blue.opacity(0.6))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.blue.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }

    private var title: String {
        if let d = nav.editorDevice, let s = model.devices.first(where: { $0.deviceID == d }) { return s.name }
        return model.deviceName
    }

    private var chip: String {
        if let id = editor.selected, let item = editor.item(id) {
            return String(localized: "\(item.detail) · at \(item.rect.x), \(item.rect.y)")
        }
        let n = editor.items.count
        return String(localized: "\(n) displays") + (editor.profile.map { " · \($0.name)" } ?? "")
    }

    private var targetPicker: some View {
        let others = model.devices.filter { $0.deviceID != model.deviceID }
        return Menu {
            Button("This Mac — \(model.deviceName)") { nav.editorDevice = nil }
            if !others.isEmpty {
                Divider()
                ForEach(others) { d in
                    Button("\(d.name) — \(d.displays.count) displays") { nav.editorDevice = d.deviceID }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: editor.isRemote ? "laptopcomputer" : "desktopcomputer")
                editor.isRemote ? Text(title) : Text("This Mac")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.65))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.07)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Edit this Mac's displays, or another synced Mac's")
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(2)
            Spacer()
            Button {
                editor.snapAll(threshold: model.settings.snapThreshold)
            } label: { Label("Snap All", systemImage: "square.grid.2x2") }
            .help("Pull every display flush against its neighbours and square up near-aligned edges")

            if !editor.isRemote {
                Button {
                    IdentifyOverlay.show(
                        names: Dictionary(uniqueKeysWithValues: model.displays.map { ($0.id, $0.identity.name) }))
                } label: { Label("Identify", systemImage: "eye") }
            }

            Button("Revert") { editor.revert() }
                .disabled(!editor.isDirty)

            Button {
                applyPressed()
            } label: {
                Text(editor.isRemote ? "Save for \(title)" : "Apply")
                    .frame(minWidth: 70)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(!editor.isValid || model.pendingRevert != nil)
        }
        .controlSize(.regular)
    }

    private var hint: String {
        if editor.items.count < 2 { return String(localized: "Connect another display to arrange.") }
        if !editor.isValid { return String(localized: "Displays must touch without overlapping.") }
        if editor.selected != nil {
            return String(localized: "Drag to slide along an edge (⌥ for free) · arrows place another display · ←→↑↓ nudge")
        }
        return String(localized: "Click a display to select it, drag it anywhere — it snaps flush to its neighbours.")
    }

    private func applyPressed() {
        if editor.isRemote {
            saveKept()
            return
        }
        if editor.isDirty {
            model.tryArrangement(editor.normalizedItems)
        } else {
            saveKept()
        }
    }

    /// The arrangement is final: store it as this setup's active profile.
    private func saveKept() {
        let device = editor.isRemote ? model.devices.first { $0.deviceID == nav.editorDevice } : nil
        let existing = editor.profile.flatMap { p in model.arrangements.first { $0.id == p.id } }
        model.saveArrangement(
            name: existing?.name ?? String(localized: "My Setup"), placements: editor.placements, setupKey: device?.setupKey, device: device,
            autoApply: existing?.autoApply ?? true, restoreModes: existing?.restoreModes ?? false, replacing: existing)
        editor.load(device: nav.editorDevice, model: model)
    }
}

private struct Inspector: View {
    @ObservedObject var editor: EditorModel
    let item: EditorModel.Item

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.placement.identity.name).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
                Text(identityLine).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("X").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                IntField(value: item.rect.x) { editor.setPosition(item.id, x: $0) }
                Text("Y").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
                IntField(value: item.rect.y) { editor.setPosition(item.id, y: $0) }
            }
            HStack(spacing: 2) {
                alignButton(.start, "align.horizontal.left")
                alignButton(.center, "align.horizontal.center")
                alignButton(.end, "align.horizontal.right")
            }
            Button {
                editor.makeMain(item.id)
            } label: {
                Label(editor.mainID == item.id ? "Main display" : "Make main", systemImage: "menubar.rectangle")
            }
            .disabled(editor.mainID == item.id)
            .help("The main display has the menu bar and opens new windows")
        }
        .controlSize(.small)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04)))
    }

    private var identityLine: String {
        let i = item.placement.identity
        let serial = i.alphanumericSerial ?? (i.serial != 0 ? String(i.serial) : String(localized: "no serial"))
        let mode = item.placement.mode?.label ?? item.detail
        return "\(Vendor.code(i.vendor)) · \(serial) · \(mode)"
    }

    private func alignHelp(_ a: EdgeAlignment) -> LocalizedStringKey {
        switch a {
        case .start: return "Line up the top or left edges with its neighbour"
        case .center: return "Center on its neighbour"
        case .end: return "Line up the bottom or right edges with its neighbour"
        }
    }

    private func alignButton(_ a: EdgeAlignment, _ symbol: String) -> some View {
        Button {
            editor.align(item.id, a)
        } label: { Image(systemName: symbol) }
        .help(alignHelp(a))
    }
}

private struct IntField: View {
    let value: Int
    let commit: (Int) -> Void
    @StateObject private var textState = ViewState("")
    private var text: String {
        get { textState.value }
        nonmutating set { textState.value = newValue }
    }

    var body: some View {
        TextField("", text: $textState.value)
            .font(.system(size: 11, design: .monospaced))
            .frame(width: 58)
            .textFieldStyle(.roundedBorder)
            .onAppear { text = "\(value)" }
            .onChange(of: value) { _, v in text = "\(v)" }
            .onSubmit {
                if let v = Int(text) { commit(v) } else { text = "\(value)" }
            }
    }
}

private struct CountdownBanner: View {
    let deadline: Date
    let keep: () -> Void
    let revert: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(deadline.timeIntervalSince(ctx.date).rounded(.up)))
            HStack(spacing: 12) {
                Image(systemName: "timer").foregroundColor(.orange)
                Text("Keep this arrangement? Reverting in \(left)s")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                Button("Revert", action: revert)
                Button("Keep", action: keep)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.12)).shadow(color: .black.opacity(0.5), radius: 10))
            .overlay(Capsule().stroke(Color.orange.opacity(0.4)))
        }
    }
}

/// EDID manufacturer id → 3-letter PnP code ("GSM" for LG, "DEL" for Dell…).
enum Vendor {
    static func code(_ vendor: UInt32) -> String {
        let c = [(vendor >> 10) & 0x1F, (vendor >> 5) & 0x1F, vendor & 0x1F]
        guard c.allSatisfy({ (1...26).contains($0) }) else { return "#\(vendor)" }
        return String(String.UnicodeScalarView(c.compactMap { UnicodeScalar(64 + $0) }))
    }
}
