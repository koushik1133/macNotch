import AppKit
import SwiftUI

/// Trackpad and keyboard control over the media column.
///
/// While the pointer is over the column (and only then) one local scroll
/// monitor and one key monitor exist; both go away on exit or when the
/// drawer closes (the view disappears). A horizontal two-finger swipe skips
/// a track or seeks (Settings › Media › Gestures); vertical scrolls pass
/// through untouched, so scroll views and the volume knob keep working.
/// ← / → skip 15 s and Space plays / pauses when the island has keyboard
/// focus and no text field is editing.
@MainActor
final class MediaPointerControls: ObservableObject {
    /// Glyph shown briefly after a swipe or key ("forward.fill").
    @Published private(set) var feedback: String?
    @Published private(set) var feedbackID = 0

    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var accumulator = MediaSwipeAccumulator()
    private var lastFire = Date.distantPast
    private var feedbackTask: Task<Void, Never>?
    private weak var media: MediaEngine?

    func hover(_ inside: Bool, media: MediaEngine) {
        self.media = media
        inside ? install() : remove()
    }

    func remove() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        scrollMonitor = nil
        keyMonitor = nil
        accumulator = MediaSwipeAccumulator()
    }

    private func install() {
        let settings = MediaPlusSettings.shared
        if scrollMonitor == nil, settings.swipeAction != .off {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let swallow: Bool = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
                return swallow ? nil : event
            }
        }
        if keyMonitor == nil, settings.arrowKeysSkip {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let swallow: Bool = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
                return swallow ? nil : event
            }
        }
    }

    // MARK: Swipes

    private func handleScroll(_ event: NSEvent) -> Bool {
        let settings = MediaPlusSettings.shared
        guard settings.swipeAction != .off, let media else { return false }
        let phase: MediaSwipeAccumulator.Phase = switch event.phase {
        case .began: .began
        case .changed: .changed
        case .ended, .cancelled: .ended
        default: .none
        }
        let fired = accumulator.handle(
            phase: phase,
            isMomentum: event.momentumPhase != [],
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas,
            naturalScrolling: event.isDirectionInvertedFromDevice,
            reversed: settings.swipeReversed
        )
        if let fired {
            // One gesture, one action, even on a fast double flick.
            guard Date().timeIntervalSince(lastFire) > 0.35 else { return true }
            lastFire = Date()
            perform(fired, action: settings.swipeAction, media: media)
            return true
        }
        // Keep the horizontal part of a swipe from scrolling anything else.
        return accumulator.isHorizontal || (event.momentumPhase != [] && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 2 && accumulator.fired)
    }

    private func perform(_ direction: MediaSwipeAccumulator.Direction, action: MediaSwipeAction, media: MediaEngine) {
        let forward = direction == .forward
        switch action {
        case .off:
            return
        case .tracks:
            media.send(forward ? .nextTrack : .previousTrack)
            show(forward ? "forward.fill" : "backward.fill")
        case .seek10:
            guard media.canSeek else { show("nosign"); return }
            media.skip(by: forward ? 10 : -10)
            show(forward ? "goforward.10" : "gobackward.10")
        case .seek15:
            guard media.canSkip15 else { show("nosign"); return }
            media.skip15(forward: forward)
            show(forward ? "goforward.15" : "gobackward.15")
        }
    }

    // MARK: Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        guard MediaPlusSettings.shared.arrowKeysSkip, let media,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        // Never steal keys from a text field (the bookmark note).
        if event.window?.firstResponder is NSText { return false }
        switch event.keyCode {
        case 123: // ←
            guard media.canSkip15 else { return false }
            media.skip15(forward: false)
            show("gobackward.15", animated: false)
            return true
        case 124: // →
            guard media.canSkip15 else { return false }
            media.skip15(forward: true)
            show("goforward.15", animated: false)
            return true
        case 49: // Space
            guard media.source != .none else { return false }
            media.send(.togglePlayPause)
            show(media.isPlaying ? "pause.fill" : "play.fill", animated: false)
            return true
        default:
            return false
        }
    }

    /// Keyboard-triggered feedback appears instantly; swipes fade in.
    private func show(_ symbol: String, animated: Bool = true) {
        feedbackID += 1
        if animated {
            withAnimation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.small))) { feedback = symbol }
        } else {
            feedback = symbol
        }
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            withAnimation(SparkVMotion.easeOut(SparkVMotion.Duration.standard)) { self?.feedback = nil }
        }
    }
}

/// Attaches `MediaPointerControls` and draws the swipe feedback chip.
struct MediaPointerControlsModifier: ViewModifier {
    @EnvironmentObject private var media: MediaEngine
    @StateObject private var controls = MediaPointerControls()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { controls.hover($0, media: media) }
            .onDisappear { controls.remove() }
            .overlay(alignment: .center) {
                if let symbol = controls.feedback {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .frame(width: 38, height: 30)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                        .id(controls.feedbackID)
                        .transition(SparkVMotion.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: SparkVMotion.enterScale)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// Two-finger swipes and ←/→/Space over the media column.
    func mediaPointerControls() -> some View {
        modifier(MediaPointerControlsModifier())
    }
}
