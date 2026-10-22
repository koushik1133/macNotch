import AppKit
import Carbon.HIToolbox
import Foundation

// Value types shared by the Reply Drafter: what app the user is in, the
// conversation read from it, the tone profile, drafts and settings.
// Everything here is pure data so the detection, parsing and draft-building
// steps can be tested headlessly with fixtures.

/// The kind of app or web app the reply is for.
enum ReplyAppKind: String, Sendable, CaseIterable, Codable {
    case gmail, outlook, appleMail, slack, whatsapp, messages, teams, linkedin, discord, generic

    var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .appleMail: "Mail"
        case .slack: "Slack"
        case .whatsapp: "WhatsApp"
        case .messages: "Messages"
        case .teams: "Teams"
        case .linkedin: "LinkedIn"
        case .discord: "Discord"
        case .generic: "Message"
        }
    }

    /// Email clients get a greeting, paragraphs, a sign-off and a subject.
    var isEmail: Bool { self == .gmail || self == .outlook || self == .appleMail }

    /// Apps whose messages are left/right bubbles (outgoing on the right).
    var usesBubbles: Bool { self == .whatsapp || self == .messages }

    /// Generic SF Symbols only (no brand marks).
    var symbol: String {
        switch self {
        case .gmail, .outlook, .appleMail: "envelope.fill"
        case .slack, .discord, .teams: "bubble.left.and.text.bubble.right.fill"
        case .whatsapp, .messages: "message.fill"
        case .linkedin: "person.2.fill"
        case .generic: "text.bubble.fill"
        }
    }
}

/// One element of the frontmost window's Accessibility tree, flattened in
/// depth-first (reading) order. `frame` is in global Quartz points
/// (top-left origin, y down), as `AXPosition`/`AXSize` report it.
struct ReplyAXNode: Sendable, Equatable {
    var role: String
    var subrole: String = ""
    var title: String = ""
    /// `AXDescription` (the web `aria-label`).
    var label: String = ""
    var value: String = ""
    var placeholder: String = ""
    /// `AXIdentifier` or `AXDOMIdentifier`.
    var identifier: String = ""
    /// `AXDOMClassList` (Chromium and WebKit web content).
    var domClasses: [String] = []
    var frame: CGRect = .zero
    var depth: Int = 0
    /// Index of the parent node in the flattened list (nil for the window).
    var parent: Int?
    var isFocused = false
    /// A text input the user can type into.
    var isEditable = false
    /// `AXURL` of a web area.
    var url: String = ""

    init(
        role: String, subrole: String = "", title: String = "", label: String = "", value: String = "",
        placeholder: String = "", identifier: String = "", domClasses: [String] = [], frame: CGRect = .zero,
        depth: Int = 0, parent: Int? = nil, isFocused: Bool = false, isEditable: Bool = false, url: String = ""
    ) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.identifier = identifier
        self.domClasses = domClasses
        self.frame = frame
        self.depth = depth
        self.parent = parent
        self.isFocused = isFocused
        self.isEditable = isEditable
        self.url = url
    }

    /// The text a person would read for this node.
    var readableText: String {
        switch role {
        case "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell":
            return value.isEmpty ? title : value
        case "AXLink", "AXButton":
            return title.isEmpty ? label : title
        default:
            return ""
        }
    }

    func hasClass(prefix: String) -> Bool { domClasses.contains { $0.hasPrefix(prefix) } }
    func hasClass(_ name: String) -> Bool { domClasses.contains(name) }
}

/// The frontmost window as read through Accessibility (or a test fixture).
struct ReplyWindowSnapshot: Sendable, Equatable {
    var bundleID: String
    var appName: String
    var windowTitle: String
    /// Global Quartz frame of the window.
    var windowFrame: CGRect
    var nodes: [ReplyAXNode]
    /// Index of the focused element, if it is inside the window.
    var focusedIndex: Int?

    /// URL of the first web area (the page in a browser).
    var url: String? { nodes.first { $0.role == "AXWebArea" && !$0.url.isEmpty }?.url }
}

