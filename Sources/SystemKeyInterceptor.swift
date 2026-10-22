import AppKit
import ApplicationServices
import Combine
import CoreAudio

/// Replaces macOS's own volume and brightness pop-up with SparkV's band.
///
/// An active event tap (needs Accessibility) catches the brightness and
/// volume keys before the system does, swallows them, and applies the change
/// itself: CoreAudio for the default output device, DisplayServices for the
/// built-in display. The HUD's existing change listeners then draw SparkV's
/// band. Keys pass through untouched whenever SparkV can't apply them (an
/// output with no volume control, an external display, Option held to open
/// System Settings), so nothing ever stops working.
@MainActor
final class SystemKeyInterceptor {
    /// Called after a key was handled, so the HUD can show the level even when
    /// it didn't change (already at 0 % or 100 %).
    var onHandled: ((Int) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Follows Accessibility through PermissionCenter (no polling).
    private var trustWatch: AnyCancellable?
    private let brightness = BrightnessControl()

    var isActive: Bool { tap != nil }

    func start() {
        watchTrust()
        guard tap == nil else { return }
        // No Accessibility yet: the system pop-up stays until it's granted,
        // then trustWatch installs the tap. Never prompts.
        _ = installTap()
    }

    func stop() {
        trustWatch = nil
        removeTap()
    }

    /// A tap made before Accessibility was (re-)granted never sees keys, and
    /// one left behind after the user switched it off is dead: rebuild.
    private func watchTrust() {
        guard trustWatch == nil else { return }
        trustWatch = PermissionCenter.shared.onChange(of: .accessibility) { [weak self] status in
            guard let self else { return }
            self.removeTap()
            if status.isGranted { _ = self.installTap() }
        }
    }

    private func removeTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        runLoopSource = nil
        tap = nil
    }

    // MARK: - Tap

    private func installTap() -> Bool {
        guard PermissionCenter.shared.isGranted(.accessibility) else { return false }
        let mask = CGEventMask(1) << CGEventMask(NSEvent.EventType.systemDefined.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: systemKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        AppLog.log("HUD: replacing the system volume/brightness pop-up")
        return true
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    /// Returns true when the event was handled and must be swallowed.
    fileprivate func handle(subtype: Int16, data1 data: Int, flags allFlags: NSEvent.ModifierFlags) -> Bool {
        guard let key = SystemKeyEvent(subtype: subtype, data1: data),
              let step = Self.step(for: key.keyCode, flags: allFlags)
        else { return false }

        switch key.keyCode {
        case SystemKeyEvent.mute:
            // Without a mute control macOS knows best (it may hide the key).
            guard let device = VolumeControl.defaultOutput(), VolumeControl.hasMute(device) else { return false }
            if key.isKeyDown, !key.isRepeat {
                VolumeControl.setMuted(device, !VolumeControl.isMuted(device))
                onHandled?(key.keyCode)
            }
            return true
        case SystemKeyEvent.soundUp, SystemKeyEvent.soundDown:
            guard let device = VolumeControl.defaultOutput(), VolumeControl.canSetVolume(device) else { return false }
            if key.isKeyDown {
                let current = VolumeControl.volume(device) ?? 0
                VolumeControl.setVolume(device, Self.stepped(current, step: step, up: key.keyCode == SystemKeyEvent.soundUp))
                // Either volume key unmutes, like macOS.
                if VolumeControl.isMuted(device) { VolumeControl.setMuted(device, false) }
                onHandled?(key.keyCode)
            }
            return true
        case SystemKeyEvent.brightnessUp, SystemKeyEvent.brightnessDown:
            guard brightness.isAvailable, let current = brightness.read() else { return false }
            if key.isKeyDown {
                brightness.write(Self.stepped(current, step: step, up: key.keyCode == SystemKeyEvent.brightnessUp))
                onHandled?(key.keyCode)
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Pure key math

    /// The step a handled key moves by, or nil to leave the key to macOS:
    /// a key SparkV doesn't drive, or Option alone (opens Sound / Displays
    /// settings). Option+Shift gives quarter steps (1/64), like macOS.
    nonisolated static func step(for keyCode: Int, flags allFlags: NSEvent.ModifierFlags) -> Float? {
        let handled = [SystemKeyEvent.soundUp, SystemKeyEvent.soundDown, SystemKeyEvent.mute,
                       SystemKeyEvent.brightnessUp, SystemKeyEvent.brightnessDown]
        guard handled.contains(keyCode) else { return nil }
        let flags = allFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.option), !flags.contains(.shift) { return nil }
        return flags.contains(.option) && flags.contains(.shift) ? 1 / 64 : 1 / 16
    }

    /// Next level one step up or down, snapped to the step grid: 0.53 goes
    /// to 0.5625 or 0.5, never skipping a notch. Clamped to 0...1.
    nonisolated static func stepped(_ current: Float, step: Float, up: Bool) -> Float {
        guard step > 0, current.isFinite else { return up ? step : 0 }
        let position = min(1, max(0, current)) / step
        let nearest = position.rounded()
        // Float noise (0.4999 for 0.5) counts as being on the grid.
        let base = abs(position - nearest) < 0.02 ? nearest : position
        let index = up ? base.rounded(.down) + 1 : base.rounded(.up) - 1
        return min(1, max(0, index * step))
    }
}

/// C callback for the event tap; runs on the main run loop.
private func systemKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<SystemKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { interceptor.reenable() }
        return Unmanaged.passUnretained(event)
    }
    // Only a Bool crosses into the main actor; the event stays here.
    let data1 = NSEvent(cgEvent: event).map { ($0.subtype.rawValue, $0.data1, $0.modifierFlags.rawValue) }
    let swallow = MainActor.assumeIsolated {
        guard let data1 else { return false }
        return interceptor.handle(subtype: data1.0, data1: data1.1, flags: NSEvent.ModifierFlags(rawValue: data1.2))
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

// MARK: - Volume

private enum VolumeControl {
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
        for element in elements(device) {
            var address = outputAddress(kAudioDevicePropertyVolumeScalar, element)
            var v = value
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

// MARK: - Brightness

/// Built-in display brightness through the private DisplayServices framework.
private final class BrightnessControl {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getFn: Get?
    private let setFn: Set?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        let handle = dlopen(path, RTLD_LAZY)
        getFn = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
        setFn = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }
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
