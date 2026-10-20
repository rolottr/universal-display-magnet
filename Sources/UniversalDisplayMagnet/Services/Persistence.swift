import UniversalDisplayMagnetCore
import Foundation

enum RestoreOnConnect: String, Codable, CaseIterable, Identifiable {
    case off, autosave, latestSaved
    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Don't restore"
        case .autosave: return "Last automatic snapshot"
        case .latestSaved: return "Most recent saved layout"
        }
    }
}

/// Per-Mac preferences (not synced).
struct AppSettings: Codable, Equatable {
    var autoApplyArrangements = true
    var restoreOnConnect: RestoreOnConnect = .autosave
    var autosaveWindows = true
    var autosaveMinutes = 2
    var moveBetweenDesktops = true
    var launchMissingApps = false
    /// Sync with the Macs Universal Control links this one to.
    var syncOn = true
    /// Universal Control ids: this Mac, and the Macs it has been linked with.
    var ucSelf: String?
    var ucPeers: [String] = []
    /// The cross-Mac arrangement last set here, put back after a reset.
    var ucLink: UCLink?
    var manualPeers: [String] = []
    var hotkeysEnabled = true
    var snapThreshold = 48
    /// When this Mac wakes or is unlocked, wake the other Macs too.
    var wakeOtherMacs = true
    /// Window snapping commands (nil = the built-in defaults).
    var snapCommands: [SnapCommand]?
    /// Snap windows dragged against a screen edge or corner.
    var dragToSnap = true

    init() {}

    // Tolerate settings files written by older builds.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        autoApplyArrangements = try c.decodeIfPresent(Bool.self, forKey: .autoApplyArrangements) ?? d.autoApplyArrangements
        restoreOnConnect = try c.decodeIfPresent(RestoreOnConnect.self, forKey: .restoreOnConnect) ?? d.restoreOnConnect
        autosaveWindows = try c.decodeIfPresent(Bool.self, forKey: .autosaveWindows) ?? d.autosaveWindows
        autosaveMinutes = try c.decodeIfPresent(Int.self, forKey: .autosaveMinutes) ?? d.autosaveMinutes
        moveBetweenDesktops = try c.decodeIfPresent(Bool.self, forKey: .moveBetweenDesktops) ?? d.moveBetweenDesktops
        launchMissingApps = try c.decodeIfPresent(Bool.self, forKey: .launchMissingApps) ?? d.launchMissingApps
        syncOn = try c.decodeIfPresent(Bool.self, forKey: .syncOn) ?? d.syncOn
        ucSelf = try c.decodeIfPresent(String.self, forKey: .ucSelf)
        ucPeers = try c.decodeIfPresent([String].self, forKey: .ucPeers) ?? d.ucPeers
        ucLink = try c.decodeIfPresent(UCLink.self, forKey: .ucLink)
        manualPeers = try c.decodeIfPresent([String].self, forKey: .manualPeers) ?? d.manualPeers
        hotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeysEnabled) ?? d.hotkeysEnabled
        snapThreshold = try c.decodeIfPresent(Int.self, forKey: .snapThreshold) ?? d.snapThreshold
        wakeOtherMacs = try c.decodeIfPresent(Bool.self, forKey: .wakeOtherMacs) ?? d.wakeOtherMacs
        snapCommands = try c.decodeIfPresent([SnapCommand].self, forKey: .snapCommands)
        dragToSnap = try c.decodeIfPresent(Bool.self, forKey: .dragToSnap) ?? d.dragToSnap
    }

    private static let defaults = AppSettings()
}

/// Everything on disk lives in ~/Library/Application Support/Universal Display Magnet.
enum Persistence {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // UDM_DATA_DIR lets two instances run side by side (sync testing).
        let dir =
            ProcessInfo.processInfo.environment["UDM_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent("Universal Display Magnet", isDirectory: true)
        // Data from before the rename (the app was called DisplayBack).
        let old = base.appendingPathComponent("DisplayBack", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.moveItem(at: old, to: dir)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var recordsURL: URL { directory.appendingPathComponent("records.json") }
    private static var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    private static var deviceURL: URL { directory.appendingPathComponent("device-id") }
    private static var secretURL: URL { directory.appendingPathComponent("pairing-code") }

    static func loadRecords() -> RecordStore {
        guard let data = try? Data(contentsOf: recordsURL),
            let records = try? RecordStore.decoder.decode([SyncRecord].self, from: data)
        else { return RecordStore() }
        return RecordStore(records: records)
    }

    static func saveRecords(_ store: RecordStore) {
        let records = store.records.values.sorted { $0.id < $1.id }
        guard let data = try? RecordStore.encoder.encode(records) else { return }
        try? data.write(to: recordsURL, options: .atomic)
    }

    static func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
            let s = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    static func saveSettings(_ s: AppSettings) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(s) else { return }
        try? data.write(to: settingsURL, options: .atomic)
    }

    /// Stable random id for this Mac.
    static func deviceID() -> String {
        if let s = try? String(contentsOf: deviceURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            !s.isEmpty
        {
            return s
        }
        let id = UUID().uuidString
        try? id.write(to: deviceURL, atomically: true, encoding: .utf8)
        return id
    }
}
