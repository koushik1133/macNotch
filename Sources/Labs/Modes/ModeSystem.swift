import AppKit
import CoreAudio
import Foundation

// Every side effect a mode has goes through `ModeSystem`, so the engine can
// be tested with a recording fake (no real wallpaper, volume, Do Not Disturb,
// appearance or apps are touched in tests). `LiveModeSystem` is the real one.

// MARK: - Values

/// A display, identified by its CGDirectDisplayID as a string.
struct ModeScreen: Hashable, Sendable {
    let id: String
    /// Native resolution in pixels (what wallpaper images are rendered at).
    let pixelSize: CGSize
}

/// The desktop picture of one screen, with its options, so it can be put back exactly.
struct ModeWallpaperState: Codable, Hashable, Sendable {
    var path: String
    /// NSImageScaling raw value.
    var scaling: UInt?
    var allowClipping: Bool?
    /// "#RRGGBB" fill shown around a scaled image.
    var fillColorHex: String?
}

struct ModeRunningApp: Hashable, Sendable {
    let bundleID: String
    let name: String
    let isHidden: Bool
    /// The user's front app (while SparkV's own window is in front, the
    /// app that was in front before it).
    let isActive: Bool
    /// Where it is on disk (for reopening after a quit).
    let path: String?

    /// Matches a bundle ID, an app name or an .app path, ignoring case.
    func matches(_ identifier: String) -> Bool {
        let id = identifier.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return false }
        if id.caseInsensitiveCompare(bundleID) == .orderedSame { return true }
        if id.caseInsensitiveCompare(name) == .orderedSame { return true }
        if id.hasSuffix(".app") {
            if let path, (path as NSString).standardizingPath == (id as NSString).standardizingPath { return true }
            let base = URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent
            return base.caseInsensitiveCompare(name) == .orderedSame
        }
        return false
    }
}

/// How SparkV's Focus feature is reached. The integration fills these in
/// from `FocusController` and `NotificationMonitor`; until then the actions
/// report that they're unavailable.
struct ModeFocusHooks {
    /// Starts a session (nil lengths use the user's Focus settings). Returns
    /// false when one is already running (then the mode leaves it alone).
    var startSession: @MainActor (_ focusMinutes: Int?, _ breakMinutes: Int?) -> Bool
    var endSession: @MainActor () -> Void
    var isSessionActive: @MainActor () -> Bool
    /// SparkV's own notification previews (nil: not available).
    var previewsEnabled: @MainActor () -> Bool?
    var setPreviewsEnabled: @MainActor (Bool) -> Void
    /// The Do Not Disturb shortcut names chosen in Focus settings.
    var doNotDisturbShortcuts: @MainActor () -> (on: String, off: String)
}

enum ModeSystemError: LocalizedError, Equatable {
    case unavailable(String)
    case failed(String)
    case notAuthorized(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let m), .failed(let m), .notAuthorized(let m): m
        }
    }
}

// MARK: - Protocol

@MainActor
protocol ModeSystem: AnyObject {
    /// SparkV's own bundle ID (never hidden or quit by a mode).
    var ownBundleID: String { get }

    // Wallpaper
    func screens() -> [ModeScreen]
    func wallpaper(screenID: String) -> ModeWallpaperState?
    func setWallpaper(_ state: ModeWallpaperState, screenID: String) throws
    /// Renders (or resolves) the image for a choice at a screen's pixel size.
    func wallpaperImage(for choice: ModeWallpaperChoice, size: CGSize) throws -> URL

    // Sound and display
    /// 0...1, nil when the output device has no volume control.
    func outputVolume() -> Double?
    func setOutputVolume(_ value: Double) throws
    /// Effective system appearance, nil when unknown.
    func isDarkMode() -> Bool?
    func setDarkMode(_ on: Bool) async throws
    /// Built-in display, 0...1, nil when unavailable (external display only).
    func brightness() -> Double?
    func setBrightness(_ value: Double) throws

    // Apps
    func runningApps() -> [ModeRunningApp]
    func openApp(_ identifier: String, activate: Bool) async throws
    func hideApp(bundleID: String) -> Bool
    func unhideApp(bundleID: String) -> Bool
    /// Asks the app to quit normally (it may show its own save dialog). Never force quits.
    func quitApp(bundleID: String) -> Bool
    /// Asks the user before SparkV quits an app for the first time.
    func confirmQuit(appName: String, modeName: String) async -> Bool
    func openURL(_ url: URL) throws

