import Foundation

// SparkV Modes: one tap sets up the Mac for a kind of work (wallpaper,
// music, Do Not Disturb, apps, appearance, a Pomodoro), and ending the mode
// puts everything back. Same idea as Apple's Focus filters (settings that
// apply while a Focus is on and revert when it ends), Keyboard Maestro macro
// groups and Bartender presets, but with SparkV doing the revert itself.
//
// Value types only: no AppKit, no singletons, so the headless harness can
// encode, decode and compare them.

// MARK: - Mode

struct SparkMode: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// SF Symbol name.
    var symbol: String
    /// "#RRGGBB".
    var colorHex: String
    /// Applied top to bottom; ending the mode restores in reverse order.
    var actions: [ModeAction]
    /// Put back the wallpaper, volume, appearance, brightness and apps when
    /// the mode ends. Music, the focus session, Do Not Disturb and muted
    /// previews always end with the mode either way.
    var restoreOnExit: Bool
    /// Ends the mode on its own after this many minutes (nil: until stopped).
    var autoEndMinutes: Int?

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "sparkles",
        colorHex: String = "#7C5CFF",
        actions: [ModeAction] = [],
        restoreOnExit: Bool = true,
        autoEndMinutes: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.actions = actions
        self.restoreOnExit = restoreOnExit
        self.autoEndMinutes = autoEndMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, colorHex, actions, restoreOnExit, autoEndMinutes
    }

    /// Tolerant: missing keys get defaults and unknown action types (from a
    /// newer SparkV) are dropped instead of failing the whole mode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mode"
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "sparkles"
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#7C5CFF"
        let lenient = try c.decodeIfPresent([ModeLenient<ModeAction>].self, forKey: .actions) ?? []
        actions = lenient.compactMap(\.value)
        restoreOnExit = try c.decodeIfPresent(Bool.self, forKey: .restoreOnExit) ?? true
        autoEndMinutes = try c.decodeIfPresent(Int.self, forKey: .autoEndMinutes)
        if let minutes = autoEndMinutes, minutes <= 0 { autoEndMinutes = nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(symbol, forKey: .symbol)
        try c.encode(colorHex, forKey: .colorHex)
        try c.encode(actions, forKey: .actions)
        try c.encode(restoreOnExit, forKey: .restoreOnExit)
        try c.encodeIfPresent(autoEndMinutes, forKey: .autoEndMinutes)
    }

    /// One line for menus and tooltips ("Wallpaper · Music · Do Not Disturb").
    var summary: String {
        actions.isEmpty ? "No actions" : actions.map(\.title).joined(separator: " · ")
    }
}

// MARK: - Actions

enum ModeAction: Codable, Hashable, Sendable {
    case wallpaper(ModeWallpaperChoice)
    case music(ModeMusicChoice)
    /// Output volume, 0...1.
    case volume(Double)
    /// Runs the user's "SparkV Focus On" / "SparkV Focus Off" shortcuts.
    case doNotDisturb(Bool)
    /// Bundle IDs (preferred), app names or .app paths.
    case openApps([String])
    /// Bundle IDs or app names; `ModeAction.allOtherApps` hides every app
    /// except the frontmost one (and SparkV).
    case hideApps([String])
    /// Asks once per app before quitting it; never force quits.
    case quitApps([String])
    case openURLs([String])
    /// Name of a shortcut in the user's Shortcuts library.
    case runShortcut(String)
    case darkMode(Bool)
    /// Starts a SparkV focus session with these lengths.
    case pomodoro(focusMinutes: Int, breakMinutes: Int)
    /// Starts a SparkV focus session with the user's Focus settings.
    case focusSession
    /// Built-in display brightness, 0...1.
    case brightness(Double)
    /// true mutes SparkV's own notification previews while the mode is on.
    case muteNotificationsPreviews(Bool)

    /// Token for `hideApps` meaning "everything except the front app".
    static let allOtherApps = "*"

