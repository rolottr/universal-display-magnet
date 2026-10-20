import Foundation

public enum RecordKind: String, Codable, Sendable {
    case arrangement
    case windowLayout
    case device
}

/// Version stamp for last-writer-wins. Millis are bumped past the previous
/// version on every local write, so ordering holds even if the two Macs'
/// clocks disagree a little; the device id breaks exact ties.
public struct RecordVersion: Codable, Hashable, Comparable, Sendable {
    public var millis: Int64
    public var device: String

    public init(millis: Int64, device: String) {
        self.millis = millis
        self.device = device
    }

    public static func < (l: RecordVersion, r: RecordVersion) -> Bool {
        l.millis != r.millis ? l.millis < r.millis : l.device < r.device
    }
}

/// One replicated document. `payload` is the JSON of the typed model.
public struct SyncRecord: Codable, Hashable, Sendable {
    public var id: String
    public var kind: RecordKind
    public var version: RecordVersion
    public var deleted: Bool
    public var payload: Data

    public init(id: String, kind: RecordKind, version: RecordVersion, deleted: Bool = false, payload: Data) {
        self.id = id
        self.kind = kind
        self.version = version
        self.deleted = deleted
        self.payload = payload
    }
}

/// All replicated state on one Mac. Merging is commutative and idempotent,
/// so peers converge no matter the order messages arrive in.
public struct RecordStore: Codable, Sendable {
    public private(set) var records: [String: SyncRecord] = [:]

    public init(records: [SyncRecord] = []) {
        for r in records { self.records[r.id] = r }
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    /// Write a value locally. Returns the record to broadcast, or nil when
    /// the payload is unchanged (no version bump, no sync traffic).
    @discardableResult
    public mutating func put<T: Encodable>(
        _ value: T, id: String, kind: RecordKind, device: String, now: Date = Date()
    ) -> SyncRecord? {
        guard let payload = try? Self.encoder.encode(value) else { return nil }
        if let existing = records[id], !existing.deleted, existing.payload == payload { return nil }
        let record = SyncRecord(
            id: id, kind: kind, version: nextVersion(for: id, device: device, now: now), payload: payload)
        records[id] = record
        return record
    }

    /// Mark a record deleted (tombstone, so the deletion replicates).
    @discardableResult
    public mutating func delete(id: String, device: String, now: Date = Date()) -> SyncRecord? {
        guard let existing = records[id], !existing.deleted else { return nil }
        let record = SyncRecord(
            id: id, kind: existing.kind, version: nextVersion(for: id, device: device, now: now), deleted: true,
            payload: Data())
        records[id] = record
        return record
    }

    /// Apply remote records; returns those that won and changed local state.
    @discardableResult
    public mutating func merge(_ incoming: [SyncRecord]) -> [SyncRecord] {
        var accepted: [SyncRecord] = []
        for r in incoming {
            if let local = records[r.id], local.version >= r.version { continue }
            records[r.id] = r
            accepted.append(r)
        }
        return accepted
    }

    /// id → version, sent in the hello so a peer can reply with only what we lack.
    public var digest: [String: RecordVersion] { records.mapValues(\.version) }

    /// Records the owner of `digest` is missing or has an older version of.
    public func newer(than digest: [String: RecordVersion]) -> [SyncRecord] {
        records.values.filter { r in digest[r.id].map { $0 < r.version } ?? true }
            .sorted { $0.id < $1.id }
    }

    public func values<T: Decodable>(_ kind: RecordKind, as type: T.Type) -> [T] {
        records.values
            .filter { $0.kind == kind && !$0.deleted }
            .sorted { $0.id < $1.id }
            .compactMap { try? Self.decoder.decode(T.self, from: $0.payload) }
    }

    public func value<T: Decodable>(id: String, as type: T.Type) -> T? {
        guard let r = records[id], !r.deleted else { return nil }
        return try? Self.decoder.decode(T.self, from: r.payload)
    }

    /// Drop tombstones old enough that every peer has surely seen them.
    public mutating func pruneTombstones(olderThan age: TimeInterval, now: Date = Date()) {
        let cutoff = Int64((now.timeIntervalSince1970 - age) * 1000)
        records = records.filter { !($0.value.deleted && $0.value.version.millis < cutoff) }
    }

    private func nextVersion(for id: String, device: String, now: Date) -> RecordVersion {
        let wall = Int64(now.timeIntervalSince1970 * 1000)
        let floor = (records[id]?.version.millis ?? 0) + 1
        return RecordVersion(millis: max(wall, floor), device: device)
    }
}
