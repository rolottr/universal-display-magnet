import UniversalDisplayMagnetCore
import Foundation
import UniversalControl

/// Reads and writes Universal Control's cross-Mac display arrangement using
/// Apple's own UniversalControl framework (the code System Settings runs),
/// so the configuration's hashes and format are produced by Apple's code.
/// Universal Control picks changes up live and syncs them to the other Mac.
enum UCBridge {
    struct State: Equatable {
        /// Universal Control's id for this Mac.
        var selfDevice: String?
        /// Every device Universal Control knows → the display UUIDs it has linked.
        var devices: [String: Set<String>]
        /// Current links (the arrangement).
        var links: [UCLink]
        var enabled: Bool

        func device(owning displayUUIDs: [String]) -> String? {
            let set = Set(displayUUIDs)
            return devices.max { $0.value.intersection(set).count < $1.value.intersection(set).count }
                .flatMap { $0.value.intersection(set).isEmpty ? nil : $0.key }
        }

        /// The current link between two devices, oriented device1 = `from`.
        func link(from: String, to: String) -> UCLink? {
            for l in links {
                if l.device1 == from && l.device2 == to { return l }
                if l.device1 == to && l.device2 == from {
                    return UCLink(
                        device1: from, display1: l.display2, device2: to, display2: l.display1, edge: l.edge.opposite,
                        offset1: l.offset2, offset2: l.offset1)
                }
            }
            return nil
        }
    }

    enum BridgeError: LocalizedError {
        case unavailable, noConfiguration, badID(String), verificationFailed

        var errorDescription: String? {
            switch self {
            case .unavailable: return String(localized: "Universal Control isn't available on this Mac")
            case .noConfiguration:
                return String(
                    localized: "Universal Control has no arrangement yet; link the Macs once in System Settings › Displays")
            case .badID(let s): return String(localized: "Unexpected Universal Control id \(s)")
            case .verificationFailed:
                return String(
                    localized:
                        "Refused to save: the new arrangement didn't read back correctly (macOS may have changed Universal Control)")
            }
        }
    }

