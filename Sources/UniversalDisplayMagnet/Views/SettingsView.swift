import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Displays") {
                Toggle("Re-apply the saved arrangement when displays connect or macOS moves them", isOn: $model.settings.autoApplyArrangements)
                Stepper(value: $model.settings.snapThreshold, in: 0...400, step: 8) {
                    LabeledContent("Snap alignment strength", value: "\(model.settings.snapThreshold) pt")
                }
            }

            Section("Windows") {
                Picker("When a display setup reconnects, restore", selection: $model.settings.restoreOnConnect) {
                    ForEach(RestoreOnConnect.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Keep an automatic snapshot of window positions", isOn: $model.settings.autosaveWindows)
                if model.settings.autosaveWindows {
                    Stepper(value: $model.settings.autosaveMinutes, in: 1...30) {
                        LabeledContent("Snapshot every", value: "\(model.settings.autosaveMinutes) min")
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
                    LabeledContent("⌃⌥⌘S", value: "Quick-save windows")
                    LabeledContent("⌃⌥⌘R", value: "Restore windows")
                    LabeledContent("⌃⌥⌘D", value: "Re-apply / snap displays")
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