    // Shortcuts
    func shortcutNames() async throws -> [String]
    func runShortcut(_ name: String) async throws
    func doNotDisturbShortcuts() -> (on: String, off: String)

    // Music (delegated to ModeMusicPlayer)
    func startMusic(_ choice: ModeMusicChoice) async throws
    func stopMusic() async

    // SparkV's Focus feature
    func notificationPreviewsEnabled() -> Bool?
    func setNotificationPreviewsEnabled(_ enabled: Bool) throws
    /// Returns true when a new session was started by this call.
    func startFocusSession(focusMinutes: Int?, breakMinutes: Int?) throws -> Bool
    func endFocusSession()
    func isFocusSessionActive() -> Bool

    // Added after the first version; the extension below gives fakes defaults.
    /// Like `wallpaperImage`, but the live system renders off the main
    /// thread (a first 5K render takes up to about a second).
    func renderWallpaperImage(for choice: ModeWallpaperChoice, size: CGSize) async throws -> URL
    /// Whether the default output is muted (nil: unknown or no mute control).
    func outputMuted() -> Bool?
    func setOutputMuted(_ muted: Bool) throws
}

extension ModeSystem {
    func renderWallpaperImage(for choice: ModeWallpaperChoice, size: CGSize) async throws -> URL {
        try wallpaperImage(for: choice, size: size)
    }
    func outputMuted() -> Bool? { nil }
    func setOutputMuted(_ muted: Bool) throws {}
}

// MARK: - Live

@MainActor
final class LiveModeSystem: ModeSystem {
    static let shared = LiveModeSystem()

    /// Set by the integration (see INTEGRATION.md).
    var focusHooks: ModeFocusHooks?

    /// The mode's player (the editor's Test button has its own).
    private var music: ModeMusicPlayer { ModeMusicPlayer.shared }
    private let shortcuts = ShortcutRunner(timeout: 30)
    private let brightnessControl = ModeBrightnessControl()
    /// The last app other than SparkV that was frontmost. When a mode is
    /// started from SparkV's own window (SparkV is frontmost), "hide all
    /// but the front app" keeps this one instead of hiding everything.
    private var lastOtherFrontPID: pid_t?
    private var activationObserver: NSObjectProtocol?

    var ownBundleID: String { Bundle.main.bundleIdentifier ?? "SparkV" }

