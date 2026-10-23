import UniversalDisplayMagnetCore
import SwiftUI

/// Universal Control's "Arrange Displays" done properly: every display of
/// both Macs on one canvas, positioned where Universal Control actually has
/// them. Drag the other Mac's displays: they snap flush against this Mac's,
/// and on release the arrangement is written straight into Universal
/// Control (live, on both Macs).
struct LinkedMacsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var dragOffset = ViewState<IPoint?>(nil)
    @StateObject private var dragStart = ViewState<IPoint?>(nil)
    @StateObject private var frozen = ViewState<CanvasTransform?>(nil)
    @StateObject private var chosenRemote = ViewState<String?>(nil)
    /// One of this Mac's displays being dragged: its id and snapped frame.
    @StateObject private var localDrag = ViewState<(id: CGDirectDisplayID, start: IRect, rect: IRect)?>(nil)

    init() {}

    /// A frozen moment mid-drag (README animations).
    init(demoOffset: IPoint?, demoTransform: CanvasTransform?) {
        _dragOffset = StateObject(wrappedValue: ViewState(demoOffset))
        _frozen = StateObject(wrappedValue: ViewState(demoTransform))
    }

    // MARK: - Data

    private var me: String? { model.universalControl?.selfDevice }

    /// Other Macs Universal Display Magnet knows the displays of, with their Universal Control id.
    private var remotes: [(status: DeviceStatus, uc: String)] {
        model.devices.compactMap { d in
            guard d.deviceID != model.deviceID, !d.displays.isEmpty, let uc = model.ucDevice(for: d), uc != me else {
                return nil
            }
            return (d, uc)
        }
    }

    private var remote: (status: DeviceStatus, uc: String)? {
        remotes.first { $0.status.deviceID == chosenRemote.value } ?? remotes.first
    }

    /// This Mac's displays as shown (including one mid-drag).
    private var localDisplays: [UCDisplay] {
        model.displays.compactMap { d in d.identity.uuid.map { UCDisplay(uuid: $0, frame: frame(of: d)) } }
    }

    private func frame(of d: LiveDisplay) -> IRect {
        localDrag.value.flatMap { $0.id == d.id ? $0.rect : nil } ?? d.frame
    }

    private func remoteDisplays(_ r: DeviceStatus) -> [UCDisplay] {
        r.displays.compactMap { p in p.identity.uuid.map { UCDisplay(uuid: $0, frame: p.frame) } }
    }

    /// Where Universal Control currently puts the other Mac's displays (in
    /// this Mac's coordinates), or parked on the left if they aren't linked.
    private func currentOffset(_ r: (status: DeviceStatus, uc: String)) -> IPoint {
        let theirs = remoteDisplays(r.status)
        if let me, let link = model.universalControl?.link(from: r.uc, to: me),
            let o = UCGeometry.offset(of: link, displays1: theirs, displays2: localDisplays)
        {
            return o
        }
        let mine = LayoutEngine.boundingBox(localDisplays.map(\.frame)) ?? IRect(x: 0, y: 0, width: 1, height: 1)
        let box = LayoutEngine.boundingBox(theirs.map(\.frame)) ?? mine
        return IPoint(x: mine.minX - box.maxX, y: mine.minY - box.minY)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Universal Control").font(.title2.weight(.semibold))
                    Text(
                        "Both Macs' displays, where Universal Control has them. Drag the other Mac's displays, or any of yours: they snap flush against each other across both Macs, and when you let go everything is applied at once — this Mac's arrangement and Universal Control, on both Macs. No System Settings."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                banners
                if let r = remote {
                    if remotes.count > 1 {
                        Picker("Other Mac", selection: Binding(get: { r.status.deviceID }, set: { chosenRemote.value = $0 })) {
                            ForEach(remotes, id: \.status.deviceID) { Text($0.status.name).tag($0.status.deviceID) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 400)
                    }
                    canvas(r)
                        .frame(height: 400)
                    linkCard(r)
                }
                wakeCard
                resetCard
            }
            .padding(22)
        }
        .onAppear { model.refreshUniversalControl() }
    }

    @ViewBuilder
    private var banners: some View {
        if !UCBridge.isAvailable {
            PermissionBanner(
                icon: "exclamationmark.triangle", title: "Universal Control isn't available",
                detail: "This version of macOS doesn't provide the Universal Control framework Universal Display Magnet uses.",
                action: "Open Displays Settings"
            ) { openDisplaysSettings() }
        } else if me == nil {
            PermissionBanner(
                icon: "link", title: "Link your Macs once with Universal Control",
                detail:
                    "In System Settings › Displays, use “Link to Mac or iPad” once. From then on Universal Display Magnet recognises both Macs and arranges them here.",
                action: "Open Displays Settings"
            ) { openDisplaysSettings() }
        } else if remote == nil {
            PermissionBanner(
                icon: "desktopcomputer", title: "Open Universal Display Magnet on your other Mac",
                detail:
                    "Universal Display Magnet on the other Mac shares its display sizes with this one automatically (same network, nothing to pair). Its displays then appear here.",
                action: "Refresh"
            ) { model.refreshUniversalControl() }
        }
    }

    // MARK: - Canvas

    private func canvas(_ r: (status: DeviceStatus, uc: String)) -> some View {
        let offset = dragOffset.value ?? currentOffset(r)
        let theirs = remoteDisplays(r.status)
        let placedTheirs = theirs.map { $0.frame.offsetBy(dx: offset.x, dy: offset.y) }
        let all = localDisplays.map(\.frame) + placedTheirs
        let bridges = LayoutEngine.adjacencies(
            localDisplays.map { LayoutItem(id: "me#\($0.uuid)", rect: $0.frame) }
                + theirs.map { LayoutItem(id: "them#\($0.uuid)", rect: $0.frame.offsetBy(dx: offset.x, dy: offset.y)) }
        ).filter { $0.a.hasPrefix("me#") != $0.b.hasPrefix("me#") }

        return GeometryReader { geo in
            let t = frozen.value ?? CanvasTransform.fit(all, in: geo.size, fill: 0.78)
            ZStack(alignment: .topLeading) {
                Color.clear
                // This Mac: each display can move (it stays attached to this
                // Mac's other displays, and snaps to the other Mac's too).
                ForEach(Array(model.displays.enumerated()), id: \.offset) { _, d in
                    let rect = t.rect(frame(of: d))
                    tile(
                        name: d.identity.name, isMain: d.isMain, wallpaper: Wallpaper.thumbnail(for: d.id),
                        size: rect.size, movable: localDrag.value?.id == d.id
                    )
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(localDragGesture(d, r: r, t: t, remoteOffset: offset, placedTheirs: placedTheirs))
                }
                groupLabel(
                    String(localized: "\(model.deviceName) (this Mac)"), box: LayoutEngine.boundingBox(localDisplays.map(\.frame)), t: t)
                // The other Mac: one rigid, draggable group.
                ForEach(Array(r.status.displays.enumerated()), id: \.offset) { i, p in
                    let rect = t.rect(p.frame.offsetBy(dx: offset.x, dy: offset.y))
                    tile(
                        name: p.identity.name, isMain: p.isMain, wallpaper: r.status.wallpapers?[safe: i] ?? nil,
                        size: rect.size, movable: true
                    )
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(drag(r, t: t, base: offset))
                }
                groupLabel(r.status.name, box: LayoutEngine.boundingBox(placedTheirs), t: t)
                ForEach(Array(bridges.enumerated()), id: \.offset) { _, b in
                    LinkBadge()
                        .position(t.point(x: b.midX, y: b.midY))
                        .allowsHitTesting(false)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06)))
        .environment(\.colorScheme, .dark)
    }

    private func groupLabel(_ text: String, box: IRect?, t: CanvasTransform) -> some View {
        let b = box.map(t.rect) ?? .zero
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .fixedSize()
            .position(x: b.midX, y: b.maxY + 16)
            .allowsHitTesting(false)
    }

    private func tile(name: String, isMain: Bool, wallpaper: Data?, size: CGSize, movable: Bool) -> some View {
        ZStack {
            if let wallpaper, let image = NSImage(data: wallpaper) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.25), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) {
            if isMain { Rectangle().fill(Color.white.opacity(0.85)).frame(height: 3) }
        }
        .overlay(alignment: .bottomLeading) {
            Text(name)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.8), radius: 2)
                .padding(4)
                .lineLimit(1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(movable ? Color.blue.opacity(0.7) : Color.white.opacity(0.3), lineWidth: movable ? 1.5 : 1))
        .shadow(color: movable ? .blue.opacity(0.3) : .black.opacity(0.4), radius: movable ? 8 : 4)
        .contentShape(Rectangle())
    }

    private func drag(_ r: (status: DeviceStatus, uc: String), t: CanvasTransform, base: IPoint) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart.value == nil {
                    dragStart.value = base
                    frozen.value = t
                }
                guard let start = dragStart.value, let f = frozen.value else { return }
                let proposed = IPoint(
                    x: start.x + Int((value.translation.width / f.scale).rounded()),
                    y: start.y + Int((value.translation.height / f.scale).rounded()))
                let threshold =
                    NSEvent.modifierFlags.contains(.option) ? 0 : max(model.settings.snapThreshold, Int(14 / f.scale))
                dragOffset.value = LayoutEngine.snapGroup(
                    remoteDisplays(r.status).map(\.frame), proposed: proposed, others: localDisplays.map(\.frame),
                    threshold: threshold)
            }
            .onEnded { _ in
                if let o = dragOffset.value, let me {
                    let moved = remoteDisplays(r.status).map {
                        UCDisplay(uuid: $0.uuid, frame: $0.frame.offsetBy(dx: o.x, dy: o.y))
                    }
                    model.applyUniversalControl(
                        UCGeometry.link(device1: r.uc, displays1: moved, device2: me, displays2: localDisplays))
                }
                dragStart.value = nil
                dragOffset.value = nil
                withAnimation(.easeInOut(duration: 0.2)) { frozen.value = nil }
            }
    }

    private func localDragGesture(
        _ d: LiveDisplay, r: (status: DeviceStatus, uc: String), t: CanvasTransform, remoteOffset: IPoint,
        placedTheirs: [IRect]
    ) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if localDrag.value == nil {
                    localDrag.value = (d.id, d.frame, d.frame)
                    frozen.value = t
                }
                guard let drag = localDrag.value, let f = frozen.value else { return }
                let proposed = drag.start.offsetBy(
                    dx: Int((value.translation.width / f.scale).rounded()),
                    dy: Int((value.translation.height / f.scale).rounded()))
                let threshold =
                    NSEvent.modifierFlags.contains(.option) ? 0 : max(model.settings.snapThreshold, Int(14 / f.scale))
                // Attach to this Mac's other displays; snap to and avoid the other Mac's.
                let items = model.displays.map { LayoutItem(id: String($0.id), rect: $0.frame) }
                let snapped = LayoutEngine.snap(
                    String(d.id), proposed: proposed, in: items, threshold: threshold, context: placedTheirs)
                localDrag.value = (drag.id, drag.start, snapped)
            }
            .onEnded { _ in
                if let drag = localDrag.value, drag.rect != drag.start {
                    model.moveLocalDisplay(
                        drag.id, to: drag.rect, remoteDevice: r.uc, remoteDisplays: remoteDisplays(r.status),
                        remoteOffset: remoteOffset)
                }
                localDrag.value = nil
                withAnimation(.easeInOut(duration: 0.2)) { frozen.value = nil }
            }
    }

    // MARK: - Cards

    private func linkCard(_ r: (status: DeviceStatus, uc: String)) -> some View {
        let link = me.flatMap { model.universalControl?.link(from: r.uc, to: $0) }
        let theirName = { (uuid: String) in
            r.status.displays.first { $0.identity.uuid == uuid }?.identity.name ?? String(localized: "display")
        }
        let myName = { (uuid: String) in model.displays.first { $0.identity.uuid == uuid }?.identity.name ?? String(localized: "display")
        }
        return HStack(spacing: 12) {
            Image(systemName: link == nil ? "link.badge.plus" : "link").foregroundStyle(.blue).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                if let link {
                    Text("\(r.status.name)'s \(theirName(link.display1)) touches your \(myName(link.display2))")
                        .font(.callout.weight(.medium))
                    Text("Universal Control link: \(link.summary)").font(.caption.monospaced()).foregroundStyle(.secondary)
                } else {
                    Text("Not linked yet. Drag \(r.status.name)'s displays next to yours.").font(.callout)
                }
            }
            Spacer()
            Button("Undo Last Change") { model.undoUniversalControl() }
                .disabled(!UCBridge.canUndo)
            Button("Reload") { model.refreshUniversalControl() }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var wakeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("When this Mac wakes or is unlocked, wake my other Macs too", isOn: $model.settings.wakeOtherMacs)
                Spacer()
                Button("Wake Other Mac Now") { model.wakeOtherMacs() }
                    .disabled(model.devices.filter { $0.deviceID != model.deviceID }.isEmpty)
            }
            Text(
                "If the other Mac is fully asleep it's woken with Wake-on-LAN, which needs “Wake for network access” in its Energy settings."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var resetCard: some View {
        let others = model.peers.map(\.name)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue).font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Universal Control stopped working?").font(.callout.weight(.medium))
                Text(
                    others.isEmpty
                        ? "Restarts the services Universal Control runs on, on this Mac, then puts your arrangement back if it was lost. Open Universal Display Magnet on the other Mac to reset it too."
                        : "Restarts the services Universal Control runs on, on this Mac and on \(others.formatted(.list(type: .and))) over your network, then puts your arrangement back if it was lost. Takes about 10 seconds."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.resettingUniversalControl {
                ProgressView().controlSize(.small)
            }
            Button("Reset Universal Control") { model.resetUniversalControl() }
                .disabled(model.resettingUniversalControl || !UCBridge.isAvailable)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func openDisplaysSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