    var kind: ModeStepKind {
        switch self {
        case .wallpaper: .wallpaper
        case .music: .music
        case .volume: .volume
        case .doNotDisturb: .doNotDisturb
        case .openApps: .openApps
        case .hideApps: .hideApps
        case .quitApps: .quitApps
        case .openURLs: .openURLs
        case .runShortcut: .runShortcut
        case .darkMode: .darkMode
        case .pomodoro: .pomodoro
        case .focusSession: .focusSession
        case .brightness: .brightness
        case .muteNotificationsPreviews: .muteNotificationsPreviews
        }
    }

    var title: String { kind.title }
    var symbol: String { kind.symbol }

    /// Short description of the value ("Black", "35 %", "Slack, Mail").
    var detail: String {
        switch self {
        case .wallpaper(let choice): choice.title
        case .music(let choice): choice.title
        case .volume(let v): "\(ModeAction.percent(v)) %"
        case .doNotDisturb(let on): on ? "On" : "Off"
        case .openApps(let apps), .quitApps(let apps): ModeAction.appList(apps)
        case .hideApps(let apps):
            apps.contains(ModeAction.allOtherApps) ? "All except the front app" : ModeAction.appList(apps)
        case .openURLs(let urls): urls.count == 1 ? (URL(string: urls[0])?.host ?? urls[0]) : "\(urls.count) links"
        case .runShortcut(let name): name.isEmpty ? "No shortcut chosen" : name
        case .darkMode(let on): on ? "Dark" : "Light"
        case .pomodoro(let f, let b): "\(f) min focus, \(b) min break"
        case .focusSession: "Your Focus settings"
        case .brightness(let v): "\(ModeAction.percent(v)) %"
        case .muteNotificationsPreviews(let on): on ? "Muted" : "Shown"
        }
    }

    /// "Wallpaper: Black".
    var label: String { "\(title): \(detail)" }

    static func percent(_ value: Double) -> Int { Int((min(1, max(0, value)) * 100).rounded()) }

    private static func appList(_ apps: [String]) -> String {
        guard !apps.isEmpty else { return "None" }
        let names = apps.map { ModeAppNames.displayName(for: $0) }
        return names.count <= 3 ? names.joined(separator: ", ") : names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
    }

    // MARK: Codable ({"type": "volume", "value": 0.35})

