import Foundation

/// What Universal Control reports about the other Macs, read from its log
/// (`log show` for the last hours, then `log stream`) and put in plain words:
/// the Bluetooth signal it finds them by, connections, arrangement changes
/// and keyboard/mouse input it had to throw away.
@MainActor
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()

    struct Event: Identifiable {
        enum Kind {
            /// The other Mac's Bluetooth signal disappeared / came back.
            case signalLost, signalFound
            /// Universal Control decided the other Mac isn't nearby any more / is again.
            case unavailable, available
            case connected, disconnected
            /// The pointer is crossing to the other Mac / coming from it.
            case pointerOut, pointerIn
            /// The arrangement changed (`links` connections; nil = unknown).
            case arrangement(links: Int, fromOtherMac: Bool)
            /// Keyboard/mouse events dropped because the connection was gone.
            case inputDropped
        }

        let id = UUID()
        let date: Date
        let kind: Kind
        /// Universal Control's id for the other Mac (first 8 hex digits).
        let device: String?
        var count = 1

        var isProblem: Bool {
            switch kind {
            case .signalLost, .unavailable, .inputDropped: return true
            case .arrangement(let links, _): return links == 0
            default: return false
            }
        }
    }

    @Published private(set) var events: [Event] = []
    @Published private(set) var loading = false
    @Published private(set) var failed: String?

    private var stream: Process?
    /// When following stopped; the next start reads only the log since then.
    private var stoppedAt: Date?
    private var seen = Set<String>()
    private var configSource: (device: String, date: Date)?
    private static let historyHours = 6
    private static let limit = 3000

    private nonisolated static let predicate = """
        process == "UniversalControl" AND (eventMessage CONTAINS "Device Lost" \
        OR eventMessage CONTAINS "Device Found" OR eventMessage CONTAINS "Device Unavailable" \
        OR eventMessage CONTAINS "Device Available" OR eventMessage BEGINSWITH "Connections:" \
        OR eventMessage CONTAINS "Configuration Changed" OR eventMessage CONTAINS "Merge Config" \
        OR eventMessage CONTAINS "dropping events")
        """

    /// Load the last hours (or what was missed since `stop`) and keep
    /// following new entries.
    func start() {
        guard stream == nil else { return }
        loading = true
        startStream()
        var range = ["--last", "\(Self.historyHours)h"]
        if let stoppedAt {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            range = ["--start", f.string(from: stoppedAt.addingTimeInterval(-5))]
        }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show"] + range + ["--style", "ndjson", "--predicate", Self.predicate]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var data = Data()
            do {
                try p.run()
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
            } catch {}
            let lines = Self.entries(in: data)
            DispatchQueue.main.async {
                self.loading = false
                if lines.isEmpty && p.terminationStatus != 0 {
                    self.failed = String(
                        localized: "Couldn't read Universal Control's log (macOS only shares it with administrator accounts).")
                }
                self.ingest(lines)
            }
        }
    }

    /// Stop following while nobody is looking (`log stream` isn't free).
    func stop() {
        guard let stream else { return }
        self.stream = nil
        stoppedAt = Date()
        stream.terminate()
    }

    private func startStream() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "ndjson", "--predicate", Self.predicate]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let complete = buffer.append(chunk) else { return }
            let lines = Self.entries(in: complete)
            if !lines.isEmpty { DispatchQueue.main.async { self.ingest(lines) } }
        }
        p.terminationHandler = { p in
            // Restarted on the next start() (e.g. reopening Activity).
            DispatchQueue.main.async { if self.stream === p { self.stream = nil } }
        }
        do {
            try p.run()
            stream = p
        } catch {
            failed = String(localized: "Couldn't follow Universal Control's log.")
        }
    }

    // MARK: - Parsing

    struct Entry: Sendable {
        let key: String
        let date: Date
        let message: String
    }

    private nonisolated static func entries(in data: Data) -> [Entry] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let message = obj["eventMessage"] as? String, let stamp = obj["timestamp"] as? String,
                let date = formatter.date(from: stamp)
            else { return nil }
            let category = obj["category"] as? String ?? ""
            return Entry(key: stamp + message, date: date, message: "[\(category)] " + message)
        }
    }

    private func ingest(_ entries: [Entry]) {
        let fresh = entries.filter { seen.insert($0.key).inserted }.sorted { $0.date < $1.date }
        guard !fresh.isEmpty else { return }
        var list = events
        var outOfOrder = false
        for e in fresh {
            if let last = list.last, e.date < last.date { outOfOrder = true }
            guard let event = interpret(e) else { continue }
            // A burst of dropped input is one row.
            if case .inputDropped = event.kind, let i = list.lastIndex(where: { $0.date > e.date.addingTimeInterval(-10) && $0.isDrop }) {
                list[i].count += 1
                continue
            }
            list.append(event)
        }
        if outOfOrder { list.sort { $0.date < $1.date } }
        if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
        events = list
    }

    private func interpret(_ e: Entry) -> Event? {
        let m = e.message
        let device = Self.device(in: m)
        func event(_ kind: Event.Kind, _ device: String? = device) -> Event { Event(date: e.date, kind: kind, device: device) }

        if m.contains("dropping events") { return event(.inputDropped, nil) }
        if m.contains("Device Lost") { return event(.signalLost) }
        if m.contains("Device Found") { return event(.signalFound) }
        // Proximity verdicts come from the SYNC category (DISC repeats "Available").
        if m.hasPrefix("[SYNC]") && m.contains("Device Unavailable") { return event(.unavailable) }
        if m.hasPrefix("[SYNC]") && m.contains("Device Available") { return event(.available) }
        if m.contains("Merge Config"), let device {
            configSource = (device, e.date)
            return nil
        }
        if let r = m.range(of: "Configuration Changed: ") {
            // "OLD:[links] -> NEW:[links]": the new configuration is what counts.
            var rest = m[r.upperBound...]
            if let arrow = rest.range(of: " -> ") { rest = rest[arrow.upperBound...] }
            guard let open = rest.firstIndex(of: "["), let close = rest.lastIndex(of: "]"), open < close else { return nil }
            let body = rest[rest.index(after: open)..<close]
            let links = body.isEmpty ? 0 : body.components(separatedBy: ", ").count
            let source = configSource.flatMap { e.date.timeIntervalSince($0.date) < 3 ? $0.device : nil }
            configSource = nil
            return event(.arrangement(links: links, fromOtherMac: source != nil), source)
        }
        if let r = m.range(of: "Connections: ") {
            let parts = m[r.upperBound...].components(separatedBy: " -> ")
            guard parts.count == 2 else { return nil }
            let before = parts[0], after = parts[1]
            let id = Self.device(in: after) ?? Self.device(in: before)
            if after.contains("(connected)") && !before.contains("(connected)") { return event(.connected, id) }
            if after.contains("glue sending") && !before.contains("glue sending") { return event(.pointerOut, id) }
            if after.contains("glue receiving") && !before.contains("glue receiving") { return event(.pointerIn, id) }
            if after.contains("(disconnecting)") && !before.contains("(disconnecting)") { return event(.disconnected, id) }
            if before.contains("(connected)") && !after.contains("(connected)") && !after.contains("(disconnecting)") {
                return event(.disconnected, id)
            }
            return nil
        }
        return nil
    }

    /// "IDS 1A2B3C4D: …" or "[1A2B3C4D (connected)]" → "1A2B3C4D".
    private static func device(in text: some StringProtocol) -> String? {
        let s = String(text)
        guard let r = s.range(of: #"\b[0-9A-F]{8}\b"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }
}

extension ActivityMonitor.Event {
    var isDrop: Bool {
        if case .inputDropped = kind { return true }
        return false
    }
}

/// Bytes from `log stream` until a whole line has arrived (the readability
/// handler runs serially).
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    /// The complete lines received so far, if any.
    func append(_ chunk: Data) -> Data? {
        data.append(chunk)
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        let complete = Data(data[...end])
        data.removeSubrange(...end)
        return complete
    }
}
