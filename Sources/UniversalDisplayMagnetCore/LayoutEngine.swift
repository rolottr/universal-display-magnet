import Foundation

/// One display in an arrangement being edited or applied.
public struct LayoutItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var rect: IRect

    public init(id: String, rect: IRect) {
        self.id = id
        self.rect = rect
    }
}

/// Two displays that share an edge segment.
public struct Adjacency: Hashable, Sendable {
    /// The display whose `side` the other one is attached to.
    public var a: String
    public var b: String
    public var side: Side
    /// Middle of the shared segment, in layout coordinates.
    public var midX: Double
    public var midY: Double
    public var length: Int
}

/// Pure arrangement math. macOS requires every display to touch the group and
/// silently "fixes" layouts that float or overlap — which is exactly the random
/// shuffling System Settings produces. Everything in here guarantees layouts
/// where each display shares a real edge segment with another and nothing
/// overlaps, so what we hand to CoreGraphics is what lands on screen.
public enum LayoutEngine {
    /// Shared-edge length we aim for when generating placements, so displays
    /// don't hang off each other by a sliver the cursor can barely cross.
    public static let preferredSharedEdge = 100

    // MARK: - Relationships

    /// Length of the edge segment `a` and `b` share (0 when they don't touch).
    public static func sharedEdge(_ a: IRect, _ b: IRect) -> Int {
        var best = 0
        if a.maxX == b.minX || b.maxX == a.minX {
            best = max(best, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        }
        if a.maxY == b.minY || b.maxY == a.minY {
            best = max(best, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        }
        return max(0, best)
    }

    public static func adjacencies(_ items: [LayoutItem]) -> [Adjacency] {
        var result: [Adjacency] = []
        for i in items.indices {
            for j in items.indices where j > i {
                let a = items[i].rect
                let b = items[j].rect
                let length = sharedEdge(a, b)
                guard length > 0 else { continue }
                let side: Side
                let mid: (Double, Double)
                if a.maxX == b.minX || b.maxX == a.minX {
                    side = a.maxX == b.minX ? .right : .left
                    let y = (Double(max(a.minY, b.minY)) + Double(min(a.maxY, b.maxY))) / 2
                    mid = (Double(side == .right ? a.maxX : a.minX), y)
                } else {
                    side = a.maxY == b.minY ? .below : .above
                    let x = (Double(max(a.minX, b.minX)) + Double(min(a.maxX, b.maxX))) / 2
                    mid = (x, Double(side == .below ? a.maxY : a.minY))
                }
                result.append(
                    Adjacency(a: items[i].id, b: items[j].id, side: side, midX: mid.0, midY: mid.1, length: length))
            }
        }
        return result
    }

    public static func hasOverlaps(_ items: [LayoutItem]) -> Bool {
        for i in items.indices {
            for j in items.indices where j > i && items[i].rect.overlaps(items[j].rect) {
                return true
            }
        }
        return false
    }

    /// Every display reachable from every other through shared edges.
    public static func isConnected(_ items: [LayoutItem]) -> Bool {
        guard items.count > 1 else { return true }
        var seen: Set<Int> = [0]
        var stack = [0]
        while let i = stack.popLast() {
            for j in items.indices where !seen.contains(j) && sharedEdge(items[i].rect, items[j].rect) > 0 {
                seen.insert(j)
                stack.append(j)
            }
        }
        return seen.count == items.count
    }

    /// A layout macOS will accept as-is.
    public static func isValid(_ items: [LayoutItem]) -> Bool {
        isConnected(items) && !hasOverlaps(items)
    }

    public static func boundingBox(_ rects: [IRect]) -> IRect? {
        guard let first = rects.first else { return nil }
        var minX = first.minX, minY = first.minY, maxX = first.maxX, maxY = first.maxY
        for r in rects.dropFirst() {
            minX = min(minX, r.minX)
            minY = min(minY, r.minY)
            maxX = max(maxX, r.maxX)
            maxY = max(maxY, r.maxY)
        }
        return IRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Placement

    /// Rectangle of size `width`×`height` flush against `side` of `anchor`.
    public static func placed(
        width: Int, height: Int, side: Side, of anchor: IRect,
        alignment: EdgeAlignment = .center, offset: Int = 0
    ) -> IRect {
        switch side {
        case .left, .right:
            let x = side == .right ? anchor.maxX : anchor.minX - width
            let y: Int
            switch alignment {
            case .start: y = anchor.minY
            case .center: y = anchor.minY + (anchor.height - height) / 2
            case .end: y = anchor.maxY - height
            }
            return IRect(x: x, y: y + offset, width: width, height: height)
        case .above, .below:
            let y = side == .below ? anchor.maxY : anchor.minY - height
            let x: Int
            switch alignment {
            case .start: x = anchor.minX
            case .center: x = anchor.minX + (anchor.width - width) / 2
            case .end: x = anchor.maxX - width
            }
            return IRect(x: x + offset, y: y, width: width, height: height)
        }
    }

    /// Place display `id` against `side` of `anchorID`, then re-seat anything
    /// the move left floating or overlapped. The anchor never moves.
    public static func place(
        _ id: String, side: Side, of anchorID: String, alignment: EdgeAlignment = .center,
        in items: [LayoutItem]
    ) -> [LayoutItem] {
        guard id != anchorID,
            let anchor = items.first(where: { $0.id == anchorID }),
            let index = items.firstIndex(where: { $0.id == id })
        else { return items }
        var result = items
        let r = result[index].rect
        result[index].rect = placed(width: r.width, height: r.height, side: side, of: anchor.rect, alignment: alignment)
        return compact(result, priority: [anchorID, id])
    }

    /// Re-align display `id` along the edge it shares with its main neighbour.
    public static func align(_ id: String, _ alignment: EdgeAlignment, in items: [LayoutItem]) -> [LayoutItem] {
        guard let edge = adjacencies(items)
            .filter({ $0.a == id || $0.b == id })
            .max(by: { $0.length < $1.length })
        else { return items }
        // Express the relationship as "id sits on <side> of neighbour".
        let neighbour = edge.a == id ? edge.b : edge.a
        let side: Side
        if edge.a == neighbour {
            side = edge.side
        } else {
            switch edge.side {
            case .left: side = .right
            case .right: side = .left
            case .above: side = .below
            case .below: side = .above
            }
        }
        return place(id, side: side, of: neighbour, alignment: alignment, in: items)
    }

    // MARK: - Magnetic snapping

    /// The closest valid position to `proposed` for display `id`: flush against
    /// at least one other display, overlapping none, with its edges/centre pulled
    /// onto nearby edges/centres of the others when within `threshold`.
    ///
    /// `context` holds displays that must not be overlapped and that edges snap
    /// to, but that don't count as attachment (another Mac's displays: this
    /// Mac's own displays must stay connected among themselves).
    public static func snap(
        _ id: String, proposed: IRect, in items: [LayoutItem], threshold: Int, context: [IRect] = []
    ) -> IRect {
        let others = items.filter { $0.id != id }.map(\.rect)
        guard !others.isEmpty else { return proposed }
        let obstacles = others + context

        var best: IRect?
        var bestDistance = Double.infinity
        for anchor in others {
            for side in Side.allCases {
                for candidate in candidates(
                    for: proposed, side: side, anchor: anchor, others: obstacles, threshold: threshold)
                where !obstacles.contains(where: { $0.overlaps(candidate) }) {
                    let dx = Double(candidate.x - proposed.x)
                    let dy = Double(candidate.y - proposed.y)
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < bestDistance {
                        bestDistance = d
                        best = candidate
                    }
                }
            }
        }
        return best ?? proposed
    }

    /// Positions flush against `side` of `anchor`, sliding along that edge.
    private static func candidates(
        for proposed: IRect, side: Side, anchor: IRect, others: [IRect], threshold: Int
    ) -> [IRect] {
        let w = proposed.width
        let h = proposed.height
        if side.isHorizontal {
            let x = side == .right ? anchor.maxX : anchor.minX - w
            let need = min(preferredSharedEdge, h, anchor.height)
            let lo = anchor.minY - h + need
            let hi = anchor.maxY - need
            guard lo <= hi else { return [] }
            var ys: [Int] = []
            ys.append(snapped(proposed.y, size: h, targets: others, horizontal: false, threshold: threshold))
            // Slide past every other display's edge so a crowded edge still
            // offers a free slot.
            for o in others {
                ys.append(o.maxY)
                ys.append(o.minY - h)
            }
            return Set(ys.map { clamp($0, lo, hi) }).map { IRect(x: x, y: $0, width: w, height: h) }
        } else {
            let y = side == .below ? anchor.maxY : anchor.minY - h
            let need = min(preferredSharedEdge, w, anchor.width)
            let lo = anchor.minX - w + need
            let hi = anchor.maxX - need
            guard lo <= hi else { return [] }
            var xs: [Int] = []
            xs.append(snapped(proposed.x, size: w, targets: others, horizontal: true, threshold: threshold))
            for o in others {
                xs.append(o.maxX)
                xs.append(o.minX - w)
            }
            return Set(xs.map { clamp($0, lo, hi) }).map { IRect(x: $0, y: y, width: w, height: h) }
        }
    }

    /// Pull `value` (an origin coordinate) onto the nearest start/centre/end
    /// alignment with any target, if within `threshold`.
    private static func snapped(_ value: Int, size: Int, targets: [IRect], horizontal: Bool, threshold: Int) -> Int {
        guard threshold > 0 else { return value }
        var best = value
        var bestDelta = threshold + 1
        for t in targets {
            // Align starts, ends or centres, or sit edge-to-edge beside it.
            let lines: [Int] =
                horizontal
                ? [t.minX, t.maxX - size, Int((t.midX - Double(size) / 2).rounded()), t.maxX, t.minX - size]
                : [t.minY, t.maxY - size, Int((t.midY - Double(size) / 2).rounded()), t.maxY, t.minY - size]
            for line in lines where abs(line - value) < bestDelta {
                bestDelta = abs(line - value)
                best = line
            }
        }
        return best
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

    // MARK: - Snap all together

    /// Turn any rough arrangement into a valid one while keeping each display
    /// as close as possible to where it was. Displays are seated one at a
    /// time — `priority` ids first (the first never moves), then whichever is
    /// nearest to the already-seated group — and only displays that float or
    /// overlap get moved. Returns items in their original order.
    public static func compact(
        _ items: [LayoutItem], priority: [String] = [], alignThreshold: Int = 0
    ) -> [LayoutItem] {
        guard items.count > 1 else { return items }
        var remaining = items
        var seated: [LayoutItem] = []

        func take(_ id: String) -> LayoutItem? {
            guard let i = remaining.firstIndex(where: { $0.id == id }) else { return nil }
            return remaining.remove(at: i)
        }

        let ordered = priority.filter { id in items.contains { $0.id == id } }
        let firstID = ordered.first ?? items.max(by: { $0.rect.area < $1.rect.area })!.id
        seated.append(take(firstID)!)
        var queue = ordered.filter { $0 != firstID }

        while !remaining.isEmpty {
            let next: LayoutItem
            if let id = queue.first {
                queue.removeFirst()
                guard let item = take(id) else { continue }
                next = item
            } else {
                let rects = seated.map(\.rect)
                let pick = remaining.indices.min { a, b in
                    let ga = rects.map { $0.gap(to: remaining[a].rect) }.min()!
                    let gb = rects.map { $0.gap(to: remaining[b].rect) }.min()!
                    return ga == gb ? remaining[a].rect.area > remaining[b].rect.area : ga < gb
                }!
                next = remaining.remove(at: pick)
            }

            let rects = seated.map(\.rect)
            let fits =
                !rects.contains { $0.overlaps(next.rect) }
                && rects.contains { sharedEdge($0, next.rect) > 0 }
            if fits && alignThreshold == 0 {
                seated.append(next)
            } else {
                let rect = snap(next.id, proposed: next.rect, in: seated + [next], threshold: alignThreshold)
                seated.append(LayoutItem(id: next.id, rect: rect))
            }
        }
        return items.map { item in seated.first { $0.id == item.id }! }
    }

    /// Shift everything so display `mainID` sits at (0,0) — macOS treats the
    /// display at the origin as the main one (menu bar, Dock, new windows).
    public static func normalized(_ items: [LayoutItem], mainID: String) -> [LayoutItem] {
        guard let main = items.first(where: { $0.id == mainID }) else { return items }
        let dx = -main.rect.x
        let dy = -main.rect.y
        return items.map { LayoutItem(id: $0.id, rect: $0.rect.offsetBy(dx: dx, dy: dy)) }
    }
}
