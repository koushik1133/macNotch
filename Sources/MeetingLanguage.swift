import Foundation

/// The language meetings are transcribed in (Meetings window › Language).
/// Speech recognition listens in one language: speech in another comes out
/// as wrong, English-sounding words, so the choice is shown when a recording
/// starts and in the notes. Live Translation's "Others speak" still wins for
/// the other side while it is on.
enum MeetingLanguage {
    static let key = "meetings.spokenLanguage"

    /// "" is Automatic (the Mac's language). `mul-IN` is SpeechTranscriber's
    /// multilingual Indian model (code-mixed Hindi, Telugu, Tamil… and English).
    static let options: [String] = [
        "", "mul-IN", "en-US", "en-GB", "en-IN", "hi-IN", "te-IN", "ta-IN", "kn-IN", "ml-IN", "mr-IN",
        "bn-IN", "gu-IN", "pa-IN", "ur-IN", "es-ES", "es-MX", "fr-FR", "de-DE", "it-IT", "pt-BR",
        "nl-NL", "ja-JP", "ko-KR", "zh-CN", "zh-TW", "ar-SA", "ru-RU", "tr-TR", "vi-VN", "id-ID",
    ]

    static var selectedID: String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    /// nil: the Mac's language.
    static var locale: Locale? {
        let id = selectedID
        return id.isEmpty ? nil : Locale(identifier: id)
    }

    /// The language actually used: the choice, or the Mac's language.
    static var effectiveID: String {
        let id = selectedID
        return id.isEmpty ? Locale.current.identifier.replacingOccurrences(of: "_", with: "-") : id
    }

    static func name(_ id: String) -> String {
        if id.isEmpty { return "Automatic (\(name(effectiveIDForAutomatic)))" }
        if id == "mul-IN" { return "Indian languages, mixed" }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    private static var effectiveIDForAutomatic: String {
        Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// "English (United States)".
    static var effectiveName: String { name(effectiveID) }
}
