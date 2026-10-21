import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var nav: Navigation

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(get: { nav.section }, set: { if let s = $0 { nav.section = s } })) {
                section in
                Label(section.title, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) { statusFooter }
        } detail: {
            VStack(spacing: 0) {
                UpdateOffer()
                Group {
                    switch nav.section {
                    case .displays: DisplaysView()
                    case .linked: LinkedMacsView()
                    case .windows: WindowsView()
                    case .snapping: SnappingView()
                    case .sync: SyncView()
                    case .activity: ActivityView()
                    case .settings: SettingsView()
                    case .about: AboutView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(nav.section.title)
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let activity = model.activity {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.caption).lineLimit(2)
                }
            } else if !model.message.isEmpty {
                Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 6) {
                Circle().fill(model.peers.isEmpty ? Color.secondary.opacity(0.4) : .green).frame(width: 7, height: 7)
                Text(syncLine).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var syncLine: String {
        if !model.settings.syncOn { return "Sync off" }
        if model.peers.isEmpty { return "Looking for your other Mac…" }
        return "Synced with " + model.peers.map(\.name).joined(separator: ", ")
    }
}

/// Explains a missing permission with a button that fixes it.
struct PermissionBanner: View {
    let icon: String
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action, action: perform).buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3)))
    }
}
