import AppKit
import SwiftUI

/// Shows and hides the full-screen notice. A protocol so the harness can
/// test the controller without opening windows.
@MainActor
protocol ScreenDistanceOverlayPresenting: AnyObject {
    func show(controller: ScreenDistanceController)
    func hide(animated: Bool)
}

/// The iOS-style blocking notice: a blurred, dimmed panel over every
/// screen, above the notch and normal windows but below menus. The panels
/// are non-activating key panels, so they take the keyboard even though
/// SparkV is an accessory app that macOS 14+ may refuse to activate (with an
/// activating window, keystrokes would fall through to the app behind). Esc
/// is ignored unless skipping is allowed, and the notice fades out on its own
/// once you are back at a safe distance.
@MainActor
final class ScreenDistanceOverlayController: ScreenDistanceOverlayPresenting {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private var panels: [ScreenDistanceOverlayPanel] = []
    private weak var controller: ScreenDistanceController?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var failsafe: Timer?
    private var generation = 0
    private var lastRefocus = Date.distantPast

    var isVisible: Bool { !panels.isEmpty }

    func show(controller: ScreenDistanceController) {
        self.controller = controller
        generation += 1
        if panels.isEmpty {
            buildPanels()
            observe()
        }
        for panel in panels {
            panel.ignoresMouseEvents = false   // a fade-out in progress made it pass-through
            panel.alphaValue = panel.alphaValue == 1 ? 1 : 0
            panel.orderFrontRegardless()
        }
        primaryPanel?.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            // A full-screen sheet: the drawer duration with a strong ease-out.
            context.duration = SparkVMotion.Duration.drawer
            context.timingFunction = ScreenDistanceOverlayTiming.easeOut
            for panel in panels { panel.animator().alphaValue = 1 }
        }
    }

    func hide(animated: Bool) {
        guard !panels.isEmpty else { return }
        generation += 1
        let token = generation
        let closing = panels
        // Mouse clicks pass through at once, even while fading.
        closing.forEach { $0.ignoresMouseEvents = true }
        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == token else { return }
            closing.forEach { $0.orderOut(nil) }
            self.panels.removeAll()
            self.stopObserving()
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup({ context in
            // Exits are quicker than entrances (was 0.45 s, default curve).
            context.duration = SparkVMotion.Duration.standard
            context.timingFunction = ScreenDistanceOverlayTiming.easeOut
            for panel in closing { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated { finish() }
        })
    }

    private var primaryPanel: ScreenDistanceOverlayPanel? {
        panels.first { $0.isPrimary } ?? panels.first
    }

    private func buildPanels() {
        guard let controller else { return }
        panels.forEach { $0.orderOut(nil) }
        // The built-in display (the one with the camera) gets keyboard focus;
        // every display gets the notice so nothing behind it is usable.
        let screens = NSScreen.screens
        let builtIn = screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
        panels = screens.map { screen in
            let panel = ScreenDistanceOverlayPanel(screen: screen, isPrimary: screen == builtIn)
            panel.onEscape = { [weak controller] in
                guard let controller else { return }
                if !controller.skipTapped() { NSSound.beep() }
            }
            panel.setContent(ScreenDistanceOverlayView(controller: controller))
            panel.alphaValue = 0
            return panel
        }
    }

    private func observe() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        // Displays added, removed or rearranged: cover the new layout.
        observers.append((center, center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panels.isEmpty else { return }
                self.buildPanels()
                for panel in self.panels { panel.alphaValue = 1; panel.orderFrontRegardless() }
                self.primaryPanel?.makeKey()
            }
        }))
        // Cmd-Tab or a click on another app while too close: take the
        // keyboard back (at most once a second), like the iOS notice that
        // can't be dismissed by switching apps.
        observers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refocus() }
        }))
        // Failsafe: whatever happens to the controller's loop, the notice
        // never outlives the warning (feature off, paused, alert ended).
        failsafe?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panels.isEmpty else { return }
                guard let controller = self.controller, controller.alertPhase != nil, controller.isEnabled else {
                    self.hide(animated: true)
                    return
                }
                if controller.alertPhase == .tooClose, !(self.primaryPanel?.isKeyWindow ?? true) { self.refocus() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        failsafe = timer
    }

    private func refocus() {
        guard !panels.isEmpty, controller?.alertPhase == .tooClose,
              Date().timeIntervalSince(lastRefocus) > 1
        else { return }
        lastRefocus = Date()
        for panel in panels { panel.orderFrontRegardless() }
        primaryPanel?.makeKey()
    }

    private func stopObserving() {
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        failsafe?.invalidate()
        failsafe = nil
    }
}

