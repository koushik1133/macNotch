import AppKit
import CoreAudio
import SwiftUI

// MARK: - Audio backend

/// Output volume access, so tests can swap CoreAudio for a fake.
@MainActor
protocol WidgetVolumeBackend: AnyObject {
    /// Current default output: volume 0...1 (nil if it has no software volume) and mute.
    func read() -> (volume: Float?, muted: Bool, canMute: Bool)
    func setVolume(_ value: Float)
    func setMuted(_ muted: Bool)
    /// Starts calling `onChange` when the device, its volume or mute changes.
    func startObserving(_ onChange: @escaping @MainActor () -> Void)
    func stopObserving()
}

/// Default output device through CoreAudio: `kAudioDevicePropertyVolumeScalar`
/// on the main element, or channels 1 and 2 (the same approach as
/// SystemKeyInterceptor's VolumeControl), plus property listeners while visible.
@MainActor
final class CoreAudioVolumeBackend: WidgetVolumeBackend {
    private var observedDevice: AudioObjectID = 0
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var valueListener: AudioObjectPropertyListenerBlock?
    private var onChange: (@MainActor () -> Void)?

    func read() -> (volume: Float?, muted: Bool, canMute: Bool) {
        guard let device = Self.defaultOutput() else { return (nil, false, false) }
        return (Self.volume(device), Self.isMuted(device), Self.hasMute(device))
    }

    func setVolume(_ value: Float) {
        guard let device = Self.defaultOutput() else { return }
        let clamped = min(1, max(0, value))
        for element in Self.elements(device) {
            var address = Self.address(kAudioDevicePropertyVolumeScalar, element)
            var v = Float32(clamped)
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
        // Turning the knob up unmutes, like the volume keys.
        if clamped > 0, Self.isMuted(device) { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard let device = Self.defaultOutput(), Self.hasMute(device) else { return }
        var address = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func startObserving(_ onChange: @escaping @MainActor () -> Void) {
        stopObserving()
        self.onChange = onChange
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.attachValueListeners()
                self?.onChange?()
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceBlock) == noErr {
            deviceListener = deviceBlock
        }
        attachValueListeners()
    }

    func stopObserving() {
        detachValueListeners()
        if let deviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
        }
        deviceListener = nil
        onChange = nil
    }

    private func attachValueListeners() {
        detachValueListeners()
        guard let device = Self.defaultOutput() else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        for var address in Self.observedAddresses(device) {
            AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        }
        observedDevice = device
        valueListener = block
    }

    private func detachValueListeners() {
        if let valueListener, observedDevice != 0 {
            for var address in Self.observedAddresses(observedDevice) {
                AudioObjectRemovePropertyListenerBlock(observedDevice, &address, .main, valueListener)
            }
        }
        valueListener = nil
        observedDevice = 0
    }

    private static func observedAddresses(_ device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        var list = elements(device).map { address(kAudioDevicePropertyVolumeScalar, $0) }
        if hasMute(device) { list.append(address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)) }
        return list
    }

    // MARK: CoreAudio helpers

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

