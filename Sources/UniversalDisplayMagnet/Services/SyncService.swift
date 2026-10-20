import UniversalDisplayMagnetCore
import Foundation
import Network

/// Mac-to-Mac sync with no server: each Mac advertises itself over Bonjour on
/// the local network (Wi-Fi, Ethernet, Thunderbolt Bridge or peer-to-peer
/// Wi-Fi), dials Macs it shares a key with, and exchanges sealed record sets.
/// Keys come from identities Universal Control already shares between your
/// Macs, so there's nothing to pair by hand. State lives only on the Macs.
final class SyncService {
    static let serviceType = "_udmagnet._tcp"
    static let preferredPort: NWEndpoint.Port = 52731

    struct Peer: Identifiable, Hashable {
        var id: String  // device id
        var name: String
        var endpoint: String
        var connectedAt: Date
        var lastMessageAt: Date
    }

    // Callbacks are delivered on the main queue.
    var onPeersChanged: (([Peer]) -> Void)?
    var onRecords: (([SyncRecord], String) -> Void)?
    /// The peer just woke up or was unlocked and asks us to turn the display on.
    var onWake: ((String) -> Void)?
    /// The peer is resetting Universal Control and asks us to do the same.
    var onResetUniversalControl: ((String) -> Void)?
    /// A peer's screens went to sleep or woke (peer id, asleep).
    var onPeerAsleep: ((String, Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "Universal Display Magnet.sync")
    private let deviceID: String
    private let deviceName: String
    private let digestProvider: () -> [String: RecordVersion]
    private let recordsProvider: ([String: RecordVersion]) -> [SyncRecord]

    /// One key per Mac we trust.
    private var secrets: [SyncSecret] = []
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: PeerConnection] = [:]
    private var browseResults: [String: (endpoint: NWEndpoint, secret: SyncSecret)] = [:]  // peer id →
    private var manualPeers: [String] = []
    /// Device id each manual address turned out to be (possibly this Mac).
    private var manualPeerIDs: [String: String] = [:]
    private var timer: DispatchSourceTimer?
    private var asleep = false
    private let onlineLock = NSLock()
    private var online: Set<String> = []

    /// `digestProvider` / `recordsProvider` are called on the sync queue and
    /// must be thread-safe.
    init(
        deviceID: String, deviceName: String, digestProvider: @escaping () -> [String: RecordVersion],
        recordsProvider: @escaping ([String: RecordVersion]) -> [SyncRecord]
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.digestProvider = digestProvider
        self.recordsProvider = recordsProvider
    }

    // MARK: - Lifecycle

    func start(secrets: [SyncSecret], manualPeers: [String]) {
        queue.async {
            self.stopLocked()
            self.secrets = secrets
            guard !secrets.isEmpty else { return }
            self.manualPeers = manualPeers
            self.startListener(port: Self.preferredPort)
            self.startBrowser()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 5, repeating: 20)
            t.setEventHandler { self.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.async { self.stopLocked() }
    }

    func updateManualPeers(_ peers: [String]) {
        queue.async {
            self.manualPeers = peers
            self.tick()
        }
    }

    /// Ask a peer to turn its display on.
    /// Whether this Mac's screens are asleep, told to peers with every ping.
    func setAsleep(_ asleep: Bool) {
        queue.async {
            self.asleep = asleep
            for c in self.connections.values where c.peerID != nil { self.send(.ping(asleep: asleep), on: c) }
        }
    }

    func sendWake(to peerID: String) {
        queue.async {
            guard let c = self.connections.values.first(where: { $0.peerID == peerID }) else { return }
            self.send(.wake, on: c)
        }
    }

    func sendResetUniversalControl(to peerID: String) {
        queue.async {
            guard let c = self.connections.values.first(where: { $0.peerID == peerID }) else { return }
            self.send(.resetUniversalControl, on: c)
        }
    }

    /// Peers with a live, authenticated connection (any thread).
    func isOnline(_ peerID: String) -> Bool {
        onlineLock.lock()
        defer { onlineLock.unlock() }
        return online.contains(peerID)
    }

    /// Drop every connection and dial again (after wake, sockets are stale).
    func reconnect() {
        queue.async {
            for c in self.connections.values { c.connection.cancel() }
            self.queue.asyncAfter(deadline: .now() + 1) { self.tick() }
        }
    }

    /// Send records to every connected peer.
    func broadcast(_ records: [SyncRecord], except peerID: String? = nil) {
        guard !records.isEmpty else { return }
        queue.async {
            for c in self.connections.values where c.peerID != nil && c.peerID != peerID {
                self.send(.records(records), on: c)
            }
        }
    }

    private func stopLocked() {
        timer?.cancel()
        timer = nil
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for c in connections.values { c.connection.cancel() }
        connections.removeAll()
        browseResults.removeAll()
        manualPeerIDs.removeAll()
        publishPeers()
    }

    // MARK: - Listener / browser

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        return params
    }

