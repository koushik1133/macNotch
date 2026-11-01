import AppKit
import Combine
import SwiftUI

/// A Caps Lock indicator: a short "Caps Lock On / Off" band when it flips,
/// and (optionally) a small ⇪ beside the notch while it stays on.
///
/// Off by default: macOS 14+ already shows Caps Lock at the text cursor.
/// Key-related global event monitors need Accessibility, which SparkV asks
/// for through PermissionCenter (for Clicky and notifications too); the
/// monitors are re-created the moment it is granted. Without it, the state
/// is read when any app comes to the front (no timer). When Caps Lock is
/// set to switch input sources, its flag never changes and nothing shows.
@MainActor
final class CapsLockMonitor: ObservableObject {
    static let shared = CapsLockMonitor()

    static let enabledKey = "capsLock.isEnabled"
    static let persistentKey = "capsLock.showsWhileOn"
    static let bandID = "capsLock"
    static let badgeID = "capsLock.on"

    @Published var isEnabled: Bool {
        didSet { guard isEnabled != oldValue else { return }; StatusDefaults.set(isEnabled, Self.enabledKey); apply() }
    }
    /// The ⇪ badge in the wings while Caps Lock stays on.
    @Published var showsWhileOn: Bool {
        didSet { StatusDefaults.set(showsWhileOn, Self.persistentKey); postBadge() }
    }

    @Published private(set) var isOn = false
    /// Accessibility isn't granted, so changes in other apps aren't seen live.
    @Published private(set) var needsAccessibility = false

    private var isStarted = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var grantWatch: AnyCancellable?

    private init() {
        isEnabled = StatusDefaults.bool(Self.enabledKey, default: false)
        showsWhileOn = StatusDefaults.bool(Self.persistentKey, default: true)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        apply()
    }

    func stop() {
        isStarted = false
        apply()
    }

    /// From a user action: asks for Accessibility (or opens its pane).
    func requestAccessibility() {
        Task { _ = await PermissionCenter.shared.request(.accessibility, from: "Caps Lock indicator") }
    }

    private func apply() {
        removeMonitors()
        guard isStarted, isEnabled else {
            grantWatch = nil
            SystemStatusCenter.shared.dismiss(id: Self.bandID)
            SystemStatusCenter.shared.dismiss(id: Self.badgeID)
            return
        }
        isOn = NSEvent.modifierFlags.contains(.capsLock)
        installMonitors()
        if grantWatch == nil {
            grantWatch = PermissionCenter.shared.whenGranted(.accessibility) { [weak self] in
                guard let self, self.isStarted, self.isEnabled else { return }
                // Monitors made before the grant receive nothing: rebuild them.
                self.removeMonitors()
                self.installMonitors()
            }
        }
        postBadge()
    }

    private func installMonitors() {
        needsAccessibility = !PermissionCenter.shared.isGranted(.accessibility)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.update(on) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.update(on) }
            return event
        }
        // Fallback without Accessibility: catch up whenever an app activates.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(NSEvent.modifierFlags.contains(.capsLock)) }
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func update(_ on: Bool) {
        guard isStarted, isEnabled, on != isOn else { return }
        isOn = on
        // A key press: instant feedback that only fades (live-feedback kind).
        SystemStatusCenter.shared.post(LiveActivity(id: Self.bandID, kind: .volume, priority: 88, duration: 1.2) {
            CapsLockBand(isOn: on)
        }
        .titled("Caps Lock")
        .accessibility(on ? "Caps Lock on" : "Caps Lock off"))
        postBadge()
    }

    private func postBadge() {
        guard isStarted, isEnabled, isOn, showsWhileOn else {
            SystemStatusCenter.shared.dismiss(id: Self.badgeID)
            return
        }
        SystemStatusCenter.shared.post(LiveActivity(
            id: Self.badgeID, kind: .notification, priority: 14, duration: nil,
            symbol: "capslock.fill", tint: SparkVTheme.text
        ) {
            CapsLockBand(isOn: true)
        }
        .titled("Caps Lock")
        .accessibility("Caps Lock is on")
        .compact {
            Image(systemName: "capslock.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .accessibilityLabel("Caps Lock is on")
        } trailing: {
            Text("Caps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize()
        }
        .minimal {
            Image(systemName: "capslock.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SparkVTheme.text)
                .frame(width: 18, height: 18)
                .background(Circle().fill(SparkVTheme.surfaceHover))
                .accessibilityLabel("Caps Lock is on")
        })
    }
}