    static func volume(_ device: AudioObjectID) -> Float? {
        let values = elements(device).compactMap { element -> Float? in
            var address = address(kAudioDevicePropertyVolumeScalar, element)
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? Float(value) : nil
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    static func hasMute(_ device: AudioObjectID) -> Bool {
        isSettable(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr && muted != 0
    }

    private static func isSettable(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var address = address(selector, element)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
}

// MARK: - Knob math (pure)

enum VolumeKnobMath {
    /// The knob turns through 270°, from -135° (7:30) to +135° (4:30), 0° up.
    static let sweep: Double = 270
    static let startAngle: Double = -135
    /// Detents (and tick marks) every 1/16, like the volume keys.
    static let detents = 16

    /// Indicator angle for a level, 0° pointing up, clockwise positive.
    static func angle(for value: Double) -> Double {
        startAngle + sweep * min(1, max(0, value))
    }

    /// Angle in degrees of `point` around `center`, 0° up, clockwise positive
    /// (SwiftUI's y axis points down).
    static func pointerAngle(_ point: CGPoint, center: CGPoint) -> Double {
        atan2(Double(point.x - center.x), Double(center.y - point.y)) * 180 / .pi
    }

    /// Shortest signed difference b - a in degrees, in -180...180, so a drag
    /// across the bottom gap or the ±180° seam never jumps.
    static func angleDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// New level after the pointer turned by `degrees`.
    static func value(_ value: Double, turnedBy degrees: Double) -> Double {
        min(1, max(0, value + degrees / sweep))
    }

    /// Index of the detent at or below a level; crossing one fires a haptic.
    static func detent(for value: Double) -> Int {
        Int((min(1, max(0, value)) * Double(detents) + 0.0001).rounded(.down))
    }

    /// Volume change for one scroll event. Precise (trackpad) deltas are
    /// points; wheel deltas are lines. Fingers up / wheel away = louder.
    static func scrollDelta(deltaY: Double, precise: Bool, inverted: Bool) -> Double {
        let physical = inverted ? -deltaY : deltaY
        return physical * (precise ? 0.0035 : 1.0 / Double(detents))
    }
}

// MARK: - Model

@MainActor
final class VolumeKnobModel: ObservableObject {
    static let shared = VolumeKnobModel(backend: CoreAudioVolumeBackend())

    @Published private(set) var volume: Double = 0
    @Published private(set) var isMuted = false
    @Published private(set) var isAvailable = false
    @Published private(set) var canMute = false

    private let backend: WidgetVolumeBackend
    private var viewers = 0
    /// Last level written, so a listener echo of our own write doesn't fight the drag.
    private var pendingWrite: Double?
    private var pendingWriteAt = Date.distantPast
    var haptics: (_ strong: Bool) -> Void = { strong in
        NSHapticFeedbackManager.defaultPerformer.perform(strong ? .levelChange : .alignment, performanceTime: .now)
    }

    init(backend: WidgetVolumeBackend) {
        self.backend = backend
    }

    func appear() {
        viewers += 1
        refresh()
        guard viewers == 1 else { return }
        backend.startObserving { [weak self] in self?.refresh() }
    }

    func disappear() {
        viewers = max(0, viewers - 1)
        if viewers == 0 { backend.stopObserving() }
    }

    var isObserving: Bool { viewers > 0 }

    func refresh() {
        let state = backend.read()
        isAvailable = state.volume != nil
        canMute = state.canMute
        isMuted = state.muted
        if let v = state.volume {
            // Some devices quantize the level, so a pending write also expires.
            if pendingWrite != nil, Date().timeIntervalSince(pendingWriteAt) > 0.6 { pendingWrite = nil }
            if let pending = pendingWrite, abs(pending - Double(v)) < 0.02 {
                pendingWrite = nil
            } else if pendingWrite == nil {
                volume = Double(v)
            }
        }
    }

    /// Sets the level, firing a haptic detent for every 1/16 crossed (a
    /// stronger one at 0% and 100%).
    func set(_ newValue: Double) {
        let clamped = min(1, max(0, newValue))
        guard isAvailable, abs(clamped - volume) > 0.0001 else { return }
        let before = VolumeKnobMath.detent(for: volume)
        let after = VolumeKnobMath.detent(for: clamped)
        volume = clamped
        pendingWrite = clamped
        pendingWriteAt = Date()
        backend.setVolume(Float(clamped))
        if clamped > 0, isMuted { isMuted = false }
        if before != after { haptics(clamped <= 0 || clamped >= 1) }
    }

    func turn(by degrees: Double) {
        set(VolumeKnobMath.value(volume, turnedBy: degrees))
    }

    func toggleMute() {
        guard canMute else { return }
        backend.setMuted(!isMuted)
        isMuted.toggle()
        haptics(true)
    }

    /// Drag-end bookkeeping: the device is the truth again.
    func endInteraction() {
        pendingWrite = nil
        refresh()
    }

    var percentText: String {
        isAvailable ? "\(Int((volume * 100).rounded()))%" : "--"
    }

    var speakerSymbol: String {
        if isMuted || volume <= 0.001 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

// MARK: - Drag state

@MainActor
final class KnobDragState: ObservableObject {
    var lastAngle: Double?
    var travelled: CGFloat = 0
    var turned: Double = 0
    @Published var isDragging = false
    @Published var isHovering = false
    var scrollMonitor: Any?
}

// MARK: - Views

/// Rotary volume knob: drag around it or scroll over it to change the
/// default output volume, click to mute.
struct VolumeKnobWidget: View {
    @ObservedObject var model: VolumeKnobModel = .shared
    var size: WidgetSize = .small
    /// Knob only (56 pt), no card or label: for beside the media in Home.
    var compact = false

    var body: some View {
        Group {
            if compact {
                VolumeKnob(model: model)
                    .frame(width: 56, height: 56)
            } else {
                WidgetCard(padding: 6) {
                    HStack(spacing: 6) {
                        VolumeKnob(model: model)
                            .aspectRatio(1, contentMode: .fit)
                        VStack(alignment: .leading, spacing: 2) {
                            Image(systemName: model.speakerSymbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(model.isMuted ? SparkVTheme.destructive : SparkVTheme.textSecondary)
                                .frame(height: 12)
                            Text(model.isMuted ? "Muted" : model.percentText)
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .tracking(-0.2)
                                .foregroundStyle(SparkVTheme.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text("VOLUME")
                                .font(WidgetStyle.label(7))
                                .tracking(WidgetStyle.labelTracking)
                                .foregroundStyle(WidgetStyle.tertiaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .whileVisible(start: { model.appear() }, stop: { model.disappear() })
    }
}

struct VolumeKnob: View {
    @ObservedObject var model: VolumeKnobModel
    @StateObject private var drag = KnobDragState()

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ticks(side: side)
                // Level arc.
                arc(to: 1).stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: side * 0.06, lineCap: .round))
                arc(to: model.isAvailable ? model.volume : 0)
                    .stroke(levelGradient, style: StrokeStyle(lineWidth: side * 0.06, lineCap: .round))
                    .opacity(model.isMuted ? 0.3 : 1)
                // Knob body.
                Circle()
                    .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .padding(side * 0.2)
                // Indicator.
                Capsule()
                    .fill(model.isMuted ? SparkVTheme.destructive : SparkVTheme.text)
                    .frame(width: max(2, side * 0.05), height: side * 0.15)
                    .offset(y: -side * 0.2)
                    .rotationEffect(.degrees(VolumeKnobMath.angle(for: model.volume)))
                if model.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: side * 0.16, weight: .bold))
                        .foregroundStyle(SparkVTheme.destructive)
                }
            }
            .frame(width: side, height: side)
            .position(center)
            // Grabbed: the knob lifts slightly (a picked-up dial, not a press).
            .scaleEffect(drag.isDragging && !SparkVMotion.reduceMotion ? 1.04 : 1)
            .animation(SparkVMotion.snappy, value: drag.isDragging)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        drag.isDragging = true
                        drag.travelled = max(drag.travelled, hypot(value.translation.width, value.translation.height))
                        // Too close to the center the angle is noise.
                        let radius = hypot(value.location.x - center.x, value.location.y - center.y)
                        guard radius > side * 0.12 else { drag.lastAngle = nil; return }
                        let angle = VolumeKnobMath.pointerAngle(value.location, center: center)
                        if let last = drag.lastAngle {
                            let delta = VolumeKnobMath.angleDelta(from: last, to: angle)
                            drag.turned += abs(delta)
                            model.turn(by: delta)
                        }
                        drag.lastAngle = angle
                    }
                    .onEnded { _ in
                        if drag.travelled < 3, drag.turned < 2 { model.toggleMute() }
                        drag.lastAngle = nil
                        drag.travelled = 0
                        drag.turned = 0
                        drag.isDragging = false
                        model.endInteraction()
                    }
            )
            .onHover { hovering in
                drag.isHovering = hovering
                hovering ? installScrollMonitor() : removeScrollMonitor()
            }
            .onDisappear { removeScrollMonitor() }
        }
        .help(model.isAvailable
              ? "Volume \(model.percentText)\(model.isMuted ? " (muted)" : ""). Drag around or scroll to change; click to \(model.isMuted ? "unmute" : "mute")."
              : "This output device has no volume control")
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue(model.isMuted ? "Muted" : model.percentText)
        .accessibilityAdjustableAction { direction in
            let step = 1.0 / Double(VolumeKnobMath.detents)
            model.set(model.volume + (direction == .increment ? step : -step))
        }
    }

    private var levelGradient: AngularGradient {
        // Apple: a white level, like the system volume HUD. SparkV Red: ember to red.
        AngularGradient(colors: SparkVTheme.isApple
                            ? [Color.white.opacity(0.75), Color.white, Color.white]
                            : [SparkVTheme.redDeep, SparkVTheme.red, Color(red: 1, green: 0.36, blue: 0.34)],
                        center: .center, startAngle: .degrees(135), endAngle: .degrees(405))
    }

    /// Arc from the start angle covering `fraction` of the sweep. Circle trim
    /// starts at 3 o'clock going clockwise; the start (-135° from up) is 135° there.
    private func arc(to fraction: Double) -> some Shape {
        Circle()
            .trim(from: 0, to: max(0.0001, 0.75 * min(1, max(0, fraction))))
            .rotation(.degrees(135))
            .scale(0.80)
    }

    private func ticks(side: CGFloat) -> some View {
        ZStack {
            ForEach(0...VolumeKnobMath.detents, id: \.self) { index in
                let value = Double(index) / Double(VolumeKnobMath.detents)
                let major = index % 4 == 0
                Capsule()
                    .fill(Color.white.opacity(value <= model.volume + 0.0001 && model.isAvailable && !model.isMuted ? 0.75 : 0.22))
                    .frame(width: major ? 1.6 : 1, height: major ? side * 0.075 : side * 0.05)
                    .offset(y: -side * 0.475)
                    .rotationEffect(.degrees(VolumeKnobMath.angle(for: value)))
            }
        }
    }

    private func installScrollMonitor() {
        guard drag.scrollMonitor == nil else { return }
        let model = model
        drag.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let consumed: Bool = MainActor.assumeIsolated {
                let delta = VolumeKnobMath.scrollDelta(deltaY: Double(event.scrollingDeltaY),
                                                       precise: event.hasPreciseScrollingDeltas,
                                                       inverted: event.isDirectionInvertedFromDevice)
                guard delta != 0 else { return true }
                model.set(model.volume + delta)
                if event.phase == .ended || event.momentumPhase == .ended { model.endInteraction() }
                return true
            }
            return consumed ? nil : event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = drag.scrollMonitor { NSEvent.removeMonitor(monitor) }
        drag.scrollMonitor = nil
    }
}