    private enum CodingKeys: String, CodingKey {
        case type, value, focusMinutes, breakMinutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        guard let kind = ModeStepKind(rawValue: type) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown mode action \(type)")
        }
        switch kind {
        case .wallpaper: self = .wallpaper(try c.decode(ModeWallpaperChoice.self, forKey: .value))
        case .music: self = .music(try c.decode(ModeMusicChoice.self, forKey: .value))
        case .volume: self = .volume(min(1, max(0, try c.decode(Double.self, forKey: .value))))
        case .doNotDisturb: self = .doNotDisturb(try c.decode(Bool.self, forKey: .value))
        case .openApps: self = .openApps(try c.decode([String].self, forKey: .value))
        case .hideApps: self = .hideApps(try c.decode([String].self, forKey: .value))
        case .quitApps: self = .quitApps(try c.decode([String].self, forKey: .value))
        case .openURLs: self = .openURLs(try c.decode([String].self, forKey: .value))
        case .runShortcut: self = .runShortcut(try c.decode(String.self, forKey: .value))
        case .darkMode: self = .darkMode(try c.decode(Bool.self, forKey: .value))
        case .pomodoro:
            self = .pomodoro(
                focusMinutes: min(240, max(1, try c.decodeIfPresent(Int.self, forKey: .focusMinutes) ?? 25)),
                breakMinutes: min(60, max(1, try c.decodeIfPresent(Int.self, forKey: .breakMinutes) ?? 5))
            )
        case .focusSession: self = .focusSession
        case .brightness: self = .brightness(min(1, max(0, try c.decode(Double.self, forKey: .value))))
        case .muteNotificationsPreviews: self = .muteNotificationsPreviews(try c.decode(Bool.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind.rawValue, forKey: .type)
        switch self {
        case .wallpaper(let v): try c.encode(v, forKey: .value)
        case .music(let v): try c.encode(v, forKey: .value)
        case .volume(let v), .brightness(let v): try c.encode(v, forKey: .value)
        case .doNotDisturb(let v), .darkMode(let v), .muteNotificationsPreviews(let v): try c.encode(v, forKey: .value)
        case .openApps(let v), .hideApps(let v), .quitApps(let v), .openURLs(let v): try c.encode(v, forKey: .value)
        case .runShortcut(let v): try c.encode(v, forKey: .value)
        case .pomodoro(let f, let b):
            try c.encode(f, forKey: .focusMinutes)
            try c.encode(b, forKey: .breakMinutes)
        case .focusSession: break
        }
    }
}

/// The kinds of action, for the editor's "Add Action" menu.
enum ModeStepKind: String, CaseIterable, Identifiable, Sendable {
    case wallpaper, music, volume, doNotDisturb, openApps, hideApps, quitApps, openURLs
    case runShortcut, darkMode, pomodoro, focusSession, brightness, muteNotificationsPreviews

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallpaper: "Wallpaper"
        case .music: "Music"
        case .volume: "Volume"
        case .doNotDisturb: "Do Not Disturb"
        case .openApps: "Open Apps"
        case .hideApps: "Hide Apps"
        case .quitApps: "Quit Apps"
        case .openURLs: "Open Links"
        case .runShortcut: "Run Shortcut"
        case .darkMode: "Appearance"
        case .pomodoro: "Pomodoro"
        case .focusSession: "Focus Session"
        case .brightness: "Brightness"
        case .muteNotificationsPreviews: "SparkV Previews"
        }
    }

    var symbol: String {
        switch self {
        case .wallpaper: "photo.on.rectangle"
        case .music: "music.note"
        case .volume: "speaker.wave.2.fill"
        case .doNotDisturb: "moon.fill"
        case .openApps: "macwindow.badge.plus"
        case .hideApps: "eye.slash"
        case .quitApps: "xmark.app"
        case .openURLs: "link"
        case .runShortcut: "square.stack.3d.up.fill"
        case .darkMode: "circle.lefthalf.filled"
        case .pomodoro: "timer"
        case .focusSession: "scope"
        case .brightness: "sun.max.fill"
        case .muteNotificationsPreviews: "bell.slash.fill"
        }
    }

    /// Value a freshly added action starts with.
    var defaultAction: ModeAction {
        switch self {
        case .wallpaper: .wallpaper(.solid(colorHex: "#000000"))
        case .music: .music(ModeMusicChoice(title: "Custom", url: "", volume: nil, openInBackground: true))
        case .volume: .volume(0.35)
        case .doNotDisturb: .doNotDisturb(true)
        case .openApps: .openApps([])
        case .hideApps: .hideApps([])
        case .quitApps: .quitApps([])
        case .openURLs: .openURLs([])
        case .runShortcut: .runShortcut("")
        case .darkMode: .darkMode(true)
        case .pomodoro: .pomodoro(focusMinutes: 25, breakMinutes: 5)
        case .focusSession: .focusSession
        case .brightness: .brightness(0.5)
        case .muteNotificationsPreviews: .muteNotificationsPreviews(true)
        }
    }
}

// MARK: - Wallpaper

enum ModeWallpaperChoice: Codable, Hashable, Sendable {
    case solid(colorHex: String)
    case gradient(fromHex: String, toHex: String)
    /// An image the user picked (absolute path).
    case file(path: String)
    /// A preset from `ModeWallpaperFactory` by its id.
    case builtIn(String)

