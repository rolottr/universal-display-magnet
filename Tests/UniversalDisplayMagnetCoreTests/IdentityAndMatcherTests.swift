import Foundation
import Testing

@testable import UniversalDisplayMagnetCore

@Suite struct DisplayIdentityTests {
    let lg = DisplayIdentity(
        vendor: 7789, model: 30510, serial: 123456, alphanumericSerial: "007NTAB12345", name: "LG HDR WQHD")
    let anmite = DisplayIdentity(vendor: 19083, model: 6432, serial: 987654321, name: "ANMITE")

    @Test func identicalModelsWithDifferentSerialsAreDistinct() {
        let a = DisplayIdentity(vendor: 1, model: 2, serial: 100, name: "Dell")
        let b = DisplayIdentity(vendor: 1, model: 2, serial: 200, name: "Dell")
        #expect(a.hardwareKey != b.hardwareKey)
        #expect(DisplayMatcher.score(saved: a, live: b) == nil)
        let m = DisplayMatcher.match(saved: [a, b], live: [b, a])
        #expect(m == [0: 1, 1: 0])
    }

    @Test func identicalModelsWithoutSerialsStillBothMatch() {
        // The display-align failure: two units of one model → only one placed.
        let a = DisplayIdentity(vendor: 1, model: 2, serial: 0, name: "USB-C", uuid: "U1")
        let b = DisplayIdentity(vendor: 1, model: 2, serial: 0, name: "USB-C", uuid: "U2")
        let m = DisplayMatcher.match(saved: [a, b], live: [b, a])
        #expect(m.count == 2)
        #expect(m[0] == 1 && m[1] == 0)  // UUID tie-breaker
        #expect(DisplaySetup.key(for: [a, b]) == "0001-0002+0001-0002")
    }

    @Test func noBuiltInDisplayIsFine() {
        let key = DisplaySetup.key(for: [anmite, lg])
        #expect(key == DisplaySetup.key(for: [lg, anmite]))  // order independent
        #expect(DisplayMatcher.match(saved: [lg, anmite], live: [anmite, lg]) == [0: 1, 1: 0])
    }

    @Test func alphanumericSerialPreferredInKey() {
        #expect(lg.hardwareKey == "1e6d-772e-007NTAB12345")
        #expect(anmite.hardwareKey == "4a8b-1920-987654321")
    }
}

@Suite struct WindowMatcherTests {
    func saved(_ app: String, _ title: String, _ wid: UInt32? = nil) -> WindowSnapshot {
        WindowSnapshot(
            bundleID: app, appName: app, title: title, windowNumber: wid, displayKey: "d",
            frame: IRect(x: 0, y: 0, width: 10, height: 10), spaceIndex: 1)
    }

    @Test func cascadePrefersStrongMatches() {
        let s = [
            saved("com.google.Chrome", "Inbox (3) - Gmail - Google Chrome"),
            saved("com.google.Chrome", "GitHub - Google Chrome", 42),
            saved("com.apple.Terminal", "zsh"),
        ]
        let c = [
            WindowCandidate(key: 1, bundleID: "com.google.Chrome", title: "GitHub - Google Chrome", windowNumber: 42),
            WindowCandidate(key: 2, bundleID: "com.google.Chrome", title: "Inbox (5) - Gmail - Google Chrome", windowNumber: 7),
            WindowCandidate(key: 3, bundleID: "com.apple.Terminal", title: "vim", windowNumber: 9),
        ]
        let m = WindowMatcher.assign(saved: s, candidates: c)
        #expect(m.map(\.candidateKey) == [2, 1, 3])
        #expect(m.map(\.kind) == [.fuzzyTitle, .windowNumber, .appSlot])
    }

    @Test func weakMatchCannotStealAnExactOne() {
        let s = [saved("app", "Document"), saved("app", "Notes")]
        let c = [
            WindowCandidate(key: 1, bundleID: "app", title: "Notes", windowNumber: nil),
            WindowCandidate(key: 2, bundleID: "app", title: "Other", windowNumber: nil),
        ]
        let m = WindowMatcher.assign(saved: s, candidates: c)
        #expect(m.first { $0.savedIndex == 1 }?.candidateKey == 1)
        #expect(m.first { $0.savedIndex == 0 }?.candidateKey == 2)
    }

