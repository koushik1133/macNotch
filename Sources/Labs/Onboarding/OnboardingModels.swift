import AppKit
import SwiftUI

// MARK: - Permissions

/// Every macOS privacy permission SparkV can use, in the order the checklist
/// shows them.
enum OnboardingPermission: String, CaseIterable, Identifiable, Sendable {
    case accessibility
    case screenRecording
    case camera
    case microphone
    case speechRecognition
    case calendars
    case notifications
    case bluetooth
    case downloads
    case automationSafari
    case automationChrome
    case automationMail

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case essentials = "Essentials"
        case voiceAndVideo = "Voice & Camera"
        case personal = "Calendar, Alerts & Files"
        case automation = "Automation"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .accessibility, .screenRecording: .essentials
        case .camera, .microphone, .speechRecognition: .voiceAndVideo
        case .calendars, .notifications, .bluetooth, .downloads: .personal
        case .automationSafari, .automationChrome, .automationMail: .automation
        }
    }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .calendars: "Calendars"
        case .notifications: "Notifications"
        case .bluetooth: "Bluetooth"
        case .downloads: "Downloads Folder"
        case .automationSafari: "Control Safari"
        case .automationChrome: "Control Google Chrome"
        case .automationMail: "Control Mail"
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .camera: "camera.fill"
        case .microphone: "mic.fill"
        case .speechRecognition: "waveform"
        case .calendars: "calendar"
        case .notifications: "bell.badge.fill"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle.fill"
        case .automationSafari: "safari.fill"
        case .automationChrome: "globe"
        case .automationMail: "envelope.fill"
        }
    }

    /// The permission's own color (the pre-rebrand palette) in Apple, drawn
    /// as a System Settings–style icon; SparkV red in SparkV Red.
    var tint: Color {
        guard SparkVTheme.isApple else { return SparkVTheme.red }
        return switch self {
        case .accessibility: Color(red: 0.25, green: 0.52, blue: 1.0)
        case .screenRecording: Color(red: 0.95, green: 0.33, blue: 0.36)
        case .camera: Color(red: 0.36, green: 0.78, blue: 0.47)
        case .microphone: Color(red: 0.98, green: 0.58, blue: 0.22)
        case .speechRecognition: Color(red: 0.72, green: 0.45, blue: 0.98)
        case .calendars: Color(red: 0.98, green: 0.33, blue: 0.30)
        case .notifications: Color(red: 0.98, green: 0.30, blue: 0.40)
        case .bluetooth: Color(red: 0.20, green: 0.55, blue: 0.98)
        case .downloads: Color(red: 0.30, green: 0.72, blue: 0.95)
        case .automationSafari: Color(red: 0.18, green: 0.60, blue: 1.0)
        case .automationChrome: Color(red: 0.95, green: 0.75, blue: 0.20)
        case .automationMail: Color(red: 0.30, green: 0.62, blue: 1.0)
        }
    }

    /// Which SparkV features stop working without it.
    var features: String {
        switch self {
        case .accessibility:
            "Dictation and Clicky hotkeys, typing and pasting text, Clipboard history, Reply Drafter, notification banners, media keys, hiding the system volume HUD"
        case .screenRecording:
            "Ask About Screen, Clicky, Quick Capture, screen text capture (OCR), meeting audio"
        case .camera:
            "Mirror, Face Unlock, Screen Distance"
        case .microphone:
            "Dictation, Clicky questions, meeting recording"
        case .speechRecognition:
            "On-device transcription for dictation and meetings"
        case .calendars:
            "Next meeting under the notch with a Join button, calendar events in Spaces"
        case .notifications:
            "Timer and Pomodoro alerts, Job Agent reminders"
        case .bluetooth:
            "AirPods and headphone battery"
        case .downloads:
            "Download progress and sorting"
        case .automationSafari:
            "Save to Spaces, Job Agent and Focus read the open Safari tab"
        case .automationChrome:
            "Save to Spaces, Job Agent and Focus read the open Chrome tab"
        case .automationMail:
            "Save the selected email to Spaces"
        }
    }

    /// Accessibility drives most hotkeys, so the window calls it out.
    var isEssential: Bool { group == .essentials }

    /// Target app for Apple Events permissions.
    var automationBundleID: String? {
        switch self {
        case .automationSafari: "com.apple.Safari"
        case .automationChrome: "com.google.Chrome"
        case .automationMail: "com.apple.mail"
        default: nil
        }
    }

    /// The System Settings pane that holds the switch. The legacy
    /// `com.apple.preference.security?Privacy_*` anchors still open the right
    /// Privacy & Security page on macOS 13 and later.
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .camera: anchor = "Privacy_Camera"
        case .microphone: anchor = "Privacy_Microphone"
        case .speechRecognition: anchor = "Privacy_SpeechRecognition"
        case .calendars: anchor = "Privacy_Calendars"
        case .bluetooth: anchor = "Privacy_Bluetooth"
        case .downloads: anchor = "Privacy_FilesAndFolders"
        case .automationSafari, .automationChrome, .automationMail: anchor = "Privacy_Automation"
        case .notifications:
            let id = Bundle.main.bundleIdentifier ?? "com.sparkv.app"
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Grants that macOS only applies after the app restarts.
    var needsRelaunchAfterGrant: Bool { self == .screenRecording }

    /// Notifications, Downloads and Automation can only be read slowly
    /// (async, Apple Events): the live refresh checks them less often.
    var hasSlowStatus: Bool { !centerPermission.hasQuickStatus }
}

