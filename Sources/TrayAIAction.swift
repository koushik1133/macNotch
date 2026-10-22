import Foundation
import UniformTypeIdentifiers

// Tray AI: shared types for the engine (TrayAIEngine) and the floating panel
// (TrayAIPanelController). Select tray items, pick an action, get a result.

// MARK: - Actions

enum TrayAIAction: Hashable, Identifiable, Sendable {
    case whatIsThis
    case explain
    case summarize
    case extractText
    case improveWriting
    case checkSpelling
    case listItems
    /// Target language name in English, e.g. "Spanish". Empty means
    /// `TrayAISettings.translateTarget`.
    case translate(String)
    case webSearch
    case receiptToJSON
    case compareDesigns
    /// A date found in the items as a calendar event (.ics the user adds
    /// through Calendar's own dialog; nothing is written to a calendar here).
    case addToCalendar
    /// A free-form question about the selected items.
    case custom(String)

    var id: String {
        switch self {
        case .whatIsThis: "whatIsThis"
        case .explain: "explain"
        case .summarize: "summarize"
        case .extractText: "extractText"
        case .improveWriting: "improveWriting"
        case .checkSpelling: "checkSpelling"
        case .listItems: "listItems"
        case .translate(let language): "translate:\(language)"
        case .webSearch: "webSearch"
        case .receiptToJSON: "receiptToJSON"
        case .compareDesigns: "compareDesigns"
        case .addToCalendar: "addToCalendar"
        case .custom(let question): "custom:\(question)"
        }
    }

    var title: String {
        switch self {
        case .whatIsThis: "What is this?"
        case .explain: "Explain"
        case .summarize: "Summarize"
        case .extractText: "Copy Text"
        case .improveWriting: "Improve Writing"
        case .checkSpelling: "Check Spelling & Grammar"
        case .listItems: "List Items"
        case .translate(let language):
            "Translate to \(TrayAISettings.resolvedLanguage(language))"
        case .webSearch: "Search the Web"
        case .receiptToJSON: "Receipt to JSON"
        case .compareDesigns: "Compare Designs"
        case .addToCalendar: "Add to Calendar"
        case .custom(let question):
            question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Ask" : question
        }
    }

    /// SF Symbols available on macOS 15.
    var systemImage: String {
        switch self {
        case .whatIsThis: "questionmark.circle"
        case .explain: "lightbulb"
        case .summarize: "text.alignleft"
        case .extractText: "text.viewfinder"
        case .improveWriting: "wand.and.stars"
        case .checkSpelling: "textformat.abc"
        case .listItems: "list.bullet"
        case .translate: "character.bubble"
        case .webSearch: "magnifyingglass"
        case .receiptToJSON: "receipt"
        case .compareDesigns: "square.split.2x1"
        case .addToCalendar: "calendar.badge.plus"
        case .custom: "bubble.left"
        }
    }

    /// Actions whose answer depends on understanding the picture itself, not
    /// just its text. On-device mode can only approximate these.
    var needsVisualUnderstanding: Bool {
        switch self {
        case .whatIsThis, .explain, .listItems, .compareDesigns, .custom: true
        default: false
        }
    }

    /// False for actions that always run on this Mac, even with Groq allowed.
    var mayUseGroq: Bool {
        switch self {
        case .extractText, .addToCalendar: false
        default: true
        }
    }