    @Test func emptyTitlesCarryNoSignal() {
        #expect(!WindowMatcher.similar("(3)", "12:30"))
    }
}

@Suite struct SyncTests {
    struct Doc: Codable, Equatable { var v: Int }

    @Test func lastWriterWinsAndConverges() {
        var a = RecordStore()
        var b = RecordStore()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let ra = a.put(Doc(v: 1), id: "x", kind: .arrangement, device: "A", now: t0)!
        let rb = b.put(Doc(v: 2), id: "x", kind: .arrangement, device: "B", now: t0.addingTimeInterval(1))!
        a.merge([rb])
        b.merge([ra])
        #expect(a.value(id: "x", as: Doc.self) == Doc(v: 2))
        #expect(b.value(id: "x", as: Doc.self) == Doc(v: 2))
    }

    @Test func versionsStayMonotonicWhenTheClockGoesBackwards() {
        var s = RecordStore()
        let r1 = s.put(Doc(v: 1), id: "x", kind: .device, device: "A", now: Date(timeIntervalSince1970: 2_000))!
        let r2 = s.put(Doc(v: 2), id: "x", kind: .device, device: "A", now: Date(timeIntervalSince1970: 1_000))!
        #expect(r2.version > r1.version)
    }

    @Test func unchangedPayloadIsNotRebroadcast() {
        var s = RecordStore()
        #expect(s.put(Doc(v: 1), id: "x", kind: .device, device: "A") != nil)
        #expect(s.put(Doc(v: 1), id: "x", kind: .device, device: "A") == nil)
    }

    @Test func deletionsReplicate() {
        var a = RecordStore()
        var b = RecordStore()
        b.merge([a.put(Doc(v: 1), id: "x", kind: .windowLayout, device: "A")!])
        b.merge([a.delete(id: "x", device: "A")!])
        #expect(b.value(id: "x", as: Doc.self) == nil)
        #expect(b.values(.windowLayout, as: Doc.self).isEmpty)
    }

    @Test func digestExchangeSendsOnlyWhatIsMissing() {
        var a = RecordStore()
        var b = RecordStore()
        let shared = a.put(Doc(v: 1), id: "shared", kind: .device, device: "A")!
        b.merge([shared])
        a.put(Doc(v: 2), id: "onlyA", kind: .device, device: "A")
        #expect(a.newer(than: b.digest).map(\.id) == ["onlyA"])
        #expect(b.newer(than: a.digest).isEmpty)
    }

    @Test func framesRoundTripAndRejectWrongKey() throws {
        let secret = SyncSecret(passphrase: "abcd-efgh-JKLM")
        let same = SyncSecret(passphrase: "ABCDEFGHJKLM")  // normalisation
        let other = SyncSecret(passphrase: "something-else")
        #expect(secret.groupID == same.groupID)
        #expect(secret.groupID != other.groupID)

        var store = RecordStore()
        let rec = store.put(Doc(v: 7), id: "x", kind: .arrangement, device: "A")!
        let frame = try SyncFraming.encode(.records([rec]), secret: secret)

        // Deliver the bytes in awkward chunks.
        var reader = SyncFrameReader()
        var bodies: [Data] = []
        for chunk in stride(from: 0, to: frame.count, by: 7) {
            bodies += try reader.append(frame.subdata(in: chunk..<min(chunk + 7, frame.count)))
        }
        #expect(bodies.count == 1)
        let env = try SyncFraming.decode(bodies[0], secret: same)
        #expect(env.records?.first == rec)
        #expect(throws: (any Error).self) { try SyncFraming.decode(bodies[0], secret: other) }
    }

    @Test func staleFramesAreRejected() throws {
        let secret = SyncSecret(passphrase: "x")
        let frame = try SyncFraming.encode(.ping, secret: secret)
        var reader = SyncFrameReader()
        let body = try reader.append(frame)[0]
        #expect(throws: SyncFrameError.stale) {
            try SyncFraming.decode(body, secret: secret, now: Date().addingTimeInterval(3600))
        }
    }

    @Test func generatedPassphraseShape() {
        let p = SyncSecret.generatePassphrase()
        #expect(p.count == 24)
        #expect(p.split(separator: "-").count == 5)
    }
}
