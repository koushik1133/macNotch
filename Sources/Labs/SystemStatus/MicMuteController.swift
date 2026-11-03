import AppKit
import Carbon.HIToolbox
import Combine
import CoreAudio
import SwiftUI

/// A global microphone mute: the default input device's own mute
/// (`kAudioDevicePropertyMute`, input scope) or, on devices without one,
/// its input volume at zero. ⌃⌥M toggles it from anywhere (Carbon hotkey,
/// no permission); a red "Muted" stays beside the notch while it is on,
/// also over full-screen apps.
///
/// - Follows the default input: when AirPods take over, the old device is
///   put back and the new one muted.
/// - Follows outside changes: unmuting in Audio MIDI Setup or another app
///   clears the badge.
/// - Never leaves the mic silently dead: what SparkV changed is saved
///   (`micMute.record`) and put back when SparkV quits, and at the next
///   launch after a crash.
/// - Changing HAL properties needs no Microphone permission. Zoom and Teams
///   may say "your mic is muted by the system" and keep their own button
///   unmuted.
@MainActor
final class MicMuteController: ObservableObject {
    static let shared = MicMuteController()

    /// Who asked for the mute. Activities' Calls drive this same controller
    /// through `setMuted(_:)` and decide themselves whether a call's mute
    /// is lifted when the call ends (`mutedBySparkV` tells them).
    enum Origin: String, Sendable { case user, call }