    /// The private framework and the symbols we call are present.
    static let isAvailable: Bool = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/UniversalControl.framework/UniversalControl", RTLD_NOW)
        else { return false }
        let required = [
            "$s16UniversalControl0aB11PreferencesC6sharedACvgZ",
            "$s16UniversalControl0aB11PreferencesC13configurationAA0aB13ConfigurationVSgvg",
            "$s16UniversalControl0aB11PreferencesC13configurationAA0aB13ConfigurationVSgvs",
            "$s16UniversalControl0aB13ConfigurationV9replacing5linksACSayAA0aB4LinkVG_tF",
            "$s16UniversalControl0aB4LinkV8display18display24edge12fixedOffset10G7Offset2AcA0aB9DisplayIDV_AjA0aB4EdgeOs6UInt16VANtcfC",
        ]
        return required.allSatisfy { dlsym(h, $0) != nil }
    }()

    // MARK: - Reading

    static func read() -> State? {
        guard isAvailable else { return nil }
        let prefs = UniversalControlPreferences.shared
        let links = prefs.configuration?.links().map { convert($0.link) } ?? []
        var devices: [String: Set<String>] = [:]
        // Every device/display pair in the stored history, not just the
        // current links, so Macs are recognised even when unlinked right now.
        for (device, display) in historyPairs() { devices[device, default: []].insert(display) }
        for l in links {
            devices[l.device1, default: []].insert(l.display1)
            devices[l.device2, default: []].insert(l.display2)
        }
        let local = DisplayService.activeDisplays().compactMap(\.identity.uuid)
        var state = State(selfDevice: nil, devices: devices, links: links, enabled: prefs.enabled)
        state.selfDevice = state.device(owning: local)
        return state
    }

    /// (device, display) pairs from Universal Control's stored configuration.
    private static func historyPairs() -> [(String, String)] {
        guard
            let blob = CFPreferencesCopyValue(
                "Configuration" as CFString, "com.apple.universalcontrol" as CFString, kCFPreferencesCurrentUser,
                kCFPreferencesCurrentHost) as? Data,
            let config = try? PropertyListSerialization.propertyList(from: blob, format: nil) as? [String: Any],
            let heap = config["heap"] as? [[Any]]
        else { return [] }
        var pairs: [(String, String)] = []
        for node in heap where node.count > 5 {
            for case let entry as [Any] in node[5...] where entry.count >= 6 {
                if let d1 = entry[2] as? String, let s1 = entry[3] as? String { pairs.append((d1, s1)) }
                if let d2 = entry[4] as? String, let s2 = entry[5] as? String { pairs.append((d2, s2)) }
            }
        }
        return pairs
    }

    private static func convert(_ l: UniversalControlLink) -> UCLink {
        UCLink(
            device1: l.display1.deviceID.uuidValue.uuidString, display1: l.display1.displayUUID.uuidValue.uuidString,
            device2: l.display2.deviceID.uuidValue.uuidString, display2: l.display2.displayUUID.uuidValue.uuidString,
            edge: UCLink.Edge(rawValue: l.edge.intValue) ?? .right, offset1: l.fixedOffset1, offset2: l.fixedOffset2)
    }

    // MARK: - Writing

    /// Make `link` the link between its two Macs (Universal Control keeps one
    /// per pair); links to any other device are kept. The result is verified
    /// and the previous links backed up before Universal Control gets it.
    static func apply(_ link: UCLink) throws {
        guard isAvailable else { throw BridgeError.unavailable }
        let newLinks = [link]
        let prefs = UniversalControlPreferences.shared
        guard let config = prefs.configuration else { throw BridgeError.noConfiguration }

        let pair: Set<String> = [link.device1, link.device2]
        var links = config.links().map(\.link).filter {
            Set([$0.display1.deviceID.uuidValue.uuidString, $0.display2.deviceID.uuidValue.uuidString]) != pair
        }
        links += try newLinks.map(make)
        let next = config.replacing(links: links)

        // Read the encoded result back with Apple's decoder and check every
        // link survived intact; any ABI mismatch shows up here, before saving.
        let decoded = try UniversalControlConfiguration(data: try next.encoded()).links().map { convert($0.link) }
        guard newLinks.allSatisfy({ l in decoded.contains { same($0, l) } }) else {
            throw BridgeError.verificationFailed
        }
        backup(config)
        prefs.configuration = next
        prefs.configurationID = next.digest
        CFPreferencesAppSynchronize("com.apple.universalcontrol" as CFString)
    }

    private static func same(_ a: UCLink, _ b: UCLink) -> Bool {
        let flipped = UCLink(
            device1: b.device2, display1: b.display2, device2: b.device1, display2: b.display1, edge: b.edge.opposite,
            offset1: b.offset2, offset2: b.offset1)
        return a == b || a == flipped
    }

    private static func make(_ l: UCLink) throws -> UniversalControlLink {
        func uuid(_ s: String) throws -> UUID {
            guard let u = UUID(uuidString: s) else { throw BridgeError.badID(s) }
            return u
        }
        let d1 = UniversalControlDisplayID(
            deviceID: UniversalControlDeviceID(uuid: try uuid(l.device1)),
            displayUUID: UniversalControlUUID(uuid: try uuid(l.display1)))
        let d2 = UniversalControlDisplayID(
            deviceID: UniversalControlDeviceID(uuid: try uuid(l.device2)),
            displayUUID: UniversalControlUUID(uuid: try uuid(l.display2)))
        guard let edge = UniversalControlEdge(intValue: l.edge.rawValue) else { throw BridgeError.badID("edge") }
        return UniversalControlLink(display1: d1, display2: d2, edge: edge, fixedOffset1: l.offset1, fixedOffset2: l.offset2)
    }

    // MARK: - Reset

    /// The services Universal Control runs on: Bluetooth discovery (sharingd),
    /// the Continuity link between Macs (rapportd) and Universal Control
    /// itself. They run as this user and launchd starts them again at once,
    /// so stopping them resets a Universal Control that lost the other Mac.
    /// (`launchctl kickstart` is refused under SIP, and Universal Control
    /// ignores SIGTERM, so it gets SIGKILL.)
    static func restartServices() {
        killall(["sharingd", "rapportd"])
        killall(["-KILL", "UniversalControl"])
    }

    private static func killall(_ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = arguments
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - Backups

    static var backupDirectory: URL { Persistence.directory.appendingPathComponent("universal-control-backups") }

    /// Keep the links as they were before each change (newest 30).
    private static func backup(_ config: UniversalControlConfiguration) {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let links = config.links().map { convert($0.link) }
        guard let data = try? JSONEncoder().encode(links) else { return }
        let name = "links-\(Int(Date().timeIntervalSince1970 * 1000)).json"
        try? data.write(to: backupDirectory.appendingPathComponent(name))
        let all = (try? fm.contentsOfDirectory(atPath: backupDirectory.path).sorted()) ?? []
        for old in all.dropLast(30) { try? fm.removeItem(at: backupDirectory.appendingPathComponent(old)) }
    }

    static var canUndo: Bool { latestBackup != nil }

    private static var latestBackup: URL? {
        let all = (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path).sorted()) ?? []
        return all.last.map { backupDirectory.appendingPathComponent($0) }
    }

    /// Put back the links from before the last change.
    static func undo() throws {
        guard let url = latestBackup, let data = try? Data(contentsOf: url),
            let links = try? JSONDecoder().decode([UCLink].self, from: data)
        else { return }
        let prefs = UniversalControlPreferences.shared
        guard let config = prefs.configuration else { throw BridgeError.noConfiguration }
        let next = config.replacing(links: try links.map(make))
        _ = try UniversalControlConfiguration(data: try next.encoded())
        prefs.configuration = next
        prefs.configurationID = next.digest
        CFPreferencesAppSynchronize("com.apple.universalcontrol" as CFString)
        try? FileManager.default.removeItem(at: url)
    }
}
