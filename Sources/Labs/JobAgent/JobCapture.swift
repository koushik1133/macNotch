import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UserNotifications

// MARK: - Window capture

struct JobCapturedWindow: @unchecked Sendable {
    let image: CGImage
    let appName: String
    let bundleID: String
    /// True when only the front window was captured (not the whole display).
    let isWindow: Bool
}

/// Captures the frontmost app's front window (ScreenCaptureKit), falling
/// back to the display under the mouse. Runs only from the user's fn+Control
/// or Capture button. Screen Recording goes through PermissionCenter: the
/// system prompt at most once per signature, then the Settings pane, and
/// "restart SparkV" while a fresh grant waits for a relaunch. The window
/// list comes from PermissionCenter's cache, so ScreenCaptureKit (and
/// macOS 15's recurring capture confirmation) is touched as little as possible.
enum JobScreenCapture {
    static let maxLongEdge: CGFloat = 2600

    enum Failure: Error, LocalizedError {
        case permissionDenied
        /// Granted in Settings, but macOS applies it only after a restart.
        case needsRelaunch
        case noWindow
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Allow Screen Recording for SparkV in System Settings › Privacy & Security, then try again."
            case .needsRelaunch: "Turn on Screen Recording for SparkV in System Settings › Privacy & Security, then restart SparkV."
            case .noWindow: "Couldn't find a window to read."
            case .failed(let message): "Screen capture failed: \(message)"
            }
        }
    }

    /// Never prompts.
    @MainActor
    static var hasPermission: Bool { PermissionCenter.shared.isGranted(.screenRecording) }

    /// From a user action only (fn+Control, Capture button).
    @MainActor
    static func captureFrontWindow() async throws -> JobCapturedWindow {
        let permissions = PermissionCenter.shared
        if !permissions.isGranted(.screenRecording) {
            // Already allowed in Settings this session: re-asking or reopening
            // Settings won't help, only a restart does.
            if permissions.screenRecordingNeedsRelaunch { throw Failure.needsRelaunch }
            guard await permissions.ensure(.screenRecording, from: "Job Agent") else {
                throw permissions.screenRecordingNeedsRelaunch ? Failure.needsRelaunch : Failure.permissionDenied
            }
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        let pid = front?.processIdentifier ?? 0
        let appName = front?.localizedName ?? ""
        let bundleID = front?.bundleIdentifier ?? ""

        var content: SCShareableContent
        do {
            content = try await permissions.shareableContent(from: "Job Agent", excludingDesktopWindows: true, onScreenWindowsOnly: true)
        } catch {
            throw Failure.permissionDenied
        }

        // CGWindowList is front-to-back; the first normal-layer window of the app is its front window.
        var windowID: CGWindowID?
        if pid != 0, pid != ownPID,
           let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in list {
                guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                      (bounds["Width"] ?? 0) >= 300, (bounds["Height"] ?? 0) >= 200,
                      let number = info[kCGWindowNumber as String] as? Int else { continue }
                windowID = CGWindowID(number)
                break
            }
        }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true

        // The cached list may predate a window that just opened: one fresh read.
        if let windowID, !content.windows.contains(where: { $0.windowID == windowID }),
           let fresh = try? await permissions.shareableContent(from: "Job Agent", excludingDesktopWindows: true,
                                                               onScreenWindowsOnly: true, maxAge: 0) {
            content = fresh
        }

        let filter: SCContentFilter
        let isWindow: Bool
        if let windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 2
            let size = fitted(CGSize(width: window.frame.width * scale, height: window.frame.height * scale))
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
            isWindow = true
        } else {
            let mouse = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main,
                  let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.noWindow }
            let own = content.applications.filter { $0.processID == ownPID }
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let size = fitted(CGSize(width: CGFloat(display.width) * screen.backingScaleFactor,
                                     height: CGFloat(display.height) * screen.backingScaleFactor))
            configuration.width = Int(size.width)
            configuration.height = Int(size.height)
            isWindow = false
        }
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            AppLog.log("Job Agent: captured \(isWindow ? "window" : "display") \(image.width)x\(image.height) of \(appName)")
            return JobCapturedWindow(image: image, appName: appName, bundleID: bundleID, isWindow: isWindow)
        } catch {
            if PermissionCenter.isCaptureDenial(error) { throw Failure.permissionDenied }
            throw Failure.failed(error.localizedDescription)
        }
    }

    static func fitted(_ size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > maxLongEdge else { return size }
        let factor = maxLongEdge / longest
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }
}

