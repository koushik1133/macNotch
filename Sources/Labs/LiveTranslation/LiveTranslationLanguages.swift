import Foundation
import NaturalLanguage

// Language helpers for Live Translation: identifiers, display names, the
// "already in the target language" test, caption masking rules, and the
// spoken-language detector (NLLanguageRecognizer, sticky per speaker).

enum LiveTranslationLanguages {
    /// Targets offered when the system list hasn't loaded yet (the languages
    /// Apple Translation supports on macOS 15–27, one entry per language).
    static let fallbackTargets: [String] = [
        "ar", "zh-Hans", "zh-Hant", "da", "nl", "en", "fi", "fr", "de", "he", "hi",
        "id", "it", "ja", "ko", "ms", "nb", "pl", "pt", "ru", "es", "sv", "th",
        "tr", "uk", "vi",
    ]

    /// Short, stable identifier ("es", "zh-Hans", "pt-PT").
    static func id(_ language: Locale.Language) -> String {
        let minimal = language.minimalIdentifier
        return minimal.isEmpty ? language.maximalIdentifier : minimal
    }

    static func language(_ id: String) -> Locale.Language {
        Locale.Language(identifier: id)
    }

    /// "Spanish", "Chinese (Simplified)"… in the user's own language.
    static func displayName(_ id: String, locale: Locale = .current) -> String {
        if let name = locale.localizedString(forIdentifier: id), !name.isEmpty {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return id
    }

    /// Two- or three-letter tag for the band chip ("ES", "ZH").
    static func shortTag(_ id: String) -> String {
        let code = language(id).languageCode?.identifier ?? id
        return code.uppercased()
    }

    /// The language a Mac user most likely wants captions in.
    static var defaultTarget: String {
        let preferred = Locale.preferredLanguages.first.map(Locale.Language.init(identifier:))
            ?? Locale.current.language
        return normalizedTarget(preferred)
    }

    /// Maps a preferred/system language onto one of the offered targets
    /// ("en-IN" → "en", "zh-Hant-TW" → "zh-Hant").
    static func normalizedTarget(_ language: Locale.Language) -> String {
        guard let code = language.languageCode?.identifier else { return "en" }
        if code == "zh" {
            return script(of: language) == "Hant" ? "zh-Hant" : "zh-Hans"
        }
        if code == "pt", language.region?.identifier == "PT" { return "pt-PT" }
        return code
    }

    /// The writing system, filling in the likely one ("zh" → "Hans").
    static func script(of language: Locale.Language) -> String? {
        if let script = language.script?.identifier { return script }
        return Locale.Language(identifier: language.maximalIdentifier).script?.identifier
    }

    /// True when text in `source` needs no translation into `target`:
    /// the same language and writing system; regional variants count as the
    /// same ("en-US" speech for an "en-GB" reader).
    static func isSame(_ source: Locale.Language, _ target: Locale.Language) -> Bool {
        guard let a = source.languageCode?.identifier, let b = target.languageCode?.identifier else {
            return false
        }
        guard normalizeCode(a) == normalizeCode(b) else { return false }
        return script(of: source) == script(of: target)
    }

    /// Norwegian Bokmål is "nb" in Translation and "no"/"nb" in NaturalLanguage.
    private static func normalizeCode(_ code: String) -> String {
        code == "no" ? "nb" : code
    }

    /// Languages written without spaces between words: captions mask
    /// characters instead of words while a phrase is still being spoken.
    static func writesWithoutSpaces(_ language: Locale.Language) -> Bool {
        guard let code = language.languageCode?.identifier else { return false }
        return ["ja", "zh", "th", "lo", "km", "my"].contains(code)
    }

    /// Stabilizes a caption that is still changing (Google's "mask-k"
    /// re-translation heuristic): hide the last few words of the translation
    /// of a volatile phrase, because they depend on words not spoken yet and
    /// would otherwise flicker. The full translation appears when the phrase
    /// is final.
    static func masked(_ translation: String, target: Locale.Language, words k: Int = 2) -> String {
        let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k > 0 else { return text }
        if writesWithoutSpaces(target) {
            let characters = Array(text)
            let drop = k * 2
            guard characters.count > drop + 4 else { return text }
            return String(characters.dropLast(drop)) + "…"
        }
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > k + 2 else { return text }
        return words.dropLast(k).joined(separator: " ") + "…"
    }
}

// MARK: - Spoken language detection

/// Detects the language of transcript text with NLLanguageRecognizer. Short
/// fragments ("yes", "okay so") are unreliable, so a confident detection is
/// remembered per speaker and reused for short or ambiguous text; with no
/// history the transcriber's own language is assumed.
struct LiveTranslationLanguageDetector {
    /// The language the speech recognizer listens in (MeetingTranscriber
    /// uses the Mac's current locale).
    var transcriberLanguage: Locale.Language
    /// Restrict guesses to these (the languages translation supports), so
    /// short English isn't read as, say, Latin or Catalan.
    var constraints: [NLLanguage]
    /// Per-stream transcriber language when it differs from
    /// `transcriberLanguage` (the "Others Speak" setting).
    var speakerLanguages: [MeetingSpeaker: Locale.Language] = [:]