/// A line of text with its position, from Accessibility or from OCR.
/// `frame` is window-relative, top-left origin, y down, in points.
struct ReplyTextLine: Sendable, Equatable {
    enum Role: String, Sendable { case text, author, time, subject, body, quoted }

    var text: String
    var frame: CGRect
    var role: Role = .text
    /// True/false when the app marks the message as outgoing/incoming.
    var outgoing: Bool?
    /// Message container the line belongs to (same value = same message).
    var group: Int?
}

struct ReplyMessage: Sendable, Equatable {
    var author: String
    var text: String
    var isFromMe: Bool
    var time: String?
}

/// What the drafter knows about the conversation it replies to.
struct ReplyConversation: Sendable, Equatable {
    enum Source: String, Sendable { case accessibility, screen, none }

    var kind: ReplyAppKind
    /// Chat or channel name, or the email subject.
    var title: String = ""
    /// Email subject as shown in the thread (nil for chats).
    var subject: String?
    var messages: [ReplyMessage] = []
    var participants: [String] = []
    /// Email To field (new mail), e.g. ["sam.patel@vendorco.com"].
    var recipients: [String] = []
    /// Node index of the message box to write into.
    var composeIndex: Int?
    /// Node index of an email Subject field (new mail / reply with editable subject).
    var subjectIndex: Int?
    /// The Subject field's current text.
    var subjectFieldValue: String = ""
    /// What the user already typed in the message box (their notes), without
    /// any signature.
    var existingDraft: String = ""
    /// The user's own signature already in the message box without a "-- "
    /// marker (Apple Mail, Outlook), kept out of the replaced range.
    var signature: String?
    var source: Source = .accessibility

    /// No thread on screen: the user is writing a new email.
    var isNewEmail: Bool { kind.isEmail && messages.isEmpty }

    var lastIncoming: ReplyMessage? { messages.last { !$0.isFromMe } }

    var myMessages: [ReplyMessage] { messages.filter(\.isFromMe) }

    /// The Subject field should be filled: it exists and is empty.
    var shouldFillSubject: Bool {
        kind.isEmail && subjectIndex != nil && subjectFieldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var characterCount: Int { messages.reduce(0) { $0 + $1.text.count } }
}

/// The user's writing style, learned from their own messages on screen plus
/// the tone description they set.
struct ReplyToneProfile: Sendable, Equatable {
    var userName: String
    /// Free text from settings, e.g. "Friendly and brief, no emojis".
    var preference: String = ""
    var greeting: String?
    var signOff: String?
    var usesEmoji = false
    var startsLowercase = false
    var usesExclamations = false
    /// Median words per message of the user's own messages (0 = unknown).
    var typicalWords = 0
    /// A few of the user's own messages, verbatim (short ones).
    var examples: [String] = []
}

/// Ways to rework a draft from the floating bar.
enum ReplyRevision: String, Sendable, CaseIterable {
    case regenerate, shorter, longer, formal, casual

    var title: String {
        switch self {
        case .regenerate: "Regenerate"
        case .shorter: "Shorter"
        case .longer: "Longer"
        case .formal: "More formal"
        case .casual: "More casual"
        }
    }

    var instruction: String {
        switch self {
        case .regenerate: "Write a different version of the reply with the same intent."
        case .shorter: "Rewrite the draft at about half its length. Keep the key point and the same voice."
        case .longer: "Rewrite the draft a little longer: add one or two sentences of useful detail taken from the conversation, without inventing facts."
        case .formal: "Rewrite the draft in a more formal, professional tone: full sentences, proper capitalization, no slang or emoji."
        case .casual: "Rewrite the draft in a more casual, relaxed tone, with contractions, like a message to a colleague you know well."
        }
    }
}

/// A generated reply.
struct ReplyDraft: Sendable, Equatable {
    var body: String
    /// Only for emails whose Subject field is empty.
    var subject: String?
    /// "Apple Intelligence (on-device)", "Groq", or "Basic template".
    var producedBy: String
}

/// Context from the user's Spaces for the reply.
struct ReplySpaceContext: Sendable, Equatable {
    struct Snippet: Sendable, Equatable {
        var title: String
        var text: String
    }

