import Foundation

/// A Universal Control link in plain values: the point at `offset1` along
/// `edge` of display 1 is pinned to the point at `offset2` along the opposite
/// edge of display 2. Offsets run 0…65535 from top (left/right edges) or from
/// left (top/bottom edges). Universal Control keeps one such link per pair of
/// Macs; with each Mac's own arrangement it places every display, and the
/// pointer crosses wherever displays of the two Macs touch.
public struct UCLink: Hashable, Sendable, Codable {
    public enum Edge: Int, Codable, Sendable, CaseIterable {
        case top = 0, left = 1, bottom = 2, right = 3

        public var opposite: Edge {
            switch self {
            case .top: return .bottom
            case .bottom: return .top
            case .left: return .right
            case .right: return .left
            }
        }

        var side: Side {
            switch self {
            case .top: return .above
            case .bottom: return .below
            case .left: return .left
            case .right: return .right
            }
        }
    }

    public var device1: String
    public var display1: String
    public var device2: String
    public var display2: String
    public var edge: Edge
    public var offset1: UInt16
    public var offset2: UInt16

    public init(
        device1: String, display1: String, device2: String, display2: String, edge: Edge, offset1: UInt16,
        offset2: UInt16
    ) {
        self.device1 = device1
        self.display1 = display1
        self.device2 = device2
        self.display2 = display2
        self.edge = edge
        self.offset1 = offset1
        self.offset2 = offset2
    }

    /// "right@0.43=left@0.50", the notation Universal Control logs.
    public var summary: String {
        String(
            format: "%@@%.2f=%@@%.2f", "\(edge)", Double(offset1) / 65535, "\(edge.opposite)", Double(offset2) / 65535)
    }
}

/// One display on a Mac, in that Mac's own coordinates.
public struct UCDisplay: Hashable, Sendable {
    public var uuid: String
    public var frame: IRect

    public init(uuid: String, frame: IRect) {
        self.uuid = uuid
        self.frame = frame
    }
}

public enum UCGeometry {
    /// Point on `edge` of `r` at fraction `f` (0…1).
    static func point(on r: IRect, edge: UCLink.Edge, fraction f: Double) -> (x: Double, y: Double) {
        switch edge {
        case .top: return (Double(r.minX) + f * Double(r.width), Double(r.minY))
        case .bottom: return (Double(r.minX) + f * Double(r.width), Double(r.maxY))
        case .left: return (Double(r.minX), Double(r.minY) + f * Double(r.height))
        case .right: return (Double(r.maxX), Double(r.minY) + f * Double(r.height))
        }
    }

    static func fraction(of p: (x: Double, y: Double), on r: IRect, edge: UCLink.Edge) -> Double {
        let f: Double
        switch edge {
        case .top, .bottom: f = (p.x - Double(r.minX)) / Double(r.width)
        case .left, .right: f = (p.y - Double(r.minY)) / Double(r.height)
        }
        return min(max(f, 0), 1)
    }

    static func encode(_ f: Double) -> UInt16 { UInt16((min(max(f, 0), 1) * 65535).rounded()) }

    /// Where the group of displays `device1` sits relative to `device2`'s
    /// coordinates, as implied by `link`: the translation to add to device 1's
    /// own frames. nil if a display named in the link isn't in the lists.
    public static func offset(of link: UCLink, displays1: [UCDisplay], displays2: [UCDisplay]) -> IPoint? {
        guard let d1 = displays1.first(where: { $0.uuid == link.display1 }),
            let d2 = displays2.first(where: { $0.uuid == link.display2 })
        else { return nil }
        let p1 = point(on: d1.frame, edge: link.edge, fraction: Double(link.offset1) / 65535)
        let p2 = point(on: d2.frame, edge: link.edge.opposite, fraction: Double(link.offset2) / 65535)
        return IPoint(x: Int((p2.x - p1.x).rounded()), y: Int((p2.y - p1.y).rounded()))
    }

    /// The link that reproduces an arrangement: group 1 (already translated
    /// onto group 2's coordinates) touching group 2. Picks the pair of
    /// displays sharing the longest edge and pins the middle of that shared
    /// segment. nil when the groups don't touch.
    public static func link(
        device1: String, displays1: [UCDisplay], device2: String, displays2: [UCDisplay]
    ) -> UCLink? {
        var best: (d1: UCDisplay, d2: UCDisplay, length: Int)?
        for a in displays1 {
            for b in displays2 {
                let length = LayoutEngine.sharedEdge(a.frame, b.frame)
                if length > 0, length > (best?.length ?? 0) { best = (a, b, length) }
            }
        }
        guard let (a, b, _) = best else { return nil }
        let r1 = a.frame
        let r2 = b.frame
        let edge: UCLink.Edge
        let mid: (x: Double, y: Double)
        if r1.maxX == r2.minX || r1.minX == r2.maxX {
            edge = r1.maxX == r2.minX ? .right : .left
            let y = (Double(max(r1.minY, r2.minY)) + Double(min(r1.maxY, r2.maxY))) / 2
            mid = (Double(edge == .right ? r1.maxX : r1.minX), y)
        } else {
            edge = r1.maxY == r2.minY ? .bottom : .top
            let x = (Double(max(r1.minX, r2.minX)) + Double(min(r1.maxX, r2.maxX))) / 2
            mid = (x, Double(edge == .bottom ? r1.maxY : r1.minY))
        }
        return UCLink(
            device1: device1, display1: a.uuid, device2: device2, display2: b.uuid, edge: edge,
            offset1: encode(fraction(of: mid, on: r1, edge: edge)),
            offset2: encode(fraction(of: mid, on: r2, edge: edge.opposite)))
    }
}
