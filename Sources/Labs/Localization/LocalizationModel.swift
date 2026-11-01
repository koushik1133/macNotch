import Foundation

// Pure logic for SparkV's languages (no SwiftUI, so the test harness can
// compile it on its own). The translations themselves live in
// Resources/<lang>.lproj/Localizable.strings; SwiftUI looks literal Text,
// Button, Toggle, Label, .help and accessibility strings up there by itself.

/// A language SparkV ships, or "follow the Mac".
enum SparkVLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case spanish = "es"
    case german = "de"
    case hindi = "hi"

    var id: String { rawValue }

    /// The bundle localization code, nil for `.system`.
    var code: String? { self == .system ? nil : rawValue }

    /// The languages with a bundled Localizable.strings, in menu order.
    static let shipped: [SparkVLanguage] = [.english, .spanish, .german, .hindi]

    /// The name in its own language (never translated).
    var nativeName: String {
        switch self {
        case .system: "Same as Mac"
        case .english: "English"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .hindi: "हिन्दी"
        }
    }

    /// The English name (logs, tests, fallback).
    var englishName: String {
        switch self {
        case .system: "Same as Mac"
        case .english: "English"
        case .spanish: "Spanish"
        case .german: "German"
        case .hindi: "Hindi"
        }
    }

    /// The name in the UI language `uiLanguage` (a code such as "de"), the
    /// way macOS's own language lists label a row: "Spanisch" in a German
    /// SparkV, "स्पेनिश" in a Hindi one. Falls back to the English name.
    /// Nil for `.system`, which has no single language. `standalone`
    /// capitalizes it for a label of its own; inside a sentence ("Ahora
    /// inglés") it keeps the language's own casing.
    func displayName(inUILanguage uiLanguage: String, standalone: Bool = true) -> String? {
        guard let code else { return nil }
        let locale = Locale(identifier: uiLanguage)
        guard let name = locale.localizedString(forLanguageCode: code), !name.isEmpty else { return englishName }
        guard standalone else { return name }
        // Spanish and others write language names in lower case; a row
        // label starts with a capital in every language that has one.
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// The shipped language for a BCP-47 code such as "de-AT" or "es-419",
    /// nil when SparkV has no translation for it.
    static func shipped(matching identifier: String) -> SparkVLanguage? {
        let base = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return shipped.first { $0.rawValue == base }
    }
}

/// Reads and writes the per-app language. macOS reads the app domain's
/// `AppleLanguages` once at launch, so a change applies after a restart
/// (the same thing System Settings › General › Language & Region ›
/// Applications does).
enum LocalizationPreferences {
    /// SparkV's own record of the choice ("localization." prefix).
    static let choiceKey = "localization.language"
    /// The key Foundation reads at launch.
    static let appleLanguagesKey = "AppleLanguages"

    /// The saved choice; `.system` when unset or unknown.
    static func choice(in defaults: UserDefaults) -> SparkVLanguage {
        defaults.string(forKey: choiceKey).flatMap(SparkVLanguage.init(rawValue:)) ?? .system
    }

    /// Saves the choice and the matching `AppleLanguages` override (removed
    /// for `.system`, so the Mac's own language order applies again).
    static func save(_ language: SparkVLanguage, in defaults: UserDefaults) {
        defaults.set(language.rawValue, forKey: choiceKey)
        if let languages = appleLanguages(for: language) {
            defaults.set(languages, forKey: appleLanguagesKey)
        } else {
            defaults.removeObject(forKey: appleLanguagesKey)
        }
    }

    /// The `AppleLanguages` value for a choice: the code first, English as
    /// the fallback for anything not translated. Nil means "remove it".
    static func appleLanguages(for language: SparkVLanguage) -> [String]? {
        guard let code = language.code else { return nil }
        return code == "en" ? ["en"] : [code, "en"]
    }

    /// The language the running app resolved at launch from the bundle's
    /// localizations (English when the bundle has none, e.g. in tests).
    static func running(preferred: [String]) -> SparkVLanguage {
        preferred.lazy.compactMap(SparkVLanguage.shipped(matching:)).first ?? .english
    }

    /// What `.system` resolves to on this Mac, from the user's language
    /// order (`Locale.preferredLanguages`): the first shipped language.
    static func systemResolved(preferredLanguages: [String]) -> SparkVLanguage {
        preferredLanguages.lazy.compactMap(SparkVLanguage.shipped(matching:)).first ?? .english
    }

    /// True when the saved choice differs from what is on screen, so the
    /// UI offers Restart.
    static func needsRestart(choice: SparkVLanguage, running: SparkVLanguage, systemResolved: SparkVLanguage) -> Bool {
        let wanted = choice == .system ? systemResolved : choice
        return wanted != running
    }
}

extension String {
    /// This string looked up in SparkV's Localizable.strings, or itself
    /// when there is no translation. For components that take a `String`
    /// title and show it with `Text(title)` (verbatim), and for AppKit
    /// menu items, which SwiftUI's automatic lookup never reaches.
    var sparkVLocalized: String {
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}