// MARK: - Browser URL / title over Apple Events

struct JobBrowserPage: Sendable, Equatable {
    var url: String
    var title: String
    var browser: String
}

/// Reads the active tab's URL and title from Safari, Chrome, Arc, Edge,
/// Brave and Vivaldi. Background reads never show the Automation prompt;
/// `requestAccess` (from a button the user clicks) does.
final class JobBrowserBridge: @unchecked Sendable {
    enum Status: Sendable, Equatable {
        case page(JobBrowserPage)
        case needsConsent(String)
        case denied(String)
        case notBrowser
        case unavailable
    }

    static let safariLike: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromeLike: [String: String] = [
        "com.google.Chrome": "Chrome", "com.google.Chrome.beta": "Chrome Beta", "com.google.Chrome.canary": "Chrome Canary",
        "company.thebrowser.Browser": "Arc", "com.microsoft.edgemac": "Edge", "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]

    static func isSupported(_ bundleID: String) -> Bool { safariLike.contains(bundleID) || chromeLike[bundleID] != nil }

    static func name(of bundleID: String) -> String {
        safariLike.contains(bundleID) ? "Safari" : chromeLike[bundleID] ?? bundleID
    }

    private let queue = DispatchQueue(label: "SparkV.JobBrowserBridge", qos: .userInitiated)

    func current(bundleID: String) async -> Status {
        guard Self.isSupported(bundleID) else { return .notBrowser }
        return await perform { self.readNow(bundleID) }
    }

    /// From the "Allow reading the URL" button only. PermissionCenter shows
    /// "SparkV wants to control <browser>" if it was never answered (one
    /// system prompt at a time), and opens Settings › Automation when denied.
    @MainActor
    func requestAccess(bundleID: String) async -> Bool {
        await PermissionCenter.shared.request(.automation(bundleID: bundleID), from: "Job Agent").isGranted
    }

    /// Without prompting.
    func accessStatus(bundleID: String) async -> OSStatus {
        await perform { self.permission(bundleID, askUser: false) }
    }

    private func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private func permission(_ bundleID: String, askUser: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let address = target.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUser)
    }

    private func readNow(_ bundleID: String) -> Status {
        let name = Self.name(of: bundleID)
        switch Int(permission(bundleID, askUser: false)) {
        case Int(noErr): break
        case errAEEventWouldRequireUserConsent: return .needsConsent(name)
        case errAEEventNotPermitted: return .denied(name)
        default: return .unavailable
        }
        let source: String
        if Self.safariLike.contains(bundleID) {
            source = """
            tell application id "\(bundleID)"
                if (count of documents) is 0 then return ""
                return (URL of front document) & linefeed & (name of front document)
            end tell
            """
        } else {
            source = """
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return (URL of active tab of front window) & linefeed & (title of active tab of front window)
            end tell
            """
        }
        guard let script = NSAppleScript(source: source) else { return .unavailable }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            return code == errAEEventNotPermitted ? .denied(name) : .unavailable
        }
        let parts = (result.stringValue ?? "").components(separatedBy: "\n")
        guard let url = parts.first, !url.isEmpty else { return .unavailable }
        return .page(JobBrowserPage(url: url, title: parts.dropFirst().joined(separator: " "), browser: name))
    }
}

// MARK: - Hotkey (fn + Control)

/// Hold fn and Control together, then release both: one trigger.
///
/// NSEvent global + local monitors (`flagsChanged`, `keyDown`), observe
/// only, like `ClickyHotkeyMonitor`. Any key or another modifier while the
/// chord is held cancels it, so fn+Control+key shortcuts never trigger.
/// Global monitors need Accessibility (already granted for dictation and
/// Clicky); checked without prompting. A global monitor installed before the
/// grant can stay deaf, so it is re-installed when PermissionCenter sees
/// Accessibility turn on.
@MainActor
final class JobHotkeyMonitor {
    var onTrigger: (@MainActor () -> Void)?
    /// Shortest and longest hold that counts.
    var minimumHold: TimeInterval = 0.06
    var maximumHold: TimeInterval = 5

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var accessibilityWatch: AnyCancellable?
    private var chordDown = false
    private var cancelled = false
    private var chordStart: TimeInterval = 0

