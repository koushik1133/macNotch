import AppKit
import Combine
import CoreAudio
import IOBluetooth
import SwiftUI

/// One-tap toggles for the expanded island: Keep Awake, Mute Mic, Dark
/// Mode, Hide Desktop Icons, Night Shift, AirPods, Low Power Mode and the
/// Screen Saver. Every state is re-read when the grid appears, never
/// cached; anything that asks the user (Automation for Dark Mode, the
/// administrator password for Low Power Mode, Bluetooth for AirPods) only
/// runs from a tap.
///
/// - Dark Mode: System Events, through Modes' consent path (`LiveModeSystem`).
/// - Hide Desktop Icons: a wallpaper picture just above the desktop icons on
///   every screen (no `defaults write` + `killall Finder`, which would close
///   Finder windows). It takes desktop clicks, so hidden icons stay untouched.
/// - Night Shift: no public API, so a Shortcut with the built-in
///   "Set Night Shift" action does it (named in settings).
/// - AirPods: pairs from IOBluetooth, connects asynchronously, then makes
///   them the sound output.
/// - Low Power Mode: `/usr/bin/pmset -a lowpowermode 1|0` through macOS's
///   administrator dialog, fixed arguments only.
@MainActor
final class QuickTogglesController: ObservableObject {
    static let shared = QuickTogglesController()

    static let visibleKey = "quickToggles.visible"
    static let nightShiftKey = "quickToggles.nightShiftShortcut"
    static let desktopKey = "quickToggles.hidesDesktopIcons"
    static let airPodsKey = "quickToggles.airPodsAddress"
    static let defaultNightShiftShortcut = "Toggle Night Shift"

    @Published private(set) var visibleKinds: [QuickToggleKind]
    @Published var nightShiftShortcut: String {
        didSet { StatusDefaults.set(nightShiftShortcut, Self.nightShiftKey) }
    }
    @Published private(set) var isDarkMode: Bool?
    @Published private(set) var hidesDesktopIcons: Bool
    @Published private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// Paired Bluetooth headphones (needs Bluetooth access).
    @Published private(set) var audioDevices: [PairedAudioDevice] = []
    /// The headset the AirPods toggle uses.
    @Published var favoriteAudioAddress: String? {
        didSet { StatusDefaults.set(favoriteAudioAddress, Self.airPodsKey) }
    }
    /// Toggles waiting on the system (a script, a connection).
    @Published private(set) var busy: Set<QuickToggleKind> = []
    /// The last thing that went wrong (or needs doing), shown under the grid.
    @Published private(set) var message: QuickToggleMessage?

    private var isStarted = false
    private let cover = DesktopIconsCover()
    private var themeObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?
    private var connector: BluetoothAudioConnector?
    private var messageTask: Task<Void, Never>?
    private let shortcuts = ShortcutRunner(timeout: 20)

