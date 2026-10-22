import AppKit
import Combine
import CoreAudio
import CoreGraphics
import SwiftUI

/// Volume and brightness HUD. Shows our own band under the notch whenever the
/// output volume, mute state, output device or built-in display brightness
/// changes. With `replacesSystemHUD` (and Accessibility), SystemKeyInterceptor
/// swallows the keys so macOS's own pop-up doesn't show as well.
///
/// - Volume: CoreAudio property listeners on the default output device
///   (volume scalar on the main element, or channels 1/2, plus mute), run on a
///   private queue because the first HAL call can take 100+ ms.
/// - Brightness: DisplayServices (private, loaded with dlopen) for the level
///   and its change notifications, plus the brightness keys seen through an
///   NSEvent monitor, after which the level is polled for a second.
@MainActor
final class HUDController: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            guard isStarted else { return }
            if isEnabled { startMonitoring() } else { stopMonitoring() }
        }
    }

    /// Swallow the brightness/volume keys and apply them ourselves so only
    /// SparkV's band shows, not macOS's pop-up as well.
    @Published var replacesSystemHUD: Bool {
        didSet {
            guard replacesSystemHUD != oldValue else { return }
            UserDefaults.standard.set(replacesSystemHUD, forKey: Self.replaceKey)
            guard isMonitoring else { return }
            if replacesSystemHUD { interceptor.start() } else { interceptor.stop() }
        }
    }

    static let volumeActivityID = "volume"
    static let brightnessActivityID = "brightness"
    private static let enabledKey = "HUDEnabled"
    private static let replaceKey = "HUDReplacesSystem"
    private static let hudDuration: TimeInterval = 1.6
    private static let deviceDuration: TimeInterval = 2

    private let activities: ActivityCenter
    private var isStarted = false
    private var isMonitoring = false

    // Volume
    private var audio: AudioOutputMonitor?
    private var lastAudio: AudioOutputMonitor.State?
    private var deviceCaptionUntil = Date.distantPast
    private var lastVolumePost = Date.distantPast
    private var volumeKeyTask: Task<Void, Never>?

    // Brightness
    private let brightness = BuiltInBrightness()
    private var lastBrightness: Float?
    private var brightnessKeyUntil = Date.distantPast
    private var brightnessSamples: [(time: Date, value: Float)] = []
    private var pollTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    // Keys
    private let interceptor = SystemKeyInterceptor()
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    /// Re-installs the global key monitor after an Accessibility grant.
    private var trustWatch: AnyCancellable?

    /// The controller DisplayServices' C callback forwards to.
    fileprivate static weak var brightnessTarget: HUDController?

    init(activities: ActivityCenter) {
        self.activities = activities
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        replacesSystemHUD = UserDefaults.standard.object(forKey: Self.replaceKey) as? Bool ?? true
        interceptor.onHandled = { [weak self] key in
            guard let self, self.isMonitoring else { return }
            switch key {
            case SystemKeyEvent.brightnessUp, SystemKeyEvent.brightnessDown:
                self.brightnessKeyPressed()
            default:
                self.volumeKeyPressed()
            }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        if isEnabled { startMonitoring() }
    }

    func stop() {
        stopMonitoring()
        isStarted = false
    }

    // MARK: - Lifecycle

    private func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let monitor = AudioOutputMonitor { [weak self] change in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleAudio(change) }
            }
        }
        audio = monitor
        monitor.start()

        Self.brightnessTarget = self
        lastBrightness = brightness.read()
        brightness.registerForChanges()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { HUDController.brightnessTarget?.screensChanged() }
        }

        startKeyMonitors()
        trustWatch = PermissionCenter.shared.whenGranted(.accessibility) { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.startKeyMonitors()
        }
        if replacesSystemHUD { interceptor.start() }
        AppLog.log("HUD: monitoring started (brightness \(brightness.isAvailable ? "available" : "unavailable"), change notifications \(brightness.isRegistered ? "on" : "off"))")
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        audio?.stop()
        audio = nil
        lastAudio = nil
        volumeKeyTask?.cancel()
        volumeKeyTask = nil

        brightness.unregister()
        if Self.brightnessTarget === self { Self.brightnessTarget = nil }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        pollTask?.cancel()
        pollTask = nil
        lastBrightness = nil
        brightnessSamples = []

        interceptor.stop()
        trustWatch = nil
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil

        activities.dismiss(id: Self.volumeActivityID)
        activities.dismiss(id: Self.brightnessActivityID)
        AppLog.log("HUD: monitoring stopped")
    }

    // MARK: - Volume

    private func handleAudio(_ change: AudioOutputMonitor.Change) {
        guard isMonitoring else { return }
        switch change {
        case .initial(let state):
            // Startup read: remember, never show.
            lastAudio = state
        case .deviceChanged(let state):
            let previous = lastAudio
            lastAudio = state
            guard previous != nil, previous?.deviceID != state.deviceID else { return }
            deviceCaptionUntil = Date().addingTimeInterval(Self.deviceDuration)
            postDevice(state)
        case .volumeChanged(let state, let forced):
            let previous = lastAudio
            lastAudio = state
            guard previous != nil else { return }
            if !forced, previous?.volume == state.volume, previous?.isMuted == state.isMuted { return }
            postVolume(state)
        }
    }

    private func postVolume(_ state: AudioOutputMonitor.State) {
        lastVolumePost = Date()
        let caption = Date() < deviceCaptionUntil ? state.name : nil
        let content = HUDContent(
            style: .volume(muted: state.isMuted, deviceName: caption),
            level: state.volume.map(Double.init)
        )
        activities.post(LiveActivity(
            id: Self.volumeActivityID,
            kind: .volume,
            priority: 90,
            duration: Self.hudDuration
        ) {
            HUDActivityView(content: content)
        }
        // Inline OSD beside the camera housing (boring.notch style): the
        // level never covers what is under the menu bar.
        .compact {
            Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        } trailing: {
            CompactLevelBar(level: state.isMuted ? 0 : Double(state.volume ?? 0))
        })
    }

    private func postDevice(_ state: AudioOutputMonitor.State) {
        lastVolumePost = Date()
        let content = HUDContent(
            style: .outputDevice(name: state.name, transport: state.transport, muted: state.isMuted),
            level: state.volume.map(Double.init)
        )
        activities.post(LiveActivity(
            id: Self.volumeActivityID,
            kind: .volume,
            priority: 90,
            duration: Self.deviceDuration
        ) {
            HUDActivityView(content: content)
        })
    }

    /// A volume key was pressed. Normally CoreAudio reports the new level
    /// right away; at 0 % or 100 % nothing changes, so show the level anyway.
    private func volumeKeyPressed() {
        let pressedAt = Date()
        volumeKeyTask?.cancel()
        volumeKeyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.isMonitoring else { return }
            if self.lastVolumePost < pressedAt { self.audio?.refresh(forced: true) }
        }
    }

    // MARK: - Brightness

    /// DisplayServices change notification (user, keys, Control Center or
    /// auto-brightness).
    fileprivate func brightnessNotified() {
        guard isMonitoring else { return }
        sampleBrightness(forced: false)
    }

    private func screensChanged() {
        guard isMonitoring else { return }
        brightness.registerForChanges()
        lastBrightness = brightness.read()
        brightnessSamples = []
    }

    private func brightnessKeyPressed() {
        guard brightness.isAvailable else { return }
        brightnessKeyUntil = Date().addingTimeInterval(1.2)
        // Show the current level right away (it may already be at a limit),
        // then follow the system's smooth ramp for a second.
        sampleBrightness(forced: true)
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.isMonitoring else { return }
                self.sampleBrightness(forced: false)
            }
        }
    }

    private func sampleBrightness(forced: Bool) {
        guard let value = brightness.read() else { return }
        let now = Date()
        let previous = lastBrightness
        lastBrightness = value

        brightnessSamples.append((now, value))
        brightnessSamples.removeAll { now.timeIntervalSince($0.time) > 1 }

        // First read after launch is never shown.
        guard let previous else { return }
        let changed = abs(value - previous) > 0.001
        guard forced || changed else { return }

        if !forced, now >= brightnessKeyUntil {
            // No brightness key just now: show it only for a quick, deliberate
            // change (Control Center slider), not auto-brightness drifting.
            guard Self.isDeliberateChange(samples: brightnessSamples, now: now) else { return }
        }
        postBrightness(value)
    }

    /// True when the level moved by at least 4 % within the last half second.
    /// Auto-brightness ramps far slower than that.
    static func isDeliberateChange(samples: [(time: Date, value: Float)], now: Date) -> Bool {
        guard let current = samples.last?.value else { return false }
        return samples.contains { now.timeIntervalSince($0.time) <= 0.5 && abs($0.value - current) >= 0.04 }
    }

    private func postBrightness(_ value: Float) {
        let content = HUDContent(style: .brightness, level: Double(value))
        activities.post(LiveActivity(
            id: Self.brightnessActivityID,
            kind: .brightness,
            priority: 90,
            duration: Self.hudDuration
        ) {
            HUDActivityView(content: content)
        }
        .compact {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        } trailing: {
            CompactLevelBar(level: Double(value))
        })
    }

    // MARK: - Keys

    /// Listens (never swallows) for the media keys: brightness up/down and
    /// volume up/down/mute. The system OSD still appears as usual.
    /// Re-callable: replaces existing monitors (a global monitor added before
    /// an Accessibility grant may stay deaf).
    private func startKeyMonitors() {
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        let mask: NSEvent.EventTypeMask = [.systemDefined]
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let key = SystemKeyEvent(event) else { return }
            MainActor.assumeIsolated { self?.handleKey(key) }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if let key = SystemKeyEvent(event) {
                MainActor.assumeIsolated { self?.handleKey(key) }
            }
            return event
        }
    }

    private func handleKey(_ key: SystemKeyEvent) {
        guard isMonitoring, key.isKeyDown else { return }
        switch key.keyCode {
        case SystemKeyEvent.brightnessUp, SystemKeyEvent.brightnessDown:
            brightnessKeyPressed()
        case SystemKeyEvent.soundUp, SystemKeyEvent.soundDown, SystemKeyEvent.mute:
            volumeKeyPressed()
        default:
            break
        }
    }
}

