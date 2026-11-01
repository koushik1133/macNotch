import AppKit
import Combine
import SwiftUI

/// Wires the System Status package into the app: one `connect` from
/// NotchWindowController, then `start()` / `stop()` with the other monitors.
/// Every feature controller is a `.shared` singleton so settings sections,
/// menu items and hub tiles can take no arguments.
///
/// Nothing here polls. Each controller listens to its own system events
/// (IOKit, CoreAudio, CoreMediaIO, Network, NSWorkspace) and only while its
/// feature is on.
@MainActor
final class SystemStatusCenter {
    static let shared = SystemStatusCenter()

    private(set) var activities: ActivityCenter?
    private(set) var isStarted = false

    // MARK: Hooks the integrator sets (all optional)

    /// Another app shares the screen (SmartMoments' best-effort detector).
    /// Connectivity alerts stay quiet while it is true.
    var isScreenSharing: @MainActor () -> Bool = { false }
    /// SparkV itself has the camera (mirror, Screen Distance, Face Unlock):
    /// the camera indicator stays off, since macOS can't say who else uses it.
    var isOwnCameraActive: @MainActor () -> Bool = { false }
    /// Opens the drawer on the Status page.
    var openStatusPage: (@MainActor () -> Void)?
    /// The tab live bands open on hover (the Status page), if any.
    var statusTab: NotchState.Tab?

    private init() {}

    func connect(activities: ActivityCenter) {
        self.activities = activities
    }

    /// Starts every feature that is turned on. Call after `connect`.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        MicMuteController.shared.start()
        PeripheralBatteryMonitor.shared.start()
        PrivacyIndicatorMonitor.shared.start()
        KeepAwakeController.shared.start()
        ConnectivityMonitor.shared.start()
        CapsLockMonitor.shared.start()
        QuickTogglesController.shared.start()
        AppLog.log("System Status: started")
    }

    /// Stops everything: releases the keep-awake assertion, unmutes a mic
    /// SparkV muted, removes every listener and monitor.
    func stop() {
        guard isStarted else { return }
        isStarted = false
        QuickTogglesController.shared.stop()
        CapsLockMonitor.shared.stop()
        ConnectivityMonitor.shared.stop()
        KeepAwakeController.shared.stop()
        PrivacyIndicatorMonitor.shared.stop()
        PeripheralBatteryMonitor.shared.stop()
        MicMuteController.shared.stop()
    }

    // MARK: Posting

    func post(_ activity: LiveActivity) {
        activities?.post(activity)
    }

    func dismiss(id: String) {
        activities?.dismiss(id: id)
    }

    func peek(id: String, for duration: TimeInterval = NotchMetrics.activityPeekDuration) {
        activities?.peek(id: id, for: duration)
    }

    func openPage() {
        openStatusPage?()
    }
}

/// Small persisted-setting helpers shared by the controllers.
enum StatusDefaults {
    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static func int(_ key: String, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? value
    }

    static func string(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: key)
    }

    static func set(_ value: Any?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
}
