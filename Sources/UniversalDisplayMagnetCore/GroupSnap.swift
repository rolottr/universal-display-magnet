import Foundation

public struct IPoint: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

extension LayoutEngine {
    /// Move a rigid group of rectangles (one Mac's monitors) so that at least
    /// one of them sits flush against `others` without any overlap, as close
    /// as possible to translating it by `proposed`. Returns the translation.
    public static func snapGroup(
        _ group: [IRect], proposed: IPoint, others: [IRect], threshold: Int
    ) -> IPoint {
        guard !group.isEmpty, !others.isEmpty else { return proposed }
        var best: IPoint?
        var bestDistance = Double.infinity
        for g in group {
            let moved = g.offsetBy(dx: proposed.x, dy: proposed.y)
            for anchor in others {
                // Single-rect snap of this member, then carry the whole group.
                let solo = snap("m", proposed: moved, in: [LayoutItem(id: "a", rect: anchor), LayoutItem(id: "m", rect: moved)], threshold: threshold)
                let t = IPoint(x: proposed.x + solo.x - moved.x, y: proposed.y + solo.y - moved.y)
                let translated = group.map { $0.offsetBy(dx: t.x, dy: t.y) }
                guard !translated.contains(where: { r in others.contains { $0.overlaps(r) } }) else { continue }
                let d = hypot(Double(t.x - proposed.x), Double(t.y - proposed.y))
                if d < bestDistance {
                    bestDistance = d
                    best = t
                }
            }
        }
        return best ?? proposed
    }
}