// MARK: - Media key decoding

/// An NX_SUBTYPE_AUX_CONTROL_BUTTONS system-defined event (media keys).
struct SystemKeyEvent: Equatable, Sendable {
    static let soundUp = 0       // NX_KEYTYPE_SOUND_UP
    static let soundDown = 1     // NX_KEYTYPE_SOUND_DOWN
    static let brightnessUp = 2  // NX_KEYTYPE_BRIGHTNESS_UP
    static let brightnessDown = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
    static let mute = 7          // NX_KEYTYPE_MUTE

    let keyCode: Int
    let isKeyDown: Bool
    let isRepeat: Bool

    /// Decodes `data1`: key code in the high 16 bits, state (0xA down,
    /// 0xB up) in bits 8–15, repeat flag in bit 0.
    init?(subtype: Int16, data1: Int) {
        guard subtype == 8 else { return nil }
        keyCode = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        isKeyDown = state == 0xA
        isRepeat = flags & 0x1 != 0
    }

    init?(_ event: NSEvent) {
        guard event.type == .systemDefined else { return nil }
        self.init(subtype: event.subtype.rawValue, data1: event.data1)
    }
}

// MARK: - Brightness (DisplayServices)

/// The built-in display's brightness through the private DisplayServices
/// framework, loaded at runtime so a missing symbol just disables the HUD.
@MainActor
private final class BuiltInBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias Unregister = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    private let getBrightness: GetBrightness?
    private let register: Register?
    private let unregisterFn: Unregister?
    private var registeredDisplay: CGDirectDisplayID?

    var isAvailable: Bool { getBrightness != nil && Self.builtInDisplay() != nil }
    var isRegistered: Bool { registeredDisplay != nil }

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            AppLog.log("HUD: DisplayServices unavailable")
            getBrightness = nil
            register = nil
            unregisterFn = nil
            return
        }
        getBrightness = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
        register = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications").map { unsafeBitCast($0, to: Register.self) }
        unregisterFn = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications").map { unsafeBitCast($0, to: Unregister.self) }
    }

    /// 0...1, or nil when there's no active built-in display (lid closed).
    func read() -> Float? {
        guard let getBrightness, let display = Self.builtInDisplay() else { return nil }
        var value: Float = 0
        guard getBrightness(display, &value) == 0, value.isFinite else { return nil }
        return min(1, max(0, value))
    }

    /// (Re)subscribes to change notifications for the current built-in display.
    func registerForChanges() {
        let display = Self.builtInDisplay()
        guard display != registeredDisplay else { return }
        unregister()
        guard let register, let display else { return }
        // The observer only identifies the subscription; DisplayServices
        // treats it as an opaque 32-bit value, so use the display ID.
        if register(display, Self.observer(for: display), brightnessChangeCallback) == 0 {
            registeredDisplay = display
        } else {
            AppLog.log("HUD: brightness change notifications unavailable")
        }
    }

    func unregister() {
        guard let display = registeredDisplay else { return }
        registeredDisplay = nil
        _ = unregisterFn?(display, Self.observer(for: display))
    }

    private static func observer(for display: CGDirectDisplayID) -> UnsafeRawPointer? {
        UnsafeRawPointer(bitPattern: UInt(display))
    }

    static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }
    }
}

