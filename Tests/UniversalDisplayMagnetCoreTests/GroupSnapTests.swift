import Foundation
import Testing

@testable import UniversalDisplayMagnetCore

@Suite struct GroupSnapTests {
    // Mac Studio: LG ultrawide + ANMITE below it. MacBook: built-in + a USB-C monitor.
    let studio = [IRect(x: 0, y: 0, width: 3440, height: 1440), IRect(x: 1199, y: 1440, width: 1920, height: 1200)]
    let macbook = [IRect(x: 0, y: 0, width: 1512, height: 982), IRect(x: 1512, y: -200, width: 1920, height: 1080)]

    @Test func groupSnapKeepsMonitorsRigidAndFlush() {
        // Drop the MacBook group overlapping the LG: it must end flush, not overlapping.
        let t = LayoutEngine.snapGroup(macbook, proposed: IPoint(x: 3000, y: 100), others: studio, threshold: 40)
        let moved = macbook.map { $0.offsetBy(dx: t.x, dy: t.y) }
        #expect(!moved.contains { m in studio.contains { $0.overlaps(m) } })
        let touching = moved.contains { m in studio.contains { LayoutEngine.sharedEdge($0, m) > 0 } }
        #expect(touching)
        #expect(moved[1].x - moved[0].x == 1512)  // internal arrangement untouched
    }

    @Test func wakeMessagesRoundTripThroughTheWire() throws {
        let secret = SyncSecret(passphrase: "k")
        var reader = SyncFrameReader()
        let body = try reader.append(try SyncFraming.encode(.wake, secret: secret))[0]
        #expect(try SyncFraming.decode(body, secret: secret).kind == .wake)
    }
}