    static let hotkeyKey = "micMute.hotkeyEnabled"
    static let showsKey = "micMute.showsActivity"
    static let activityID = "micMute"
    static let feedbackID = "micMute.feedback"
    /// ⌃⌥M. ⌃⌥J/R/S/T/C/F, ⌃⌥⇧R and ⌃⌥1-5 belong to other features.
    static let shortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(controlKey | optionKey))

    /// The default input is muted right now (by SparkV or anything else).
    @Published private(set) var isMuted = false
    /// SparkV muted it (and will put it back).
    @Published private(set) var mutedBySparkV = false
    @Published private(set) var deviceName: String?
    /// The default input has a mute or an input volume SparkV can set.
    @Published private(set) var canMute = false
    /// RegisterEventHotKey refused ⌃⌥M. (Carbon only refuses a duplicate
    /// inside SparkV, so another app using the same keys is not detected.)
    @Published private(set) var hotkeyFailed = false
    /// Where the current SparkV mute came from (nil when SparkV holds none).
    @Published private(set) var origin: Origin?

    @Published var hotkeyEnabled: Bool {
        didSet {
            guard hotkeyEnabled != oldValue else { return }
            StatusDefaults.set(hotkeyEnabled, Self.hotkeyKey)
            updateHotkey()
        }
    }

    @Published var showsInNotch: Bool {
        didSet {
            StatusDefaults.set(showsInNotch, Self.showsKey)
            postState(feedback: false)
        }
    }

    private var isStarted = false
    private var device = AudioObjectID(kAudioObjectUnknown)
    /// The current device's mute / volume elements, read once per attach
    /// (so a listener callback costs one or two property reads).
    private var controls = MicMuteHAL.Controls.none
    private var record: MicMuteRecord?
    /// A record whose device went away before it could be put back: kept
    /// (and persisted) until that UID shows up again.
    private var pending: MicMuteRecord?
    private var systemListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?
    private var deviceListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private let hotkey = ScreenRegionHotkey()

    private init() {
        hotkeyEnabled = StatusDefaults.bool(Self.hotkeyKey, default: false)
        showsInNotch = StatusDefaults.bool(Self.showsKey, default: true)
    }

    // MARK: Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        recoverFromEarlierRun()
        installSystemListener()
        attach(to: MicMuteHAL.defaultInputDevice(), carryMute: false)
        updateHotkey()
    }

    /// Puts back anything SparkV muted, then removes listeners and the hotkey.
    func stop() {
        guard isStarted else { return }
        if mutedBySparkV { restore() }
        isStarted = false
        hotkey.unregister()
        removeDeviceListeners()
        if let systemListener {
            var address = MicMuteHAL.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, systemListener)
        }
        systemListener = nil
        removeDevicesListener()
        SystemStatusCenter.shared.dismiss(id: Self.activityID)
    }

    // MARK: Actions

    func toggle() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        _ = apply(muted, origin: .user, feedback: true)
    }

    @discardableResult
    private func apply(_ muted: Bool, origin newOrigin: Origin, feedback: Bool) -> Bool {
        guard isStarted else { return false }
        if device == AudioObjectID(kAudioObjectUnknown) { attach(to: MicMuteHAL.defaultInputDevice(), carryMute: false) }
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            AppLog.log("Mic Mute: no input device")
            if feedback { flash(text: "No microphone", muted: false) }
            return false
        }
        var ok = true
        if muted {
            if mutedBySparkV, isMuted {
                // Already ours: a user mute outranks a call's.
                if newOrigin == .user { origin = .user }
            } else if let newRecord = MicMuteHAL.mute(device, controls: controls) {
                record = newRecord
                origin = newOrigin
                persist()
                mutedBySparkV = true
                AppLog.log("Mic Mute: muted \(deviceName ?? "input") (\(newRecord.method.rawValue), \(newOrigin.rawValue))")
            } else {
                ok = false
                AppLog.log("Mic Mute: \(deviceName ?? "input") has no mute or input volume")
                if feedback { flash(text: "Can't mute \(deviceName ?? "this mic")", muted: false) }
            }
        } else if mutedBySparkV {
            restore()
        } else if isMuted {
            // Muted elsewhere: lift the device's own mute (a volume-only
            // device has nothing saved, so it gets a usable level).
            ok = MicMuteHAL.unmute(device, controls: controls, record: nil)
            AppLog.log("Mic Mute: unmuted \(deviceName ?? "input")\(ok ? "" : " (failed)")")
        }
        readState()
        postState(feedback: feedback && ok)
        return ok
    }

    /// For dictation, Clicky and meeting notes: a short band when the mic
    /// is muted, so the user knows why nothing is heard. True when muted.
    @discardableResult
    func warnIfMuted(feature: String) -> Bool {
        guard isStarted, isMuted else { return false }
        AppLog.log("Mic Mute: \(feature) started while the mic is muted")
        SystemStatusCenter.shared.post(LiveActivity(id: "micMute.warning", kind: .meeting, priority: 80, duration: 3) {
            StatusBand(symbol: "mic.slash.fill", tint: SparkVTheme.recording, title: "Mic muted",
                       detail: "\(feature) can't hear you", trailing: Self.shortcut.displayString)
        }
        .titled("Microphone Muted")
        .accessibility("Microphone muted. \(feature) can't hear you. Press \(Self.shortcut.displayString) to unmute."))
        return true
    }

    // MARK: Device tracking

    private func installSystemListener() {
        guard systemListener == nil else { return }
        var address = MicMuteHAL.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                self.attach(to: MicMuteHAL.defaultInputDevice(), carryMute: true)
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            systemListener = block
        }
    }

    /// Switches to `newDevice`. With `carryMute`, a SparkV mute moves along:
    /// the old device is put back and the new one muted.
    private func attach(to newDevice: AudioObjectID?, carryMute: Bool) {
        let target = newDevice ?? AudioObjectID(kAudioObjectUnknown)
        guard target != device || deviceListeners.isEmpty else { return }
        let wasMutedBySparkV = mutedBySparkV
        let carriedOrigin = origin
        if carryMute, wasMutedBySparkV { restore() }
        removeDeviceListeners()
        device = target
        let known = target != AudioObjectID(kAudioObjectUnknown)
        deviceName = known ? MicMuteHAL.name(target) : nil
        controls = known ? MicMuteHAL.controls(target) : .none
        canMute = !controls.isEmpty
        // Listen to exactly the controls in use: the mute elements, or the
        // volume elements only on devices without a mute (so an app's
        // auto-gain moving the volume of a mutable mic costs nothing).
        for element in controls.mute { addDeviceListener(target, kAudioDevicePropertyMute, element) }
        if controls.mute.isEmpty {
            for element in controls.volume { addDeviceListener(target, kAudioDevicePropertyVolumeScalar, element) }
        }
        if carryMute, wasMutedBySparkV, known, let newRecord = MicMuteHAL.mute(target, controls: controls) {
            record = newRecord
            origin = carriedOrigin ?? .user
            persist()
            mutedBySparkV = true
            AppLog.log("Mic Mute: input switched to \(deviceName ?? "?"); muted it too")
        }
        readState()
        postState(feedback: false)
    }

    private func addDeviceListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.externalChange() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr {
            deviceListeners.append((object, address, block))
        }
    }

    private func removeDeviceListeners() {
        for listener in deviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, DispatchQueue.main, listener.block)
        }
        deviceListeners.removeAll()
    }

    /// The mute or volume changed: maybe by us, maybe by someone else.
    private func externalChange() {
        guard isStarted else { return }
        let wasMuted = isMuted
        readState()
        if mutedBySparkV, !isMuted {
            // Unmuted elsewhere: nothing left for SparkV to put back.
            mutedBySparkV = false
            origin = nil
            record = nil
            persist()
            AppLog.log("Mic Mute: unmuted outside SparkV")
        }
        if wasMuted != isMuted { postState(feedback: false) }
    }

    private func readState() {
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            if isMuted { isMuted = false }
            return
        }
        let muted = MicMuteHAL.isMuted(device, controls: controls)
        if isMuted != muted { isMuted = muted }
    }

    /// Puts back what SparkV changed. When the device is gone (AirPods put
    /// away), the record is kept, keyed by its UID, and applied when that
    /// device comes back, so a volume mute never strands it at zero.
    private func restore() {
        defer {
            mutedBySparkV = false
            origin = nil
        }
        guard let record else { return }
        self.record = nil
        if let target = MicMuteHAL.device(uid: record.deviceUID),
           MicMuteHAL.unmute(target, controls: target == device ? controls : MicMuteHAL.controls(target), record: record) {
            AppLog.log("Mic Mute: put back \(MicMuteHAL.name(target) ?? record.deviceUID)")
        } else {
            AppLog.log("Mic Mute: \(record.deviceUID) is gone; will put it back when it returns")
            pending = record
            watchForPendingDevice()
        }
        persist()
    }

    /// A mute an earlier SparkV left behind (crash, force quit) is undone,
    /// now or when its device returns.
    private func recoverFromEarlierRun() {
        guard let saved = MicMuteRecord.decode(UserDefaults.standard.data(forKey: MicMuteRecord.defaultsKey)) else { return }
        if let target = MicMuteHAL.device(uid: saved.deviceUID),
           MicMuteHAL.unmute(target, controls: MicMuteHAL.controls(target), record: saved) {
            AppLog.log("Mic Mute: unmuted \(MicMuteHAL.name(target) ?? saved.deviceUID), left muted by an earlier run")
            UserDefaults.standard.removeObject(forKey: MicMuteRecord.defaultsKey)
        } else {
            pending = saved
            watchForPendingDevice()
        }
    }

    /// Listens to the device list only while a restore is pending.
    private func watchForPendingDevice() {
        guard pending != nil, devicesListener == nil else { return }
        var address = MicMuteHAL.address(kAudioHardwarePropertyDevices)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.retryPending() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            devicesListener = block
        }
    }

    private func retryPending() {
        guard let saved = pending, let target = MicMuteHAL.device(uid: saved.deviceUID) else { return }
        guard MicMuteHAL.unmute(target, controls: MicMuteHAL.controls(target), record: saved) else { return }
        AppLog.log("Mic Mute: \(MicMuteHAL.name(target) ?? saved.deviceUID) is back; put its input back")
        pending = nil
        persist()
        removeDevicesListener()
        if target == device { readState(); postState(feedback: false) }
    }

    private func removeDevicesListener() {
        guard let devicesListener else { return }
        var address = MicMuteHAL.address(kAudioHardwarePropertyDevices)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, devicesListener)
        self.devicesListener = nil
    }

    /// The live record, else one still waiting for its device.
    private func persist() {
        StatusDefaults.set((record ?? pending)?.encoded(), MicMuteRecord.defaultsKey)
    }

    // MARK: Hotkey

    private func updateHotkey() {
        guard isStarted, hotkeyEnabled else {
            hotkey.unregister()
            hotkeyFailed = false
            return
        }
        guard !hotkey.isRegistered else { return }
        hotkey.onPress = { [weak self] in self?.toggle() }
        hotkeyFailed = !hotkey.register(Self.shortcut)
        if hotkeyFailed { AppLog.log("Mic Mute: couldn't register \(Self.shortcut.displayString)") }
    }

    // MARK: Island

    /// The persistent "Muted" badge, plus (from a key press or tap) an
    /// instant feedback band that only fades.
    private func postState(feedback: Bool) {
        if feedback { flash(text: nil, muted: isMuted) }
        guard isMuted, showsInNotch, isStarted else {
            SystemStatusCenter.shared.dismiss(id: Self.activityID)
            return
        }
        let red = SparkVTheme.recording
        let name = deviceName
        SystemStatusCenter.shared.post(LiveActivity(
            id: Self.activityID,
            kind: .meeting,
            priority: 58,
            duration: nil,
            opensTab: SystemStatusCenter.shared.statusTab,
            symbol: "mic.slash.fill",
            tint: red,
            compactText: "Muted"
        ) {
            MicMuteBand(isMuted: true, deviceName: name, message: nil)
        }
        .titled("Microphone Muted")
        .accessibility("Microphone muted\(name.map { ", \($0)" } ?? "")")
        .compact {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(red)
                .accessibilityLabel("Microphone muted")
        } trailing: {
            Text("Muted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(red)
                .fixedSize()
        }
        .minimal {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(red))
                .accessibilityLabel("Microphone muted")
        })
    }

    private func flash(text: String?, muted: Bool) {
        let name = deviceName
        // Volume/brightness-style feedback: replaces itself, never queued.
        SystemStatusCenter.shared.post(LiveActivity(id: Self.feedbackID, kind: .volume, priority: 90, duration: 1.4) {
            MicMuteBand(isMuted: muted, deviceName: name, message: text)
        }
        .titled("Microphone"))
    }
}