    var spaceID: UUID?
    var spaceName: String?
    var background: String?
    var snippets: [Snippet] = []

    var isEmpty: Bool { snippets.isEmpty && (background ?? "").isEmpty }
}

// MARK: - Settings

/// Persisted preferences (UserDefaults). Groq is off by default and the key
/// is never read while it is off.
@MainActor
final class ReplyDrafterSettings: ObservableObject {
    enum Key {
        static let allowGroq = "ReplyDrafterAllowsGroq"
        static let autoInsert = "ReplyDrafterAutoInsert"
        static let fillSubject = "ReplyDrafterFillSubject"
        static let useSpaces = "ReplyDrafterUseSpaces"
        static let readScreen = "ReplyDrafterReadScreen"
        static let tone = "ReplyDrafterTone"
        static let userName = "ReplyDrafterUserName"
        static let signOff = "ReplyDrafterSignOff"
        static let hotkeyEnabled = "ReplyDrafterHotkeyEnabled"
        static let shortcut = "ReplyDrafterShortcut"
    }

    static let tonePresets: [(title: String, text: String)] = [
        ("Match my messages", ""),
        ("Friendly", "Friendly and warm, plain words."),
        ("Professional", "Professional and polite, clear and to the point."),
        ("Concise", "Very concise. Short sentences, no filler."),
        ("Casual", "Casual and relaxed, like texting a colleague I know well."),
    ]

    /// ⌃⌥R.
    static let defaultShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey))

    private let defaults: UserDefaults

    @Published var allowGroq: Bool { didSet { defaults.set(allowGroq, forKey: Key.allowGroq) } }
    /// Write the draft straight into the message box (Undo puts it back).
    @Published var autoInsert: Bool { didSet { defaults.set(autoInsert, forKey: Key.autoInsert) } }
    /// Fill an empty email Subject.
    @Published var fillSubject: Bool { didSet { defaults.set(fillSubject, forKey: Key.fillSubject) } }
    @Published var useSpaces: Bool { didSet { defaults.set(useSpaces, forKey: Key.useSpaces) } }
    /// Capture the window and OCR it when the app hides its text from Accessibility.
    @Published var readScreen: Bool { didSet { defaults.set(readScreen, forKey: Key.readScreen) } }
    @Published var tone: String { didSet { defaults.set(tone, forKey: Key.tone) } }
    @Published var userName: String { didSet { defaults.set(userName, forKey: Key.userName) } }
    @Published var signOff: String { didSet { defaults.set(signOff, forKey: Key.signOff) } }
    @Published var hotkeyEnabled: Bool { didSet { defaults.set(hotkeyEnabled, forKey: Key.hotkeyEnabled) } }
    @Published var shortcut: ScreenRegionShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: Key.shortcut) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.allowGroq: false, Key.autoInsert: true, Key.fillSubject: true, Key.useSpaces: true,
            Key.readScreen: true, Key.hotkeyEnabled: true,
        ])
        allowGroq = defaults.bool(forKey: Key.allowGroq)
        autoInsert = defaults.bool(forKey: Key.autoInsert)
        fillSubject = defaults.bool(forKey: Key.fillSubject)
        useSpaces = defaults.bool(forKey: Key.useSpaces)
        readScreen = defaults.bool(forKey: Key.readScreen)
        tone = defaults.string(forKey: Key.tone) ?? ""
        userName = defaults.string(forKey: Key.userName) ?? ""
        signOff = defaults.string(forKey: Key.signOff) ?? ""
        hotkeyEnabled = defaults.bool(forKey: Key.hotkeyEnabled)
        if let data = defaults.data(forKey: Key.shortcut),
           let saved = try? JSONDecoder().decode(ScreenRegionShortcut.self, from: data), saved.isValidGlobal {
            shortcut = saved
        } else {
            shortcut = Self.defaultShortcut
        }
    }

    /// The name to sign with and to recognize the user's own messages by.
    var effectiveUserName: String {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? NSFullUserName() : trimmed
    }

    var tonePresetTitle: String {
        Self.tonePresets.first { $0.text == tone }?.title ?? "Custom"
    }
}
