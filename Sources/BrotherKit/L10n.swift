import Foundation

/// Lightweight runtime localization.
///
/// Keys are the English texts. Translations live in `<code>.lproj/Localizable.strings`
/// inside the app bundle. Missing keys (or a missing bundle, e.g. in command-line tools)
/// fall back to English. The language follows the system unless the user picks one in Settings.
public enum L10n {
    public struct Language: Identifiable, Hashable, Sendable {
        public let code: String
        public let name: String
        public var id: String { code }
    }

    public static let languages: [Language] = [
        Language(code: "en", name: "English"),
        Language(code: "cs", name: "Čeština"),
        Language(code: "de", name: "Deutsch"),
        Language(code: "fr", name: "Français"),
        Language(code: "pl", name: "Polski"),
        Language(code: "ru", name: "Русский"),
        Language(code: "ja", name: "日本語"),
        Language(code: "zh-Hans", name: "简体中文"),
    ]

    public static let preferenceKey = "PrintBridgeLanguage"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var table: [String: String] = [:]
    nonisolated(unsafe) private static var code: String = "en"

    /// Currently active language code.
    public static var current: String {
        lock.lock(); defer { lock.unlock() }
        return code
    }

    /// Language chosen in Settings, or `nil` to follow the system.
    public static var preference: String? {
        get { UserDefaults.standard.string(forKey: preferenceKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: preferenceKey) }
            activate()
        }
    }

    /// Picks the language: user preference → first supported system language → English.
    public static func resolve(preference: String?, system: [String] = Locale.preferredLanguages) -> String {
        let supported = Set(languages.map(\.code))
        if let preference, supported.contains(preference) { return preference }
        for identifier in system {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") { return "zh-Hans" }
            let base = String(lower.prefix(while: { $0 != "-" && $0 != "_" }))
            if supported.contains(base) { return base }
        }
        return "en"
    }

    /// Loads the strings table for the resolved language.
    public static func activate() {
        // PB_LANG overrides everything (used for README screenshots and testing).
        let forced = ProcessInfo.processInfo.environment["PB_LANG"]
        let resolved = resolve(preference: forced ?? UserDefaults.standard.string(forKey: preferenceKey))
        var loaded: [String: String] = [:]
        if resolved != "en",
           let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: resolved),
           let dict = NSDictionary(contentsOf: url) as? [String: String] {
            loaded = dict
        }
        lock.lock()
        code = resolved
        table = loaded
        lock.unlock()
    }

    static func lookup(_ key: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return table[key] ?? key
    }

    public static var locale: Locale { Locale(identifier: current) }
}

/// Localized text for an English key.
public func L(_ key: String) -> String { L10n.lookup(key) }

/// Localized format string (`%@`, `%d`, `%1$@`…) filled with arguments.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.lookup(key), locale: L10n.locale, arguments: args)
}
