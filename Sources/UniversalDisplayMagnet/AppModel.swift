import AppKit
import UniversalDisplayMagnetCore
import ServiceManagement
import SwiftUI

/// Thread-safe holder so the sync queue can read records while the main
/// actor owns all writes.
private final class LockedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var store = RecordStore()

    func set(_ s: RecordStore) {
        lock.lock()
        store = s
        lock.unlock()
    }

    func get() -> RecordStore {
        lock.lock()
        defer { lock.unlock() }
        return store
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
}

/// Displays the user is currently trying out, with the arrangement to go back to.
struct PendingRevert {
    let deadline: Date
    let previous: [CGDirectDisplayID: IRect]
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let deviceID = Persistence.deviceID()
    let deviceName = ProcessInfo.processInfo.environment["UDM_DEVICE_NAME"] ?? Host.current().localizedName ?? "Mac"
    let modelName: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    @Published private(set) var displays: [LiveDisplay] = []
    @Published private(set) var setupKey = "" {
        didSet { MenuItems.shared.update(from: self) }
    }
    @Published private(set) var arrangements: [ArrangementProfile] = [] {
        didSet { MenuItems.shared.update(from: self) }
    }
    @Published private(set) var windowLayouts: [WindowLayout] = [] {
        didSet { MenuItems.shared.update(from: self) }
    }
    @Published private(set) var devices: [DeviceStatus] = []
    /// Universal Control's current cross-Mac arrangement (nil if unavailable).
    @Published private(set) var universalControl: UCBridge.State?
    /// Snap commands whose shortcut another app (e.g. Magnet) already owns.
    @Published private(set) var shortcutConflicts: Set<String> = []
    @Published private(set) var accessibilityTrusted = WindowService.isTrusted
    @Published private(set) var desktopShortcuts = SpaceService.availableDesktopShortcuts()
    @Published private(set) var peers: [SyncService.Peer] = []
    /// Connected Macs whose screens are asleep.
    @Published private(set) var sleepingPeers: Set<String> = []
    @Published private(set) var resettingUniversalControl = false {
        didSet { MenuItems.shared.update(from: self) }
    }
    @Published private(set) var activity: String? {
        didSet { MenuBarIcon.shared.show(busy: activity != nil) }
    }
    @Published private(set) var message = ""
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var pendingRevert: PendingRevert?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var settings = Persistence.loadSettings() {
        didSet { settingsChanged(from: oldValue) }
    }

    private var store = Persistence.loadRecords()
    private let shared = LockedStore()
    private var sync: SyncService!
    private let windowQueue = DispatchQueue(label: "Universal Display Magnet.windows", qos: .userInitiated)
    private let saveQueue = DispatchQueue(label: "Universal Display Magnet.save", qos: .utility)
    private var saveWork: DispatchWorkItem?
    private var settleWork: DispatchWorkItem?
    private var lastDisplayChange = Date.distantPast
    private var lastAutosave = Date.distantPast
    /// The window server's view when the autosave last matched the windows.
    private var lastCapture: (signature: String, date: Date)?
    private var applyHistory: [Date] = []
    /// An automatic window restore is owed for the current setup. Cleared only
    /// once one completes for that setup; autosave waits until then so a
    /// shuffled state can't overwrite the good snapshot.
    private var restorePending = false
    private var restoreWork: DispatchWorkItem?
    /// Displays as they were when the screens went to sleep.
    private var sleepState: (setup: String, frames: [IRect])?
    private var compareWithSleepState = false
    private var knownDisplayCount = 0
    private var isRestoring = false
    private var asleepUntil = Date.distantPast
    private var timers: [Timer] = []
    private var pendingWake: [String: Date] = [:]
    private var lastWakeBroadcast = Date.distantPast
    private var suppressWakeUntil = Date.distantPast
    private static let macAddresses = WakeService.macAddresses()

    private init() {
        store.pruneTombstones(olderThan: 60 * 24 * 3600)
        shared.set(store)
        reloadFromStore()
        let shared = self.shared
        sync = SyncService(
            deviceID: deviceID, deviceName: deviceName,
            digestProvider: { shared.get().digest },
            recordsProvider: { shared.get().newer(than: $0) })
        sync.onPeersChanged = { [weak self] in self?.peersChanged($0) }
        sync.onRecords = { [weak self] records, peer in self?.receive(records, from: peer) }
        sync.onLog = { [weak self] in self?.note($0, quiet: true) }
        sync.onPeerAsleep = { [weak self] peer, asleep in
            // Every ping repeats the state: publish only changes.
            guard let self, self.sleepingPeers.contains(peer) != asleep else { return }
            if asleep { self.sleepingPeers.insert(peer) } else { self.sleepingPeers.remove(peer) }
        }
        sync.onWake = { [weak self] from in
            // Turning our display on will fire our own wake handling: don't echo it back.
            self?.suppressWakeUntil = Date().addingTimeInterval(30)
            WakeService.wakeDisplay()
            self?.note("Woken by \(self?.deviceName(from) ?? "another Mac")", quiet: true)
        }
        sync.onResetUniversalControl = { [weak self] from in
            guard let self else { return }
            self.note("\(self.deviceName(from)) is resetting Universal Control")
            // The Mac that started the reset puts the arrangement back.
            self.restartUniversalControl(restoreArrangement: false)
        }
    }

