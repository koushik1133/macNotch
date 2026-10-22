import AppKit
import Carbon.HIToolbox
import Foundation

// Quick capture to Spaces: shared types, persisted settings and the pure
// decisions (what to capture, where to file it) that the tests exercise.

/// What one press of the capture hotkey grabbed.
enum QuickCaptureKind: String, Codable, CaseIterable, Sendable {
    /// Text selected in the front app (read through Accessibility).
    case selection
    /// The front browser tab (URL, title and readable text).
    case webPage
    /// An interactive screenshot (OCR'd on device).
    case screenshot

    var label: String {
        switch self {
        case .selection: "selection"
        case .webPage: "web page"
        case .screenshot: "screenshot"
        }
    }

    var symbol: String {
        switch self {
        case .selection: "text.quote"
        case .webPage: "safari"
        case .screenshot: "camera.viewfinder"
        }
    }
}

/// What to do when no Space's agent is confident enough to file the capture.
enum QuickCaptureFallback: String, Codable, CaseIterable, Sendable {
    /// Leave it in the Inbox (Spaces may still suggest a Space later).
    case inbox
    /// File it with the Space used last (Notion Web Clipper keeps its last destination).
    case lastUsed

    var title: String {
        switch self {
        case .inbox: "Leave in Inbox"
        case .lastUsed: "File to Last-Used Space"
        }
    }
}

/// The first capture source that applies, in the order Raycast/PopClip-style
/// tools use: an explicit selection beats the page, the page beats a screenshot.
enum QuickCapturePlan: Equatable, Sendable {
    case selection(String)
    case webPage(SpaceConnectors.Browser)
    case screenshot
    /// Every source that applied is switched off.
    case nothing
}

enum QuickCapturePlanner {
    /// Selections shorter than this (after trimming) are treated as no
    /// selection, e.g. a stray caret selecting one space.
    static let minimumSelectionCharacters = 2
    /// Longest selection kept (the store caps text at 60k as well).
    static let maximumSelectionCharacters = 60_000

    /// Picks what to capture. `selection` is the AX selected text (nil when
    /// none or unreadable); `frontBundleID` is the app that was frontmost
    /// when the hotkey fired.
    static func plan(selection: String?, frontBundleID: String?, settings: QuickCaptureSettings.Snapshot) -> QuickCapturePlan {
        if settings.capturesSelection, let text = cleanedSelection(selection) {
            return .selection(text)
        }
        if settings.capturesWebPage, let front = frontBundleID,
           let browser = SpaceConnectors.Browser.all.first(where: { $0.bundleID == front }) {
            return .webPage(browser)
        }
        if settings.capturesScreenshot { return .screenshot }
        return .nothing
    }

    /// Trimmed selection, or nil when it is too short to be meaningful.
    static func cleanedSelection(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumSelectionCharacters else { return nil }
        guard text.count > maximumSelectionCharacters else { return text }
        return String(text.prefix(maximumSelectionCharacters))
    }

    /// The Spaces input for a selection. The key is a hash of the text so
    /// capturing the same passage twice refreshes one item.
    static func selectionInput(
        _ text: String, appBundleID: String?, appName: String?, windowTitle: String?, page: SpaceConnectors.BrowserTab?,
        now: Date = Date()
    ) -> SpaceIngestInput {
        var hints: [String: String] = ["capture": "selection"]
        if let appBundleID { hints["app"] = appBundleID }
        if let appName, !appName.isEmpty { hints["appName"] = appName }
        if let windowTitle, !windowTitle.isEmpty { hints["window"] = String(windowTitle.prefix(120)) }
        var body = text
        var url: URL?
        if let page {
            url = page.url
            if let domain = SpaceConnectors.domain(of: page.url) { hints["domain"] = domain }
            hints["browser"] = page.browser
            let source = page.title.isEmpty ? page.url.absoluteString : "\(page.title) — \(page.url.absoluteString)"
            body += "\n\nSource: \(source)"
        } else if let appName, !appName.isEmpty {
            let place = (windowTitle?.isEmpty == false) ? "\(appName) — \(windowTitle!)" : appName
            body += "\n\nSource: \(place)"
        }
        let digest = String(SpaceConnectors.sha256Hex(Data(text.utf8)).prefix(32))
        return SpaceIngestInput(
            kind: .note, source: .manual, title: SpaceConnectors.headline(text), text: SpaceConnectors.capped(body),
            url: url, attachment: nil, sourceKey: "capture:\(digest)", createdAt: now, hints: hints
        )
    }

