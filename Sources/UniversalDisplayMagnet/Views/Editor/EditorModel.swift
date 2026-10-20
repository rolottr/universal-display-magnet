import UniversalDisplayMagnetCore
import SwiftUI

/// State of the arrangement editor. Works on either this Mac's live displays
/// or another Mac's displays (as published over sync); edits for another Mac
/// are saved as a profile that Mac applies when it receives it.
@MainActor
final class EditorModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        var id: String
        var placement: DisplayPlacement
        var rect: IRect

        var name: String { placement.identity.name }
        var detail: String { "\(rect.width)×\(rect.height)" }
    }

    /// nil = this Mac.
    @Published private(set) var device: String?
    @Published private(set) var items: [Item] = []
    @Published private(set) var mainID = ""
    @Published var selected: String?
    @Published private(set) var baseline: [String: IRect] = [:]
    @Published private(set) var baselineMain = ""
    /// Profile currently loaded into the editor, if any.
    @Published private(set) var profile: ArrangementProfile?

    var isRemote: Bool { device != nil }
    var isDirty: Bool { mainID != baselineMain || items.contains { baseline[$0.id] != $0.rect } }
    var layoutItems: [LayoutItem] { items.map { LayoutItem(id: $0.id, rect: $0.rect) } }
    var isValid: Bool { LayoutEngine.isValid(layoutItems) }

    func item(_ id: String) -> Item? { items.first { $0.id == id } }

    // MARK: - Loading

    func load(device: String?, model: AppModel) {
        self.device = device
        selected = nil
        if let device, let status = model.devices.first(where: { $0.deviceID == device }) {
            setItems(
                status.displays.enumerated().map { i, p in Item(id: "\(i)", placement: p, rect: p.frame) },
                main: status.displays.firstIndex(where: \.isMain).map { "\($0)" })
            profile = model.profiles(forSetup: status.setupKey).first
        } else {
            self.device = nil
            setItems(
                model.displays.map { Item(id: String($0.id), placement: $0.placement, rect: $0.frame) },
                main: model.displays.first(where: \.isMain).map { String($0.id) })
            profile = model.activeProfile
        }
    }

    /// Show a saved profile's positions on the current displays.
    func loadProfile(_ p: ArrangementProfile) {
        let match = DisplayMatcher.match(saved: p.displays.map(\.identity), live: items.map(\.placement.identity))
        var next = items
        var main = mainID
        for (si, li) in match {
            let f = p.displays[si].frame
            next[li].rect = IRect(x: f.x, y: f.y, width: next[li].rect.width, height: next[li].rect.height)
            if p.displays[si].isMain { main = next[li].id }
        }
        let fixed = LayoutEngine.compact(next.map { LayoutItem(id: $0.id, rect: $0.rect) }, priority: [main])
        for i in next.indices { next[i].rect = fixed[i].rect }
        items = next
        mainID = main
        profile = p
    }

    private func setItems(_ new: [Item], main: String?) {
        items = new
        mainID = main ?? new.first?.id ?? ""
        markClean()
    }

    func markClean() {
        baseline = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.rect) })
        baselineMain = mainID
    }

    func revert() {
        for i in items.indices { items[i].rect = baseline[items[i].id] ?? items[i].rect }
        mainID = baselineMain
    }

    // MARK: - Editing

    /// Live drag: magnetic snap to the closest valid spot.
    func drag(_ id: String, to proposed: IRect, threshold: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].rect = LayoutEngine.snap(id, proposed: proposed, in: layoutItems, threshold: threshold)
    }

    func place(_ id: String, side: Side, of anchor: String, alignment: EdgeAlignment = .center) {
        apply(LayoutEngine.place(id, side: side, of: anchor, alignment: alignment, in: layoutItems))
        selected = id
    }

    func align(_ id: String, _ alignment: EdgeAlignment) {
        apply(LayoutEngine.align(id, alignment, in: layoutItems))
    }

    func nudge(_ id: String, dx: Int, dy: Int) {
        guard let r = item(id)?.rect else { return }
        drag(id, to: r.offsetBy(dx: dx, dy: dy), threshold: 0)
    }

    func setPosition(_ id: String, x: Int? = nil, y: Int? = nil) {
        guard let r = item(id)?.rect else { return }
        drag(id, to: r.with(x: x, y: y), threshold: 0)
    }

    func makeMain(_ id: String) { mainID = id }

    func snapAll(threshold: Int) {
        apply(LayoutEngine.compact(layoutItems, priority: [mainID], alignThreshold: threshold))
    }

    private func apply(_ layout: [LayoutItem]) {
        for l in layout {
            if let i = items.firstIndex(where: { $0.id == l.id }) { items[i].rect = l.rect }
        }
    }

    /// Final frames, main display at the origin.
    var normalizedItems: [LayoutItem] { LayoutEngine.normalized(layoutItems, mainID: mainID) }

    /// Placements ready to save in a profile.
    var placements: [DisplayPlacement] {
        let frames = Dictionary(uniqueKeysWithValues: normalizedItems.map { ($0.id, $0.rect) })
        return items.map { item in
            var p = item.placement
            p.frame = frames[item.id] ?? item.rect
            p.isMain = item.id == mainID
            return p
        }
    }
}
