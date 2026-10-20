import Foundation
import Testing

@testable import UniversalDisplayMagnetCore

@Suite struct UCLinkTests {
    // This Mac: LG ultrawide with the ANMITE below it.
    let studio = [
        UCDisplay(uuid: "LG", frame: IRect(x: 0, y: 0, width: 3440, height: 1440)),
        UCDisplay(uuid: "ANMITE", frame: IRect(x: 1199, y: 1440, width: 1920, height: 1200)),
    ]
    // Other Mac: a big display with a smaller one below (in its own coordinates).
    let other = [
        UCDisplay(uuid: "DELL", frame: IRect(x: 0, y: 0, width: 2560, height: 1440)),
        UCDisplay(uuid: "PORTABLE", frame: IRect(x: 320, y: 1440, width: 1920, height: 1080)),
    ]

    @Test func theRealLinkOnThisMacMapsToAPlacement() {
        // Read from Universal Control: 7DDD/right@0.43 = left@0.50/LG.
        let link = UCLink(
            device1: "B", display1: "DELL", device2: "A", display2: "LG", edge: .right, offset1: 27887, offset2: 32767)
        let o = UCGeometry.offset(of: link, displays1: other, displays2: studio)!
        // DELL's right edge sits on the LG's left edge…
        #expect(o.x == -2560)
        // …with 43% down the DELL at 50% down the LG.
        #expect(o.y == Int((0.5 * 1440 - Double(27887) / 65535 * 1440).rounded()))
        #expect(link.summary == "right@0.43=left@0.50")
    }

    @Test func linkFromASnappedLayoutRoundTrips() {
        // Other Mac's displays to the left of the LG, tops aligned (like the screenshot).
        let t = IPoint(x: -2560, y: 0)
        let moved = other.map { UCDisplay(uuid: $0.uuid, frame: $0.frame.offsetBy(dx: t.x, dy: t.y)) }
        let link = UCGeometry.link(device1: "B", displays1: moved, device2: "A", displays2: studio)!
        #expect(link.display1 == "DELL" && link.display2 == "LG")
        #expect(link.edge == .right)
        // Applying the link to the untranslated displays gives back the same translation.
        #expect(UCGeometry.offset(of: link, displays1: other, displays2: studio) == t)
    }

    @Test func groupsThatDontTouchHaveNoLink() {
        let far = other.map { UCDisplay(uuid: $0.uuid, frame: $0.frame.offsetBy(dx: -9000, dy: 0)) }
        #expect(UCGeometry.link(device1: "B", displays1: far, device2: "A", displays2: studio) == nil)
    }

    @Test func verticalLinksUseHorizontalFractions() {
        // Other Mac stacked above the LG, centred.
        let t = IPoint(x: 440, y: -2520)
        let moved = other.map { UCDisplay(uuid: $0.uuid, frame: $0.frame.offsetBy(dx: t.x, dy: t.y)) }
        let link = UCGeometry.link(device1: "B", displays1: moved, device2: "A", displays2: studio)!
        #expect(link.edge == .bottom)
        #expect(link.display1 == "PORTABLE")
        let back = UCGeometry.offset(of: link, displays1: other, displays2: studio)!
        #expect(abs(back.x - t.x) <= 1 && abs(back.y - t.y) <= 1)
    }
}

@Suite struct UCCrossMacTests {
    // The setup in the screenshot: Mac mini (LG 4K over TYPE C) left of the
    // Studio (LG WQHD over ANMITE), both rows touching.
    let mini = [
        UCDisplay(uuid: "LG4K", frame: IRect(x: -2560, y: 0, width: 2560, height: 1440)),
        UCDisplay(uuid: "TYPEC", frame: IRect(x: -1600, y: 1440, width: 1600, height: 1000)),
    ]
    let studio = [
        UCDisplay(uuid: "LGWQHD", frame: IRect(x: 0, y: 0, width: 3440, height: 1440)),
        UCDisplay(uuid: "ANMITE", frame: IRect(x: 0, y: 1440, width: 1920, height: 1200)),
    ]

    @Test func theLongestTouchingPairAnchorsTheLink() {
        let link = UCGeometry.link(device1: "MINI", displays1: mini, device2: "STUDIO", displays2: studio)!
        #expect(link.display1 == "LG4K" && link.display2 == "LGWQHD")
        // The single link reproduces the whole placement, bottom row included.
        let local = mini.map { UCDisplay(uuid: $0.uuid, frame: $0.frame.offsetBy(dx: 2560, dy: 0)) }
        let o = UCGeometry.offset(of: link, displays1: local, displays2: studio)!
        #expect(abs(o.x + 2560) <= 1 && abs(o.y) <= 1)
    }

    @Test func aDisplaySnapsEdgeToEdgeAgainstTheOtherMac() {
        // Drag the ANMITE (attached below the LG WQHD) towards the TYPE C: it
        // must end flush against TYPE C's right edge while staying on the LG.
        let items = studio.map { LayoutItem(id: $0.uuid, rect: $0.frame) }
        let proposed = IRect(x: 25, y: 1440, width: 1920, height: 1200)
        let r = LayoutEngine.snap("ANMITE", proposed: proposed, in: items, threshold: 60, context: mini.map(\.frame))
        #expect(r.x == 0)  // TYPEC.maxX == 0
        #expect(r.y == 1440)
        // Never overlaps the other Mac's display.
        let into = IRect(x: -300, y: 1440, width: 1920, height: 1200)
        let r2 = LayoutEngine.snap("ANMITE", proposed: into, in: items, threshold: 0, context: mini.map(\.frame))
        #expect(!mini.contains { $0.frame.overlaps(r2) })
    }
}
