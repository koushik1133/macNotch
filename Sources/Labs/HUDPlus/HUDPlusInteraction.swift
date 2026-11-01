import AppKit
import Combine
import SwiftUI

/// Where on the closed island the HUD is drawn.
enum HUDPlacement: Equatable, Sendable {
    /// Beside the camera housing (inline and ring styles).
    case wings
    /// In the band under the notch.
    case band
}

/// What the pointer is doing to the HUD, for the views' hover feedback.
@MainActor
final class HUDPointerState: ObservableObject {
    static let shared = HUDPointerState()

    @Published private(set) var part: HUDHitPart = .none
    @Published private(set) var placement: HUDPlacement?
    @Published private(set) var isDragging = false
    /// The level under the pointer while a drag sets it. The views draw this
    /// instead of the posted level, so the bar tracks the pointer 1:1 while
    /// the island itself is re-posted at most ten times a second.
    @Published private(set) var liveLevel: Double?
    /// The drag is on the brightness HUD (else the volume HUD).
    private(set) var liveIsBrightness = false

    func isHovering(_ part: HUDHitPart, in placement: HUDPlacement) -> Bool {
        self.part == part && self.placement == placement
    }

    func update(part: HUDHitPart, placement: HUDPlacement?) {
        if self.part != part { self.part = part }
        if self.placement != placement { self.placement = placement }
    }

    func setDragging(_ dragging: Bool) {
        if isDragging != dragging { isDragging = dragging }
        if !dragging, liveLevel != nil { liveLevel = nil }
    }

    func setLiveLevel(_ level: Double?, brightness: Bool) {
        liveIsBrightness = brightness
        if liveLevel != level { liveLevel = level }
    }

    func reset() {
        update(part: .none, placement: nil)
        setDragging(false)
    }
}

/// The parts of a mouse or scroll event the HUD reads: plain values, so the
/// event itself never crosses into the main actor (and tests can make them).
struct HUDPointerInput: Sendable {
    enum Kind: Sendable { case down, dragged, up, scroll, other }

    var kind: Kind
    /// Screen coordinates (y up), like `NSEvent.mouseLocation`.
    var location: CGPoint
    /// The event's window number; 0 when it has none.
    var windowNumber: Int = 0
    var isMomentum = false
    var deltaX: Double = 0
    var deltaY: Double = 0
    var precise = false
    var inverted = false

    init(kind: Kind, location: CGPoint, windowNumber: Int = 0, isMomentum: Bool = false,
         deltaX: Double = 0, deltaY: Double = 0, precise: Bool = false, inverted: Bool = false) {
        self.kind = kind
        self.location = location
        self.windowNumber = windowNumber
        self.isMomentum = isMomentum
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.precise = precise
        self.inverted = inverted
    }

    /// Reads only NSEvent's own (nonisolated) properties.
    init(_ event: NSEvent, location: CGPoint) {
        switch event.type {
        case .leftMouseDown: kind = .down
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .up
        case .scrollWheel: kind = .scroll
        default: kind = .other
        }
        self.location = location
        windowNumber = event.windowNumber
        let scroll = kind == .scroll
        isMomentum = scroll && !event.momentumPhase.isEmpty
        deltaX = scroll ? Double(event.scrollingDeltaX) : 0
        deltaY = scroll ? Double(event.scrollingDeltaY) : 0
        precise = scroll && event.hasPreciseScrollingDeltas
        inverted = scroll && event.isDirectionInvertedFromDevice
    }
}

/// Makes the HUD on the closed island take the pointer: click the icon to
/// mute, click or drag the level to set it, scroll over it to nudge it.
///
/// The island panel ignores the mouse while closed, so the menu bar under
/// the transparent parts keeps working. `NotchWindowController.handlePointer`
/// asks this controller first: while the pointer is on the HUD's icon or
/// level (or its band) the panel takes mouse events and the drawer does not
/// open from hover; as soon as the pointer leaves, the HUD goes away or the
/// drawer opens, the panel is click-through again. Mouse and scroll events
/// are read with a local monitor that exists only during that time, and
/// `onActiveChange` lets `HUDController` keep the HUD up while the pointer
/// rests on it. Hovering the camera housing still opens the drawer.
@MainActor
final class HUDInteractionController {
    /// What the HUD on screen controls.
    enum Target: Equatable {
        case volume(level: Double, muted: Bool)
        case brightness(display: CGDirectDisplayID, level: Double)

