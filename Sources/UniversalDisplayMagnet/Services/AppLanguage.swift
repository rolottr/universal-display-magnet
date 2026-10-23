import AppKit

/// The app follows the system language (or the one picked for it in System Settings → General → Language & Region
/// → Applications). Settings can override it; like that system setting, the change applies on the next launch.
enum AppLanguage {
    /// The language the running app shows, as a localization code ("de", "pt-BR", "zh-Hans").
    static let current = Bundle.main.preferredLocalizations.first ?? "en"

    /// The language the app shows without an override: the first of the Mac's languages it is translated into.
    static var system: String {
        let preferred = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        return Bundle.preferredLocalizations(from: available, forPreferences: preferred).first ?? "en"
    }

    /// Every language the app is translated into, by their own names in the order the system sorts them.
    static var available: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }
            .sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    /// The override picked in Settings; nil follows the system.
    static var override: String? {
        // The app's own domain only: the global AppleLanguages is the system's list.
        get { (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }
    }

    /// "Deutsch", "Português (Brasil)", "简体中文"…
    static func name(of code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// Starts a fresh copy of the app and quits this one, so a new language takes effect.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