final class ScreenDistanceOverlayPanel: NSPanel {
    let isPrimary: Bool
    var onEscape: (() -> Void)?

    init(screen: NSScreen, isPrimary: Bool) {
        self.isPrimary = isPrimary
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        level = ScreenDistanceOverlayController.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = false
        // Not `isFloatingPanel`: setting it resets `level` to .floating.
        animationBehavior = .none
        setFrame(screen.frame, display: false)
    }

    func setContent(_ view: some View) {
        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: view.followsAppearance())
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        contentView = blur
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

// MARK: - Notice content

/// The notice itself: icon, title, short explanation, live distance and a
/// Continue button that unlocks only at a safe distance.
struct ScreenDistanceOverlayView: View {
    @ObservedObject var controller: ScreenDistanceController

    var body: some View {
        let safe = controller.alertPhase == .safe
        let clear = controller.thresholdCM + ScreenDistanceController.clearMarginCM
        ZStack {
            SparkVTheme.background.opacity(0.55)
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill((safe ? ScreenDistanceStyle.good : ScreenDistanceStyle.warning).opacity(0.18))
                        .frame(width: 96, height: 96)
                    Image(systemName: safe ? "checkmark" : "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(safe ? ScreenDistanceStyle.good : ScreenDistanceStyle.warning)
                }
                .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: safe)

                VStack(spacing: 8) {
                    Text(safe ? "That’s better" : "Your Mac screen is too close")
                        .font(SparkVTheme.title(28))
                        .tracking(-0.8)
                        .foregroundStyle(SparkVTheme.text)
                    Text(safe
                        ? "You’re at a comfortable distance. This will close in a moment."
                        : "Looking at a screen up close for a long time can strain your eyes. Move back to at least \(Int(clear)) cm (\(ScreenDistanceStyle.inches(clear))) to continue.")
                        .font(.system(size: 14))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420, minHeight: 40, alignment: .top)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    Text(controller.distanceCM == nil ? "Looking for your face…" : "Now \(ScreenDistanceStyle.centimeters(controller.distanceCM))")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(ScreenDistanceStyle.color(distance: controller.distanceCM, threshold: controller.thresholdCM))
                    ScreenDistanceGauge(distance: controller.distanceCM, threshold: controller.thresholdCM, height: 6, showsLabels: true)
                        .frame(width: 300)
                }
                .padding(.vertical, 4)

                Button { controller.continueTapped() } label: {
                    Text("Continue")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(safe ? Color.white : SparkVTheme.textTertiary)
                        .frame(width: 260, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                                .fill(safe ? SparkVTheme.accent : SparkVTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                                .strokeBorder(safe ? Color.clear : SparkVTheme.stroke)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous))
                        .animation(SparkVMotion.hover(), value: safe)
                }
                .buttonStyle(SparkVPressStyle())
                .disabled(!safe)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(safe ? "" : "Available once you move back")

                HStack(spacing: 14) {
                    linkButton("Snooze 15 min") { controller.snooze(minutes: 15) }
                    linkButton("Snooze 1 hour") { controller.snooze(minutes: 60) }
                    if controller.allowSkipping, !safe {
                        linkButton("Skip (Esc)") { controller.skipTapped() }
                    }
                }

                Text("Measured on this Mac with the FaceTime camera. No images are saved.")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .padding(.top, 6)
            }
            .padding(40)
        }
        .environment(\.colorScheme, .dark)
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .underline(color: SparkVTheme.choose(apple: SparkVTheme.textTertiary, sparkv: SparkVTheme.red.opacity(0.7)))
        }
        .buttonStyle(SparkVPressStyle())
    }
}

/// cubic-bezier(0.23, 1, 0.32, 1), the SparkVMotion strong ease-out, for
/// the AppKit panel fades.
private enum ScreenDistanceOverlayTiming {
    static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1) }
}

