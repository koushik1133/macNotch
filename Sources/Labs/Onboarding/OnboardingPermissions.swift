import AppKit

/// Reads and requests macOS privacy permissions. A protocol so tests can
/// use fixed answers instead of the real TCC state.
@MainActor
protocol OnboardingPermissionProbe: AnyObject {
    /// Accessibility, synchronously (for the launch check).
    func isAccessibilityTrusted() -> Bool
    /// Every permission's status, without showing any prompt. `includeSlow`
    /// false skips the slow checks (notifications, Downloads, Automation)
    /// and leaves them out of the result.
    func statuses(downloadsRequested: Bool, includeSlow: Bool) async -> [OnboardingPermission: OnboardingPermissionStatus]
    /// Shows the macOS prompt for `permission` (only call from a click).
    func request(_ permission: OnboardingPermission) async
}

extension OnboardingPermissionProbe {
    func statuses(downloadsRequested: Bool) async -> [OnboardingPermission: OnboardingPermissionStatus] {
        await statuses(downloadsRequested: downloadsRequested, includeSlow: true)
    }
}

/// The real thing: every check and request goes through `PermissionCenter`,
/// so onboarding shares one prompt queue, one "already asked" record (per
/// code signature) and one status cache with the rest of SparkV.
@MainActor
final class SystemPermissionProbe: OnboardingPermissionProbe {
    private let center: PermissionCenter
    /// Targets whose consent alert is up: not re-checked until it closes.
    private var askingAutomation: Set<String> = []
    /// The first read of ~/Downloads blocks on macOS's alert; don't start a
    /// second read from the status refresh while that alert is up.
    private var requestingDownloads = false

    init(center: PermissionCenter? = nil) {
        self.center = center ?? .shared
    }

    func isAccessibilityTrusted() -> Bool { center.isGranted(.accessibility) }

    func statuses(downloadsRequested: Bool, includeSlow: Bool) async -> [OnboardingPermission: OnboardingPermissionStatus] {
        var result: [OnboardingPermission: OnboardingPermissionStatus] = [:]
        for permission in OnboardingPermission.allCases {
            let mapped = permission.centerPermission
            if mapped.hasQuickStatus {
                // Live preflight (no prompt). Accessibility / Screen Recording
                // report "not asked yet" until SparkV asked with this signature.
                result[permission] = Self.map(await center.freshStatus(mapped))
                continue
            }
            guard includeSlow else { continue }
            switch permission {
            case .downloads:
                // The first read is the prompt: only once the user asked.
                result[permission] = downloadsRequested && !requestingDownloads
                    ? Self.map(await center.freshStatus(mapped)) : .notDetermined
            default:
                if let bundleID = permission.automationBundleID, askingAutomation.contains(bundleID) {
                    result[permission] = .notDetermined
                } else {
                    result[permission] = Self.map(await center.freshStatus(mapped))
                }
            }
        }
        return result
    }

    func request(_ permission: OnboardingPermission) async {
        AppLog.log("Onboarding: requesting \(permission.rawValue)")
        switch permission {
        case .downloads:
            requestingDownloads = true
            defer { requestingDownloads = false }
            _ = await center.request(.downloadsFolder, from: "Onboarding")
        case .automationSafari, .automationChrome, .automationMail:
            guard let bundleID = permission.automationBundleID else { return }
            await requestAutomation(bundleID: bundleID)
        default:
            // One prompt per permission per signature; denied opens Settings.
            _ = await center.request(permission.centerPermission, from: "Onboarding")
        }
    }

    // MARK: Mapping

    nonisolated static func map(_ status: PermissionCenter.Status) -> OnboardingPermissionStatus {
        switch status {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .limited: .limited
        case .appNotRunning: .appNotRunning
        case .appNotInstalled: .appNotInstalled
        case .unknown: .unknown
        }
    }

    // MARK: Automation

    private func requestAutomation(bundleID: String) async {
        guard !askingAutomation.contains(bundleID) else { return }
        askingAutomation.insert(bundleID)
        defer { askingAutomation.remove(bundleID) }
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            // macOS can only ask once the target accepts Apple Events.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { break }
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        // Queued with every other prompt; denied before opens Settings.
        _ = await center.request(.automation(bundleID: bundleID), from: "Onboarding")
    }
}

extension OnboardingPermission {
    /// The same permission in `PermissionCenter`'s terms.
    var centerPermission: PermissionCenter.Permission {
        switch self {
        case .accessibility: .accessibility
        case .screenRecording: .screenRecording
        case .camera: .camera
        case .microphone: .microphone
        case .speechRecognition: .speech
        case .calendars: .calendars
        case .notifications: .notifications
        case .bluetooth: .bluetooth
        case .downloads: .downloadsFolder
        case .automationSafari, .automationChrome, .automationMail:
            .automation(bundleID: automationBundleID ?? "")
        }
    }
}
