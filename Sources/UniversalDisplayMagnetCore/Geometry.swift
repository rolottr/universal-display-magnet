import Foundation

/// Integer rectangle in the global display coordinate space (points, origin at
/// the top-left of the main display, y grows downward) — the same space
/// `CGDisplayBounds` and `CGConfigureDisplayOrigin` use.
public struct IRect: Codable, Hashable, Sendable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var midX: Double { Double(x) + Double(width) / 2 }
    public var midY: Double { Double(y) + Double(height) / 2 }
    public var area: Int { width * height }

    public func offsetBy(dx: Int, dy: Int) -> IRect {
        IRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    public func with(x: Int? = nil, y: Int? = nil) -> IRect {
        IRect(x: x ?? self.x, y: y ?? self.y, width: width, height: height)
    }

    /// True when the two rectangles share interior area (touching edges do not count).
    public func overlaps(_ other: IRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func intersectionArea(_ other: IRect) -> Int {
        let w = min(maxX, other.maxX) - max(minX, other.minX)
        let h = min(maxY, other.maxY) - max(minY, other.minY)
        return (w > 0 && h > 0) ? w * h : 0
    }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= Double(minX) && px < Double(maxX) && py >= Double(minY) && py < Double(maxY)
    }

    /// Smallest distance between the two rectangles' borders (0 when touching or overlapping).
    public func gap(to other: IRect) -> Double {
        let dx = max(0, max(other.minX - maxX, minX - other.maxX))
        let dy = max(0, max(other.minY - maxY, minY - other.maxY))
        return (Double(dx * dx + dy * dy)).squareRoot()
    }

    public var description: String { "(\(x),\(y) \(width)×\(height))" }
}

/// A side of a display, used to place another display flush against it.
public enum Side: String, Codable, CaseIterable, Sendable {
    case left, right, above, below

    public var isHorizontal: Bool { self == .left || self == .right }
}

/// Where a display sits along the edge it is attached to.
public enum EdgeAlignment: String, Codable, CaseIterable, Sendable {
    /// Top edges (left/right attach) or left edges (above/below attach) line up.
    case start
    case center
    /// Bottom edges (left/right attach) or right edges (above/below attach) line up.
    case end
}
