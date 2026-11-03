import AppKit
import ColorSync
import CoreAudio
import CoreGraphics
import IOKit

// The system calls behind the HUD, in one place: display brightness
// (DisplayServices, which SparkV already used for the built-in panel), the
// screen list with stable display UUIDs, the display tools that own the
// brightness keys for external monitors, the default output's volume
// (CoreAudio), and whether the Mac has a keyboard backlight (IOKit, read
// only). Nothing here polls: callers refresh on notifications.

// MARK: - Display brightness

/// Per-display brightness through DisplayServices, loaded at runtime so a
/// missing symbol only disables brightness. Works for the built-in panel and
/// Apple's own displays (Studio Display, Pro Display XDR, LG UltraFine);
/// other monitors need DDC, which has no public API on Apple silicon, so
/// SparkV leaves them to BetterDisplay, Lunar or macOS.
@MainActor
final class HUDDisplayBrightness {
    static let shared = HUDDisplayBrightness()

    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias Unregister = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    private let getFn: Get?
    private let setFn: SetFn?
    private let canChangeFn: CanChange?
    private let registerFn: Register?
    private let unregisterFn: Unregister?
    private(set) var registered: Set<CGDirectDisplayID> = []

    /// DisplayServices loaded with get and set.
    var isAvailable: Bool { getFn != nil && setFn != nil }

    private init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let handle = dlopen(path, RTLD_LAZY)
        if handle == nil { AppLog.log("HUD: DisplayServices unavailable") }
        getFn = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
        setFn = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetFn.self) }
        canChangeFn = handle.flatMap { dlsym($0, "DisplayServicesCanChangeBrightness") }.map { unsafeBitCast($0, to: CanChange.self) }
        registerFn = handle.flatMap { dlsym($0, "DisplayServicesRegisterForBrightnessChangeNotifications") }.map { unsafeBitCast($0, to: Register.self) }
        unregisterFn = handle.flatMap { dlsym($0, "DisplayServicesUnregisterForBrightnessChangeNotifications") }.map { unsafeBitCast($0, to: Unregister.self) }
    }

    /// 0...1, or nil when the display has no readable brightness.
    func read(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(display, &value) == 0, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    func write(_ value: Float, to display: CGDirectDisplayID) {
        _ = setFn?(display, min(1, max(0, value)))
    }

    /// True when SparkV can set this display's brightness. The built-in panel
    /// always can (older systems lack the query); externals only when
    /// DisplayServices says so.
    func canChange(_ display: CGDirectDisplayID) -> Bool {
        guard isAvailable else { return false }
        if let canChangeFn { return canChangeFn(display) && read(display) != nil }
        return CGDisplayIsBuiltin(display) != 0 && read(display) != nil
    }

    /// Subscribes `callback` to change notifications for exactly `displays`
    /// (unsubscribing the rest). The observer value is the display ID, so the
    /// callback can tell which display changed.
    func registerForChanges(_ displays: Set<CGDirectDisplayID>, callback: CFNotificationCallback) {
        for display in registered.subtracting(displays) { unregister(display) }
        guard let registerFn else { return }
        for display in displays.subtracting(registered) {
            if registerFn(display, Self.observer(for: display), callback) == 0 {
                registered.insert(display)
            } else {
                AppLog.log("HUD: brightness change notifications unavailable for display \(display)")
            }
        }
    }

    func unregisterAll() {
        for display in registered { unregister(display) }
    }

    private func unregister(_ display: CGDirectDisplayID) {
        registered.remove(display)
        _ = unregisterFn?(display, Self.observer(for: display))
    }

    /// DisplayServices treats the observer as an opaque value: use the display ID.
    nonisolated static func observer(for display: CGDirectDisplayID) -> UnsafeRawPointer? {
        UnsafeRawPointer(bitPattern: UInt(display))
    }

    /// The display ID a callback's observer stands for.
    nonisolated static func display(fromObserver observer: UnsafeMutableRawPointer?) -> CGDirectDisplayID? {
        guard let observer else { return nil }
        let raw = UInt(bitPattern: observer)
        return raw <= UInt(UInt32.max) ? CGDirectDisplayID(raw) : nil
    }
}

// MARK: - Displays

/// One connected screen.
struct HUDScreenInfo: Equatable {
    var facts: HUDDisplayFacts
    /// Stable across reconnects (CGDirectDisplayID is not).
    var uuid: String?
    var name: String
    var frame: CGRect
    var visibleFrame: CGRect
    var hasNotch: Bool
}

/// The screens and their display facts, cached so the key tap's callback
/// never walks the display list. Refreshed on
/// `didChangeScreenParametersNotification` while the HUD runs.
@MainActor
final class HUDDisplayDirectory: ObservableObject {
    static let shared = HUDDisplayDirectory()

    @Published private(set) var screens: [HUDScreenInfo] = []
    private var observer: NSObjectProtocol?
    private var users = 0

    private init() {}