/// Live state of one permission, as far as macOS lets an app find out
/// without showing a prompt.
enum OnboardingPermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    /// Parental controls or a profile blocks it.
    case restricted
    /// Calendars: write-only access (no reading events).
    case limited
    /// Automation: the target app isn't installed.
    case appNotInstalled
    /// Automation: macOS can only answer while the target app runs.
    case appNotRunning
    case unknown

    var isGranted: Bool { self == .granted }

    /// The row needs nothing from the user.
    var isSettled: Bool { self == .granted || self == .appNotInstalled }

    var label: String {
        switch self {
        case .granted: "Allowed"
        case .denied: "Off"
        case .notDetermined: "Not asked yet"
        case .restricted: "Blocked by a profile"
        case .limited: "Add events only"
        case .appNotInstalled: "Not installed"
        case .appNotRunning: "Not checked"
        case .unknown: "Checking…"
        }
    }

    var color: Color {
        switch self {
        // Apple: the system green / red / orange.
        case .granted: SparkVTheme.choose(apple: Color.green, sparkv: Color(red: 0.30, green: 0.82, blue: 0.50))
        case .denied, .restricted: SparkVTheme.choose(apple: Color.red, sparkv: Color(red: 1.0, green: 0.42, blue: 0.40))
        case .limited, .appNotRunning: SparkVTheme.choose(apple: Color.orange, sparkv: Color(red: 1.0, green: 0.74, blue: 0.30))
        case .notDetermined: Color(white: 0.62)
        case .appNotInstalled, .unknown: Color(white: 0.45)
        }
    }
}

/// What the row's button does for the current status.
enum OnboardingRowAction: Equatable, Sendable {
    case none
    /// Shows the macOS prompt (only possible while not determined).
    case request
    /// macOS won't ask again; the switch lives in System Settings.
    case openSettings
    /// Automation: open the target app, then ask.
    case launchAndRequest

    var title: String {
        switch self {
        case .none: ""
        case .request: "Allow…"
        case .openSettings: "Open Settings"
        case .launchAndRequest: "Allow…"
        }
    }

    static func `for`(_ permission: OnboardingPermission, status: OnboardingPermissionStatus) -> OnboardingRowAction {
        switch status {
        case .granted, .appNotInstalled, .unknown: return .none
        case .notDetermined:
            // Accessibility and Screen Recording count as "not asked yet"
            // until SparkV asked with this code signature (PermissionCenter
            // remembers), so the system alert shows at most once.
            return .request
        case .appNotRunning: return .launchAndRequest
        case .denied, .restricted, .limited:
            // macOS won't ask again once the user said no (or SparkV already
            // asked): the switch has to be turned on in System Settings.
            return .openSettings
        }
    }
}

// MARK: - Terms

/// The Terms of Use and Privacy summary. Bump `version` when the text
/// changes in a way people should re-read; the window then shows again.
enum OnboardingTerms {
    static let version = 1
    static let effectiveDate = "October 21, 2026"