        var level: Double {
            switch self {
            case .volume(let level, _), .brightness(_, let level): level
            }
        }

        var isBrightness: Bool {
            if case .brightness = self { return true }
            return false
        }
    }

    /// Supplied by `HUDController`.
    var target: () -> Target? = { nil }
    var setLevel: (Double) -> Void = { _ in }
    /// The button went up after setting the level: write and post the last value.
    var commit: () -> Void = {}
    var toggleMute: () -> Void = {}
    /// Restarts the HUD's time on screen (re-posts what is showing).
    var hold: () -> Void = {}
    /// The pointer came onto the HUD (true) or the interaction ended (false).
    var onActiveChange: (Bool) -> Void = { _ in }
    /// Placement of the HUD on the island right now, or nil when it isn't there.
    var placement: () -> HUDPlacement? = { nil }
    /// Whether the user turned the interactive HUD on (tests pass their own).
    var isEnabled: () -> Bool = { HUDPlusSettings.shared.isInteractive }
    /// Key steps for a mouse wheel notch.
    var stepDivisions: () -> Int = { HUDPlusSettings.shared.stepDivisions }

    private weak var window: NSWindow?
    private var isDrawerOpen: () -> Bool = { true }
    let pointer: HUDPointerState

    private(set) var isActive = false
    private(set) var zones: HUDInteractionZones?
    private var monitors: [Any] = []
    private var drag: (startX: CGFloat, startLevel: Double, absolute: Bool)?
    /// Installs the local event monitor while active (tests turn it off and
    /// feed `handle(_:)` directly).
    var installsMonitor = true

    init(pointer: HUDPointerState? = nil) {
        self.pointer = pointer ?? .shared
    }

    /// Hands over the island panel. `isDrawerOpen` tells whether the drawer
    /// owns the panel's mouse handling.
    func attach(window: NSWindow, isDrawerOpen: @escaping () -> Bool) {
        self.window = window
        self.isDrawerOpen = isDrawerOpen
    }

    /// Called on every pointer move while the drawer is closed. Returns true
    /// while the pointer is on the HUD: the caller then skips its hover-open.
    func handlePointer(_ mouse: CGPoint, zones: HUDInteractionZones?) -> Bool {
        guard isEnabled(), window != nil, !isDrawerOpen(), let zones, let placement = placement(), target() != nil else {
            if drag == nil || isDrawerOpen() { end() }
            return drag != nil
        }
        // A drag keeps going wherever the pointer wanders until the button is up.
        if drag != nil {
            self.zones = zones
            return true
        }
        let part = zones.part(at: mouse)
        guard part != .none else {
            end()
            return false
        }
        self.zones = zones
        begin()
        pointer.update(part: part, placement: placement)
        return true
    }

    /// The HUD went away, the pointer left or the drawer opened: back to
    /// click-through.
    func end() {
        guard isActive else { return }
        isActive = false
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        let wasDragging = drag != nil
        drag = nil
        zones = nil
        pointer.reset()
        if wasDragging { commit() }
        if !isDrawerOpen(), window?.ignoresMouseEvents == false {
            window?.ignoresMouseEvents = true
        }
        onActiveChange(false)
    }

