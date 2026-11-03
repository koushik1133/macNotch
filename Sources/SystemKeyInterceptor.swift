import AppKit
import ApplicationServices
import Combine
import CoreAudio

/// Replaces macOS's own volume and brightness pop-up with SparkV's HUD.
///
/// An active event tap (needs Accessibility) catches the brightness and
/// volume keys before the system does, swallows them, and applies the change
/// itself: CoreAudio for the default output device, DisplayServices for the
/// display the key is for. The HUD's change listeners then draw SparkV's HUD.
///
/// Keys pass through untouched whenever SparkV can't (or shouldn't) apply
/// them, so nothing ever stops working:
/// - an output with no volume control (HDMI, AirPlay);
/// - a brightness key for a monitor SparkV can't set (DDC monitors: there's
///   no public API, BetterDisplay / Lunar / MonitorControl or macOS handle it);
/// - a brightness key for an external display while one of those tools runs
///   (and the user lets it handle those, the default);
/// - Option held alone (opens Sound / Displays settings), and the keyboard
///   backlight keys, which SparkV never touches;
/// - a key whose display has its HUD style set to Off, so macOS's pop-up
///   still gives feedback there.
@MainActor
final class SystemKeyInterceptor {
    /// Called after a key was handled, so the HUD can show the level even when
    /// it didn't change (already at 0 % or 100 %).
    var onHandled: ((Int) -> Void)?
    /// Called after a brightness key was applied to `display`.
    var onHandledBrightness: ((CGDirectDisplayID) -> Void)?
    /// Whether SparkV draws a HUD for this key: the brightness key's display,
    /// or nil for volume. False (style Off there): the key goes to macOS.
    var showsFeedback: (CGDirectDisplayID?) -> Bool = { _ in true }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Follows Accessibility through PermissionCenter (no polling).
    private var trustWatch: AnyCancellable?
    private let brightness = HUDDisplayBrightness.shared
    private let displays = HUDDisplayDirectory.shared
    private let displayApps = HUDDisplayAppWatcher.shared
    private let settings = HUDPlusSettings.shared
    /// Last brightness route, to log only when it changes.
    private var lastRoute: HUDBrightnessRoute?

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
              let step = Self.step(for: key.keyCode, flags: allFlags, divisions: settings.stepDivisions)
        else { return false }

        switch key.keyCode {
        case SystemKeyEvent.mute:
            guard showsFeedback(nil) else { return false }
            // Without a mute control macOS knows best (it may hide the key).
            guard let device = HUDVolumeControl.defaultOutput(), HUDVolumeControl.hasMute(device) else { return false }
            if key.isKeyDown, !key.isRepeat {
                HUDVolumeControl.setMuted(device, !HUDVolumeControl.isMuted(device))
                onHandled?(key.keyCode)
            }
            return true
        case SystemKeyEvent.soundUp, SystemKeyEvent.soundDown:
            guard showsFeedback(nil) else { return false }
            guard let device = HUDVolumeControl.defaultOutput(), HUDVolumeControl.canSetVolume(device) else { return false }
            if key.isKeyDown {
                let current = HUDVolumeControl.volume(device) ?? 0
                HUDVolumeControl.setVolume(device, Self.stepped(current, step: step, up: key.keyCode == SystemKeyEvent.soundUp))
                // Either volume key unmutes, like macOS.
                if HUDVolumeControl.isMuted(device) { HUDVolumeControl.setMuted(device, false) }
                onHandled?(key.keyCode)
            }
            return true
        case SystemKeyEvent.brightnessUp, SystemKeyEvent.brightnessDown:
            guard case .apply(let display) = brightnessRoute(), showsFeedback(display),
                  let current = brightness.read(display) else { return false }
            if key.isKeyDown {
                brightness.write(Self.stepped(current, step: step, up: key.keyCode == SystemKeyEvent.brightnessUp), to: display)
                onHandledBrightness?(display)
                onHandled?(key.keyCode)
            }
            return true
        default:
            return false
        }
    }

    /// Which display a brightness key is for and whether SparkV applies it.
    /// Uses cached display facts: cheap enough for every key repeat.
    func brightnessRoute() -> HUDBrightnessRoute {
        let route = HUDBrightnessRouter.route(
            pointer: displays.screenUnderPointer()?.facts,
            builtIn: displays.builtIn()?.facts,
            followsPointer: settings.brightnessFollowsPointer,
            displayAppRunning: displayApps.isRunning,
            stepAside: settings.stepAsideForDisplayApps,
            appsHandleBuiltIn: settings.displayAppsHandleBuiltIn
        )
        if route != lastRoute {
            lastRoute = route
            switch route {
            case .apply(let display):
                AppLog.log("HUD: brightness keys drive display \(display)")
            case .passThrough(let reason):
                AppLog.log("HUD: brightness keys pass through (\(reason)\(displayApps.runningName.map { ", \($0) running" } ?? ""))")
            }
        }
        return route
    }

    // MARK: - Pure key math

    /// The step a handled key moves by, or nil to leave the key to macOS:
    /// a key SparkV doesn't drive (keyboard backlight, media keys), or Option
    /// alone (opens Sound / Displays settings). `divisions` steps span 0...100 %
    /// (16 like macOS); Option+Shift gives quarter steps (1/64 by default).
    nonisolated static func step(for keyCode: Int, flags allFlags: NSEvent.ModifierFlags, divisions: Int = HUDStepMath.defaultDivisions) -> Float? {
        let handled = [SystemKeyEvent.soundUp, SystemKeyEvent.soundDown, SystemKeyEvent.mute,
                       SystemKeyEvent.brightnessUp, SystemKeyEvent.brightnessDown]
        guard handled.contains(keyCode) else { return nil }
        let flags = allFlags.intersection(.deviceIndependentFlagsMask)
        return HUDStepMath.keyStep(option: flags.contains(.option), shift: flags.contains(.shift), divisions: divisions)
    }

    /// Next level one step up or down, snapped to the step grid: 0.53 goes
    /// to 0.5625 or 0.5, never skipping a notch. Clamped to 0...1.
    nonisolated static func stepped(_ current: Float, step: Float, up: Bool) -> Float {
        HUDStepMath.stepped(current, step: step, up: up)
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
