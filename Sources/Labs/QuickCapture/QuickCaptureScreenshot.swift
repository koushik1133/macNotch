import AppKit
import CoreGraphics

/// Interactive screenshot through the system tool (`/usr/sbin/screencapture -i`),
/// the same crosshair, Space-for-window and Esc-to-cancel the user already
/// knows from ⌘⇧4. The file goes to SparkV's temporary folder, never to the
/// user's screenshot location, so the system screenshot settings are untouched.
enum QuickCaptureScreenshot {
    enum Outcome: Equatable, Sendable {
        case captured(URL)
        /// The user pressed Esc (no file written).
        case cancelled
        /// Screen Recording isn't granted, so macOS would only capture the wallpaper.
        case needsPermission
        case failed(String)
    }

    static let tool = "/usr/sbin/screencapture"

    /// Seam for tests: runs the capture tool with these arguments and returns
    /// its exit status. Defaults to the real tool.
    nonisolated(unsafe) static var runTool: @Sendable (_ arguments: [String]) async -> Int32 = { arguments in
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    /// Seam for tests (Screen Recording preflight through PermissionCenter,
    /// never prompts; keeps the shared status cache current).
    nonisolated(unsafe) static var hasPermission: @Sendable () async -> Bool = {
        await PermissionCenter.shared.isGranted(.screenRecording)
    }

    /// Seam for tests: whether ⌃⌥⌘⇧ are still held from the hotkey. In
    /// `screencapture -i`, Control held at mouse-up sends the shot to the
    /// clipboard (no file, and the user's clipboard is replaced) and Option
    /// resizes the selection from its centre, so the tool starts only once
    /// the shortcut's keys are released.
    nonisolated(unsafe) static var modifiersHeld: @Sendable () async -> Bool = {
        await MainActor.run {
            !NSEvent.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
        }
    }

    /// Waits (up to `limit`) for the hotkey's modifiers to be released.
    static func waitForModifierRelease(limit: Duration = .milliseconds(1500)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while await modifiersHeld(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Where captures are written before they are filed (removed afterwards).
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SparkV-QuickCapture", isDirectory: true)
    }

    /// Arguments for an interactive capture to `url` (PNG, no window shadow).
    static func arguments(for url: URL) -> [String] {
        ["-i", "-o", "-t", "png", url.path]
    }

    /// File name like the system's ("Screenshot 2026-10-20 at 09.30.00.png"),
    /// so the store's screenshot heuristics recognise it.
    static func fileName(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).png"
    }

    static func capture() async -> Outcome {
        guard await hasPermission() else { return .needsPermission }
        let directory = folder
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failed("Couldn't prepare a temporary folder")
        }
        let url = directory.appendingPathComponent(fileName())
        try? FileManager.default.removeItem(at: url)
        await waitForModifierRelease()
        let status = await runTool(arguments(for: url))
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0 { return .captured(url) }
        if status == 0 || status == 1 { return .cancelled }
        return .failed("Screenshot tool exited with \(status)")
    }

    /// Removes a temporary capture (only files inside `folder`).
    static func discard(_ url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
