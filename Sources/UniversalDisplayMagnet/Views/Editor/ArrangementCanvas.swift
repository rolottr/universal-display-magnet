import UniversalDisplayMagnetCore
import SwiftUI

/// Maps layout points to canvas points.
struct CanvasTransform: Equatable {
    var scale: CGFloat
    var dx: CGFloat
    var dy: CGFloat

    func rect(_ r: IRect) -> CGRect {
        CGRect(
            x: CGFloat(r.x) * scale + dx, y: CGFloat(r.y) * scale + dy, width: CGFloat(r.width) * scale,
            height: CGFloat(r.height) * scale)
    }

    func point(x: Double, y: Double) -> CGPoint { CGPoint(x: CGFloat(x) * scale + dx, y: CGFloat(y) * scale + dy) }

    /// Fit `rects` into `size` with breathing room for the arrow buttons.
    static func fit(_ rects: [IRect], in size: CGSize, fill: CGFloat = 0.72) -> CanvasTransform {
        guard let box = LayoutEngine.boundingBox(rects), box.width > 0, box.height > 0, size.width > 0 else {
            return CanvasTransform(scale: 0.1, dx: size.width / 2, dy: size.height / 2)
        }
        let s = min(size.width * fill / CGFloat(box.width), size.height * fill / CGFloat(box.height))
        return CanvasTransform(
            scale: s, dx: (size.width - CGFloat(box.width) * s) / 2 - CGFloat(box.x) * s,
            dy: (size.height - CGFloat(box.height) * s) / 2 - CGFloat(box.y) * s)
    }
}

struct ArrangementCanvas: View {
    @ObservedObject var editor: EditorModel
    var snapThreshold: Int
    var interactive = true

    @StateObject private var frozenState = ViewState<CanvasTransform?>(nil)
    private var frozen: CanvasTransform? {
        get { frozenState.value }
        nonmutating set { frozenState.value = newValue }
    }
    @StateObject private var dragStartState = ViewState<IRect?>(nil)
    private var dragStart: IRect? {
        get { dragStartState.value }
        nonmutating set { dragStartState.value = newValue }
    }
    @StateObject private var pickingState = ViewState<Side?>(nil)
    private var pickingSide: Side? {
        get { pickingState.value }
        nonmutating set { pickingState.value = newValue }
    }

    var body: some View {
        GeometryReader { geo in
            let t = frozen ?? CanvasTransform.fit(editor.items.map(\.rect), in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { editor.selected = nil }

                ForEach(editor.items) { item in
                    displayBlock(item, t: t)
                }

                ForEach(Array(LayoutEngine.adjacencies(editor.layoutItems).enumerated()), id: \.offset) { _, adj in
                    LinkBadge()
                        .position(t.point(x: adj.midX, y: adj.midY))
                        .allowsHitTesting(false)
                }

                if interactive, frozen == nil, let id = editor.selected, let item = editor.item(id),
                    editor.items.count > 1
                {
                    ForEach(freeSides(of: id), id: \.self) { side in
                        arrow(side, around: t.rect(item.rect), anchor: id)
                    }
                }
            }
        }
    }

    // MARK: - Display block