    nonisolated static let relevant: NSEvent.ModifierFlags = [.control, .option, .command, .shift, .function]
    nonisolated static let chord: NSEvent.ModifierFlags = [.control, .function]

    var isRunning: Bool { globalMonitor != nil || localMonitor != nil }
    static var isTrusted: Bool { PermissionCenter.shared.isGranted(.accessibility) }

    private struct Info: Sendable {
        let isFlags: Bool
        let flags: UInt
        let time: TimeInterval
    }

    func start() {
        guard !isRunning else { return }
        if accessibilityWatch == nil {
            accessibilityWatch = PermissionCenter.shared.whenGranted(.accessibility) { [weak self] in
                guard let self, self.isRunning else { return }
                AppLog.log("Job Agent: Accessibility granted; re-installing the fn+Control monitor")
                self.removeMonitors()
                self.installMonitors()
            }
        }
        installMonitors()
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let info = Info(isFlags: event.type == .flagsChanged, flags: event.modifierFlags.rawValue, time: event.timestamp)
            MainActor.assumeIsolated { self?.handle(info) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            let info = Info(isFlags: event.type == .flagsChanged, flags: event.modifierFlags.rawValue, time: event.timestamp)
            MainActor.assumeIsolated { self?.handle(info) }
            return event
        }
        AppLog.log("Job Agent: fn+Control monitor started (Accessibility \(Self.isTrusted ? "granted" : "missing"))")
    }

    func stop() {
        accessibilityWatch = nil
        removeMonitors()
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        chordDown = false
    }

    private func handle(_ info: Info) {
        guard info.isFlags else {
            if chordDown { cancelled = true }
            return
        }
        let flags = NSEvent.ModifierFlags(rawValue: info.flags).intersection(Self.relevant)
        if Self.transition(flags: flags, chordDown: &chordDown, cancelled: &cancelled, chordStart: &chordStart, time: info.time,
                           minimumHold: minimumHold, maximumHold: maximumHold) {
            onTrigger?()
        }
    }

    /// Pure state machine (exposed for tests). Returns true when the chord completes.
    nonisolated static func transition(flags: NSEvent.ModifierFlags, chordDown: inout Bool, cancelled: inout Bool,
                                       chordStart: inout TimeInterval, time: TimeInterval,
                                       minimumHold: TimeInterval, maximumHold: TimeInterval) -> Bool {
        if flags == chord {
            if !chordDown {
                chordDown = true
                cancelled = false
                chordStart = time
            }
            return false
        }
        guard chordDown else { return false }
        if flags.isEmpty {
            chordDown = false
            let held = time - chordStart
            return !cancelled && held >= minimumHold && held <= maximumHold
        }
        // Releasing one of the two keys first is fine; anything else cancels.
        if !flags.isSubset(of: chord) { cancelled = true }
        return false
    }
}

// MARK: - Reminders

/// Follow-up reminders on the expected response date. Only scheduled when
/// notifications are already authorized; the Job Agent never asks.
enum JobReminders {
    /// UNUserNotificationCenter traps outside an app bundle.
    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    static func isAuthorized() async -> Bool {
        guard canNotify else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    /// Returns the request id, or nil when not scheduled.
    static func schedule(company: String, title: String, on date: Date) async -> String? {
        guard JobAgentSettings.reminders, await isAuthorized() else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        components.hour = 10
        let content = UNMutableNotificationContent()
        content.title = "Follow up: \(title)"
        content.body = "No reply yet from \(company)? It's a good day to send a short follow-up."
        content.sound = .default
        let id = "SparkV.job.\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(request)
            return id
        } catch {
            AppLog.log("Job Agent: reminder not scheduled: \(error.localizedDescription)")
            return nil
        }
    }

    static func cancel(_ id: String?) {
        guard canNotify, let id else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
