import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var language = ViewState(AppLanguage.override)

    var body: some View {
        Form {
            Section("Displays") {
                Toggle("Re-apply the saved arrangement when displays connect or macOS moves them", isOn: $model.settings.autoApplyArrangements)
                Stepper(value: $model.settings.snapThreshold, in: 0...400, step: 8) {
                    LabeledContent("Snap alignment strength", value: String(localized: "\(model.settings.snapThreshold) pt"))
                }
            }

            Section("Windows") {
                Picker("When a display setup reconnects, restore", selection: $model.settings.restoreOnConnect) {
                    ForEach(RestoreOnConnect.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Keep an automatic snapshot of window positions", isOn: $model.settings.autosaveWindows)
                if model.settings.autosaveWindows {
                    Stepper(value: $model.settings.autosaveMinutes, in: 1...30) {
                        LabeledContent("Snapshot every", value: String(localized: "\(model.settings.autosaveMinutes) min"))
                    }
                }
                Toggle("Move windows back to their Desktop", isOn: $model.settings.moveBetweenDesktops)
                if model.settings.moveBetweenDesktops {
                    LabeledContent("Desktop shortcuts") {
                        if model.desktopShortcuts > 0 {
                            Text("⌃1…⌃\(min(model.desktopShortcuts, 9)) available").foregroundStyle(.secondary)
                        } else {
                            Button("Enable ⌃1…⌃0") { model.enableDesktopShortcuts() }
                        }
                    }
                }
                Toggle("Open apps that aren't running when restoring manually", isOn: $model.settings.launchMissingApps)
            }

            Section("General") {
                Toggle(
                    "Launch at login",
                    isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Global shortcuts", isOn: $model.settings.hotkeysEnabled)
                if model.settings.hotkeysEnabled {
                    LabeledContent("⌃⌥⌘S", value: String(localized: "Quick-save windows"))
                    LabeledContent("⌃⌥⌘R", value: String(localized: "Restore windows"))
                    LabeledContent("⌃⌥⌘D", value: String(localized: "Re-apply / snap displays"))
                }
            }

            Section("Language") {
                Picker("Language", selection: $language.value) {
                    Text("System (\(AppLanguage.name(of: AppLanguage.system)))").tag(String?.none)
                    Divider()
                    ForEach(AppLanguage.available, id: \.self) { Text(verbatim: AppLanguage.name(of: $0)).tag(Optional($0)) }
                }
                .onChange(of: language.value) { _, value in AppLanguage.override = value }
                if (language.value ?? AppLanguage.system) != AppLanguage.current {
                    HStack {
                        Text("Universal Display Magnet switches to \(AppLanguage.name(of: language.value ?? AppLanguage.system)) when it restarts.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                    }
                } else {
                    Text("Universal Display Magnet follows the language of your Mac unless you pick another one here.")
                        .foregroundStyle(.secondary)
                }
            }

            UpdatesSection()

            Section("Permissions") {
                LabeledContent("Device Control and Data Access") {
                    if model.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            model.requireAccessibility()
                            model.openAccessibilitySettings()
                        }
                    }
                }
                LabeledContent("Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(Persistence.directory) }
                }
            }
        }
        .formStyle(.grouped)
    }
}