    private init() {
        visibleKinds = QuickToggleKind.visible(from: UserDefaults.standard.stringArray(forKey: Self.visibleKey))
        nightShiftShortcut = StatusDefaults.string(Self.nightShiftKey) ?? Self.defaultNightShiftShortcut
        hidesDesktopIcons = StatusDefaults.bool(Self.desktopKey, default: false)
        favoriteAudioAddress = StatusDefaults.string(Self.airPodsKey)
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Our own overlay: safe to bring back after a relaunch.
        if hidesDesktopIcons { cover.show() }
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isDarkMode = LiveModeSystem.shared.isDarkMode() }
        }
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }

    func stop() {
        isStarted = false
        cover.hide()
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        themeObserver = nil
        powerObserver = nil
        connector = nil
    }

    /// Re-reads every state (the grid calls this when it appears).
    func refresh() {
        isDarkMode = LiveModeSystem.shared.isDarkMode()
        isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        refreshAudioDevices()
    }

    func setVisible(_ kinds: [QuickToggleKind]) {
        visibleKinds = kinds
        StatusDefaults.set(kinds.map(\.rawValue), Self.visibleKey)
    }

    func setVisible(_ kind: QuickToggleKind, _ visible: Bool) {
        var kinds = visibleKinds.filter { $0 != kind }
        if visible {
            let order = QuickToggleKind.defaultOrder
            kinds.append(kind)
            kinds.sort { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
        }
        setVisible(kinds)
    }

    // MARK: State

    /// On / off for the tile; nil for actions and unknown states.
    func isOn(_ kind: QuickToggleKind) -> Bool? {
        switch kind {
        case .keepAwake: KeepAwakeController.shared.isActive
        case .micMute: MicMuteController.shared.isMuted
        case .darkMode: isDarkMode
        case .desktopIcons: hidesDesktopIcons
        case .nightShift: nil
        case .airPods: favoriteDevice?.isConnected
        case .lowPower: isLowPowerMode
        case .screenSaver: nil
        }
    }

    /// Short status under a tile's title ("1h left", "Muted", "Not set up").
    func detail(_ kind: QuickToggleKind) -> String? {
        switch kind {
        case .keepAwake:
            guard let session = KeepAwakeController.shared.session else { return KeepAwakeDurations.short(KeepAwakeController.shared.defaultMinutes) }
            return session.until.map { StatusFormat.remaining(until: $0, now: Date()) } ?? "On"
        case .micMute:
            return MicMuteController.shared.canMute ? nil : "No control"
        case .airPods:
            return favoriteDevice.map { $0.isConnected ? "Connected" : "Connect" } ?? (PermissionCenter.shared.isGranted(.bluetooth) ? "None paired" : "Allow…")
        case .lowPower:
            return "Password"
        default:
            return nil
        }
    }

    var favoriteDevice: PairedAudioDevice? {
        audioDevices.first { $0.address == favoriteAudioAddress } ?? audioDevices.first { $0.isConnected } ?? audioDevices.first
    }

    // MARK: Actions

    func perform(_ kind: QuickToggleKind) {
        guard !busy.contains(kind) else { return }
        switch kind {
        case .keepAwake:
            KeepAwakeController.shared.toggle()
        case .micMute:
            MicMuteController.shared.toggle()
        case .darkMode:
            toggleDarkMode()
        case .desktopIcons:
            setHidesDesktopIcons(!hidesDesktopIcons)
        case .nightShift:
            runNightShift()
        case .airPods:
            toggleAirPods()
        case .lowPower:
            setLowPowerMode(!ProcessInfo.processInfo.isLowPowerModeEnabled)
        case .screenSaver:
            startScreenSaver()
        }
        objectWillChange.send()
    }

    func setHidesDesktopIcons(_ hide: Bool) {
        hidesDesktopIcons = hide
        StatusDefaults.set(hide, Self.desktopKey)
        if hide { cover.show() } else { cover.hide() }
        AppLog.log("Quick Toggles: desktop icons \(hide ? "hidden" : "shown")")
    }

    private func toggleDarkMode() {
        let target = !(LiveModeSystem.shared.isDarkMode() ?? false)
        busy.insert(.darkMode)
        Task { [weak self] in
            do {
                try await LiveModeSystem.shared.setDarkMode(target)
                self?.isDarkMode = target
            } catch {
                self?.show(.init(text: error.localizedDescription, action: .automationSettings))
            }
            self?.busy.remove(.darkMode)
            self?.isDarkMode = LiveModeSystem.shared.isDarkMode()
        }
    }

    private func runNightShift() {
        let name = nightShiftShortcut.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            show(.init(text: "Name the Night Shift shortcut in Settings first.", action: .openShortcuts))
            return
        }
        busy.insert(.nightShift)
        Task { [weak self, shortcuts] in
            do {
                _ = try await shortcuts.run(name)
                AppLog.log("Quick Toggles: ran “\(name)”")
            } catch {
                AppLog.log("Quick Toggles: Night Shift shortcut failed: \(error.localizedDescription)")
                self?.show(.init(text: "Add a shortcut named “\(name)” that runs Set Night Shift → Toggle.", action: .openShortcuts))
            }
            self?.busy.remove(.nightShift)
        }
    }

    private func startScreenSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { AppLog.log("Quick Toggles: screen saver failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Low Power Mode

    /// Runs pmset as root through macOS's administrator dialog (one
    /// password prompt per change). Call from a user action.
    func setLowPowerMode(_ on: Bool) {
        busy.insert(.lowPower)
        LowPowerModeSwitch.set(on) { [weak self] result in
            guard let self else { return }
            self.busy.remove(.lowPower)
            switch result {
            case .success:
                AppLog.log("Quick Toggles: Low Power Mode \(on ? "on" : "off")")
            case .failure(let error):
                if error != .cancelled {
                    self.show(.init(text: error.message, action: .batterySettings))
                }
            }
            self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    // MARK: AirPods

    func refreshAudioDevices() {
        guard PermissionCenter.shared.isGranted(.bluetooth) else {
            audioDevices = []
            return
        }
        audioDevices = BluetoothAudioConnector.pairedAudioDevices()
    }

    /// Asks for Bluetooth (the same prompt the AirPods battery uses) and
    /// never touches a headset. Already granted: just re-lists devices.
    func requestBluetoothAccess() {
        if PermissionCenter.shared.isGranted(.bluetooth) {
            refreshAudioDevices()
            return
        }
        if let power = PowerMonitor.current {
            power.requestBluetoothAccess()
        } else {
            Task { [weak self] in
                _ = await PermissionCenter.shared.request(.bluetooth, from: "Quick Toggles AirPods")
                self?.refreshAudioDevices()
            }
        }
    }

    private func toggleAirPods() {
        guard PermissionCenter.shared.isGranted(.bluetooth) else {
            requestBluetoothAccess()
            return
        }
        refreshAudioDevices()
        guard let device = favoriteDevice else {
            show(.init(text: "Pair your AirPods in Bluetooth settings first.", action: .bluetoothSettings))
            return
        }
        busy.insert(.airPods)
        let connector = BluetoothAudioConnector(address: device.address, name: device.name)
        self.connector = connector
        if device.isConnected {
            connector.disconnect()
            busy.remove(.airPods)
            refreshAudioDevices()
        } else {
            connector.connect { [weak self] ok in
                guard let self else { return }
                self.busy.remove(.airPods)
                self.connector = nil
                self.refreshAudioDevices()
                if !ok { self.show(.init(text: "\(device.name) didn't connect. Open the case near the Mac and retry.", action: nil)) }
            }
        }
    }

    // MARK: Messages

    func performMessageAction(_ action: QuickToggleMessage.Action) {
        let url: URL?
        switch action {
        case .openShortcuts:
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts")
        case .automationSettings:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        case .batterySettings:
            url = PowerMonitor.batterySettingsURL
        case .bluetoothSettings:
            url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")
        }
        if let url { NSWorkspace.shared.open(url) }
        message = nil
    }

    /// The message card's close button.
    func dismissMessage() {
        messageTask?.cancel()
        messageTask = nil
        message = nil
    }

    private func show(_ newMessage: QuickToggleMessage) {
        message = newMessage
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }
}

struct QuickToggleMessage: Equatable {
    enum Action: Equatable { case openShortcuts, automationSettings, batterySettings, bluetoothSettings }
    var text: String
    var action: Action?

    var actionTitle: String? {
        switch action {
        case .openShortcuts?: "Open Shortcuts"
        case .automationSettings?: "Automation Settings"
        case .batterySettings?: "Battery Settings"
        case .bluetoothSettings?: "Bluetooth Settings"
        case nil: nil
        }
    }
}

// MARK: - Low Power Mode

enum LowPowerModeSwitch {
    enum Failure: Error, Equatable {
        case cancelled
        case failed(String)

        var message: String {
            switch self {
            case .cancelled: "Cancelled."
            case .failed(let detail): "Couldn't change Low Power Mode (\(detail)). You can switch it in Battery settings."
            }
        }
    }

    /// `pmset -a lowpowermode 1|0` as root. The value is chosen from a Bool,
    /// and the script text is fixed: nothing is interpolated.
    static func set(_ on: Bool, completion: @escaping @MainActor @Sendable (Result<Void, Failure>) -> Void) {
        let source = [
            "on run argv",
            "do shell script \"/usr/bin/pmset -a lowpowermode \" & (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
            "end run",
        ]
        let value = on ? "1" : "0"
        let prompt = on ? "SparkV wants to turn on Low Power Mode." : "SparkV wants to turn off Low Power Mode."
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = source.flatMap { ["-e", $0] } + [value, prompt]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            let result: Result<Void, Failure>
            do {
                try process.run()
                let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    result = .success(())
                } else if err.contains("-128") {
                    result = .failure(.cancelled)
                } else {
                    result = .failure(.failed(err.split(whereSeparator: \.isNewline).first.map(String.init) ?? "status \(process.terminationStatus)"))
                }
            } catch {
                result = .failure(.failed(error.localizedDescription))
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }
}

// MARK: - AirPods

struct PairedAudioDevice: Identifiable, Equatable, Sendable {
    var name: String
    var address: String
    var isConnected: Bool
    var id: String { address }
}

/// Connects a paired Bluetooth headset without blocking (IOBluetooth's
/// asynchronous `openConnection(_:)`), then routes sound to it once it
/// shows up as a CoreAudio device.
@MainActor
final class BluetoothAudioConnector: NSObject {
    private let address: String
    private let name: String
    private var completion: (@MainActor (Bool) -> Void)?
    private var routeTask: Task<Void, Never>?

    init(address: String, name: String) {
        self.address = address
        self.name = name
    }

    static func pairedAudioDevices() -> [PairedAudioDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() ?? []).compactMap { $0 as? IOBluetoothDevice }
        return paired.filter(isAudio).map { device in
            PairedAudioDevice(
                name: device.name ?? device.nameOrAddress ?? "Headphones",
                address: BluetoothAudioDevice.normalize(address: device.addressString ?? ""),
                isConnected: device.isConnected()
            )
        }
        .sorted { $0.isConnected != $1.isConnected ? $0.isConnected : $0.name < $1.name }
    }

    private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        if Int(device.deviceClassMajor) == Int(kBluetoothDeviceClassMajorAudio) { return true }
        let lower = (device.name ?? "").lowercased()
        return ["airpods", "beats", "buds", "headphone", "headset"].contains { lower.contains($0) }
    }

    private var device: IOBluetoothDevice? {
        IOBluetoothDevice(addressString: address.replacingOccurrences(of: ":", with: "-"))
    }

    func connect(completion: @escaping @MainActor (Bool) -> Void) {
        guard let device else { completion(false); return }
        self.completion = completion
        AppLog.log("Quick Toggles: connecting \(name)")
        let status = device.openConnection(self)
        if status != kIOReturnSuccess {
            AppLog.log("Quick Toggles: \(name) connection failed to start (\(status))")
            finish(false)
        }
    }

    func disconnect() {
        guard let device else { return }
        AppLog.log("Quick Toggles: disconnecting \(name)")
        device.closeConnection()
    }

    /// IOBluetooth's callback for `openConnection(_:)`.
    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard status == kIOReturnSuccess else {
            AppLog.log("Quick Toggles: \(name) didn't connect (\(status))")
            finish(false)
            return
        }
        // The CoreAudio device appears a moment after the link.
        routeTask = Task { [weak self] in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(600))
                guard let self, !Task.isCancelled else { return }
                if BluetoothAudioRouting.makeDefaultOutput(named: self.name) {
                    AppLog.log("Quick Toggles: sound now plays on \(self.name)")
                    break
                }
            }
            self?.finish(true)
        }
    }

    private func finish(_ ok: Bool) {
        completion?(ok)
        completion = nil
    }
}