    /// Called once the app has finished launching.
    func start() {
        refreshDisplays()
        knownDisplayCount = displays.count
        DisplayService.observeChanges { [weak self] in self?.displaysChanged() }

        let ws = NSWorkspace.shared.notificationCenter
        // Snapshot windows as the screens go dark: monitors (USB-C ones
        // especially) often disconnect during sleep and macOS piles every
        // window onto whatever is left.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.asleepUntil != .distantFuture else { return }
                    self.autosaveTick(force: true)
                    self.sync.setAsleep(true)
                    self.sleepState = (self.setupKey, self.displays.map(\.frame))
                    self.asleepUntil = .distantFuture
                }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.woke() }
            }
        }
        // Unlocking this Mac also wakes the others, so the shared mouse and
        // keyboard can go straight over.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.wakeOtherMacs(automatic: true) }
        }

        timers.append(
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.autosaveTick() }
            })
        timers.append(
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollPermissions() }
            })

        registerHotKeys()
        WindowSnapper.shared.commands = { [weak self] in self?.snapCommands ?? SnapDefaults.commands }
        WindowSnapper.shared.setDragSnapping(settings.dragToSnap)
        refreshUniversalControl()
        startSync()

        // First run: open at login by default, and ask for Accessibility up
        // front so window layouts work right away.
        if !UserDefaults.standard.bool(forKey: "didFirstRunSetup") {
            UserDefaults.standard.set(true, forKey: "didFirstRunSetup")
            setLaunchAtLogin(true)
        }
        // Windows can't be saved or restored without it: ask up front.
        if !WindowService.isTrusted { WindowService.requestTrust() }

        // First launch at a setup we already know: make sure it's arranged.
        if settings.autoApplyArrangements, let p = activeProfile, p.autoApply, !isArranged(p) {
            apply(p, reason: "Launch")
        }
    }

    // MARK: - Displays

    var activeProfile: ArrangementProfile? { profiles(forSetup: setupKey).first }

    /// Profiles for a setup, the one to auto-apply first (most recently chosen).
    func profiles(forSetup key: String) -> [ArrangementProfile] {
        arrangements.filter { $0.setupKey == key }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var setupLabel: String { DisplaySetup.label(for: displays.map(\.identity)) }

    func refreshDisplays() {
        displays = DisplayService.activeDisplays()
        setupKey = DisplaySetup.key(for: displays.map(\.identity))
        publishDeviceStatus()
    }

    private func displaysChanged() {
        lastDisplayChange = Date()
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        // A display went away: macOS has just piled its windows elsewhere.
        if Int(count) < knownDisplayCount { markRestorePending() }
        knownDisplayCount = Int(count)
        // Whatever restore was scheduled targeted displays that just changed.
        restoreWork?.cancel()
        scheduleSettle()
    }

    /// Displays arrive one by one and macOS shuffles them as they do; act
    /// once things have been quiet for a moment.
    private func scheduleSettle(after delay: TimeInterval = 2.0) {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.settle() }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func woke() {
        sync.setAsleep(false)
        asleepUntil = Date().addingTimeInterval(60)
        compareWithSleepState = true
        displaysChanged()
        sync.reconnect()  // sockets from before sleep are usually dead
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.wakeOtherMacs(automatic: true) }
    }

    // MARK: - Universal Control arrangement

    func deviceName(_ id: String?) -> String {
        guard let id, id != deviceID else { return "this Mac" }
        return devices.first { $0.deviceID == id }?.name ?? "another Mac"
    }

    /// Universal Control's id for a Mac Universal Display Magnet knows (by its displays).
    func ucDevice(for status: DeviceStatus) -> String? {
        if status.deviceID == deviceID { return universalControl?.selfDevice }
        return universalControl?.device(owning: status.displays.compactMap(\.identity.uuid))
    }

    /// Re-read records from disk (README animations write demo data after launch).
    func reloadRecords() {
        store = Persistence.loadRecords()
        shared.set(store)
        reloadFromStore()
    }

    /// README animations: fixed Universal Control state (never the real
    /// one) and permissions shown as granted.
    func enterDemo(universalControl state: UCBridge.State) {
        universalControl = state
        accessibilityTrusted = true
        desktopShortcuts = 10
    }

    func refreshUniversalControl() {
        if DemoRenderer.isActive { return }
        let state = UCBridge.read()
        if state != universalControl { universalControl = state }
        // Remember every Mac Universal Control has linked with this one, so
        // they stay trusted for sync even while unlinked.
        if let state, let me = state.selfDevice {
            var peers = Set(settings.ucPeers)
            for l in state.links where l.device1 == me || l.device2 == me {
                peers.insert(l.device1 == me ? l.device2 : l.device1)
            }
            for (device, _) in state.devices where device != me { peers.insert(device) }
            if settings.ucSelf != me || Set(settings.ucPeers) != peers {
                settings.ucSelf = me
                settings.ucPeers = peers.sorted()
            }
        }
    }

    /// Write a cross-Mac arrangement into Universal Control. It takes effect
    /// immediately on both Macs; the pointer crosses wherever displays touch.
    func applyUniversalControl(_ link: UCLink?) {
        guard let link else { return }
        do {
            try UCBridge.apply(link)
            settings.ucLink = link
            refreshUniversalControl()
            note("Universal Control updated (\(link.summary))")
        } catch {
            note(error.localizedDescription)
        }
    }

    /// Move one of this Mac's displays from the Universal Control canvas:
    /// re-arrange this Mac (keeping the change as its saved arrangement), then
    /// re-link Universal Control so the other Mac's displays stay put.
    func moveLocalDisplay(
        _ id: CGDirectDisplayID, to rect: IRect, remoteDevice: String, remoteDisplays: [UCDisplay], remoteOffset: IPoint
    ) {
        guard let me = universalControl?.selfDevice else { return }
        let items = displays.map { LayoutItem(id: String($0.id), rect: $0.id == id ? rect : $0.frame) }
        guard LayoutEngine.isValid(items) else {
            note("Displays must touch without overlapping")
            return
        }
        // Links are relative, so compute them in the canvas's coordinates.
        let mine = displays.compactMap { d in
            d.identity.uuid.map { UCDisplay(uuid: $0, frame: d.id == id ? rect : d.frame) }
        }
        let theirs = remoteDisplays.map {
            UCDisplay(uuid: $0.uuid, frame: $0.frame.offsetBy(dx: remoteOffset.x, dy: remoteOffset.y))
        }
        let link = UCGeometry.link(device1: remoteDevice, displays1: theirs, device2: me, displays2: mine)
        let main = displays.first(where: \.isMain).map { String($0.id) } ?? items[0].id
        if applyItems(LayoutEngine.normalized(items, mainID: main)) {
            rememberCurrentArrangement()
        }
        applyUniversalControl(link)
    }

    func undoUniversalControl() {
        do {
            try UCBridge.undo()
            refreshUniversalControl()
            if let saved = settings.ucLink {
                settings.ucLink = universalControl?.link(from: saved.device1, to: saved.device2)
            }
            note("Universal Control arrangement restored")
        } catch {
            note(error.localizedDescription)
        }
    }

    /// Restart Universal Control here and, over the network, on the other
    /// Macs; then put back the arrangement set here if Universal Control lost it.
    func resetUniversalControl() {
        guard !resettingUniversalControl else { return }
        for p in peers { sync.sendResetUniversalControl(to: p.id) }
        let names = ["this Mac"] + peers.map(\.name)
        note("Resetting Universal Control on \(names.joined(separator: " and "))")
        restartUniversalControl(restoreArrangement: true)
    }

    private func restartUniversalControl(restoreArrangement: Bool) {
        resettingUniversalControl = true
        DispatchQueue.global().async {
            UCBridge.restartServices()
            // Give the services time to start and find the other Mac again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self else { return }
                self.resettingUniversalControl = false
                self.refreshUniversalControl()
                if restoreArrangement { self.restoreUniversalControlArrangement() }
            }
        }
    }

    /// Re-apply the arrangement last set here when Universal Control no longer
    /// has it (another Mac can replace it with an empty one).
    private func restoreUniversalControlArrangement() {
        guard let saved = settings.ucLink, let state = universalControl,
            state.link(from: saved.device1, to: saved.device2) != saved
        else { return }
        applyUniversalControl(saved)
    }

    /// Turn the other Macs' displays on (or wake them over the network).
    func wakeOtherMacs(automatic: Bool = false) {
        if automatic {
            guard settings.wakeOtherMacs, Date() > suppressWakeUntil,
                Date().timeIntervalSince(lastWakeBroadcast) > 20
            else { return }
        }
        lastWakeBroadcast = Date()
        for d in devices where d.deviceID != deviceID {
            if sync.isOnline(d.deviceID) {
                sync.sendWake(to: d.deviceID)
            } else {
                pendingWake[d.deviceID] = Date()
                let macs = d.macAddresses ?? []
                if !macs.isEmpty { DispatchQueue.global().async { WakeService.sendMagicPacket(to: macs) } }
            }
        }
        if !automatic { note("Waking \(devices.filter { $0.deviceID != deviceID }.map(\.name).joined(separator: ", "))") }
    }

    /// A Mac we tried to wake just came online: now turn its display on.
    /// Show "Wake Other Mac" only when a connected Mac's screens are asleep.
    var canWakeOtherMac: Bool { peers.contains { sleepingPeers.contains($0.id) } }

    private func peersChanged(_ peers: [SyncService.Peer]) {
        self.peers = peers
        sleepingPeers.formIntersection(peers.map(\.id))
        pendingWake = pendingWake.filter { Date().timeIntervalSince($0.value) < 120 }
        for p in peers where pendingWake[p.id] != nil {
            pendingWake[p.id] = nil
            sync.sendWake(to: p.id)
        }
    }

    private func markRestorePending() {
        if settings.restoreOnConnect != .off { restorePending = true }
    }

    private func settle() {
        let previousSetup = setupKey
        refreshDisplays()
        let setupChanged = previousSetup != setupKey
        if setupChanged {
            markRestorePending()
            note("Displays: \(setupLabel.isEmpty ? "none" : setupLabel)", quiet: true)
        }
        // Waking up only warrants a restore if the displays actually changed.
        if compareWithSleepState {
            compareWithSleepState = false
            if let s = sleepState, s.setup != setupKey || s.frames != displays.map(\.frame) { markRestorePending() }
            sleepState = nil
        }

        var arranged = false
        if pendingRevert == nil, settings.autoApplyArrangements, let p = activeProfile, p.autoApply, !isArranged(p) {
            // Don't fight macOS forever if it keeps refusing the layout.
            applyHistory = applyHistory.filter { Date().timeIntervalSince($0) < 60 }
            if applyHistory.count < 4 {
                applyHistory.append(Date())
                apply(p, reason: setupChanged ? "Displays connected" : "macOS moved your displays")
                arranged = true
            } else {
                note("macOS keeps changing the arrangement; auto-apply paused for a minute")
            }
        }

        if restorePending { scheduleAutomaticRestore(after: arranged ? 3.0 : 1.5) }
    }

    private func scheduleAutomaticRestore(after delay: TimeInterval) {
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runAutomaticRestore() }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runAutomaticRestore() {
        guard restorePending else { return }
        if isRestoring {
            // Another restore (likely for an earlier setup) is still moving
            // windows; go again once it's done.
            scheduleAutomaticRestore(after: 2)
            return
        }
        guard settings.restoreOnConnect != .off, WindowService.isTrusted, let layout = layoutToRestoreOnConnect()
        else {
            restorePending = false
            return
        }
        restore(layout, automatic: true)
    }

    /// Target frame for each live display under `profile`, or nil if none of its displays are here.
    func targets(for profile: ArrangementProfile) -> (items: [LayoutItem], mainID: String)? {
        let match = DisplayMatcher.match(saved: profile.displays.map(\.identity), live: displays.map(\.identity))
        guard !match.isEmpty else { return nil }
        var items: [LayoutItem] = []
        var mainID: String?
        for (si, li) in match {
            let live = displays[li]
            let saved = profile.displays[si]
            items.append(
                LayoutItem(
                    id: String(live.id),
                    rect: IRect(x: saved.frame.x, y: saved.frame.y, width: live.frame.width, height: live.frame.height)))
            if saved.isMain { mainID = String(live.id) }
        }
        // Displays the profile doesn't know about get seated next to the others.
        for (li, live) in displays.enumerated() where !match.values.contains(li) {
            items.append(LayoutItem(id: String(live.id), rect: live.frame))
        }
        let main = mainID ?? displays.first(where: \.isMain).map { String($0.id) } ?? items[0].id
        let valid = LayoutEngine.compact(items, priority: [main])
        return (LayoutEngine.normalized(valid, mainID: main), main)
    }

    func isArranged(_ profile: ArrangementProfile) -> Bool {
        guard let t = targets(for: profile) else { return true }
        return t.items.allSatisfy { item in displays.first { String($0.id) == item.id }?.frame == item.rect }
    }

    /// Apply a saved arrangement (and resolutions, if the profile keeps them).
    func apply(_ profile: ArrangementProfile, reason: String? = nil) {
        if profile.restoreModes {
            let match = DisplayMatcher.match(saved: profile.displays.map(\.identity), live: displays.map(\.identity))
            var modes: [CGDirectDisplayID: CGDisplayMode] = [:]
            for (si, li) in match {
                if let spec = profile.displays[si].mode, let m = DisplayService.bestMode(for: spec, on: displays[li].id) {
                    modes[displays[li].id] = m
                }
            }
            do {
                try DisplayService.applyModes(modes)
                refreshDisplays()
            } catch {
                note("Resolution: \(error.localizedDescription)")
            }
        }
        guard let t = targets(for: profile) else {
            note("None of “\(profile.name)”’s displays are connected")
            return
        }
        if applyItems(t.items) {
            note("Applied “\(profile.name)”" + (reason.map { " · \($0)" } ?? ""))
        }
    }

    /// Move live displays (ids are `CGDirectDisplayID` strings). Returns false on failure.
    @discardableResult
    func applyItems(_ items: [LayoutItem]) -> Bool {
        let origins = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (CGDirectDisplayID, (x: Int, y: Int))? in
                guard let id = CGDirectDisplayID(item.id) else { return nil }
                return (id, (item.rect.x, item.rect.y))
            })
        let unchanged = origins.allSatisfy { id, o in
            displays.first { $0.id == id }.map { $0.frame.x == o.x && $0.frame.y == o.y } ?? true
        }
        if unchanged { return true }
        do {
            try DisplayService.applyOrigins(origins)
            refreshDisplays()
            return true
        } catch {
            note(error.localizedDescription)
            return false
        }
    }

    /// One click: pull every display flush against its neighbours (no gaps,
    /// no overlaps, near-aligned edges squared up) and keep it that way.
    func snapAllTogether() {
        guard displays.count > 1 else {
            note("Only one display connected")
            return
        }
        let items = displays.map { LayoutItem(id: String($0.id), rect: $0.frame) }
        let main = displays.first(where: \.isMain).map { String($0.id) } ?? items[0].id
        let snapped = LayoutEngine.normalized(
            LayoutEngine.compact(items, priority: [main], alignThreshold: settings.snapThreshold), mainID: main)
        if snapped == items {
            note("Displays are already snapped together")
        } else if applyItems(snapped) {
            rememberCurrentArrangement()
            note("Snapped \(displays.count) displays together")
        }
    }

    /// Store what's on screen as this setup's arrangement, so auto-apply
    /// keeps it instead of reverting to an older profile.
    func rememberCurrentArrangement() {
        if var p = activeProfile {
            p.displays = displays.map(\.placement)
            update(p)
        } else {
            saveArrangement(name: "My Setup")
        }
    }

    /// Try out an arrangement from the editor; reverts unless kept within 15 s.
    func tryArrangement(_ items: [LayoutItem]) {
        let previous = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.frame) })
        guard applyItems(items) else { return }
        let deadline = Date().addingTimeInterval(15)
        pendingRevert = PendingRevert(deadline: deadline, previous: previous)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.2) { [weak self] in
            guard let self, let p = self.pendingRevert, p.deadline == deadline else { return }
            self.revertArrangement()
        }
    }

    func keepArrangement() {
        pendingRevert = nil
        scheduleSettle()
    }

    func revertArrangement() {
        guard let p = pendingRevert else { return }
        pendingRevert = nil
        // Only displays still connected; one may have gone during the trial.
        let connected = Set(displays.map(\.id))
        let items = p.previous.filter { connected.contains($0.key) }.map { LayoutItem(id: String($0.key), rect: $0.value) }
        if items.count == connected.count, LayoutEngine.isValid(items) {
            applyItems(items)
            note("Reverted to the previous arrangement")
        }
        scheduleSettle()
    }

    /// Save an arrangement. `frames` maps display hardware keys (+ordinal) to
    /// frames; nil means "as the displays are right now on this Mac".
    @discardableResult
    func saveArrangement(
        name: String, placements: [DisplayPlacement]? = nil, setupKey key: String? = nil, device: DeviceStatus? = nil,
        autoApply: Bool = true, restoreModes: Bool = false, replacing existing: ArrangementProfile? = nil
    ) -> String {
        let displaysToSave = placements ?? displays.map(\.placement)
        let profile = ArrangementProfile(
            id: existing?.id ?? UUID().uuidString, name: name,
            setupKey: key ?? DisplaySetup.key(for: displaysToSave.map(\.identity)), displays: displaysToSave,
            autoApply: autoApply, restoreModes: restoreModes, deviceID: device?.deviceID ?? deviceID,
            deviceName: device?.name ?? deviceName)
        put(profile, id: profile.id, kind: .arrangement)
        note("Saved arrangement “\(name)”" + (device.map { " for \($0.name)" } ?? ""))
        return profile.id
    }

    func update(_ profile: ArrangementProfile) {
        var p = profile
        p.updatedAt = Date()
        put(p, id: p.id, kind: .arrangement)
    }

    func delete(_ profile: ArrangementProfile) {
        remove(id: profile.id)
    }

    /// Make `profile` the one auto-applied for its setup, and apply it here if it's this Mac's setup.
    func activate(_ profile: ArrangementProfile) {
        pendingRevert = nil  // an explicit choice ends any trial
        update(profile)
        if profile.setupKey == setupKey { apply(profile) }
    }

    // MARK: - Windows

    func layouts(forSetup key: String, device: String? = nil) -> [WindowLayout] {
        windowLayouts.filter { $0.setupKey == key && (device == nil || $0.deviceID == device) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func layoutToRestoreOnConnect() -> WindowLayout? {
        let mine = layouts(forSetup: setupKey, device: deviceID)
        switch settings.restoreOnConnect {
        case .off: return nil
        case .autosave: return mine.first(where: \.isAutosave) ?? mine.first
        case .latestSaved: return mine.first(where: { !$0.isAutosave }) ?? mine.first
        }
    }

    func saveWindowLayout(name: String, id: String? = nil, arrangementID: String? = nil) {
        guard requireAccessibility() else { return }
        let displays = self.displays
        let key = setupKey
        activity = "Capturing windows…"
        windowQueue.async {
            let windows = WindowService.capture(displays: displays, allDesktops: true)
            DispatchQueue.main.async {
                self.activity = nil
                let layout = WindowLayout(
                    id: id ?? UUID().uuidString, name: name, setupKey: key, deviceID: self.deviceID,
                    deviceName: self.deviceName, arrangementID: arrangementID, windows: windows,
                    displays: displays.map(\.placement))
                self.put(layout, id: layout.id, kind: .windowLayout)
                let apps = Set(windows.map(\.bundleID)).count
                self.note(
                    arrangementID == nil
                        ? "Saved \(windows.count) windows as “\(name)”"
                        : "Saved workspace “\(name)”: \(self.displays.count) monitors, \(windows.count) windows, \(apps) apps")
            }
        }
    }

    // MARK: - Workspaces (monitors + Desktops + apps)

    var workspaces: [WindowLayout] {
        layouts(forSetup: setupKey, device: deviceID).filter(\.isWorkspace)
    }

    /// Capture every window right now (for the Save Workspace window).
    func captureWindows(_ done: @escaping ([WindowSnapshot], [DisplayPlacement]) -> Void) {
        guard requireAccessibility() else {
            done([], displays.map(\.placement))
            return
        }
        let displays = self.displays
        windowQueue.async {
            let windows = WindowService.capture(displays: displays, allDesktops: true)
            DispatchQueue.main.async { done(windows, displays.map(\.placement)) }
        }
    }

    /// Save a workspace from the Save Workspace window: the chosen apps'
    /// windows and, with `includeArrangement`, the monitor arrangement and
    /// resolutions. `replacing` updates an existing workspace in place.
    func saveWorkspace(
        name: String, windows: [WindowSnapshot], displays placements: [DisplayPlacement], hotkey: HotkeySpec?,
        includeArrangement: Bool, replacing existing: WindowLayout?
    ) {
        var arrangementID: String?
        if includeArrangement {
            let profile = existing?.arrangementID.flatMap { id in arrangements.first { $0.id == id } }
            arrangementID = saveArrangement(
                name: name, placements: placements, autoApply: profile?.autoApply ?? true,
                restoreModes: profile?.restoreModes ?? true, replacing: profile)
        }
        let layout = WindowLayout(
            id: existing?.id ?? UUID().uuidString, name: name,
            setupKey: existing?.setupKey ?? DisplaySetup.key(for: placements.map(\.identity)), deviceID: deviceID,
            deviceName: deviceName, arrangementID: arrangementID, hotkey: hotkey, windows: windows,
            displays: placements)
        put(layout, id: layout.id, kind: .windowLayout)
        let apps = Set(windows.map(\.bundleID)).count
        note("Saved “\(name)”: \(windows.count) windows from \(apps) apps" + (hotkey.map { " · \($0.display)" } ?? ""))
        registerHotKeys()
    }

    /// Put a workspace back: arrange the monitors (and resolutions), then open
    /// any apps that aren't running and move every window to its monitor and Desktop.
    func restoreWorkspace(_ layout: WindowLayout) {
        guard requireAccessibility() else { return }
        if let id = layout.arrangementID, let profile = arrangements.first(where: { $0.id == id }),
            profile.setupKey == setupKey
        {
            activate(profile)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.restore(layout, launchApps: true)
            }
        } else {
            restore(layout, launchApps: true)
        }
    }

    func quickSaveWindows() {
        saveWindowLayout(name: "Quick Save", id: "quick:\(deviceID):\(setupKey)")
    }

    func quickRestoreWindows() {
        let mine = layouts(forSetup: setupKey, device: deviceID)
        guard let layout = mine.first(where: { !$0.isAutosave }) ?? mine.first else {
            note("No saved window layout for this display setup yet")
            return
        }
        restore(layout)
    }

    func restore(_ layout: WindowLayout, automatic: Bool = false, launchApps: Bool? = nil) {
        guard !isRestoring, !displays.isEmpty else { return }
        guard WindowService.isTrusted else {
            if !automatic { _ = requireAccessibility() }
            return
        }
        isRestoring = true
        let key = setupKey
        activity = "Restoring “\(layout.name)”…"
        let displays = self.displays
        let options = RestoreOptions(
            moveBetweenDesktops: settings.moveBetweenDesktops,
            launchMissingApps: launchApps ?? (settings.launchMissingApps && !automatic))
        windowQueue.async {
            let report = WindowService.restore(layout, displays: displays, options: options) { text in
                DispatchQueue.main.async { self.activity = text }
            }
            DispatchQueue.main.async {
                self.isRestoring = false
                self.activity = nil
                if automatic && key == self.setupKey { self.restorePending = false }
                self.lastAutosave = Date()  // don't snapshot mid-settle
                self.note("\(report.summary)" + (automatic ? " · automatic" : ""))
            }
        }
    }

    func rename(_ layout: WindowLayout, to name: String) {
        var l = layout
        l.name = name
        l.isAutosave = false
        l.updatedAt = Date()
        put(l, id: l.id, kind: .windowLayout)
    }

    func delete(_ layout: WindowLayout) { remove(id: layout.id) }

    /// Periodic snapshot; `force` skips the interval (used right before sleep).
    private func autosaveTick(force: Bool = false) {
        guard settings.autosaveWindows, WindowService.isTrusted, !isRestoring, !restorePending, !displays.isEmpty,
            Date() > asleepUntil,
            Date().timeIntervalSince(lastDisplayChange) > 45,
            force || Date().timeIntervalSince(lastAutosave) >= Double(settings.autosaveMinutes * 60) - 5
        else { return }
        lastAutosave = Date()
        let displays = self.displays
        let key = setupKey
        // Asking every app for its windows costs a second or more of CPU:
        // skip it while the window server shows nothing moved. Titles and
        // minimized windows only show up in a full capture, so take one at
        // least every 10 minutes anyway.
        let signature = "\(key)\n" + WindowService.serverSignature()
        if !force, let last = lastCapture, last.signature == signature, Date().timeIntervalSince(last.date) < 600 {
            return
        }
        windowQueue.async {
            let windows = WindowService.capture(displays: displays, allDesktops: true)
            DispatchQueue.main.async {
                // Displays changed while capturing: the snapshot may be mid-shuffle.
                guard key == self.setupKey, !self.restorePending, Date().timeIntervalSince(self.lastDisplayChange) > 45,
                    !windows.isEmpty
                else { return }
                let id = WindowLayout.autosaveID(deviceID: self.deviceID, setupKey: key)
                let old = self.store.value(id: id, as: WindowLayout.self)
                self.lastCapture = (signature, Date())
                if old?.windows.map(\.placementSignature) == windows.map(\.placementSignature) { return }
                let layout = WindowLayout(
                    id: id, name: "Automatic snapshot", setupKey: key, deviceID: self.deviceID,
                    deviceName: self.deviceName, isAutosave: true, windows: windows, displays: displays.map(\.placement))
                self.put(layout, id: id, kind: .windowLayout)
            }
        }
    }

    // MARK: - Permissions

    @discardableResult
    func requireAccessibility() -> Bool {
        if WindowService.isTrusted { return true }
        WindowService.requestTrust()
        note("Turn on Universal Display Magnet in System Settings › Privacy & Security › Device Control and Data Access")
        return false
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func enableDesktopShortcuts() {
        do {
            try SpaceService.enableDesktopShortcuts()
            desktopShortcuts = SpaceService.availableDesktopShortcuts()
            note("Enabled ⌃1…⌃0 for switching Desktops")
        } catch {
            note("Couldn't enable Desktop shortcuts: \(error.localizedDescription)")
        }
    }

    private func pollPermissions() {
        let trusted = WindowService.isTrusted
        if trusted != accessibilityTrusted { accessibilityTrusted = trusted }
        let shortcuts = SpaceService.availableDesktopShortcuts()
        if shortcuts != desktopShortcuts { desktopShortcuts = shortcuts }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            note("Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Sync

    /// One key per Mac Universal Control pairs us with: both Macs derive the
    /// same key from the two Universal Control ids (which only your own Macs,
    /// signed into the same Apple Account, know). Nothing to type.
    var syncSecrets: [SyncSecret] {
        guard let me = settings.ucSelf else { return [] }
        return settings.ucPeers.filter { $0 != me }.map { peer in
            SyncSecret(passphrase: "universal-control/" + [me, peer].sorted().joined(separator: "/"))
        }
    }

    /// Universal Control has identified this Mac and at least one other.
    var canSync: Bool { settings.ucSelf != nil && settings.ucPeers.contains { $0 != settings.ucSelf } }

    /// Test instances (UI snapshots, or a separate data folder) never sync:
    /// they would push test data to your real Macs.
    static var isTestInstance: Bool {
        DebugSnapshot.directory != nil
            || (ProcessInfo.processInfo.environment["UDM_DATA_DIR"] != nil
                && !CommandLine.arguments.contains("--purge-records"))
    }

    /// Delete records everywhere: tombstones replicate to the other Macs.
    func purge(ids: [String]) {
        for id in ids { remove(id: id) }
    }

    func startSync() {
        let secrets = syncSecrets
        guard settings.syncOn, !secrets.isEmpty, !Self.isTestInstance else {
            sync.stop()
            peers = []
            return
        }
        sync.start(secrets: secrets, manualPeers: settings.manualPeers)
    }

    private func receive(_ records: [SyncRecord], from peer: String) {
        let accepted = store.merge(records)
        guard !accepted.isEmpty else { return }
        storeChanged()
        sync.broadcast(accepted, except: peer)
        let name = peers.first { $0.id == peer }?.name ?? "another Mac"
        note("Synced \(accepted.count) change\(accepted.count == 1 ? "" : "s") from \(name)", quiet: true)
        // An arrangement for the displays on this Mac changed elsewhere.
        if accepted.contains(where: { $0.kind == .arrangement }) { scheduleSettle(after: 0.5) }
    }

    private func publishDeviceStatus() {
        let id = "device:\(deviceID)"
        let current = DeviceStatus(
            deviceID: deviceID, name: deviceName, model: modelName, displays: displays.map(\.placement), setupKey: setupKey,
            macAddresses: Self.macAddresses, wallpapers: displays.map { Wallpaper.thumbnail(for: $0.id) })
        if let old = store.value(id: id, as: DeviceStatus.self), old.displays == current.displays, old.name == current.name,
            old.macAddresses == current.macAddresses, old.wallpapers == current.wallpapers
        {
            return
        }
        put(current, id: id, kind: .device)
    }

    // MARK: - Settings

    private func settingsChanged(from old: AppSettings) {
        Persistence.saveSettings(settings)
        if old.syncOn != settings.syncOn || old.ucSelf != settings.ucSelf || old.ucPeers != settings.ucPeers {
            startSync()
        } else if old.manualPeers != settings.manualPeers {
            sync.updateManualPeers(settings.manualPeers)
        }
        if old.hotkeysEnabled != settings.hotkeysEnabled || old.snapCommands != settings.snapCommands {
            registerHotKeys()
        }
        if old.dragToSnap != settings.dragToSnap { WindowSnapper.shared.setDragSnapping(settings.dragToSnap) }
    }

    // MARK: - Window snapping

    var snapCommands: [SnapCommand] { settings.snapCommands ?? SnapDefaults.commands }

    func runSnap(_ command: SnapCommand) {
        guard requireAccessibility() else { return }
        WindowSnapper.shared.run(command)
    }

    func updateSnapCommand(_ command: SnapCommand) {
        var all = snapCommands
        if let i = all.firstIndex(where: { $0.id == command.id }) { all[i] = command } else { all.append(command) }
        settings.snapCommands = all
    }

    func deleteSnapCommand(_ id: String) {
        settings.snapCommands = snapCommands.filter { $0.id != id || $0.builtIn }
    }

    func resetSnapCommands() { settings.snapCommands = nil }

    func registerHotKeys() {
        HotKeys.shared.unregisterAll()
        var conflicts: Set<String> = []
        for command in snapCommands where command.hotkeyEnabled {
            guard let key = command.hotkey else { continue }
            let ok = HotKeys.shared.register(keyCode: Int(key.keyCode), modifiers: key.modifiers) { [weak self] in
                self?.runSnap(command)
            }
            if !ok { conflicts.insert(command.id) }
        }
        if conflicts != shortcutConflicts { shortcutConflicts = conflicts }
        // Each workspace's own shortcut restores it.
        for layout in windowLayouts where layout.deviceID == deviceID {
            guard let key = layout.hotkey else { continue }
            let id = layout.id
            HotKeys.shared.register(keyCode: Int(key.keyCode), modifiers: key.modifiers) { [weak self] in
                guard let self, let l = self.windowLayouts.first(where: { $0.id == id }) else { return }
                if l.isWorkspace { self.restoreWorkspace(l) } else { self.restore(l) }
            }
        }
        guard settings.hotkeysEnabled else { return }
        HotKeys.shared.register(keyCode: 1) { [weak self] in self?.quickSaveWindows() }  // S
        HotKeys.shared.register(keyCode: 15) { [weak self] in self?.quickRestoreWindows() }  // R
        HotKeys.shared.register(keyCode: 2) { [weak self] in  // D
            guard let self, self.pendingRevert == nil else { return }
            if let p = self.activeProfile { self.apply(p) } else { self.snapAllTogether() }
        }
    }

    // MARK: - Store plumbing

    private func put<T: Encodable>(_ value: T, id: String, kind: RecordKind) {
        guard let record = store.put(value, id: id, kind: kind, device: deviceID) else { return }
        storeChanged()
        sync.broadcast([record])
    }

    private func remove(id: String) {
        guard let record = store.delete(id: id, device: deviceID) else { return }
        storeChanged()
        sync.broadcast([record])
    }

    private func storeChanged() {
        shared.set(store)
        reloadFromStore()
        saveWork?.cancel()
        let snapshot = store
        let work = DispatchWorkItem { Persistence.saveRecords(snapshot) }
        saveWork = work
        // Serial queue: writes land in order even if one is slow.
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Write pending changes now (on quit).
    func flush() {
        saveWork?.cancel()
        let snapshot = store
        saveQueue.sync { Persistence.saveRecords(snapshot) }
    }

    private func reloadFromStore() {
        arrangements = store.values(.arrangement, as: ArrangementProfile.self)
        windowLayouts = store.values(.windowLayout, as: WindowLayout.self)
        devices = store.values(.device, as: DeviceStatus.self)
    }

    func note(_ text: String, quiet: Bool = false) {
        if !quiet { message = text }
        log.append(LogLine(text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
