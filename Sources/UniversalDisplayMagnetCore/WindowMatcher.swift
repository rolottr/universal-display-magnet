import Foundation

/// A live window as the matcher sees it.
public struct WindowCandidate: Hashable, Sendable {
    public var key: Int
    public var bundleID: String
    public var title: String
    public var windowNumber: UInt32?

    public init(key: Int, bundleID: String, title: String, windowNumber: UInt32?) {
        self.key = key
        self.bundleID = bundleID
        self.title = title
        self.windowNumber = windowNumber
    }
}

public enum MatchKind: String, Sendable {
    case windowNumber, exactTitle, fuzzyTitle, appSlot
}

/// Pairs saved windows with live ones (adapted from SnapBack's cascade):
/// window number → exact title → fuzzy title → any spare window of the same app.
/// Each live window is used at most once.
public enum WindowMatcher {
    public struct Match: Sendable {
        public var savedIndex: Int
        public var candidateKey: Int
        public var kind: MatchKind
    }

    /// Lowercased, with app suffixes, counters like "(3)", digits and punctuation removed.
    public static func normalize(_ title: String) -> String {
        var s = title.lowercased()
        for suffix in [" - google chrome", " — google chrome", " - visual studio code", " — mozilla firefox", " - mozilla firefox"]
        where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        s = String(s.unicodeScalars.filter { CharacterSet.letters.contains($0) || $0 == " " })
        return s.split(separator: " ").joined(separator: " ")
    }

    /// Substring containment on normalized titles; empty titles carry no signal.
    public static func similar(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na.contains(nb) || nb.contains(na)
    }

    public static func assign(saved: [WindowSnapshot], candidates: [WindowCandidate]) -> [Match] {
        var used: Set<Int> = []
        var matched: [Int: Match] = [:]

        // Run each tier across all saved windows before moving to a weaker
        // one, so a weak match can't steal a window a later saved entry
        // matches exactly.
        let tiers: [(MatchKind, (WindowSnapshot, WindowCandidate) -> Bool)] = [
            (.windowNumber, { s, c in s.windowNumber != nil && s.windowNumber == c.windowNumber && s.bundleID == c.bundleID }),
            (.exactTitle, { s, c in s.bundleID == c.bundleID && s.title == c.title }),
            (.fuzzyTitle, { s, c in s.bundleID == c.bundleID && similar(s.title, c.title) }),
            (.appSlot, { s, c in s.bundleID == c.bundleID }),
        ]
        for (kind, predicate) in tiers {
            for (i, s) in saved.enumerated() where matched[i] == nil {
                if let c = candidates.first(where: { !used.contains($0.key) && predicate(s, $0) }) {
                    used.insert(c.key)
                    matched[i] = Match(savedIndex: i, candidateKey: c.key, kind: kind)
                }
            }
        }
        return matched.keys.sorted().map { matched[$0]! }
    }
}