    private func displayBlock(_ item: EditorModel.Item, t: CanvasTransform) -> some View {
        let rect = t.rect(item.rect)
        let selected = editor.selected == item.id
        let isMain = editor.mainID == item.id
        let nameSize = max(8, min(13, rect.height / 7))

        return RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.blue.opacity(0.25) : Color(white: 0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(selected ? Color.blue.opacity(0.85) : Color.white.opacity(0.3), lineWidth: selected ? 1.5 : 1)
            )
            .overlay(alignment: .top) {
                if isMain {
                    // The menu bar lives on the main display.
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white.opacity(0.75))
                        .frame(height: max(3, rect.height * 0.035))
                        .padding(.horizontal, 6)
                        .padding(.top, 5)
                }
            }
            .overlay(
                VStack(spacing: 3) {
                    Text(item.name)
                        .font(.system(size: nameSize, weight: .medium))
                        .foregroundColor(selected ? .white.opacity(0.95) : .white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(item.detail)
                        .font(.system(size: max(7, nameSize - 2), design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    if isMain {
                        Text("MAIN")
                            .font(.system(size: max(7, nameSize - 4), weight: .semibold))
                            .tracking(1.2)
                            .foregroundColor(.blue.opacity(0.8))
                    }
                }
                .padding(6)
            )
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .shadow(color: selected ? .blue.opacity(0.35) : .clear, radius: 12)
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture {
                guard interactive else { return }
                editor.selected = item.id
            }
            .gesture(interactive ? drag(item, t: t) : nil)
            .animation(frozen == nil ? .spring(response: 0.28, dampingFraction: 0.82) : nil, value: item.rect)
    }

    private func drag(_ item: EditorModel.Item, t: CanvasTransform) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = item.rect
                    frozen = t  // keep scale steady while the bounding box changes
                    editor.selected = item.id
                }
                guard let start = dragStart, let f = frozen else { return }
                let proposed = start.offsetBy(
                    dx: Int((value.translation.width / f.scale).rounded()),
                    dy: Int((value.translation.height / f.scale).rounded()))
                // Magnet strength is ~14 screen points whatever the zoom; ⌥ turns alignment off.
                let optionDown = NSEvent.modifierFlags.contains(.option)
                let threshold = optionDown ? 0 : max(snapThreshold, Int(14 / f.scale))
                editor.drag(item.id, to: proposed, threshold: threshold)
            }
            .onEnded { _ in
                dragStart = nil
                withAnimation(.easeInOut(duration: 0.2)) { frozen = nil }
            }
    }

    // MARK: - Direction arrows

    /// Sides with nothing attached yet (display-align only offers those).
    private func freeSides(of id: String) -> [Side] {
        let taken = LayoutEngine.adjacencies(editor.layoutItems).compactMap { adj -> Side? in
            if adj.a == id { return adj.side }
            guard adj.b == id else { return nil }
            switch adj.side {
            case .left: return .right
            case .right: return .left
            case .above: return .below
            case .below: return .above
            }
        }
        return Side.allCases.filter { !taken.contains($0) }
    }

    private func arrow(_ side: Side, around rect: CGRect, anchor: String) -> some View {
        let others = editor.items.filter { $0.id != anchor }
        let pos: CGPoint
        switch side {
        case .above: pos = CGPoint(x: rect.midX, y: rect.minY - 24)
        case .below: pos = CGPoint(x: rect.midX, y: rect.maxY + 24)
        case .left: pos = CGPoint(x: rect.minX - 24, y: rect.midY)
        case .right: pos = CGPoint(x: rect.maxX + 24, y: rect.midY)
        }
        return Button {
            if others.count == 1 {
                editor.place(others[0].id, side: side, of: anchor)
                editor.selected = anchor
            } else {
                pickingSide = side
            }
        } label: {
            ZStack {
                Circle().fill(Color.blue.opacity(0.12))
                Circle().strokeBorder(Color.blue.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                Image(systemName: glyph(side))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue.opacity(0.9))
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(others.count == 1 ? "Put \(others[0].name) \(phrase(side)) this display" : "Put a display \(phrase(side)) this one")
        .popover(
            isPresented: Binding(get: { pickingSide == side }, set: { if !$0 { pickingSide = nil } }),
            arrowEdge: popoverEdge(side)
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PLACE \(phrase(side).uppercased())")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.2)
                    .foregroundColor(.secondary)
                ForEach(others) { other in
                    Button {
                        pickingSide = nil
                        editor.place(other.id, side: side, of: anchor)
                        editor.selected = anchor
                    } label: {
                        HStack {
                            Image(systemName: "display")
                            Text(other.name)
                            Spacer()
                            Text(other.detail).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(minWidth: 240)
        }
        .position(pos)
        .transition(.scale.combined(with: .opacity))
    }

    private func glyph(_ side: Side) -> String {
        switch side {
        case .above: return "arrow.up"
        case .below: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    private func phrase(_ side: Side) -> String {
        switch side {
        case .above: return "above"
        case .below: return "below"
        case .left: return "left of"
        case .right: return "right of"
        }
    }

    private func popoverEdge(_ side: Side) -> Edge {
        switch side {
        case .above: return .bottom
        case .below: return .top
        case .left: return .trailing
        case .right: return .leading
        }
    }
}

/// The yellow chain on a shared edge (display-align's visual language).
struct LinkBadge: View {
    var body: some View {
        Image(systemName: "link")
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color.yellow.opacity(0.55))
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.black.opacity(0.85)))
            .overlay(Circle().fill(Color.yellow.opacity(0.07)))
    }
}

/// Read-only miniature of an arrangement (menu bar panel, device cards).
struct MiniMap: View {
    let rects: [(id: String, rect: IRect, name: String, isMain: Bool)]
    var highlight: Set<String> = []

    var body: some View {
        GeometryReader { geo in
            let t = CanvasTransform.fit(rects.map(\.rect), in: geo.size, fill: 0.9)
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.id) { r in
                    let rect = t.rect(r.rect)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(highlight.contains(r.id) ? Color.blue.opacity(0.3) : Color(white: 0.18))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.28), lineWidth: 0.75))
                        .overlay(alignment: .top) {
                            if r.isMain {
                                Rectangle().fill(Color.white.opacity(0.7)).frame(height: 2).padding(.horizontal, 3).padding(.top, 3)
                            }
                        }
                        .overlay(
                            Text(r.name)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(.white.opacity(0.65))
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .padding(3)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}