    /// Actions offered for a selection, most useful first.
    static func suggested(for items: [TrayItem]) -> [TrayAIAction] {
        guard !items.isEmpty else { return [] }
        let images = items.filter(\.trayAIIsImage)
        let links = items.filter { $0.trayAILinkURL != nil }
        let texts = items.filter { $0.kind == .text && $0.trayAILinkURL == nil }
        let documents = items.filter { $0.kind == .file && !$0.trayAIIsImage }
        let target = TrayAIAction.translate(TrayAISettings.translateTarget)

        var actions: [TrayAIAction] = []
        if images.count >= 2 { actions.append(.compareDesigns) }
        if !images.isEmpty {
            if images.contains(where: \.trayAILooksLikeReceipt) { actions.append(.receiptToJSON) }
            actions += [.whatIsThis, .explain, .extractText, .summarize, .listItems]
        }
        if !links.isEmpty { actions += [.summarize, .explain, .listItems] }
        if !texts.isEmpty {
            // A date in the text (an invite, a booking) is the most likely want.
            if texts.contains(where: { TrayAICalendar.containsDate($0.text ?? "") }) { actions.append(.addToCalendar) }
            let short = texts.allSatisfy { ($0.text ?? "").split(whereSeparator: \.isWhitespace).count <= 12 }
            if short { actions.append(.webSearch) }
            actions += [.improveWriting, .checkSpelling, .summarize, .explain]
        }
        if !documents.isEmpty { actions += [.summarize, .extractText, .explain, .listItems] }
        actions += [target, .webSearch]
        if !images.isEmpty { actions += [.addToCalendar, .receiptToJSON] }

        var seen = Set<String>()
        return actions.filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Result

struct TrayAIResult: Sendable, Equatable {
    /// What to show (plain text with light markdown: headings, bullets).
    var text: String
    /// Structured output (receipts, spelling changes), pretty-printed.
    var json: String?
    /// "On-device", "On-device (Vision OCR)", "Groq <model>", …
    var producedBy: String
    /// For web search: the search page to open. The engine never opens it.
    var openURL: URL?
}

// MARK: - Errors

enum TrayAIError: LocalizedError, Equatable, Sendable {
    case noItems
    case needsImages(Int)
    case nothingToRead
    case onDeviceUnavailable(String)
    case translationUnavailable(String)
    case invalidKey
    case rateLimited
    case groq(String)
    case network(String)
    case fetchFailed(String)
    case timedOut
    case refused
    case contextTooLarge
    case badResponse
    case noDate

    var errorDescription: String? {
        switch self {
        case .noItems: "Select at least one tray item"
        case .needsImages(let count): "Select at least \(count) images for this"
        case .nothingToRead: "Found no text in the selected items"
        case .onDeviceUnavailable(let reason):
            "Apple Intelligence isn't available (\(reason)). You can allow Groq in Tray AI settings"
        case .translationUnavailable(let reason): "Couldn't translate on this Mac: \(reason)"
        case .invalidKey: "Groq rejected the API key"
        case .rateLimited: "Groq rate limit hit, try again shortly"
        case .groq(let message): message
        case .network(let message): "Network error: \(message)"
        case .fetchFailed(let message): "Couldn't load the page: \(message)"
        case .timedOut: "The model took too long"
        case .refused: "The model declined to answer that"
        case .contextTooLarge: "That's too much text for the on-device model"
        case .badResponse: "Couldn't read the model's answer"
        case .noDate: "Found no date or time in the selected items"
        }
    }
}

// MARK: - Settings

enum TrayAISettings {
    static let allowGroqKey = "trayAI.allowGroq"
    static let visionModelKey = "trayAI.visionModel"
    static let textModelKey = "trayAI.textModel"
    static let translateTargetKey = "trayAI.translateTarget"

    static let defaultVisionModel = "qwen/qwen3.8-27b"
    static let defaultTextModel = "openai/gpt-oss-120b"
    static let defaultTranslateTarget = "English"

    /// Languages offered in the Translate menu (English names).
    static let languages = [
        "English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch",
        "Chinese (Simplified)", "Chinese (Traditional)", "Japanese", "Korean", "Hindi",
        "Arabic", "Russian", "Turkish", "Polish", "Ukrainian", "Vietnamese", "Thai",
        "Indonesian", "Telugu", "Tamil",
    ]

    /// The Groq key belongs to Clicky; Tray AI may use it only when the user
    /// switched this on. Off by default.
    static var allowGroq: Bool {
        get { UserDefaults.standard.bool(forKey: allowGroqKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowGroqKey) }
    }

    static var visionModel: String {
        get { nonEmpty(UserDefaults.standard.string(forKey: visionModelKey)) ?? defaultVisionModel }
        set { UserDefaults.standard.set(nonEmpty(newValue), forKey: visionModelKey) }
    }

    static var textModel: String {
        get { nonEmpty(UserDefaults.standard.string(forKey: textModelKey)) ?? defaultTextModel }
        set { UserDefaults.standard.set(nonEmpty(newValue), forKey: textModelKey) }
    }

    static var translateTarget: String {
        get { nonEmpty(UserDefaults.standard.string(forKey: translateTargetKey)) ?? defaultTranslateTarget }
        set { UserDefaults.standard.set(nonEmpty(newValue), forKey: translateTargetKey) }
    }

    static func resolvedLanguage(_ language: String) -> String {
        nonEmpty(language) ?? translateTarget
    }

    /// The Groq key when (and only when) Tray AI is allowed to use it. The
    /// keychain is not touched while the setting is off.
    static func groqKeyIfAllowed() -> String? {
        guard allowGroq else { return nil }
        return ClickyKeychain.load()
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Item helpers

extension TrayItem {
    /// An image item, or a file whose type is an image.
    var trayAIIsImage: Bool {
        switch kind {
        case .image: return true
        case .text: return false
        case .file:
            guard let url else { return false }
            return UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        }
    }

    /// The link when a text item is a single http(s) URL.
    var trayAILinkURL: URL? {
        guard kind == .text, let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.contains(where: \.isWhitespace) else { return nil }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// Name-based guess only; the engine checks the OCR text when it runs.
    var trayAILooksLikeReceipt: Bool {
        let name = displayName.lowercased()
        return ["receipt", "invoice", "bill", "order"].contains { name.contains($0) }
    }
}
