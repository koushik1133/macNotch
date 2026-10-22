import AppKit
import AVFoundation
import Carbon.HIToolbox
import CoreGraphics

// Screen recording: what to record, the user's options, the stream plan
// (pure, unit-tested) and where the finished file goes.

// MARK: - Target

/// What a recording captures.
enum ScreenRecorderTarget: Equatable, Sendable {
    /// A whole display.
    case display(ScreenRegionDisplay)
    /// A dragged rectangle, AppKit global points, inside `display`.
    case region(CGRect, ScreenRegionDisplay)
    /// One window (followed if it moves; other windows never show).
    case window(id: UInt32, frame: CGRect, display: ScreenRegionDisplay, appName: String?, title: String?)

    /// The overlay reports Return ("whole display") as a region equal to the
    /// display's frame.
    init(selection: ScreenRegionSelection) {
        switch selection {
        case .region(let rect, let display):
            let full = display.frame
            if abs(rect.minX - full.minX) < 1, abs(rect.minY - full.minY) < 1,
               abs(rect.width - full.width) < 1, abs(rect.height - full.height) < 1 {
                self = .display(display)
            } else {
                self = .region(rect, display)
            }
        case .window(let id, let frame, let display, let appName, let title):
            self = .window(id: id, frame: frame, display: display, appName: appName, title: title)
        }
    }

    var display: ScreenRegionDisplay {
        switch self {
        case .display(let display), .region(_, let display): display
        case .window(_, _, let display, _, _): display
        }
    }

    /// AppKit global rect of the recorded area (window: where it was at start).
    var appKitRect: CGRect {
        switch self {
        case .display(let display): display.frame
        case .region(let rect, _): rect
        case .window(_, let frame, _, _, _): frame
        }
    }

    /// "Full screen", "Area 640 × 360", "Safari window".
    var label: String {
        switch self {
        case .display: "Full screen"
        case .region(let rect, _): "Area \(ScreenRegionGeometry.badgeText(for: rect))"
        case .window(_, _, _, let appName, _): appName.map { "\($0) window" } ?? "Window"
        }
    }
}

// MARK: - Options

enum ScreenRecorderFormat: String, CaseIterable, Sendable {
    case mov, mp4

    var fileExtension: String { rawValue }
    var fileType: AVFileType { self == .mov ? .mov : .mp4 }
    var title: String { self == .mov ? "QuickTime Movie (.mov)" : "MPEG-4 (.mp4)" }
}

/// Recording options, saved under `screenRecorder.*` in UserDefaults.
@MainActor
final class ScreenRecorderSettings: ObservableObject {
    /// ⌃⌥⇧R (⌃⌥R belongs to Reply Drafter).
    static let defaultShortcut = ScreenRegionShortcut(
        keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey | shiftKey)
    )

    @Published var recordsMicrophone: Bool { didSet { defaults.set(recordsMicrophone, forKey: Keys.microphone) } }
    @Published var recordsSystemAudio: Bool { didSet { defaults.set(recordsSystemAudio, forKey: Keys.systemAudio) } }
    @Published var showsCursor: Bool { didSet { defaults.set(showsCursor, forKey: Keys.cursor) } }
    @Published var highlightsClicks: Bool { didSet { defaults.set(highlightsClicks, forKey: Keys.clicks) } }
    @Published var format: ScreenRecorderFormat { didSet { defaults.set(format.rawValue, forKey: Keys.format) } }
    /// 30 or 60.
    @Published var framesPerSecond: Int { didSet { defaults.set(framesPerSecond, forKey: Keys.fps) } }
    @Published private(set) var shortcut: ScreenRegionShortcut

    private let defaults: UserDefaults

    enum Keys {
        static let microphone = "screenRecorder.microphone"
        static let systemAudio = "screenRecorder.systemAudio"
        static let cursor = "screenRecorder.showsCursor"
        static let clicks = "screenRecorder.highlightsClicks"
        static let format = "screenRecorder.format"
        static let fps = "screenRecorder.fps"
        static let shortcut = "screenRecorder.shortcut"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recordsMicrophone = defaults.object(forKey: Keys.microphone) as? Bool ?? false
        recordsSystemAudio = defaults.object(forKey: Keys.systemAudio) as? Bool ?? true
        showsCursor = defaults.object(forKey: Keys.cursor) as? Bool ?? true
        highlightsClicks = defaults.object(forKey: Keys.clicks) as? Bool ?? true
        format = defaults.string(forKey: Keys.format).flatMap(ScreenRecorderFormat.init(rawValue:)) ?? .mov
        let fps = defaults.integer(forKey: Keys.fps)
        framesPerSecond = fps == 30 || fps == 60 ? fps : 60
        if let data = defaults.data(forKey: Keys.shortcut),
           let saved = try? JSONDecoder().decode(ScreenRegionShortcut.self, from: data), saved.isValidGlobal {
            shortcut = saved
        } else {
            shortcut = Self.defaultShortcut
        }
    }

    func save(shortcut newValue: ScreenRegionShortcut) {
        shortcut = newValue
        if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Keys.shortcut) }
    }

    var options: ScreenRecorderOptions {
        ScreenRecorderOptions(
            recordsMicrophone: recordsMicrophone, recordsSystemAudio: recordsSystemAudio,
            showsCursor: showsCursor, highlightsClicks: highlightsClicks,
            format: format, framesPerSecond: framesPerSecond
        )
    }
}