    /// Where a capture the agents left in the Inbox should go: the store's own
    /// filing suggestion for it first, then the fallback setting.
    static func fallbackSpace(
        for itemID: UUID, suggestions: [SpaceSuggestion], spaces: [Space], fallback: QuickCaptureFallback, lastUsed: UUID?
    ) -> (spaceID: UUID, suggestion: SpaceSuggestion?)? {
        let known = Set(spaces.map(\.id))
        let best = suggestions
            .compactMap { s -> (SpaceSuggestion, UUID, Double)? in
                if case .file(let id, let spaceID, let confidence, _) = s.action, id == itemID, known.contains(spaceID) {
                    return (s, spaceID, confidence)
                }
                return nil
            }
            .max { $0.2 < $1.2 }
        if let best { return (best.1, best.0) }
        if fallback == .lastUsed, let lastUsed, known.contains(lastUsed) { return (lastUsed, nil) }
        return nil
    }
}

/// A filed capture, kept so Undo and Change Space know what to revert.
struct QuickCaptureRecord: Equatable, Sendable {
    let itemID: UUID
    let kind: QuickCaptureKind
    let title: String
    /// Space it ended up in (nil = Inbox).
    var spaceID: UUID?
    /// True when the capture created the item; false when it matched an
    /// existing one (Undo then only puts it back where it was).
    let createdItem: Bool
    /// Where an existing item was before this capture moved it.
    let previousSpaceID: UUID?
    /// How it was filed, for the band: "auto" (agent), "suggested", "last used", "inbox".
    var filedBy: String
    let date: Date
}

/// Persisted settings (UserDefaults, injectable for tests).
@MainActor
final class QuickCaptureSettings: ObservableObject {
    struct Snapshot: Equatable, Sendable {
        var capturesSelection = true
        var capturesWebPage = true
        var capturesScreenshot = true
    }

    enum Keys {
        static let enabled = "QuickCapture.enabled"
        static let shortcut = "QuickCapture.shortcut"
        static let fallback = "QuickCapture.fallback"
        static let lastUsedSpace = "QuickCapture.lastUsedSpace"
        static let capturesSelection = "QuickCapture.capturesSelection"
        static let capturesWebPage = "QuickCapture.capturesWebPage"
        static let capturesScreenshot = "QuickCapture.capturesScreenshot"
        static let selectionIncludesPage = "QuickCapture.selectionIncludesPage"
    }

    /// ⌃⌥C.
    static let defaultShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey))

    let defaults: UserDefaults

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Keys.enabled) } }
    @Published var shortcut: ScreenRegionShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: Keys.shortcut) }
        }
    }
    @Published var fallback: QuickCaptureFallback { didSet { defaults.set(fallback.rawValue, forKey: Keys.fallback) } }
    @Published var capturesSelection: Bool { didSet { defaults.set(capturesSelection, forKey: Keys.capturesSelection) } }
    @Published var capturesWebPage: Bool { didSet { defaults.set(capturesWebPage, forKey: Keys.capturesWebPage) } }
    @Published var capturesScreenshot: Bool { didSet { defaults.set(capturesScreenshot, forKey: Keys.capturesScreenshot) } }
    /// Adds the browser tab's URL to a selection captured in a browser, only
    /// when SparkV already has Automation access to it (never prompts).
    @Published var selectionIncludesPage: Bool { didSet { defaults.set(selectionIncludesPage, forKey: Keys.selectionIncludesPage) } }
    @Published var lastUsedSpaceID: UUID? {
        didSet { defaults.set(lastUsedSpaceID?.uuidString, forKey: Keys.lastUsedSpace) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.shortcut),
           let saved = try? JSONDecoder().decode(ScreenRegionShortcut.self, from: data), saved.isValidGlobal {
            shortcut = saved
        } else {
            shortcut = Self.defaultShortcut
        }
        fallback = defaults.string(forKey: Keys.fallback).flatMap(QuickCaptureFallback.init(rawValue:)) ?? .inbox
        capturesSelection = defaults.object(forKey: Keys.capturesSelection) as? Bool ?? true
        capturesWebPage = defaults.object(forKey: Keys.capturesWebPage) as? Bool ?? true
        capturesScreenshot = defaults.object(forKey: Keys.capturesScreenshot) as? Bool ?? true
        selectionIncludesPage = defaults.object(forKey: Keys.selectionIncludesPage) as? Bool ?? true
        lastUsedSpaceID = defaults.string(forKey: Keys.lastUsedSpace).flatMap(UUID.init(uuidString:))
    }

    var snapshot: Snapshot {
        Snapshot(capturesSelection: capturesSelection, capturesWebPage: capturesWebPage, capturesScreenshot: capturesScreenshot)
    }
}