// MARK: - CoreAudio

/// Input mute and volume on one device. Main element first, then channels
/// 1...8 for devices that only expose per-channel controls.
enum MicMuteHAL {
    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultInputDevice() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    static func name(_ device: AudioObjectID) -> String? {
        string(device, kAudioObjectPropertyName)
    }

    static func uid(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func device(uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { self.uid($0) == uid }
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func settable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, element: UInt32) -> Bool {
        var address = address(selector, scope: kAudioDevicePropertyScopeInput, element: element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    /// Elements (0 = main) that carry `selector` and can be set.
    private static func elements(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [UInt32] {
        if settable(device, selector, element: kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...8).map(UInt32.init).filter { settable(device, selector, element: $0) }
    }

    /// The mute and input-volume elements a device exposes (settable).
    struct Controls: Equatable, Sendable {
        var mute: [UInt32]
        var volume: [UInt32]
        static let none = Controls(mute: [], volume: [])
        var isEmpty: Bool { mute.isEmpty && volume.isEmpty }
    }

    static func controls(_ device: AudioObjectID) -> Controls {
        Controls(mute: elements(device, kAudioDevicePropertyMute), volume: elements(device, kAudioDevicePropertyVolumeScalar))
    }

    static func canMute(_ device: AudioObjectID) -> Bool {
        !controls(device).isEmpty
    }

    private static func getUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, element: UInt32) -> UInt32? {
        var address = address(selector, scope: kAudioDevicePropertyScopeInput, element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func getFloat(_ device: AudioObjectID, element: UInt32) -> Float? {
        var address = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private static func setUInt32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, element: UInt32, _ value: UInt32) -> Bool {
        var address = address(selector, scope: kAudioDevicePropertyScopeInput, element: element)
        var data = value
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &data) == noErr
    }

    @discardableResult
    private static func setFloat(_ device: AudioObjectID, element: UInt32, _ value: Float) -> Bool {
        var address = address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeInput, element: element)
        var data = Float32(value)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &data) == noErr
    }

    /// Muted: the mute control is on, or (devices without one) every input
    /// volume is at zero.
    static func isMuted(_ device: AudioObjectID, controls: Controls) -> Bool {
        MicMutePolicy.isMuted(mute: controls.mute.map { getUInt32(device, kAudioDevicePropertyMute, element: $0) },
                              volume: controls.volume.map { getFloat(device, element: $0) })
    }

    /// Mutes `device`; returns what to undo, or nil when it can't be muted.
    static func mute(_ device: AudioObjectID, controls: Controls) -> MicMuteRecord? {
        let uid = uid(device) ?? "\(device)"
        if !controls.mute.isEmpty {
            let ok = controls.mute.map { setUInt32(device, kAudioDevicePropertyMute, element: $0, 1) }.contains(true)
            if ok { return MicMuteRecord(deviceUID: uid, method: .mute, savedVolumes: [:], at: Date()) }
        }
        guard !controls.volume.isEmpty else { return nil }
        var saved: [Int: Float] = [:]
        for element in controls.volume {
            if let value = getFloat(device, element: element) { saved[Int(element)] = value }
        }
        let ok = controls.volume.map { setFloat(device, element: $0, 0) }.contains(true)
        return ok ? MicMuteRecord(deviceUID: uid, method: .volume, savedVolumes: saved, at: Date()) : nil
    }

    /// Undoes `record` (or just clears the mute without one). True when
    /// every write landed.
    @discardableResult
    static func unmute(_ device: AudioObjectID, controls: Controls, record: MicMuteRecord?) -> Bool {
        switch record?.method {
        case .volume?:
            let saved = record?.savedVolumes ?? [:]
            guard !saved.isEmpty else { return true }
            return saved.map { element, value in
                setFloat(device, element: UInt32(element), MicMutePolicy.restoredVolume(saved: value))
            }.allSatisfy { $0 }
        case .mute?, nil:
            var ok = controls.mute.map { setUInt32(device, kAudioDevicePropertyMute, element: $0, 0) }.allSatisfy { $0 }
            if record == nil, controls.mute.isEmpty {
                for element in controls.volume where (getFloat(device, element: element) ?? 1) <= 0.001 {
                    ok = setFloat(device, element: element, MicMutePolicy.restoredVolume(saved: nil)) && ok
                }
            }
            if record?.method == .mute, controls.mute.isEmpty { return false }
            return ok
        }
    }
}