    private func startListener(port: NWEndpoint.Port?) {
        guard !secrets.isEmpty else { return }
        let params = Self.parameters()
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try port.map { try NWListener(using: params, on: $0) } ?? NWListener(using: params)
        } catch {
            if port != nil { startListener(port: nil) }  // preferred port taken: any port
            return
        }
        listener.service = NWListener.Service(
            name: deviceName, type: Self.serviceType,
            txtRecord: NWTXTRecord([
                "id": deviceID, "g": secrets.map(\.groupID).joined(separator: ","), "v": "\(SyncSecret.protocolVersion)",
            ]))
        listener.newConnectionHandler = { [weak self] conn in self?.adopt(conn, outbound: false) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.log("Listening on port \(listener.port?.rawValue ?? 0)")
            case .failed(let error):
                self.log("Listener failed: \(error)")
                listener.cancel()
                guard self.listener === listener else { return }
                if port != nil {
                    self.startListener(port: nil)
                } else {
                    self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                        guard let self, self.listener === listener else { return }
                        self.startListener(port: Self.preferredPort)
                    }
                }
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func startBrowser() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [String: (endpoint: NWEndpoint, secret: SyncSecret)] = [:]
            for r in results {
                guard case .bonjour(let txt) = r.metadata, let id = txt["id"], id != self.deviceID else { continue }
                let groups = Set((txt["g"] ?? "").split(separator: ",").map(String.init))
                guard let secret = self.secrets.first(where: { groups.contains($0.groupID) }) else { continue }
                found[id] = (r.endpoint, secret)
            }
            self.browseResults = found
            self.tick()
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, case .failed(let error) = state else { return }
            self.log("Discovery failed: \(error); retrying")
            browser?.cancel()
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !self.secrets.isEmpty, self.browser === browser else { return }
                self.startBrowser()
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    /// Dial anyone we know about but aren't talking to; ping the rest.
    private func tick() {
        // A peer that has been silent through several pings is gone (asleep,
        // changed network); drop it so it can be redialled.
        for c in connections.values where Date().timeIntervalSince(c.lastMessageAt) > 70 {
            c.connection.cancel()
        }
        let connectedOrDialing = Set(connections.values.compactMap { $0.peerID ?? $0.expectedPeerID })
        for (id, found) in browseResults where !connectedOrDialing.contains(id) {
            adopt(
                NWConnection(to: found.endpoint, using: Self.parameters()), outbound: true, expectedPeerID: id,
                secret: found.secret)
        }
        for address in manualPeers where !connections.values.contains(where: { $0.manualAddress == address }) {
            // Already talking to that Mac another way, or it's this Mac.
            if let id = manualPeerIDs[address], id == deviceID || connectedOrDialing.contains(id) { continue }
            let parts = address.split(separator: ":")
            let host = String(parts.first ?? "")
            let port = parts.count > 1 ? NWEndpoint.Port(String(parts[1])) : Self.preferredPort
            guard !host.isEmpty, let port else { continue }
            let c = NWConnection(host: NWEndpoint.Host(host), port: port, using: Self.parameters())
            adopt(c, outbound: true, manualAddress: address)
        }
        for c in connections.values where c.peerID != nil { send(.ping(asleep: asleep), on: c) }
    }

    // MARK: - Connections