/// C callback for DisplayServices; the thread it runs on isn't documented, so
/// hop to the main queue and re-read the level there.
private let brightnessChangeCallback: CFNotificationCallback = { _, _, _, _, _ in
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HUDController.brightnessTarget?.brightnessNotified() }
    }
}

// MARK: - Volume (CoreAudio)

/// Watches the default output device's volume, mute and identity. All
/// CoreAudio work happens on a private serial queue.
final class AudioOutputMonitor: @unchecked Sendable {
    struct State: Equatable, Sendable {
        var deviceID: AudioObjectID
        var name: String
        var transport: HUDOutputTransport
        /// 0...1; nil when the device has no volume control.
        var volume: Float?
        var isMuted: Bool
    }

    enum Change: Sendable {
        case initial(State)
        case deviceChanged(State)
        case volumeChanged(State, forced: Bool)
    }

    private let queue = DispatchQueue(label: "SparkV.HUD.audio", qos: .userInitiated)
    private let onChange: @Sendable (Change) -> Void

    // Queue-confined.
    private var running = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceAddresses: [AudioObjectPropertyAddress] = []
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var deviceBlock: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    init(onChange: @escaping @Sendable (Change) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.defaultDeviceChanged()
            }
            defaultDeviceBlock = block
            var address = Self.defaultOutputAddress
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            if status != noErr { AppLog.log("HUD: default output listener failed (\(status))") }
            attach(to: Self.defaultOutputDevice())
            if let state = readState() { onChange(.initial(state)) }
        }
    }

    /// Synchronous so listeners are gone before the app quits.
    func stop() {
        queue.sync { [self] in
            guard running else { return }
            running = false
            detach()
            if let block = defaultDeviceBlock {
                var address = Self.defaultOutputAddress
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            }
            defaultDeviceBlock = nil
        }
    }

    /// Re-reads the level and reports it even if nothing changed.
    func refresh(forced: Bool) {
        queue.async { [self] in
            guard running, let state = readState() else { return }
            onChange(.volumeChanged(state, forced: forced))
        }
    }

    // MARK: Queue-confined

    private func defaultDeviceChanged() {
        guard running else { return }
        let newDevice = Self.defaultOutputDevice()
        guard newDevice != device else { return }
        attach(to: newDevice)
        if let state = readState() { onChange(.deviceChanged(state)) }
    }

    private func deviceChanged() {
        guard running, let state = readState() else { return }
        onChange(.volumeChanged(state, forced: false))
    }

    private func attach(to newDevice: AudioObjectID) {
        detach()
        device = newDevice
        guard newDevice != kAudioObjectUnknown else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceChanged()
        }
        deviceBlock = block
        let candidates: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] = [
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, 1),
            (kAudioDevicePropertyVolumeScalar, 2),
            (kAudioDevicePropertyMute, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyMute, 1),
            (kAudioDevicePropertyMute, 2),
        ]
        for (selector, element) in candidates {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(newDevice, &address) else { continue }
            if AudioObjectAddPropertyListenerBlock(newDevice, &address, queue, block) == noErr {
                deviceAddresses.append(address)
            }
        }
    }

    private func detach() {
        if let block = deviceBlock, device != kAudioObjectUnknown {
            for var address in deviceAddresses {
                AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
            }
        }
        deviceAddresses = []
        deviceBlock = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    private func readState() -> State? {
        guard device != kAudioObjectUnknown else { return nil }
        return State(
            deviceID: device,
            name: Self.name(of: device) ?? "Output",
            transport: Self.transport(of: device),
            volume: Self.volume(of: device),
            isMuted: Self.isMuted(device)
        )
    }

    // MARK: Property reads

    private static func defaultOutputDevice() -> AudioObjectID {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    private static func volume(of device: AudioObjectID) -> Float? {
        if let main = scalar(device, kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain) {
            return min(1, max(0, main))
        }
        let channels = [1, 2].compactMap { scalar(device, kAudioDevicePropertyVolumeScalar, AudioObjectPropertyElement($0)) }
        guard !channels.isEmpty else { return nil }
        return min(1, max(0, channels.reduce(0, +) / Float(channels.count)))
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value != 0 }
        }
        return false
    }

    private static func scalar(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Float? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value.isFinite else { return nil }
        return value
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let name else { return nil }
        let string = name.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }

    private static func transport(of device: AudioObjectID) -> HUDOutputTransport {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return .other }
        switch value {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        default: return .other
        }
    }
}