/// A snapshot of the settings for one recording.
struct ScreenRecorderOptions: Equatable, Sendable {
    var recordsMicrophone = false
    var recordsSystemAudio = true
    var showsCursor = true
    var highlightsClicks = true
    var format: ScreenRecorderFormat = .mov
    var framesPerSecond = 60
}

// MARK: - Plan (pure)

/// Everything the stream configuration needs, computed without ScreenCaptureKit.
struct ScreenRecorderPlan: Equatable, Sendable {
    enum Codec: String, Sendable { case h264, hevc }

    /// Display-local points, top-left origin (`SCStreamConfiguration.sourceRect`);
    /// nil records the whole display or window.
    var sourceRect: CGRect?
    /// Output pixels (even numbers, as video encoders want).
    var width: Int
    var height: Int
    var codec: Codec
    var options: ScreenRecorderOptions

    /// H.264's largest frame side on Apple's encoders; larger output uses HEVC.
    static let h264MaxSide = 4096
    /// HEVC's limit; larger output is scaled down.
    static let hevcMaxSide = 8192

    /// `windowPointSize` is the window's content size (window targets only).
    static func make(target: ScreenRecorderTarget, scale: CGFloat, windowPointSize: CGSize? = nil,
                     options: ScreenRecorderOptions, hevcAvailable: Bool = true) -> ScreenRecorderPlan {
        let pointSize: CGSize
        var source: CGRect?
        switch target {
        case .display(let display):
            pointSize = display.frame.size
        case .region(let rect, let display):
            let local = ScreenRegionGeometry.sourceRect(forAppKit: rect, displayFrame: display.frame)
            let snapped = ScreenRegionGeometry.integralOutward(local).intersection(CGRect(origin: .zero, size: display.frame.size))
            source = snapped
            pointSize = snapped.size
        case .window(_, let frame, _, _, _):
            pointSize = windowPointSize ?? frame.size
        }
        var pixelW = max(2, pointSize.width * max(1, scale))
        var pixelH = max(2, pointSize.height * max(1, scale))
        var codec: Codec = .h264
        let longSide = max(pixelW, pixelH)
        if longSide > CGFloat(h264MaxSide) {
            if hevcAvailable {
                codec = .hevc
                if longSide > CGFloat(hevcMaxSide) {
                    let factor = CGFloat(hevcMaxSide) / longSide
                    pixelW *= factor
                    pixelH *= factor
                }
            } else {
                let factor = CGFloat(h264MaxSide) / longSide
                pixelW *= factor
                pixelH *= factor
            }
        }
        return ScreenRecorderPlan(
            sourceRect: source, width: even(pixelW), height: even(pixelH), codec: codec, options: options
        )
    }

    static func even(_ value: CGFloat) -> Int {
        let rounded = Int(value.rounded(.down))
        return max(2, rounded - rounded % 2)
    }
}

// MARK: - Recording

/// A finished recording.
struct ScreenRecording: Equatable, Identifiable {
    var url: URL
    var duration: TimeInterval
    var byteCount: Int64
    var date: Date
    var targetLabel: String

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// "0:42", "1:05:09".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    var durationText: String { Self.durationText(duration) }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
    /// "0:42 · 12.3 MB".
    var summary: String { "\(durationText) · \(sizeText)" }
}

// MARK: - Files

enum ScreenRecorderFiles {
    /// Recordings are written here first, then moved to the destination.
    nonisolated(unsafe) static var tempFolder: URL =
        FileManager.default.temporaryDirectory.appendingPathComponent("SparkV-Recordings", isDirectory: true)

    static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Used when the Desktop can't be written (e.g. Files & Folders access denied).
    static var fallback: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent("SparkV Recordings", isDirectory: true)
    }

    /// "SparkV Recording 2026-10-21 at 14.03.22", in the style of macOS's
    /// own "Screen Recording … at …" names (colons are not allowed in Finder).
    static func baseName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "SparkV Recording \(formatter.string(from: date))"
    }

    /// `folder/base.ext`, or `base 2.ext`, `base 3.ext`… if taken.
    static func uniqueURL(in folder: URL, base: String, fileExtension: String, fileManager: FileManager = .default) -> URL {
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }

    static func newTempURL(fileExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        return tempFolder.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
    }

    /// Moves a finished temp file to the first folder that accepts it.
    /// Blocking (the first Desktop write may wait on a privacy prompt), so
    /// call it off the main thread.
    nonisolated static func move(_ temp: URL, named base: String, to folders: [URL], fileManager: FileManager = .default) throws -> URL {
        var lastError: Error = CocoaError(.fileNoSuchFile)
        for folder in folders {
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = uniqueURL(in: folder, base: base, fileExtension: temp.pathExtension, fileManager: fileManager)
                try fileManager.moveItem(at: temp, to: target)
                return target
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

}