    struct Section: Identifiable, Sendable {
        let title: String
        let symbol: String
        let points: [String]
        var id: String { title }
    }

    static let sections: [Section] = [
        Section(title: "Terms of Use", symbol: "doc.text", points: [
            "SparkV is provided as is, without warranty. You use it at your own risk and are responsible for what you capture, record and send with it.",
            "Recording meetings or other people may require their consent where you live. Ask before you record.",
            "Automations, agents and AI suggestions can be wrong. Check results before you rely on them, send them or act on them.",
            "Don't use SparkV to break the law, to get around other apps' security, or to collect other people's data without permission.",
        ]),
        Section(title: "Privacy", symbol: "lock.shield", points: [
            "Camera, microphone, speech and screen content are processed on this Mac. Face Unlock data stays in your keychain.",
            "Clipboard history, Tray files, Spaces, notes and settings are stored only on this Mac, in your user account.",
            "SparkV has no account, no analytics and no tracking. It sends nothing to its developers.",
            "Cloud AI is off unless you add your own API key and turn it on for a feature. Only the text that feature needs is sent to that provider.",
            "Each macOS permission is optional. You can turn any of them off in System Settings › Privacy & Security at any time.",
        ]),
    ]
}

// MARK: - Persistence

/// UserDefaults keys under `SparkV.onboarding.*`.
struct OnboardingStore {
    enum Key {
        static let termsVersion = "SparkV.onboarding.termsVersion"
        static let termsAcceptedAt = "SparkV.onboarding.termsAcceptedAt"
        static let completedAt = "SparkV.onboarding.completedAt"
        static let downloadsRequested = "SparkV.onboarding.downloadsRequested"
        /// Signature (cdhash) of the last build that had Accessibility.
        static let trustedBuild = "SparkV.onboarding.accessibilityTrustedBuild"
        static let trustedBuildIsAdHoc = "SparkV.onboarding.accessibilityTrustedBuildIsAdHoc"
        /// Build for which the stale-grant window already opened on launch.
        static let staleNoticeBuild = "SparkV.onboarding.staleNoticeBuild"
        /// The drawer opened during Try It at least once.
        static let triedIsland = "SparkV.onboarding.triedIsland"
        /// When the full tour reached Finish and Done was clicked.
        static let finishSeenAt = "SparkV.onboarding.finishSeenAt"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var acceptedTermsVersion: Int { defaults.integer(forKey: Key.termsVersion) }
    var termsAcceptedAt: Date? { defaults.object(forKey: Key.termsAcceptedAt) as? Date }
    var hasAcceptedCurrentTerms: Bool { acceptedTermsVersion >= OnboardingTerms.version }

    func acceptTerms(version: Int = OnboardingTerms.version, at date: Date = Date()) {
        defaults.set(version, forKey: Key.termsVersion)
        defaults.set(date, forKey: Key.termsAcceptedAt)
    }

    var completedAt: Date? { defaults.object(forKey: Key.completedAt) as? Date }
    func markCompleted(at date: Date = Date()) { defaults.set(date, forKey: Key.completedAt) }

    var downloadsRequested: Bool {
        get { defaults.bool(forKey: Key.downloadsRequested) }
        nonmutating set { defaults.set(newValue, forKey: Key.downloadsRequested) }
    }

    var trustedBuild: String? {
        get { defaults.string(forKey: Key.trustedBuild) }
        nonmutating set { defaults.set(newValue, forKey: Key.trustedBuild) }
    }

    var trustedBuildIsAdHoc: Bool {
        get { defaults.bool(forKey: Key.trustedBuildIsAdHoc) }
        nonmutating set { defaults.set(newValue, forKey: Key.trustedBuildIsAdHoc) }
    }

    var staleNoticeBuild: String? {
        get { defaults.string(forKey: Key.staleNoticeBuild) }
        nonmutating set { defaults.set(newValue, forKey: Key.staleNoticeBuild) }
    }

    var triedIsland: Bool {
        get { defaults.bool(forKey: Key.triedIsland) }
        nonmutating set { defaults.set(newValue, forKey: Key.triedIsland) }
    }

    var finishSeenAt: Date? { defaults.object(forKey: Key.finishSeenAt) as? Date }
    func markFinishSeen(at date: Date = Date()) { defaults.set(date, forKey: Key.finishSeenAt) }
}