    private var sticky: [MeetingSpeaker: Locale.Language] = [:]

    init(transcriberLanguage: Locale.Language = Locale.current.language,
         constraints: [NLLanguage] = LiveTranslationLanguageDetector.defaultConstraints) {
        self.transcriberLanguage = transcriberLanguage
        self.constraints = constraints
    }

    static let defaultConstraints: [NLLanguage] = [
        .arabic, .simplifiedChinese, .traditionalChinese, .danish, .dutch, .english, .finnish,
        .french, .german, .hebrew, .hindi, .indonesian, .italian, .japanese, .korean, .malay,
        .norwegian, .polish, .portuguese, .russian, .spanish, .swedish, .thai, .turkish,
        .ukrainian, .vietnamese,
    ]

    struct Detection: Equatable {
        let language: Locale.Language
        let confidence: Double
        /// True when the text itself decided it (not the speaker's history).
        let fromText: Bool
    }

    mutating func detect(_ text: String, speaker: MeetingSpeaker) -> Detection {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let recognizer = NLLanguageRecognizer()
        if !constraints.isEmpty { recognizer.languageConstraints = constraints }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let top = hypotheses.max { $0.value < $1.value }

        if let (nl, probability) = top {
            let language = Locale.Language(identifier: nl.rawValue)
            // Scripts that identify the language on their own (kana, hangul,
            // Thai, Hebrew, Arabic…) need few letters.
            let distinctive = Self.hasDistinctiveScript(text)
            let confident = (letters >= 14 && probability >= 0.6)
                || (letters >= 6 && probability >= 0.9)
                || (distinctive && letters >= 2 && probability >= 0.5)
            if confident {
                sticky[speaker] = language
                return Detection(language: language, confidence: probability, fromText: true)
            }
            if let remembered = sticky[speaker] {
                return Detection(language: remembered, confidence: probability, fromText: false)
            }
            if probability >= 0.75, letters >= 4 {
                return Detection(language: language, confidence: probability, fromText: true)
            }
        } else if let remembered = sticky[speaker] {
            return Detection(language: remembered, confidence: 0, fromText: false)
        }
        return Detection(language: speakerLanguages[speaker] ?? transcriberLanguage, confidence: 0, fromText: false)
    }

    mutating func reset() {
        sticky = [:]
    }

    private static func hasDistinctiveScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0590...0x06FF, // Hebrew, Arabic
                 0x0900...0x097F, // Devanagari
                 0x0E00...0x0E7F, // Thai
                 0x3040...0x30FF, // Hiragana, Katakana
                 0xAC00...0xD7AF: // Hangul
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Spoken language (transcriber hook)

/// What other participants speak. MeetingTranscriber listens in the Mac's own
/// language, so a participant speaking Spanish on an English Mac is
/// transcribed by the English model and there is nothing left to translate.
/// Teams solves this with a "meeting spoken language" setting; this is the
/// same setting. MeetingTranscriber reads it through `transcriberLocale(speakerLabel:)`
/// (a two-line hook, see INTEGRATION.md). Empty means the Mac's language.
enum LiveTranslationSpokenLanguage {
    static let defaultsKey = "liveTranslation.othersSpeak"
    static let enabledKey = "liveTranslation.enabled"

    /// Speech locales offered, one per language Apple Translation supports
    /// (all have on-device speech recognition on macOS 15+).
    static let locales: [String] = [
        "ar-SA", "zh-CN", "zh-TW", "da-DK", "nl-NL", "en-US", "en-GB", "fi-FI", "fr-FR", "de-DE",
        "he-IL", "hi-IN", "id-ID", "it-IT", "ja-JP", "ko-KR", "ms-MY", "nb-NO", "pl-PL", "pt-BR",
        "pt-PT", "ru-RU", "es-ES", "es-MX", "sv-SE", "th-TH", "tr-TR", "uk-UA", "vi-VN",
    ]

    /// The locale MeetingTranscriber should listen in for one stream
    /// (`MeetingSpeaker.rawValue`: "me" or "others"), or nil for its default
    /// (`Locale.current`). Only the others stream, and only while Live
    /// Translation is on.
    static func transcriberLocale(speakerLabel: String, defaults: UserDefaults = .standard) -> Locale? {
        guard speakerLabel == MeetingSpeaker.others.rawValue,
              defaults.bool(forKey: enabledKey),
              let id = defaults.string(forKey: defaultsKey), !id.isEmpty else { return nil }
        return Locale(identifier: id)
    }

    /// "Spanish (Spain)".
    static func displayName(_ id: String, locale: Locale = .current) -> String {
        LiveTranslationLanguages.displayName(id, locale: locale)
    }
}
