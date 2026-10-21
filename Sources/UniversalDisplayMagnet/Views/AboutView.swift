import AppKit
import SwiftUI

/// About the app itself: version details for bug reports, links to the project,
/// privacy and credits. Names no individual; everything links to the public repository.
struct AboutView: View {
    @StateObject private var copied = ViewState(false)

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Universal Display Magnet").font(.title2.weight(.semibold))
                        Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
                        Text("Your displays, windows and Macs, exactly where you left them.")
                            .font(.callout).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("This Copy") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Build", value: AppInfo.build)
                LabeledContent("System", value: "\(AppInfo.system) · \(AppInfo.architecture)")
                LabeledContent("License", value: "MIT, free and open source")
                LabeledContent("For bug reports") {
                    Button(copied.value ? "Copied" : "Copy Version Info") { copy() }
                        .help("Copies one line with the version, build and system.")
                }
            }

            Section("Links") {
                link("Project on GitHub", symbol: "chevron.left.forwardslash.chevron.right", AppInfo.project)
                link("Release Notes", symbol: "doc.text", AppInfo.project.appendingPathComponent("releases/tag/v\(AppInfo.version)"))
                link("All Releases", symbol: "shippingbox", AppInfo.project.appendingPathComponent("releases"))
                link("Report an Issue", symbol: "exclamationmark.bubble", AppInfo.project.appendingPathComponent("issues/new"))
                link("License", symbol: "checkmark.shield", AppInfo.project.appendingPathComponent("blob/main/LICENSE"))
            }

            Section("Privacy") {
                paragraph("Universal Display Magnet has no account, analytics or cloud service.")
                paragraph("It syncs only with your own Macs that Universal Control links to this one, over your local network and encrypted. Its only other network request is the optional daily update check, which reads this project's latest release on GitHub and sends nothing about you.")
                paragraph("Window titles are stored on this Mac to match windows when restoring. Nothing is captured from the screen.")
            }

            Section("Credits") {
                paragraph("Built on ideas from display-align, SnapBack and displayplacer, without sharing their code. Window snapping follows Magnet's commands and shortcuts; working with windows on other Desktops draws on AltTab and Amethyst.")
                paragraph("Apple, macOS and Universal Control are trademarks of Apple Inc. This project is not affiliated with Apple.")
            }
        }
        .formStyle(.grouped)
    }

    private func link(_ title: String, symbol: String, _ url: URL) -> some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.link)
        .help(url.absoluteString)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AppInfo.summary, forType: .string)
        copied.value = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied.value = false
        }
    }
}

@MainActor
enum AppInfo {
    static let project = URL(string: "https://github.com/\(UpdateChecker.repository)")!
    private static let info = Bundle.main.infoDictionary ?? [:]
    static let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    static let build = info["CFBundleVersion"] as? String ?? "dev"
    static let system: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
    }()
    static let architecture: String = {
        #if arch(arm64)
            "Apple Silicon"
        #else
            "Intel"
        #endif
    }()
    /// One line to paste into a bug report.
    static var summary: String { "Universal Display Magnet \(version) (\(build)) · \(system) · \(architecture)" }
}
