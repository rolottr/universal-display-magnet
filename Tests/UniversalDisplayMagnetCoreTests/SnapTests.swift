import Foundation
import Testing

@testable import UniversalDisplayMagnetCore

@Suite struct SnapTests {
    // LG ultrawide usable area (menu bar 25pt) and the ANMITE below it.
    let lg = IRect(x: 0, y: 25, width: 3440, height: 1415)
    let anmite = IRect(x: 1027, y: 1440, width: 1920, height: 1200)

    @Test func halvesAndQuartersTileWithoutGaps() {
        let left = GridRect(cols: 2, rows: 1, x: 0, y: 0, w: 1, h: 1).frame(in: lg)
        let right = GridRect(cols: 2, rows: 1, x: 1, y: 0, w: 1, h: 1).frame(in: lg)
        #expect(left == IRect(x: 0, y: 25, width: 1720, height: 1415))
        #expect(right.x == left.maxX && right.maxX == lg.maxX)
        let tl = GridRect(cols: 2, rows: 2, x: 0, y: 0, w: 1, h: 1).frame(in: lg)
        let bl = GridRect(cols: 2, rows: 2, x: 0, y: 1, w: 1, h: 1).frame(in: lg)
        #expect(bl.y == tl.maxY && bl.maxY == lg.maxY)
    }

    @Test func customRegionsUseAnyCells() {
        // A custom "centre two thirds" on a 6-column grid.
        let r = GridRect(cols: 6, rows: 1, x: 1, y: 0, w: 4, h: 1)
        #expect(r.frame(in: lg) == IRect(x: 573, y: 25, width: 2294, height: 1415))
        #expect(r.sizeLabel == "2/3 × 1")
    }

    @Test func centerKeepsSize() {
        let w = IRect(x: 10, y: 40, width: 1000, height: 800)
        let c = SnapGeometry.target(for: .center, window: w, area: lg, areas: [lg], previous: nil)
        #expect(c == IRect(x: 1220, y: 332, width: 1000, height: 800))
    }

    @Test func nextDisplayKeepsRelativePlacement() {
        // Right half of the LG → right half of the ANMITE.
        let w = IRect(x: 1720, y: 25, width: 1720, height: 1415)
        let n = SnapGeometry.target(for: .nextDisplay, window: w, area: lg, areas: [lg, anmite], previous: nil)
        #expect(n == IRect(x: 1027 + 960, y: 1440, width: 960, height: 1200))
        let back = SnapGeometry.target(for: .previousDisplay, window: n!, area: anmite, areas: [lg, anmite], previous: nil)
        #expect(back == w)
        // Only one display: nothing to do.
        #expect(SnapGeometry.target(for: .nextDisplay, window: w, area: lg, areas: [lg], previous: nil) == nil)
    }

    @Test func dragZonesMatchMagnet() {
        let screen = IRect(x: 0, y: 0, width: 3440, height: 1440)
        #expect(SnapGeometry.dragZone(x: 1, y: 700, screen: screen) == "left")
        #expect(SnapGeometry.dragZone(x: 3439, y: 700, screen: screen) == "right")
        #expect(SnapGeometry.dragZone(x: 1700, y: 1, screen: screen) == "maximize")
        #expect(SnapGeometry.dragZone(x: 1, y: 10, screen: screen) == "topLeft")
        #expect(SnapGeometry.dragZone(x: 3439, y: 1439, screen: screen) == "bottomRight")
        #expect(SnapGeometry.dragZone(x: 1700, y: 700, screen: screen) == nil)
    }

    @Test func defaultsHaveNoThirds() {
        let names = SnapDefaults.commands.map(\.name)
        #expect(!names.contains { $0.contains("Third") })
        #expect(names.contains("Next Display") && names.contains("Restore"))
    }
}
