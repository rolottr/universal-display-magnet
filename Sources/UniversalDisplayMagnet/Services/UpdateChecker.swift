import AppKit
import UniversalDisplayMagnetCore
import SwiftUI

/// Looks for a newer published release on GitHub. It only reads the public
/// "latest release" endpoint (no account, no identifiers) and never installs
/// anything itself: downloads happen on the release's GitHub page.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    static let repository = "rolottr/universal-display-magnet"
    private static let interval: TimeInterval = 24 * 60 * 60

    struct Release: Equatable {
        let version: String
        /// The release's GitHub page, which lists the archives for each architecture.
        let pageURL: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate, available(Release), failed(String)
    }

    private enum Key {
        static let automatic = "updateChecksAutomatically"
        static let lastChecked = "updateLastChecked"
        static let skipped = "updateSkippedVersion"
    }

    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked = UserDefaults.standard.object(forKey: Key.lastChecked) as? Date
    /// Hidden from the in-window offer for this run only ("Later").
    @Published private(set) var offerDismissed = false
    @Published private(set) var skippedVersion = UserDefaults.standard.string(forKey: Key.skipped)
    private var schedule: Task<Void, Never>?

    @Published var checksAutomatically = UserDefaults.standard.object(forKey: Key.automatic) as? Bool ?? true {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Key.automatic) }
    }

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    /// The release to offer unprompted: not skipped and not put off for later.
    var offered: Release? {
        guard let release = available, !offerDismissed, release.version != skippedVersion else { return nil }
        return release
    }

    /// Checks shortly after launch, then hourly whether a day has passed, since
    /// the app can run for weeks in the menu bar.
    func startAutomaticChecks() {
        guard schedule == nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func checkIfDue() async {
        guard checksAutomatically, state != .checking else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.interval { return }
        await check()
    }

    func check() async {
        guard state != .checking else { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Universal Display Magnet/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let release = try Self.release(from: data)
            let newer = SemanticVersion(release.version).flatMap { latest in
                SemanticVersion(currentVersion).map { latest > $0 }
            } ?? false
            state = newer ? .available(release) : .upToDate
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Key.lastChecked)
        } catch {
            state = .failed(String(localized: "Couldn’t reach GitHub. Check your connection and try again."))
        }
    }

    /// "Check for Updates…" from the app menu: always answers, in an alert.
    func checkAndReport() async {
        await check()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch state {
        case .available(let release):
            alert.messageText = String(localized: "Universal Display Magnet \(release.version) is available")
            alert.informativeText = String(
                localized:
                    "You have \(currentVersion). Download the new version from its GitHub release page, then replace the app in your Applications folder."
            )
            alert.addButton(withTitle: String(localized: "Download"))
            alert.addButton(withTitle: String(localized: "Later"))
            if alert.runModal() == .alertFirstButtonReturn { download(release) }
        case .upToDate:
            alert.messageText = String(localized: "You’re up to date")
            alert.informativeText = String(localized: "Universal Display Magnet \(currentVersion) is the latest version.")
            alert.runModal()
        case .failed(let message):
            alert.messageText = String(localized: "Couldn’t check for updates")
            alert.informativeText = message
            alert.runModal()
        case .idle, .checking:
            break
        }
    }

    /// Opens the release page on GitHub, where the person picks the archive for their Mac.
    func download(_ release: Release) {
        NSWorkspace.shared.open(release.pageURL)
    }

    func dismissOffer() { offerDismissed = true }

    func skip(_ release: Release) {
        skippedVersion = release.version
        UserDefaults.standard.set(release.version, forKey: Key.skipped)
    }

    // MARK: - Parsing

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlUrl: URL
        let draft: Bool
        let prerelease: Bool
    }

    static func release(from data: Data) throws -> Release {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { throw URLError(.cannotParseResponse) }
        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return Release(version: version, pageURL: release.htmlUrl)
    }
}

/// The in-window offer of a new version (top of the main window).
struct UpdateOffer: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        if let release = updates.offered {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Universal Display Magnet \(release.version) is available").font(.headline)
                    Text(
                        "You have \(updates.currentVersion). Download it from the GitHub release page, then replace the app in your Applications folder."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Skip This Version") { updates.skip(release) }
                Button("Later") { updates.dismissOffer() }
                Button("Download") {
                    updates.download(release)
                    updates.dismissOffer()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.3)))
            .padding([.horizontal, .top], 16)
        }
    }
}

/// Settings › Updates.
struct UpdatesSection: View {
    @ObservedObject private var updates = UpdateChecker.shared

    var body: some View {
        Section("Updates") {
            Toggle("Check Automatically", isOn: $updates.checksAutomatically)
            LabeledContent {
                if let release = updates.available {
                    Button("Download") { updates.download(release) }
                        .buttonStyle(.borderedProminent)
                } else if updates.state == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Check Now") { Task { await updates.check() } }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var title: String {
        switch updates.state {
        case .available(let release): return String(localized: "Universal Display Magnet \(release.version) is available")
        case .upToDate: return String(localized: "Universal Display Magnet \(updates.currentVersion) is up to date")
        case .checking: return String(localized: "Checking…")
        case .failed: return String(localized: "Couldn’t check for updates")
        case .idle: return String(localized: "Version \(updates.currentVersion)")
        }
    }

    private var detail: String? {
        if case .failed(let message) = updates.state { return message }
        if updates.available != nil {
            return String(localized: "Download opens the release page on GitHub. Replace the app in your Applications folder with the new one.")
        }
        return updates.lastChecked.map { String(localized: "Last checked \($0.formatted(.relative(presentation: .named))).") }
    }
}
