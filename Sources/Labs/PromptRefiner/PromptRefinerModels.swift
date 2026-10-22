import Foundation

// Value types shared by the Prompt Refiner engine, controller, history and UI.
// Nothing here talks to a model or touches the UI, so the engine can be run
// from a command-line harness.

/// Which assistant the refined prompt is written for. Each target gets its
/// own layout (see `PromptRefinerRenderer`).
enum PromptTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case chatGPT
    case gemini
    case imageModel
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .chatGPT: "ChatGPT"
        case .gemini: "Gemini"
        case .imageModel: "Image model"
        case .general: "General"
        }
    }

    var systemImage: String {
        switch self {
        case .claudeCode: "chevron.left.forwardslash.chevron.right"
        case .chatGPT: "bubble.left.and.text.bubble.right"
        case .gemini: "sparkle"
        case .imageModel: "photo.artframe"
        case .general: "text.alignleft"
        }
    }
}

/// Coarse kind of request, used for template questions, defaults and roles.
enum PromptDomain: String, Codable, CaseIterable, Sendable {
    case code, web, writing, image, data, research, planning, general
}

/// A clarifying question with suggested answers ("chips") and the user's reply.
struct ClarifyingQuestion: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    /// Short label used when the answer is written into the prompt ("Audience").
    var label: String
    var question: String
    var options: [String]
    /// Chips the user picked (any number).
    var selected: [String] = []
    /// What the user typed.
    var freeText: String = ""

    /// The combined answer, or nil when the question was left blank.
    var answer: String? {
        var parts = selected
        let typed = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        let joined = parts.joined(separator: "; ")
        return joined.isEmpty ? nil : joined
    }

    var isAnswered: Bool { answer != nil }
}

/// The parts of a refined text prompt, filled by a model or the templates and
/// laid out per target by `PromptRefinerRenderer`.
struct PromptSpec: Codable, Equatable, Sendable {
    var title: String = ""
    var role: String = ""
    var objective: String = ""
    var context: [String] = []
    var requirements: [String] = []
    var constraints: [String] = []
    var inputs: [String] = []
    var outputFormat: String = ""
    var acceptanceCriteria: [String] = []
    var example: String = ""
}

/// The parts of a refined image prompt.
struct ImagePromptSpec: Codable, Equatable, Sendable {
    var title: String = ""
    var subject: String = ""
    var setting: String = ""
    var style: String = ""
    var composition: String = ""
    var lighting: String = ""
    var colors: String = ""
    var mood: String = ""
    var details: [String] = []
    var aspectRatio: String = "1:1"
    var avoid: [String] = []

    static let aspectRatios = ["1:1", "4:3", "3:4", "16:9", "9:16", "3:2", "2:3"]
}

/// Which engine produced a step.
enum PromptRefinerSource: String, Codable, Sendable {
    case onDevice
    case groq
    case template

    var label: String {
        switch self {
        case .onDevice: "On-device model"
        case .groq: "Groq (opt-in)"
        case .template: "Template"
        }
    }
}

struct PromptQuestionSet: Sendable, Equatable {
    var intent: String
    var domain: PromptDomain
    var questions: [ClarifyingQuestion]
    var source: PromptRefinerSource
    var latency: TimeInterval
    /// Why a model step fell back, for the log and footnote.
    var note: String?
}

struct PromptRefinement: Sendable, Equatable {
    var title: String
    var text: String
    var source: PromptRefinerSource
    var latency: TimeInterval
    var note: String?
}

/// One finished refinement, kept in the history file.
struct PromptRefinementRecord: Identifiable, Codable, Equatable, Sendable {
    struct QA: Codable, Equatable, Sendable {
        var question: String
        var answer: String
    }

    var id = UUID()
    var date = Date()
    var title: String
    var rough: String
    var target: PromptTarget
    var answers: [QA]
    var refined: String
    var source: PromptRefinerSource
    var latencyMs: Int
}

/// Persistent switches. Groq is the Clicky key: Prompt Refiner uses it only
/// when this feature's own opt-in is on (off by default).
enum PromptRefinerSettings {
    static let allowGroqKey = "promptRefiner.allowGroq"
    static let targetKey = "promptRefiner.target"
    static let askFirstKey = "promptRefiner.askQuestionsFirst"

    static var allowGroq: Bool {
        get { UserDefaults.standard.bool(forKey: allowGroqKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowGroqKey) }
    }

    static var target: PromptTarget {
        get { UserDefaults.standard.string(forKey: targetKey).flatMap(PromptTarget.init(rawValue:)) ?? .general }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: targetKey) }
    }

    /// Ask clarifying questions before refining (on by default).
    static var askQuestionsFirst: Bool {
        get { UserDefaults.standard.object(forKey: askFirstKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: askFirstKey) }
    }
}
