import Foundation

/// Shared localization for the panel, diagnostics, reports, and example app.
/// Uses the system's preferred supported language; other languages fall back to English.
public enum TraceLocalization {
    public static func text(_ key: String) -> String {
        text(key, bundle: .module)
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    private static func text(_ key: String, bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    // Explicit locale lookup for deterministic resource tests, without changing system settings.
    static func text(_ key: String, language: String) -> String {
        let supported = Bundle.preferredLocalizations(from: ["en", "zh-Hans", "zh-Hant"],
                                                      forPreferences: [language]).first ?? "en"
        guard let path = Bundle.module.path(forResource: supported, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return text(key, bundle: bundle)
    }
}
