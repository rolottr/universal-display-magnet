import Testing

@testable import UniversalDisplayMagnetCore

private func item(_ id: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> LayoutItem {
    LayoutItem(id: id, rect: IRect(x: x, y: y, width: w, height: h))
}

@Suite struct LayoutEngineTests {
    // The real setup on the Mac Studio this was built on: an LG ultrawide
    // and a portable USB-C ANMITE panel centred below it.
    let lg = item("lg", 0, 0, 3440, 1440)
    let anmite = item("anmite", 1199, 1440, 1920, 1200)

    @Test func sharedEdgeDetectsTouchingDisplays() {
        #expect(LayoutEngine.sharedEdge(lg.rect, anmite.rect) == 1920)
        #expect(LayoutEngine.sharedEdge(lg.rect, anmite.rect.offsetBy(dx: 0, dy: 1)) == 0)
        // Corner contact only is not an edge.
        #expect(LayoutEngine.sharedEdge(lg.rect, IRect(x: 3440, y: 1440, width: 100, height: 100)) == 0)
    }

    @Test func validLayoutIsConnectedWithoutOverlap() {
        #expect(LayoutEngine.isValid([lg, anmite]))
        #expect(!LayoutEngine.isValid([lg, item("anmite", 1199, 1500, 1920, 1200)]))  // floating
        #expect(!LayoutEngine.isValid([lg, item("anmite", 1199, 1000, 1920, 1200)]))  // overlapping
    }

    @Test func snapPullsAFloatingDisplayFlushAndAlignsCentres() {
        // Dropped roughly below the LG, slightly off-centre and with a gap.
        let proposed = IRect(x: 740, y: 1490, width: 1920, height: 1200)
        let snapped = LayoutEngine.snap("anmite", proposed: proposed, in: [lg, anmite], threshold: 40)
        #expect(snapped == IRect(x: 760, y: 1440, width: 1920, height: 1200))  // centred, flush
    }

    @Test func snapWithoutThresholdKeepsOffsetButAttaches() {
        let proposed = IRect(x: 500, y: 1600, width: 1920, height: 1200)
        let snapped = LayoutEngine.snap("anmite", proposed: proposed, in: [lg, anmite], threshold: 0)
        #expect(snapped == IRect(x: 500, y: 1440, width: 1920, height: 1200))
    }

    @Test func snapNeverOverlaps() {
        // Dragged straight onto the LG: must end up beside it, not on it.
        let proposed = IRect(x: 1000, y: 200, width: 1920, height: 1200)
        let snapped = LayoutEngine.snap("anmite", proposed: proposed, in: [lg, anmite], threshold: 40)
        #expect(!snapped.overlaps(lg.rect))
        #expect(LayoutEngine.sharedEdge(snapped, lg.rect) > 0)
    }

    @Test func snapFindsAFreeSlotOnACrowdedEdge() {
        let a = item("a", 0, 0, 1000, 1000)
        let b = item("b", 1000, 0, 1000, 1000)  // right of a
        let c = item("c", 1000, 300, 800, 500)  // wants the same spot
        let snapped = LayoutEngine.snap("c", proposed: c.rect, in: [a, b, c], threshold: 0)
        #expect(!snapped.overlaps(a.rect) && !snapped.overlaps(b.rect))
        #expect(LayoutEngine.isValid([a, b, LayoutItem(id: "c", rect: snapped)]))
    }

    @Test func compactRepairsAScatteredLayoutKeepingRelativeOrder() {
        // Three monitors left-to-right with gaps and a stray vertical offset —
        // what macOS leaves behind after a bad wake.
        let items = [
            item("left", -2500, 40, 2560, 1440),
            item("main", 0, 0, 3440, 1440),
            item("right", 3600, 300, 1920, 1080),
        ]
        let result = LayoutEngine.compact(items, priority: ["main"])
        #expect(LayoutEngine.isValid(result))
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0.rect) })
        #expect(byID["main"] == items[1].rect)  // anchor never moves
        #expect(byID["left"]!.maxX == 0)
        #expect(byID["right"]!.minX == 3440)
        #expect(byID["left"]!.y == 40)  // cross-axis offset preserved
        #expect(byID["right"]!.y == 300)
    }

    @Test func compactLeavesValidLayoutsAlone() {
        let result = LayoutEngine.compact([lg, anmite])
        #expect(result == [lg, anmite])
    }

    @Test func compactHandlesStackedDuplicatesOnTopOfEachOther() {
        // Two identical displays reported at the same origin.
        let items = [item("a", 0, 0, 1920, 1080), item("b", 0, 0, 1920, 1080), item("c", 0, 0, 1920, 1080)]
        let result = LayoutEngine.compact(items, priority: ["a"])
        #expect(LayoutEngine.isValid(result))
    }

    @Test func placeAgainstSideWithAlignment() {
        let result = LayoutEngine.place("anmite", side: .left, of: "lg", alignment: .end, in: [lg, anmite])
        let r = result.first { $0.id == "anmite" }!.rect
        #expect(r == IRect(x: -1920, y: 240, width: 1920, height: 1200))
        #expect(LayoutEngine.isValid(result))
    }

    @Test func placeReseatsDisplaysLeftFloating() {
        // a | b | c in a row; moving b below a must pull c back against a.
        let items = [item("a", 0, 0, 1000, 800), item("b", 1000, 0, 1000, 800), item("c", 2000, 0, 1000, 800)]
        let result = LayoutEngine.place("b", side: .below, of: "a", in: items)
        #expect(LayoutEngine.isValid(result))
        #expect(result.first { $0.id == "c" }!.rect.minX == 1000)
    }

    @Test func alignUsesTheSharedEdge() {
        let result = LayoutEngine.align("anmite", .start, in: [lg, anmite])
        #expect(result.first { $0.id == "anmite" }!.rect == IRect(x: 0, y: 1440, width: 1920, height: 1200))
    }

    @Test func normalizedPutsMainAtOrigin() {
        let result = LayoutEngine.normalized([lg, anmite], mainID: "anmite")
        #expect(result.first { $0.id == "anmite" }!.rect.x == 0)
        #expect(result.first { $0.id == "anmite" }!.rect.y == 0)
        #expect(result.first { $0.id == "lg" }!.rect == IRect(x: -1199, y: -1440, width: 3440, height: 1440))
    }

    @Test func adjacenciesReportSideAndMidpoint() {
        let adj = LayoutEngine.adjacencies([lg, anmite])
        #expect(adj.count == 1)
        #expect(adj[0].side == .below)
        #expect(adj[0].midY == 1440)
        #expect(adj[0].midX == Double(1199 + 3119) / 2)
    }
}