    /// Starts following screen changes (reference counted).
    func start() {
        users += 1
        guard users == 1 else { return }
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { HUDDisplayDirectory.shared.refresh() }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    func refresh() {
        let brightness = HUDDisplayBrightness.shared
        screens = NSScreen.screens.compactMap { screen in
            guard let id = Self.displayID(of: screen) else { return nil }
            let facts = HUDDisplayFacts(
                id: id,
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isActive: CGDisplayIsActive(id) != 0,
                canSetBrightness: brightness.canChange(id)
            )
            return HUDScreenInfo(
                facts: facts,
                uuid: Self.uuid(of: id),
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                hasNotch: screen.safeAreaInsets.top > 0
            )
        }
    }

    /// The cached screen list. Never refreshes here: this is read during
    /// view updates, where publishing is not allowed. `start()` (and views'
    /// `onAppear`) refresh it.
    private var current: [HUDScreenInfo] { screens }

    /// The screen under the pointer (cached frames: cheap per key repeat).
    func screenUnderPointer() -> HUDScreenInfo? {
        let mouse = NSEvent.mouseLocation
        return current.first { NSMouseInRect(mouse, $0.frame, false) }
            // The very top pixel row / right column sits on the frame's max edge.
            ?? current.first { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) }
    }

    /// The active built-in panel, nil in clamshell mode.
    func builtIn() -> HUDScreenInfo? {
        current.first { $0.facts.isBuiltin && $0.facts.isActive }
            ?? current.first { $0.facts.isBuiltin }
    }

    func screen(for display: CGDirectDisplayID) -> HUDScreenInfo? {
        current.first { $0.facts.id == display }
            // A mirror shows on its master's screen.
            ?? current.first { $0.facts.id == CGDisplayMirrorsDisplay(display) }
    }

    func facts(for display: CGDirectDisplayID) -> HUDDisplayFacts? {
        screen(for: display)?.facts
    }

    /// Displays whose brightness SparkV can read and set.
    var controllableDisplays: Set<CGDirectDisplayID> {
        Set(current.filter(\.facts.canSetBrightness).map(\.facts.id))
    }

    /// The NSScreen for a cached entry (for positioning panels).
    func nsScreen(for info: HUDScreenInfo) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == info.facts.id }
    }

    nonisolated static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    nonisolated static func uuid(of display: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// The island's display as `NotchWindowController.targetScreen()` picks
    /// it: the notched screen, else the first one.
    static func defaultIslandScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }
}

// MARK: - Display tools

/// Whether BetterDisplay, Lunar or MonitorControl is running, followed with
/// NSWorkspace launch / quit notifications (no polling).
@MainActor
final class HUDDisplayAppWatcher: ObservableObject {
    static let shared = HUDDisplayAppWatcher()

    /// Names of the running display tools, e.g. "BetterDisplay".
    @Published private(set) var runningName: String?
    var isRunning: Bool { runningName != nil }

    private var tokens: [NSObjectProtocol] = []
    private var users = 0

    private init() {}

    func start() {
        users += 1
        guard users == 1 else { return }
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard HUDDisplayApps.name(for: bundleID) != nil else { return }
                MainActor.assumeIsolated { HUDDisplayAppWatcher.shared.refresh() }
            })
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        tokens.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        tokens = []
    }

    /// Shows `name` as running without looking (Settings renders only).
    func setPreviewName(_ name: String?) {
        runningName = name
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(\.bundleIdentifier)
        let name = HUDDisplayApps.runningSummary(running)
        if name != runningName {
            runningName = name
            AppLog.log("HUD: display tool \(name.map { "\($0) running" } ?? "none running")")
        }
    }
}

// MARK: - Volume

/// The default output device's volume and mute through CoreAudio. Shared by
/// the key interceptor and the interactive HUD.
enum HUDVolumeControl {
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

    /// Volume elements to drive: the main element when settable, else channels 1 and 2.
    private static func elements(_ device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if isSettable(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }
        return [1, 2].filter { isSettable(device, kAudioDevicePropertyVolumeScalar, $0) }
    }

    static func canSetVolume(_ device: AudioObjectID) -> Bool {
        !elements(device).isEmpty
    }

    static func volume(_ device: AudioObjectID) -> Float? {
        let values = elements(device).compactMap { scalar(device, $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    static func setVolume(_ device: AudioObjectID, _ value: Float) {
        let clamped = min(1, max(0, value))
        for element in elements(device) {
            var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
            var v = clamped
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static func hasMute(_ device: AudioObjectID) -> Bool {
        isSettable(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = outputAddress(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr
        else { return false }
        return muted != 0
    }

    static func setMuted(_ device: AudioObjectID, _ muted: Bool) {
        var address = outputAddress(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else {
            // No mute control: emulate with volume 0.
            if muted { setVolume(device, 0) }
            return
        }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private static func scalar(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) -> Float? {
        var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var address = outputAddress(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
}

// MARK: - Keyboard backlight (read only)

/// macOS has no public API to read or set the keyboard backlight level (only
/// the private CoreBrightness framework does), so SparkV doesn't draw it:
/// the keys and Control Center keep handling it. This only reports whether
/// the Mac has one, from the IOResources registry entry (public IOKit).
enum HUDKeyboardBacklight {
    /// Read once: the hardware doesn't change while SparkV runs.
    static let isPresent: Bool = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources")
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntryCreateCFProperty(entry, "KeyboardBacklight" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }()

    /// Keyboard settings, where the backlight's brightness and auto-adjust live.
    static func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
