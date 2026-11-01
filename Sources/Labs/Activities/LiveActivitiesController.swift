import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The live-activities package in one controller (start / stop):
///
/// - Now Playing as a peer activity (`NowPlayingActivityBridge`),
/// - calls: ongoing timer, incoming Accept / Decline, mute (`CallsController`),
/// - ⌃⌥A: the next running activity in the wings (Settings can turn it off).
///   ⌃⌥ is VoiceOver's modifier (VO-A reads from the cursor), so it is let
///   go while VoiceOver runs and comes back when VoiceOver stops,
/// - stops the announcer's waiting sentences when announcements go off.
///
/// Notifications stay in `NotificationMonitor`, the timing and filters in
/// their settings objects; the island reads them directly.
@MainActor
final class LiveActivitiesController: ObservableObject {
    static weak var current: LiveActivitiesController?
    /// ⌃⌥A ("A" for activities). Free among SparkV's own: J, R, S, T, C, F,
    /// N, H, M, P, K, E, I, Space and 1–5 are taken with ⌃⌥.
    static let cycleShortcut = ScreenRegionShortcut(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey))

    let activities: ActivityCenter
    let nowPlaying: NowPlayingActivityBridge
    let calls: CallsController
    let settings: LiveActivitiesSettings

    private let hotkey = ScreenRegionHotkey()
    private var hotkeyRegistered = false
    @Published private(set) var hotkeyUnavailable = false
    /// VoiceOver is running: ⌃⌥A is VoiceOver's, so SparkV leaves it alone.
    @Published private(set) var hotkeyPausedForVoiceOver = false
    private var voiceOverWatch: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false

    init(activities: ActivityCenter, nowPlaying: NowPlayingActivityBridge, calls: CallsController, settings: LiveActivitiesSettings? = nil) {
        self.activities = activities
        self.nowPlaying = nowPlaying
        self.calls = calls
        self.settings = settings ?? .shared
        Self.current = self
    }

    /// The app's wiring.
    convenience init(activities: ActivityCenter, media: MediaEngine, notifications: NotificationMonitor, meetingAssistant: MeetingAssistant) {
        self.init(
            activities: activities,
            nowPlaying: NowPlayingActivityBridge(media: media, activities: activities),
            calls: CallsController(activities: activities, notifications: notifications, meetingAssistant: meetingAssistant)
        )
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        nowPlaying.start()
        calls.start()
        hotkey.onPress = { [weak self] in
            MainActor.assumeIsolated { self?.showNextFromKeyboard() }
        }
        settings.$cycleHotkeyEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateHotkey() } }
            }
            .store(in: &cancellables)
        // KVO, no polling: VoiceOver starting or stopping.
        hotkeyPausedForVoiceOver = NSWorkspace.shared.isVoiceOverEnabled
        voiceOverWatch = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { [weak self] _, change in
            let on = change.newValue ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hotkeyPausedForVoiceOver = on
                    self.updateHotkey()
                }
            }
        }
        ActivityAnnouncementSettings.shared.$isEnabled
            .removeDuplicates()
            .sink { on in if !on { ActivityAnnouncer.shared.cancelPending() } }
            .store(in: &cancellables)
    }

    func stop() {
        isStarted = false
        cancellables.removeAll()
        voiceOverWatch?.invalidate()
        voiceOverWatch = nil
        updateHotkey()
        nowPlaying.stop()
        calls.stop()
    }

    /// ⌃⌥A: the next running activity in the wings, instantly (keyboard-
    /// triggered UI doesn't animate). With only one, it peeks instead.
    func showNextFromKeyboard() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if activities.running.count > 1 {
                activities.cycleCompact()
            } else if let only = activities.running.first {
                activities.peek(id: only.id)
            }
        }
    }

    private func updateHotkey() {
        let on = settings.cycleHotkeyEnabled && !hotkeyPausedForVoiceOver
        if on, isStarted {
            guard !hotkeyRegistered else { return }
            hotkeyRegistered = hotkey.register(Self.cycleShortcut)
            hotkeyUnavailable = !hotkeyRegistered
            if !hotkeyRegistered { AppLog.log("Live Activities: \(Self.cycleShortcut.displayString) is taken by another app") }
        } else {
            if hotkeyRegistered {
                hotkey.unregister()
                hotkeyRegistered = false
            }
            hotkeyUnavailable = false
        }
    }
}