enum BluetoothAudioRouting {
    /// Makes the Bluetooth output device called `name` the default output.
    static func makeDefaultOutput(named name: String) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return false }
        for device in devices where transport(device) == kAudioDeviceTransportTypeBluetooth && hasOutput(device) {
            guard deviceName(device) == name else { continue }
            var target = device
            var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectSetPropertyData(system, &defaultAddress, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &target) == noErr
        }
        return false
    }

    private static func transport(_ device: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

// MARK: - Hide desktop icons

/// A borderless window per screen, one level above the desktop icons,
/// showing that screen's wallpaper scaled the way the desktop scales it.
/// It joins every Space, ignores the mouse, and follows screen changes,
/// Space switches and wallpaper changes. A dynamic or aerial wallpaper
/// shows its still picture.
@MainActor
final class DesktopIconsCover {
    /// What a screen's cover shows; a window is only rebuilt when this
    /// changes (a Space switch with the same wallpaper costs one compare).
    private struct Signature: Equatable {
        var frame: NSRect
        var url: URL?
        var options: String
    }

    private var windows: [CGDirectDisplayID: (window: NSWindow, signature: Signature)] = [:]
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// Decoded wallpapers by URL (a 6K HEIC is decoded once, not per Space
    /// switch); at most a few, dropped when the cover hides.
    private var images: [URL: NSImage] = [:]
    private(set) var isShown = false

    func show() {
        guard !isShown else { return }
        isShown = true
        update()
        let workspace = NSWorkspace.shared.notificationCenter
        let updateSoon: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in self?.update() }
        }
        observers.append((NotificationCenter.default, NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: updateSoon)))
        // Wallpapers can differ per Space: compare, rebuild only what changed.
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: updateSoon)))
        // Posted by System Settings when the wallpaper changes.
        let distributed = DistributedNotificationCenter.default()
        observers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.desktop"), object: nil, queue: .main, using: updateSoon)))
    }

    func hide() {
        isShown = false
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
        windows.values.forEach { $0.window.orderOut(nil) }
        windows.removeAll()
        images.removeAll()
    }

    private func update() {
        guard isShown else { return }
        var seen: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            seen.insert(display)
            let url = NSWorkspace.shared.desktopImageURL(for: screen)
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let signature = Signature(frame: screen.frame, url: url,
                                      options: options.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: ","))
            if let existing = windows[display] {
                guard existing.signature != signature else { continue }
                // Same window, new contents: no teardown.
                existing.window.backgroundColor = Self.fillColor(for: screen)
                existing.window.contentView = wallpaperView(for: screen, url: url, options: options)
                existing.window.setFrame(screen.frame, display: true)
                windows[display] = (existing.window, signature)
            } else {
                let window = Self.makeWindow(for: screen)
                window.contentView = wallpaperView(for: screen, url: url, options: options)
                window.orderFront(nil)
                windows[display] = (window, signature)
            }
        }
        for (display, entry) in windows where !seen.contains(display) {
            entry.window.orderOut(nil)
            windows[display] = nil
        }
    }

    /// A non-activating panel just above the desktop icons. It takes the
    /// clicks on the desktop, so hidden icons can't be selected, dragged
    /// or trashed by accident (clicking it doesn't activate SparkV).
    private static func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = false
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = fillColor(for: screen)
        window.setFrame(screen.frame, display: false)
        return window
    }

    private func image(at url: URL) -> NSImage? {
        if let cached = images[url] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        if images.count >= 4 { images.removeAll() }
        images[url] = image
        return image
    }

    private static func fillColor(for screen: NSScreen) -> NSColor {
        (NSWorkspace.shared.desktopImageOptions(for: screen)?[.fillColor] as? NSColor) ?? .black
    }

    private func wallpaperView(for screen: NSScreen, url: URL?, options: [NSWorkspace.DesktopImageOptionKey: Any]) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        guard let url, let image = image(at: url) else { return view }
        let scaling: DesktopCoverGeometry.Scaling
        let raw = (options[.imageScaling] as? NSNumber)?.uintValue ?? NSImageScaling.scaleProportionallyUpOrDown.rawValue
        let clips = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        switch NSImageScaling(rawValue: raw) {
        case .scaleAxesIndependently?: scaling = .stretch
        case .scaleNone?: scaling = .center
        default: scaling = clips ? .fill : .fit
        }
        let rect = DesktopCoverGeometry.imageRect(image: image.size, screen: screen.frame.size, scaling: scaling)
        let imageView = NSImageView(frame: rect)
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        view.addSubview(imageView)
        return view
    }
}
