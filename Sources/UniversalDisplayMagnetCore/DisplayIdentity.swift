import Foundation

/// Everything we know that identifies a physical display.
///
/// display-align keys displays on (vendor, model) only, so two units of the
/// same monitor collapse into one and the second is never placed; it also
/// refuses to do anything without a built-in panel (Mac Studio, Mac mini,
/// clamshell). Here identity prefers the EDID serial, then falls back through
/// weaker signals, and nothing is special-cased around the built-in display.
public struct DisplayIdentity: Codable, Hashable, Sendable {
    public var vendor: UInt32
    public var model: UInt32
    /// EDID numeric serial (`CGDisplaySerialNumber`); 0 when the panel doesn't report one.
    public var serial: UInt32
    /// EDID alphanumeric serial (IOKit `AlphanumericSerialNumber`), when available.
    public var alphanumericSerial: String?
    public var name: String
    public var isBuiltin: Bool
    /// `CGDisplayCreateUUIDFromDisplayID` — stable on one Mac, tie-breaker only.
    public var uuid: String?

    public init(
        vendor: UInt32, model: UInt32, serial: UInt32, alphanumericSerial: String? = nil,
        name: String, isBuiltin: Bool = false, uuid: String? = nil
    ) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.alphanumericSerial = alphanumericSerial?.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.alphanumericSerial?.isEmpty == true { self.alphanumericSerial = nil }
        self.name = name
        self.isBuiltin = isBuiltin
        self.uuid = uuid
    }

    /// True when this unit can be told apart from an identical model.
    public var hasUniqueSerial: Bool { alphanumericSerial != nil || serial != 0 }

    /// Cross-machine key for this physical display. Two identical monitors
    /// without serials share a key; `DisplaySetup` disambiguates them by count.
    public var hardwareKey: String {
        let base = String(format: "%04x-%04x", vendor, model)
        if let s = alphanumericSerial { return "\(base)-\(s)" }
        if serial != 0 { return "\(base)-\(serial)" }
        return base
    }
}

/// The set of displays connected to a Mac. Profiles are stored per setup, so
/// "desk", "laptop only" and "office" each remember their own arrangement and
/// windows. Keys are hardware-based, so the same monitors on the other Mac
/// resolve to the same setup.
public enum DisplaySetup {
    public static func key(for identities: [DisplayIdentity]) -> String {
        identities.map(\.hardwareKey).sorted().joined(separator: "+")
    }

    /// Human label: "LG HDR WQHD + ANMITE".
    public static func label(for identities: [DisplayIdentity]) -> String {
        identities.map(\.name).joined(separator: " + ")
    }
}

public enum DisplayMatcher {
    /// How confidently `saved` describes `live`, or nil if it can't be the same unit.
    public static func score(saved: DisplayIdentity, live: DisplayIdentity) -> Int? {
        if saved.isBuiltin && live.isBuiltin { return 1000 }
        guard saved.vendor == live.vendor, saved.model == live.model else { return nil }
        var score = 10
        if let a = saved.alphanumericSerial, let b = live.alphanumericSerial {
            guard a == b else { return nil }
            score += 100
        }
        if saved.serial != 0 && live.serial != 0 {
            guard saved.serial == live.serial else { return nil }
            score += 50
        }
        if let a = saved.uuid, a == live.uuid { score += 20 }
        if saved.name == live.name { score += 1 }
        return score
    }

    /// Pair saved displays with live ones, one-to-one, best matches first.
    /// Returns `savedIndex -> liveIndex`.
    public static func match(saved: [DisplayIdentity], live: [DisplayIdentity]) -> [Int: Int] {
        var pairs: [(score: Int, s: Int, l: Int)] = []
        for (si, s) in saved.enumerated() {
            for (li, l) in live.enumerated() {
                if let sc = score(saved: s, live: l) { pairs.append((sc, si, li)) }
            }
        }
        // Stable order for ties (identical monitors without serials): keep the
        // saved order paired with the live order.
        pairs.sort { $0.score != $1.score ? $0.score > $1.score : ($0.s, $0.l) < ($1.s, $1.l) }
        var result: [Int: Int] = [:]
        var usedLive: Set<Int> = []
        for p in pairs where result[p.s] == nil && !usedLive.contains(p.l) {
            result[p.s] = p.l
            usedLive.insert(p.l)
        }
        return result
    }
}