    var title: String {
        switch self {
        case .solid(let hex): ModeColorNames.name(for: hex) ?? hex.uppercased()
        case .gradient(let from, let to): "Gradient \(from.uppercased()) → \(to.uppercased())"
        case .file(let path): URL(fileURLWithPath: path).lastPathComponent
        case .builtIn(let id): id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, colorHex, fromHex, toHex, path, id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "solid": self = .solid(colorHex: try c.decode(String.self, forKey: .colorHex))
        case "gradient": self = .gradient(fromHex: try c.decode(String.self, forKey: .fromHex), toHex: try c.decode(String.self, forKey: .toHex))
        case "file": self = .file(path: try c.decode(String.self, forKey: .path))
        case "builtIn": self = .builtIn(try c.decode(String.self, forKey: .id))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown wallpaper \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let hex):
            try c.encode("solid", forKey: .type)
            try c.encode(hex, forKey: .colorHex)
        case .gradient(let from, let to):
            try c.encode("gradient", forKey: .type)
            try c.encode(from, forKey: .fromHex)
            try c.encode(to, forKey: .toHex)
        case .file(let path):
            try c.encode("file", forKey: .type)
            try c.encode(path, forKey: .path)
        case .builtIn(let id):
            try c.encode("builtIn", forKey: .type)
            try c.encode(id, forKey: .id)
        }
    }
}

/// A few friendly names for the preset colors ("#000000" → "Black").
enum ModeColorNames {
    static func name(for hex: String) -> String? {
        switch hex.uppercased().replacingOccurrences(of: "#", with: "") {
        case "000000": "Black"
        case "FFFFFF": "White"
        case "0B1A33": "Deep Navy"
        case "16302B": "Forest"
        case "3A3A3C": "Minimal Grey"
        default: nil
        }
    }
}

// MARK: - Music

struct ModeMusicChoice: Codable, Hashable, Sendable {
    var title: String
    /// A youtube.com watch URL, another web page, or a direct audio stream.
    var url: String
    /// Optional level for the player (0...1), nil leaves it alone.
    var volume: Double?
    /// Open without bringing Safari to the front.
    var openInBackground: Bool

    init(title: String, url: String, volume: Double? = nil, openInBackground: Bool = true) {
        self.title = title
        self.url = url
        self.volume = volume
        self.openInBackground = openInBackground
    }

    private enum CodingKeys: String, CodingKey { case title, url, volume, openInBackground }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Music"
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        openInBackground = try c.decodeIfPresent(Bool.self, forKey: .openInBackground) ?? true
    }
}

// MARK: - Failures

/// One action that didn't work. The others still ran.
struct ModeActionFailure: Identifiable, Hashable, Sendable {
    let id = UUID()
    /// "Do Not Disturb", or "Restore Wallpaper".
    let step: String
    let message: String

    var text: String { "\(step): \(message)" }
}

// MARK: - Helpers

/// Readable names for the identifiers stored in app actions.
enum ModeAppNames {
    static let known: [String: String] = [
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.MobileSMS": "Messages",
        "com.apple.mail": "Mail",
        "com.apple.iCal": "Calendar",
        "com.apple.Music": "Music",
        "com.apple.Safari": "Safari",
        "com.hnc.Discord": "Discord",
        "com.microsoft.teams2": "Microsoft Teams",
        "us.zoom.xos": "zoom.us",
        "ru.keepcoder.Telegram": "Telegram",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.spotify.client": "Spotify",
    ]

    /// "com.apple.mail" → "Mail", "/Applications/Xcode.app" → "Xcode", "*" → "All other apps".
    static func displayName(for identifier: String) -> String {
        if identifier == ModeAction.allOtherApps { return "All other apps" }
        if let name = known[identifier] { return name }
        if identifier.hasSuffix(".app") {
            return URL(fileURLWithPath: identifier).deletingPathExtension().lastPathComponent
        }
        return identifier
    }
}

/// Decodes an element if it can, else nil (so one bad entry is skipped).
struct ModeLenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
