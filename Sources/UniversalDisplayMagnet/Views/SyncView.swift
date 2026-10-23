import UniversalDisplayMagnetCore
import SwiftUI

struct SyncView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var newPeerState = ViewState("")
    private var newPeer: String {
        get { newPeerState.value }
        nonmutating set { newPeerState.value = newValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Macs & Sync").font(.title2.weight(.semibold))
                    Text(
                        "Your Macs find each other on the local network (Wi-Fi, Ethernet or a Thunderbolt cable) and keep arrangements and workspaces in sync directly, with no cloud. There's nothing to pair: Universal Display Magnet recognises the Macs Universal Control links together, and everything sent between them is encrypted with a key only those Macs can derive."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                connection
                devices
            }
            .padding(22)
        }
    }

    private var connection: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $model.settings.syncOn) {
                    Text("Sync with my other Macs").font(.headline)
                }
                .toggleStyle(.switch)
                if model.settings.syncOn && !model.canSync {
                    Text(
                        "Waiting for Universal Control: link your Macs once in System Settings › Displays and Universal Display Magnet will recognise them."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                } else if model.settings.syncOn {
                    if model.peers.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for your other Mac on the network…").foregroundStyle(.secondary)
                        }
                        Text(
                            "Make sure Universal Display Magnet is running there, and that both Macs allowed Universal Display Magnet under Privacy & Security › Local Network."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.peers) { peer in
                        HStack {
                            Circle().fill(Color.green).frame(width: 8, height: 8)
                            Text(peer.name).fontWeight(.medium)
                            Text(peer.endpoint).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("connected \(peer.connectedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("Connect by address (when Bonjour can't see the other Mac)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.settings.manualPeers, id: \.self) { p in
                                HStack {
                                    Text(p).font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Button("Remove") { model.settings.manualPeers.removeAll { $0 == p } }
                                        .controlSize(.small)
                                }
                            }
                            HStack {
                                TextField("other-mac.local or 192.168.1.20:\(SyncService.preferredPort.rawValue)", text: $newPeerState.value)
                                    .textFieldStyle(.roundedBorder)
                                Button("Add") {
                                    let p = newPeer.trimmingCharacters(in: .whitespaces)
                                    if !p.isEmpty, !model.settings.manualPeers.contains(p) { model.settings.manualPeers.append(p) }
                                    newPeer = ""
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: - Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MACS").font(.system(size: 10, weight: .medium)).tracking(1.2).foregroundStyle(.secondary)
            ForEach(model.devices.sorted { ($0.deviceID == model.deviceID ? 0 : 1, $0.name) < ($1.deviceID == model.deviceID ? 0 : 1, $1.name) }) { d in
                let isMe = d.deviceID == model.deviceID
                let online = isMe || model.peers.contains { $0.id == d.deviceID }
                HStack(spacing: 16) {
                    MiniMap(
                        rects: d.displays.enumerated().map { i, p in
                            (id: "\(i)", rect: p.frame, name: p.identity.name, isMain: p.isMain)
                        }
                    )
                    .frame(width: 180, height: 80)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85)))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(d.name).font(.headline)
                            if isMe { Text("this Mac").font(.caption).foregroundStyle(.secondary) }
                            Circle().fill(online ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                        }
                        Text(d.model).font(.caption).foregroundStyle(.secondary)
                        Text(DisplaySetup.label(for: d.displays.map(\.identity)))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text("\(model.profiles(forSetup: d.setupKey).count) arrangements") + Text(verbatim: " · ")
                            + Text("\(model.windowLayouts.filter { $0.deviceID == d.deviceID }.count) window layouts")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isMe ? "Arrange" : "Arrange Remotely") {
                        MainWindow.show(.displays, device: isMe ? nil : d.deviceID)
                    }
                    .help(isMe ? "" : "Edit \(d.name)'s arrangement here; it applies there as soon as it syncs")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }
}