    init() {
        noteFront(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.noteFront(pid) }
        }
    }

    private func noteFront(_ pid: pid_t?) {
        guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
        lastOtherFrontPID = pid
    }

    /// The user's front app: the frontmost one, or while SparkV itself is
    /// frontmost, the app that was in front before it.
    private func userFrontPID() -> pid_t? {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != me else {
            if let last = lastOtherFrontPID, NSRunningApplication(processIdentifier: last)?.isTerminated == false { return last }
            let owner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
            return owner == me ? nil : owner
        }
        return front.processIdentifier
    }

    // MARK: Wallpaper

    func screens() -> [ModeScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = Self.screenID(screen) else { return nil }
            let scale = screen.backingScaleFactor
            return ModeScreen(id: id, pixelSize: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale))
        }
    }

    func wallpaper(screenID: String) -> ModeWallpaperState? {
        guard let screen = screen(for: screenID), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        return ModeWallpaperState(
            path: url.path,
            scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
            allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue,
            fillColorHex: (options[.fillColor] as? NSColor).flatMap(Self.hex)
        )
    }

    func setWallpaper(_ state: ModeWallpaperState, screenID: String) throws {
        guard let screen = screen(for: screenID) else {
            throw ModeSystemError.unavailable("That display is no longer connected.")
        }
        guard FileManager.default.fileExists(atPath: state.path) else {
            throw ModeSystemError.failed("The picture \(URL(fileURLWithPath: state.path).lastPathComponent) no longer exists.")
        }
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling = state.scaling { options[.imageScaling] = NSNumber(value: scaling) }
        if let clipping = state.allowClipping { options[.allowClipping] = NSNumber(value: clipping) }
        if let hex = state.fillColorHex, let color = Self.color(hex) { options[.fillColor] = color }
        do {
            try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: state.path), for: screen, options: options)
        } catch {
            throw ModeSystemError.failed("macOS didn't accept the wallpaper (\(error.localizedDescription)).")
        }
    }

    func wallpaperImage(for choice: ModeWallpaperChoice, size: CGSize) throws -> URL {
        try ModeWallpaperFactory.imageURL(for: choice, screen: size)
    }

    func renderWallpaperImage(for choice: ModeWallpaperChoice, size: CGSize) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            try ModeWallpaperFactory.imageURL(for: choice, screen: size)
        }.value
    }

    private func screen(for id: String) -> NSScreen? {
        NSScreen.screens.first { Self.screenID($0) == id }
    }

    private static func screenID(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { "\($0.uint32Value)" }
    }

    // MARK: Sound and display

    func outputVolume() -> Double? {
        guard let device = ModeAudio.defaultOutput() else { return nil }
        return ModeAudio.volume(device).map(Double.init)
    }

    func setOutputVolume(_ value: Double) throws {
        guard let device = ModeAudio.defaultOutput(), ModeAudio.canSetVolume(device) else {
            throw ModeSystemError.unavailable("This output device has no volume control.")
        }
        let v = Float(min(1, max(0, value)))
        if v > 0, ModeAudio.isMuted(device) { ModeAudio.setMuted(device, false) }
        ModeAudio.setVolume(device, v)
    }

    func outputMuted() -> Bool? {
        guard let device = ModeAudio.defaultOutput(), ModeAudio.hasMute(device) else { return nil }
        return ModeAudio.isMuted(device)
    }

    func setOutputMuted(_ muted: Bool) throws {
        guard let device = ModeAudio.defaultOutput(), ModeAudio.hasMute(device) else {
            throw ModeSystemError.unavailable("This output device can't be muted.")
        }
        ModeAudio.setMuted(device, muted)
    }

    func isDarkMode() -> Bool? {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?["AppleInterfaceStyle"] as? String)?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    func setDarkMode(_ on: Bool) async throws {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"
        let systemEvents = ModeAutomation.systemEventsBundleID
        guard await ModeAutomation.ready(bundleID: systemEvents, mayAsk: !ModeAutomation.isRestoring, feature: "Modes appearance") else {
            throw ModeSystemError.notAuthorized(ModeAutomation.notAllowedMessage("System Events"))
        }
        try await ModeOSAScript.run(script, target: "System Events")
    }

    func brightness() -> Double? {
        brightnessControl.read().map(Double.init)
    }

    func setBrightness(_ value: Double) throws {
        guard brightnessControl.isAvailable else {
            throw ModeSystemError.unavailable("Brightness works on the built-in display only.")
        }
        brightnessControl.write(Float(min(1, max(0.02, value))))
    }

    // MARK: Apps

    func runningApps() -> [ModeRunningApp] {
        let front = userFrontPID()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier, !app.isTerminated else { return nil }
            return ModeRunningApp(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID,
                isHidden: app.isHidden,
                isActive: app.processIdentifier == front,
                path: app.bundleURL?.path
            )
        }
    }

    func openApp(_ identifier: String, activate: Bool) async throws {
        guard let url = Self.applicationURL(for: identifier) else {
            throw ModeSystemError.unavailable("Couldn't find the app \(ModeAppNames.displayName(for: identifier)).")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        configuration.addsToRecentItems = false
        let message: String? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                continuation.resume(returning: error?.localizedDescription)
            }
        }
        if let message { throw ModeSystemError.failed(message) }
    }

    func hideApp(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).reduce(false) { $1.hide() || $0 }
    }

    func unhideApp(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).reduce(false) { $1.unhide() || $0 }
    }

    func quitApp(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).reduce(false) { $1.terminate() || $0 }
    }

    func confirmQuit(appName: String, modeName: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit \(appName) when \(modeName) starts?"
        alert.informativeText = "SparkV asks \(appName) to quit normally, so it can still ask you to save. SparkV won't ask again for \(appName); remove it from the mode to stop quitting it."
        alert.addButton(withTitle: "Quit \(appName)")
        alert.addButton(withTitle: "Keep Open")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    func openURL(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw ModeSystemError.failed("Couldn't open \(url.absoluteString).")
        }
    }

    /// Bundle ID, .app path, or app name in the usual Applications folders.
    static func applicationURL(for identifier: String) -> URL? {
        let id = identifier.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        if id.hasSuffix(".app") {
            let url = URL(fileURLWithPath: (id as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        let name = id.hasSuffix(".app") ? URL(fileURLWithPath: id).lastPathComponent : id + ".app"
        let folders = [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            "/Applications/Utilities", (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        for folder in folders {
            let path = (folder as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: Shortcuts

    func shortcutNames() async throws -> [String] {
        try await shortcuts.listShortcuts()
    }

    func runShortcut(_ name: String) async throws {
        _ = try await shortcuts.run(name)
    }

    func doNotDisturbShortcuts() -> (on: String, off: String) {
        if let hooks = focusHooks { return hooks.doNotDisturbShortcuts() }
        // Same names and storage as the Focus feature (FocusSettings, "focus.settings").
        if let data = UserDefaults.standard.data(forKey: "focus.settings"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let on = json["dndOnShortcut"] as? String, let off = json["dndOffShortcut"] as? String,
           !on.isEmpty, !off.isEmpty {
            return (on, off)
        }
        return (ModeDoNotDisturbNames.on, ModeDoNotDisturbNames.off)
    }

    // MARK: Music

    func startMusic(_ choice: ModeMusicChoice) async throws {
        try await music.start(choice)
    }

    /// Also closes music an earlier SparkV process left playing (crash recovery).
    func stopMusic() async {
        await music.stop()
        await music.cleanUpOrphans()
    }

    // MARK: Focus

    func notificationPreviewsEnabled() -> Bool? {
        focusHooks?.previewsEnabled()
    }

    func setNotificationPreviewsEnabled(_ enabled: Bool) throws {
        guard let hooks = focusHooks, hooks.previewsEnabled() != nil else {
            throw ModeSystemError.unavailable("SparkV notification previews aren't available.")
        }
        hooks.setPreviewsEnabled(enabled)
    }

    func startFocusSession(focusMinutes: Int?, breakMinutes: Int?) throws -> Bool {
        guard let hooks = focusHooks else {
            throw ModeSystemError.unavailable("SparkV's Focus feature isn't available.")
        }
        return hooks.startSession(focusMinutes, breakMinutes)
    }

    func endFocusSession() {
        focusHooks?.endSession()
    }

    func isFocusSessionActive() -> Bool {
        focusHooks?.isSessionActive() ?? false
    }

    // MARK: Colors

    private static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded()), b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func color(_ hex: String) -> NSColor? {
        let s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The Do Not Disturb shortcut names, shared with the Focus feature
/// (FocusSettings.defaultOnShortcut / defaultOffShortcut), plus the common
/// names other apps' setup guides use (Session, Tuple...).
enum ModeDoNotDisturbNames {
    static let on = "SparkV Focus On"
    static let off = "SparkV Focus Off"

    static let knownPairs: [(on: String, off: String)] = [
        (on, off),
        ("dnd-on", "dnd-off"),
        ("DND On", "DND Off"),
        ("Focus On", "Focus Off"),
        ("Do Not Disturb On", "Do Not Disturb Off"),
        ("session_start", "session_end"),
    ]

    /// The pair to use: the preferred one when both exist, else a known pair in the library.
    static func resolve(preferred raw: (on: String, off: String), library: [String]) -> (on: String, off: String)? {
        let preferred = normalized(raw)
        let names = Set(library)
        if names.contains(preferred.on), names.contains(preferred.off) { return preferred }
        return knownPairs.first { names.contains($0.on) && names.contains($0.off) }
    }

    /// Empty names (cleared in Focus settings) mean the defaults.
    static func normalized(_ pair: (on: String, off: String)) -> (on: String, off: String) {
        let on = pair.on.trimmingCharacters(in: .whitespaces), off = pair.off.trimmingCharacters(in: .whitespaces)
        return (on.isEmpty ? Self.on : on, off.isEmpty ? Self.off : off)
    }

    static func missingMessage(_ raw: (on: String, off: String)) -> String {
        let preferred = normalized(raw)
        return "Do Not Disturb needs two shortcuts in the Shortcuts app: “\(preferred.on)” (Set Focus › Do Not Disturb › Turn On) and “\(preferred.off)” (Turn Off). Set them up from SparkV's Focus settings."
    }
}

// MARK: - Automation permission

/// Decides whether a mode may send Apple Events to an app, through
/// PermissionCenter so Modes never shows an Automation prompt on its own:
/// - Turning a mode on (a user action) may ask once, queued with every other
///   system prompt; a denied app is reported in the mode's error line.
/// - Undoing (crash recovery at launch, Stop, switching, quitting) never
///   asks: anything to undo was done with a grant, so without one there is
///   nothing to put back and the script is skipped.
@MainActor
enum ModeAutomation {
    static let systemEventsBundleID = "com.apple.systemevents"

    /// Set by ModeEngine while it restores a snapshot.
    static var isRestoring = false

    static func notAllowedMessage(_ app: String) -> String {
        "SparkV isn't allowed to control \(app). Turn it on in System Settings › Privacy & Security › Automation › SparkV."
    }

    /// True when the script may run now. Never prompts unless `mayAsk`.
    static func ready(bundleID: String, mayAsk: Bool, feature: String) async -> Bool {
        let center = PermissionCenter.shared
        let permission = PermissionCenter.Permission.automation(bundleID: bundleID)
        var status = await center.freshStatus(permission)
        if status == .appNotRunning {
            // macOS can only answer for a running app, and a script that
            // launches it would show the prompt by itself, outside the queue.
            await launchInBackground(bundleID: bundleID)
            status = await center.freshStatus(permission)
        }
        switch status {
        case .granted:
            return true
        case .notDetermined, .limited:
            guard mayAsk else {
                AppLog.log("Modes: not asking to control \(bundleID) while undoing a mode (\(feature))")
                return false
            }
            return await center.request(permission, from: feature).isGranted
        case .denied, .restricted:
            // Turning on: let the script report it as before. Undoing: skip.
            return mayAsk
        case .appNotRunning, .appNotInstalled, .unknown:
            // Can't tell; the script reports its own error.
            return mayAsk
        }
    }

    private static func launchInBackground(bundleID: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        for _ in 0..<20 where NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }
}

// MARK: - AppleScript

/// Runs AppleScript through /usr/bin/osascript off the main thread, so the
/// first-time Automation prompt never blocks the notch. Callers check
/// `ModeAutomation.ready` first, so the prompt itself comes from
/// PermissionCenter and osascript never asks.
enum ModeOSAScript {
    static func run(_ source: String, target: String) async throws {
        let result: (status: Int32, error: String) = await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return (-1, error.localizedDescription)
            }
            process.waitUntilExit()
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        guard result.status != 0 else { return }
        if result.error.contains("-1743") || result.error.contains("-1744") || result.error.localizedCaseInsensitiveContains("not authorized") {
            throw ModeSystemError.notAuthorized(
                "SparkV isn't allowed to control \(target). Turn it on in System Settings › Privacy & Security › Automation › SparkV."
            )
        }
        let line = result.error.split(whereSeparator: \.isNewline).first.map(String.init) ?? "status \(result.status)"
        throw ModeSystemError.failed("\(target) didn't respond (\(line.prefix(120))).")
    }
}

// MARK: - CoreAudio

/// Default output volume (same approach as SystemKeyInterceptor's VolumeControl).
enum ModeAudio {
    static func defaultOutput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func elements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if isSettable(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        return [1, 2].filter { isSettable(device, kAudioDevicePropertyVolumeScalar, $0) }
    }

    static func canSetVolume(_ device: AudioObjectID) -> Bool { !elements(device).isEmpty }

    static func volume(_ device: AudioObjectID) -> Float? {
        let values = elements(device).compactMap { scalar(device, $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    static func setVolume(_ device: AudioObjectID, _ value: Float) {
        for element in elements(device) {
            var address = address(kAudioDevicePropertyVolumeScalar, element)
            var v = value
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static func hasMute(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(device, &address)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
        else { return false }
        return muted != 0
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var address = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func scalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) -> Float? {
        var address = address(kAudioDevicePropertyVolumeScalar, element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var address = address(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
}

// MARK: - Brightness

/// Built-in display brightness through DisplayServices (as SystemKeyInterceptor does).
final class ModeBrightnessControl {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Put = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getFn: Get?
    private let setFn: Put?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        getFn = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
        setFn = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Put.self) }
    }

    var isAvailable: Bool { getFn != nil && setFn != nil && Self.builtInDisplay() != nil }

    func read() -> Float? {
        guard let getFn, let display = Self.builtInDisplay() else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    func write(_ value: Float) {
        guard let setFn, let display = Self.builtInDisplay() else { return }
        _ = setFn(display, value)
    }

    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }
    }
}
