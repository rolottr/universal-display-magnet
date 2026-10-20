import CommonCrypto
import CryptoKit
import Foundation

/// The shared secret two Macs pair with. Everything on the wire is sealed
/// with ChaCha20-Poly1305 under a key derived from it, so a device without
/// the code can neither read nor inject records; there is no server at all.
public struct SyncSecret: Sendable {
    public let key: SymmetricKey
    /// Public, non-reversible id advertised over Bonjour so Macs only dial
    /// peers from their own group.
    public let groupID: String

    public static let protocolVersion = 1
    private static let associatedData = Data("Universal Display Magnet/sync/v1".utf8)

    public init(passphrase: String) {
        let normalized = Self.normalize(passphrase)
        let master = Self.pbkdf2(Data(normalized.utf8), salt: Data("Universal Display Magnet.sync.v1".utf8), rounds: 120_000)
        let masterKey = SymmetricKey(data: master)
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey, info: Data("frame-key".utf8), outputByteCount: 32)
        let group = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey, info: Data("group-id".utf8), outputByteCount: 8)
        groupID = group.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    /// Case, spaces and dashes don't matter when typing the code on the other Mac.
    public static func normalize(_ passphrase: String) -> String {
        passphrase.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// 20 random base32 characters (100 bits), shown as XXXX-XXXX-XXXX-XXXX-XXXX.
    public static func generatePassphrase() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")  // no 0/O/1/I
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 20, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key, authenticating: Self.associatedData).combined
    }

    public func open(_ sealed: Data) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key, authenticating: Self.associatedData)
    }

    private static func pbkdf2(_ password: Data, salt: Data, rounds: UInt32) -> Data {
        var out = Data(count: 32)
        let outCount = out.count
        _ = out.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { pw in
                salt.withUnsafeBytes { s in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pw.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                        outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), outCount)
                }
            }
        }
        return out
    }
}

public struct SyncHello: Codable, Sendable {
    public var deviceID: String
    public var deviceName: String
    public var protocolVersion: Int
    public var digest: [String: RecordVersion]

    public init(deviceID: String, deviceName: String, digest: [String: RecordVersion]) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.protocolVersion = SyncSecret.protocolVersion
        self.digest = digest
    }
}

/// One message between peers.
public struct SyncEnvelope: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello, records, ping
        /// Turn your display on: the other Mac just woke up or was unlocked.
        case wake
    }

    public var kind: Kind
    public var sentAt: Date
    public var hello: SyncHello?
    public var records: [SyncRecord]?
    /// The sender's screens are asleep (sent with hello and every ping;
    /// older versions ignore it).
    public var asleep: Bool?

    public static func hello(_ h: SyncHello) -> SyncEnvelope { SyncEnvelope(kind: .hello, sentAt: Date(), hello: h) }
    public static func records(_ r: [SyncRecord]) -> SyncEnvelope { SyncEnvelope(kind: .records, sentAt: Date(), records: r) }
    public static var ping: SyncEnvelope { SyncEnvelope(kind: .ping, sentAt: Date()) }
    public static func ping(asleep: Bool) -> SyncEnvelope { SyncEnvelope(kind: .ping, sentAt: Date(), asleep: asleep) }
    public static var wake: SyncEnvelope { SyncEnvelope(kind: .wake, sentAt: Date()) }
}

public enum SyncFrameError: Error, Equatable {
    case frameTooLarge(Int)
    case stale
}

/// Length-prefixed sealed frames: [UInt32 big-endian length][sealed JSON].
public enum SyncFraming {
    public static let maxFrame = 32 * 1024 * 1024
    /// Frames older than this are rejected, which bounds replays.
    public static let maxClockSkew: TimeInterval = 15 * 60

    public static func encode(_ envelope: SyncEnvelope, secret: SyncSecret) throws -> Data {
        let json = try RecordStore.encoder.encode(envelope)
        let sealed = try secret.seal(json)
        var length = UInt32(sealed.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(sealed)
        return frame
    }

    public static func decode(_ sealed: Data, secret: SyncSecret, now: Date = Date()) throws -> SyncEnvelope {
        let json = try secret.open(sealed)
        let envelope = try RecordStore.decoder.decode(SyncEnvelope.self, from: json)
        guard abs(envelope.sentAt.timeIntervalSince(now)) <= maxClockSkew else { throw SyncFrameError.stale }
        return envelope
    }
}

/// Reassembles frames from an arbitrary chunked byte stream.
public struct SyncFrameReader: Sendable {
    private var buffer = Data()

    public init() {}

    /// Append received bytes; returns every complete sealed frame body.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let b = [UInt8](buffer.prefix(4))
            let length = Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
            guard length <= SyncFraming.maxFrame else { throw SyncFrameError.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex + 4
            frames.append(Data(buffer[start..<start + length]))
            buffer = Data(buffer[(start + length)...])
        }
        return frames
    }
}