    /// Returns true to consume the event. Internal for the test harness.
    func handle(_ input: HUDPointerInput) -> Bool {
        guard isActive, let zones else { return false }
        // The drawer opened under the pointer (hotkey): its top row is no
        // longer the HUD's.
        guard !isDrawerOpen() else {
            end()
            return false
        }
        if input.windowNumber != 0, let number = window?.windowNumber, input.windowNumber != number { return false }
        let mouse = input.location
        switch input.kind {
        case .down:
            switch zones.part(at: mouse) {
            case .icon:
                if case .volume = target() { toggleMute() }
                hold()
                return true
            case .level:
                guard let current = target()?.level else { return false }
                pointer.setDragging(true)
                if let track = zones.track,
                   Double(mouse.x) >= track.lowerBound - Double(HUDInteractionZones.slop),
                   Double(mouse.x) <= track.upperBound + Double(HUDInteractionZones.slop) {
                    drag = (mouse.x, current, true)
                    setLevel(HUDStepMath.level(atX: Double(mouse.x), minX: track.lowerBound, maxX: track.upperBound))
                } else {
                    drag = (mouse.x, current, false)
                }
                return true
            case .none:
                return false
            }
        case .dragged:
            guard let drag else { return false }
            if drag.absolute, let track = zones.track {
                setLevel(HUDStepMath.level(atX: Double(mouse.x), minX: track.lowerBound, maxX: track.upperBound))
            } else {
                setLevel(HUDStepMath.level(startLevel: drag.startLevel, dragX: Double(mouse.x - drag.startX)))
            }
            return true
        case .up:
            guard drag != nil else { return false }
            drag = nil
            commit()
            pointer.setDragging(false)
            hold()
            if !zones.contains(mouse) { end() }
            return true
        case .scroll:
            guard zones.contains(mouse) else { return false }
            // Trackpad momentum would carry the level on after the fingers lift.
            if input.isMomentum { return true }
            let change = HUDStepMath.scrollChange(
                deltaX: input.deltaX,
                deltaY: input.deltaY,
                precise: input.precise,
                inverted: input.inverted,
                divisions: stepDivisions()
            )
            if change != 0, let current = target()?.level {
                setLevel(min(1, max(0, current + change)))
            }
            return true
        case .other:
            return false
        }
    }

    // MARK: - Private

    private func begin() {
        if window?.ignoresMouseEvents == true { window?.ignoresMouseEvents = false }
        guard !isActive else { return }
        isActive = true
        onActiveChange(true)
        // Coming onto the HUD restarts its time.
        hold()
        guard installsMonitor else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // Only plain values cross into the main actor; the event stays here.
            let input = HUDPointerInput(event, location: NSEvent.mouseLocation)
            let consume = MainActor.assumeIsolated { self?.handle(input) ?? false }
            return consume ? nil : event
        }) {
            monitors.append(monitor)
        }
    }
}

// MARK: - Zones from the island layout

extension HUDInteractionZones {
    /// The HUD's zones on the closed island, from the layout the island draws.
    ///
    /// - `notchRect`: the resting island in screen coordinates.
    /// - `layout`: `NotchActivityView.closedLayout(...)`.
    /// - `placement`: where the HUD is (wings or band).
    /// - `ring`: the ring style in the wings.
    /// - `showsPercent`: the percentage follows the bar or ring.
    /// - `hasCaption`: the band shows a device name before the bar.
    @MainActor
    static func island(notchRect: NSRect, layout: IslandClosedLayout, placement: HUDPlacement, ring: Bool, showsPercent: Bool, hasCaption: Bool) -> HUDInteractionZones {
        switch placement {
        case .wings:
            return HUDIslandGeometry.wings(
                notch: notchRect,
                cameraMidX: notchRect.midX,
                housing: NotchMetrics.cameraHousingWidth,
                leadingWing: layout.leadingWing,
                trailingWing: layout.trailingWing,
                innerPadding: NotchMetrics.wingInnerPadding,
                ring: ring,
                showsPercent: showsPercent
            )
        case .band:
            return HUDIslandGeometry.band(
                notch: notchRect,
                cameraMidX: notchRect.midX,
                bodyWidth: layout.size.width,
                bandHeight: layout.band ?? NotchMetrics.activityBandHeight,
                hasCaption: hasCaption
            )
        }
    }
}