    private func adopt(
        _ connection: NWConnection, outbound: Bool, expectedPeerID: String? = nil, manualAddress: String? = nil,
        secret: SyncSecret? = nil
    ) {
        let peer = PeerConnection(
            connection: connection, outbound: outbound, expectedPeerID: expectedPeerID, manualAddress: manualAddress)
        peer.secret = secret
        let key = ObjectIdentifier(peer)
        connections[key] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready:
                var hello = SyncEnvelope.hello(
                    SyncHello(deviceID: self.deviceID, deviceName: self.deviceName, digest: self.digestProvider()))
                hello.asleep = self.asleep
                if peer.secret != nil {
                    self.send(hello, on: peer)
                    peer.helloSent = true
                } else if peer.outbound {
                    // Dialled by address: we don't know which of our keys the
                    // other side has, so say hello with each.
                    for s in self.secrets { self.send(hello, on: peer, using: s) }
                }
                self.receive(on: peer)
            case .failed, .cancelled:
                self.drop(peer)
            case .waiting:
                // No route (peer asleep, Wi-Fi off): give up and let tick() redial.
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        // Never let an unauthenticated connection linger.
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak peer] in
            if let peer, peer.peerID == nil { peer.connection.cancel() }
            _ = self
        }
    }

    private func drop(_ peer: PeerConnection) {
        guard connections.removeValue(forKey: ObjectIdentifier(peer)) != nil else { return }
        if let id = peer.peerID { log("Disconnected from \(peer.peerName ?? id)") }
        publishPeers()
    }

    private func receive(on peer: PeerConnection) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            if let data, !data.isEmpty {
                do {
                    for body in try peer.reader.append(data) {
                        do {
                            try self.handle(body, from: peer)
                        } catch SyncFrameError.stale {
                            throw SyncFrameError.stale
                        } catch where peer.rejected < 8 {
                            // A frame sealed with a key we don't share is
                            // skipped: address dial-ups say hello with each key.
                            peer.rejected += 1
                        }
                    }
                } catch SyncFrameError.stale {
                    self.log("Ignoring \(peer.peerName ?? peer.endpointDescription): its clock is more than 15 minutes off")
                    peer.connection.cancel()
                    return
                } catch {
                    self.log("Rejected data from \(peer.peerName ?? peer.endpointDescription): not one of your Macs")
                    peer.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                peer.connection.cancel()
            } else {
                self.receive(on: peer)
            }
        }
    }

    private func handle(_ body: Data, from peer: PeerConnection) throws {
        let envelope: SyncEnvelope
        if let secret = peer.secret {
            envelope = try SyncFraming.decode(body, secret: secret)
        } else {
            // First frame from this peer: find which shared key it uses.
            var opened: (SyncEnvelope, SyncSecret)?
            for s in secrets {
                if let e = try? SyncFraming.decode(body, secret: s) {
                    opened = (e, s)
                    break
                }
            }
            guard let (e, s) = opened, e.kind == .hello else { throw SyncFrameError.frameTooLarge(0) }
            envelope = e
            peer.secret = s
        }
        peer.lastMessageAt = Date()
        switch envelope.kind {
        case .hello:
            guard let hello = envelope.hello else { return }
            if let address = peer.manualAddress { manualPeerIDs[address] = hello.deviceID }
            guard hello.deviceID != deviceID else {
                peer.connection.cancel()
                return
            }
            peer.peerID = hello.deviceID
            peer.peerName = hello.deviceName
            peer.connectedAt = Date()
            // Both Macs may dial each other at once; both sides keep the
            // connection initiated by the smaller device id.
            for other in connections.values where other !== peer && other.peerID == hello.deviceID {
                let otherInitiator = other.outbound ? deviceID : hello.deviceID
                let keepOther = otherInitiator == min(deviceID, hello.deviceID)
                (keepOther ? peer : other).connection.cancel()
                if keepOther { return }
            }
            log("Connected to \(hello.deviceName)")
            if let asleep = envelope.asleep {
                let id = hello.deviceID
                DispatchQueue.main.async { self.onPeerAsleep?(id, asleep) }
            }
            if !peer.helloSent {
                // Answer once with our own hello now that we know the shared key.
                var reply = SyncEnvelope.hello(SyncHello(deviceID: deviceID, deviceName: deviceName, digest: digestProvider()))
                reply.asleep = asleep
                send(reply, on: peer)
                peer.helloSent = true
            }
            publishPeers()
            let missing = recordsProvider(hello.digest)
            if !missing.isEmpty { send(.records(missing), on: peer) }
        case .records:
            guard let from = peer.peerID, let records = envelope.records, !records.isEmpty else { return }
            DispatchQueue.main.async { self.onRecords?(records, from) }
            publishPeers()
        case .wake:
            guard let from = peer.peerID else { return }
            DispatchQueue.main.async { self.onWake?(from) }
        case .resetUniversalControl:
            guard let from = peer.peerID else { return }
            DispatchQueue.main.async { self.onResetUniversalControl?(from) }
        case .ping where envelope.asleep != nil:
            if let from = peer.peerID, let asleep = envelope.asleep {
                DispatchQueue.main.async { self.onPeerAsleep?(from, asleep) }
            }
        case .ping, .unknown:
            break
        }
    }

    private func send(_ envelope: SyncEnvelope, on peer: PeerConnection, using key: SyncSecret? = nil) {
        guard let secret = key ?? peer.secret, let frame = try? SyncFraming.encode(envelope, secret: secret) else {
            return
        }
        peer.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func publishPeers() {
        onlineLock.lock()
        online = Set(connections.values.compactMap(\.peerID))
        onlineLock.unlock()
        let peers = connections.values.compactMap { c -> Peer? in
            guard let id = c.peerID else { return nil }
            return Peer(
                id: id, name: c.peerName ?? id, endpoint: c.endpointDescription, connectedAt: c.connectedAt,
                lastMessageAt: c.lastMessageAt)
        }.sorted { $0.name < $1.name }
        DispatchQueue.main.async { self.onPeersChanged?(peers) }
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { self.onLog?(message) }
    }
}

private final class PeerConnection {
    let connection: NWConnection
    let outbound: Bool
    let expectedPeerID: String?
    let manualAddress: String?
    var reader = SyncFrameReader()
    var secret: SyncSecret?
    var rejected = 0
    var helloSent = false
    var peerID: String?
    var peerName: String?
    var connectedAt = Date()
    var lastMessageAt = Date()

    init(connection: NWConnection, outbound: Bool, expectedPeerID: String?, manualAddress: String?) {
        self.connection = connection
        self.outbound = outbound
        self.expectedPeerID = expectedPeerID
        self.manualAddress = manualAddress
    }

    var endpointDescription: String {
        if let manualAddress { return manualAddress }
        switch connection.endpoint {
        case .hostPort(let host, let port): return "\(host):\(port)"
        case .service(let name, _, _, _): return name
        default: return "\(connection.endpoint)"
        }
    }
}
