import AppKit
import SwiftUI

/// A timeline of what Universal Control did with the other Macs, and what
/// Universal Display Magnet did, so dropouts can be understood.
struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var monitor = ActivityMonitor.shared
    @StateObject private var problemsOnlyState = ViewState(false)
    private var problemsOnly: Bool {
        get { problemsOnlyState.value }
        nonmutating set { problemsOnlyState.value = newValue }
    }

    private struct Row: Identifiable {
        let id: UUID
        let date: Date
        let icon: String
        let color: Color
        let text: String
        let problem: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity").font(.title2.weight(.semibold))
                    Text(
                        "What Universal Control reports about your other Macs — the Bluetooth signal it finds them by, connections, arrangement changes, input it had to throw away — and what Universal Display Magnet did. Read live from macOS's log."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                summary
                controls
                timeline
            }
            .padding(22)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    // MARK: - Summary

    private var summary: some View {
        let hourAgo = Date().addingTimeInterval(-3600)
        let recent = monitor.events.filter { $0.date > hourAgo }
        let dropouts = recent.filter { if case .signalLost = $0.kind { return true } else { return false } }.count
        let notNearby = recent.filter { if case .unavailable = $0.kind { return true } else { return false } }.count
        let lostInput = recent.filter(\.isDrop).reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                tile("\(dropouts)", "Bluetooth dropouts", dropouts > 0 ? .orange : .secondary)
                tile("\(notNearby)", "Times Universal Control gave up", notNearby > 0 ? .red : .secondary)
                tile("\(lostInput)", "Keyboard/mouse events lost", lostInput > 0 ? .red : .secondary)
            }
            Text(
                dropouts > 2
                    ? "In the last hour. Frequent Bluetooth dropouts usually mean interference next to one of the Macs (USB 3 hubs, drives and cables) or too much distance between them. Universal Control drops the connection when the signal stays away; Reset Universal Control gets it going again."
                    : "In the last hour."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var controls: some View {
        HStack {
            Toggle("Problems only", isOn: Binding(get: { problemsOnly }, set: { problemsOnly = $0 }))
                .toggleStyle(.switch).controlSize(.small)
            if monitor.loading {
                ProgressView().controlSize(.small)
                Text("Reading the log…").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy") { copy() }
            if model.resettingUniversalControl { ProgressView().controlSize(.small) }
            Button("Reset Universal Control") { model.resetUniversalControl() }
                .disabled(model.resettingUniversalControl || !UCBridge.isAvailable)
        }
    }

    // MARK: - Timeline

    private var timeline: some View {
        let rows = visibleRows
        return VStack(alignment: .leading, spacing: 0) {
            if let failed = monitor.failed {
                Text(failed).font(.callout).foregroundStyle(.secondary).padding(14)
            } else if rows.isEmpty && !monitor.loading {
                Text(problemsOnly ? "No problems recorded." : "Nothing recorded yet.")
                    .font(.callout).foregroundStyle(.secondary).padding(14)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(timeLabel(row.date))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Image(systemName: row.icon).foregroundStyle(row.color).frame(width: 18)
                        Text(row.text).font(.callout).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .background(row.problem ? row.color.opacity(0.06) : Color.clear)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var visibleRows: [Row] {
        let ours = model.log.map {
            Row(id: $0.id, date: $0.date, icon: "app.badge", color: .accentColor, text: $0.text, problem: false)
        }
        let all = (monitor.events.map(row) + ours).sorted { $0.date > $1.date }
        return Array((problemsOnly ? all.filter(\.problem) : all).prefix(600))
    }

    private func row(_ e: ActivityMonitor.Event) -> Row {
        let name = macName(e.device)
        let (icon, color, text): (String, Color, String)
        switch e.kind {
        case .signalLost:
            (icon, color, text) = ("antenna.radiowaves.left.and.right.slash", .orange, "Lost \(name)'s Bluetooth signal")
        case .signalFound:
            (icon, color, text) = ("antenna.radiowaves.left.and.right", .secondary, "Found \(name)'s Bluetooth signal again")
        case .unavailable:
            (icon, color, text) = (
                "exclamationmark.triangle.fill", .red, "\(name) no longer counts as nearby: Universal Control disconnects it"
            )
        case .available:
            (icon, color, text) = ("checkmark.circle", .green, "\(name) is nearby again")
        case .connected:
            (icon, color, text) = ("link", .green, "Connected to \(name): keyboard and mouse shared")
        case .disconnected:
            (icon, color, text) = ("minus.circle", .secondary, "Disconnected from \(name)")
        case .pointerOut:
            (icon, color, text) = ("cursorarrow.motionlines", .blue, "Pointer crossing to \(name)")
        case .pointerIn:
            (icon, color, text) = ("cursorarrow.motionlines", .blue, "\(name)'s pointer crossing to this Mac")
        case .arrangement(let links, let fromOtherMac):
            let by = fromOtherMac ? name : "This Mac"
            if links == 0 {
                (icon, color, text) = (
                    "rectangle.3.group", .orange,
                    "\(by) cleared the arrangement: Universal Control now places the Macs itself"
                )
            } else {
                (icon, color, text) = (
                    "rectangle.3.group", .secondary,
                    "\(by) changed the arrangement (\(links) connection\(links == 1 ? "" : "s"))"
                )
            }
        case .inputDropped:
            (icon, color, text) = (
                "keyboard", .red,
                "Threw away \(e.count) keyboard/mouse event\(e.count == 1 ? "" : "s"): the connection was gone"
            )
        }
        return Row(id: e.id, date: e.date, icon: icon, color: color, text: text, problem: e.isProblem)
    }

    /// Universal Control id prefix → the Mac's name.
    private func macName(_ prefix: String?) -> String {
        guard let prefix else { return "The other Mac" }
        if model.universalControl?.selfDevice?.hasPrefix(prefix) == true { return "This Mac" }
        let match = model.devices.first { $0.deviceID != model.deviceID && model.ucDevice(for: $0)?.hasPrefix(prefix) == true }
        return match?.name ?? "The other Mac"
    }

    private func timeLabel(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .standard)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    private func copy() {
        let text = visibleRows.reversed().map { "\(timeLabel($0.date))  \($0.text)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
