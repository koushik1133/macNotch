import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// "Black Menu Bar": hides the notch by giving the wallpaper a black band
/// as tall as the menu bar, so the camera cutout disappears into it and
/// macOS draws white menu bar text over it (an overlay window behind the
/// menu bar couldn't flip the text colour).
///
/// Off until the user turns it on (it changes the wallpaper, a visible
/// system change). For each notched display it composites a copy of the
/// current picture off the main thread, saves it under Application
/// Support/SparkV/HideNotch and sets it; the original is remembered in
/// UserDefaults first, so turning it off, quitting, or the next launch
/// puts it back. macOS sets a wallpaper per Space, so it re-applies when
/// the Space changes. Live wallpapers (Aerial) are left alone; a dynamic
/// one becomes its main still while the band is on. While a Mode that sets
/// the wallpaper is on, it steps aside.
@MainActor
final class IslandBlackMenuBar: ObservableObject {
    static let shared = IslandBlackMenuBar()

    enum Status: Equatable {
        case off
        case working
        case on(displays: Int)
        case skipped(String)
        case failed(String)

        var text: String {
            switch self {
            case .off: "Off"
            case .working: "Updating the wallpaper…"
            case .on(let count): count == 1 ? "On for the built-in display" : "On for \(count) displays"
            case .skipped(let why): why
            case .failed(let why): why
            }
        }
    }

    @Published private(set) var status: Status = .off

    /// What a generated picture replaced.
    struct Original: Codable, Equatable, Sendable {
        var path: String
        var scaling: UInt?
        var allowClipping: Bool?
        var fillColorHex: String?
        /// When the record was made (seconds since 1970; nil in records
        /// saved before this field existed, which count as oldest).
        var savedAt: Double?
    }

    /// Records kept for Spaces SparkV hasn't visited again yet.
    static let recordLimit = 64

    static let originalsKey = IslandPlacementSettings.Key.prefix + "blackBar.originals"

    private let settings: IslandPlacementSettings
    private let defaults: UserDefaults
    /// Generated path → the wallpaper it replaced.
    private var originals: [String: Original]
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var settingObserver: AnyCancellable?
    private var work: Task<Void, Never>?
    private var started = false

    init(settings: IslandPlacementSettings? = nil, defaults: UserDefaults = .standard) {
        self.settings = settings ?? .shared
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.originalsKey),
           let saved = try? JSONDecoder().decode([String: Original].self, from: data) {
            originals = saved
        } else {
            originals = [:]
        }
    }

    static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("SparkV/HideNotch", isDirectory: true)
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        // Wallpapers are per Space; System Settings is where a new one is picked.
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification)
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification)
        let token = workspace.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard bundleID == "com.apple.systempreferences" || bundleID == "com.apple.Settings" else { return }
                self?.refresh()
            }
        }
        observers.append((workspace, token))
        settingObserver = settings.$blackMenuBar.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    /// Quit: the current Space gets its own wallpaper back. Other Spaces
    /// are put back the next time SparkV runs and visits them.
    func stop() {
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        settingObserver = nil
        work?.cancel()
        work = nil
        restoreCurrentSpace()
        started = false
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observers.append((center, token))
    }

    func refresh() {
        if settings.blackMenuBar {
            apply()
        } else {
            if !originals.isEmpty {
                restoreCurrentSpace()
                saveOriginals()
            }
            status = .off
        }
    }

    // MARK: Applying

    private func isOurs(_ url: URL) -> Bool {
        guard let directory = Self.directory else { return false }
        return url.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path)
    }

    private var modeOwnsWallpaper: Bool {
        guard let mode = ModeEngine.shared.activeMode else { return false }
        return mode.actions.contains { if case .wallpaper = $0 { true } else { false } }
    }

    private func apply() {
        guard let directory = Self.directory else {
            status = .failed("Couldn’t find Application Support")
            return
        }
        if modeOwnsWallpaper {
            status = .skipped("Paused while “\(ModeEngine.shared.activeMode?.name ?? "a mode")” sets the wallpaper")
            return
        }
        let screens = NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
        guard !screens.isEmpty else {
            status = .skipped("No display with a notch is connected")
            return
        }
        var jobs: [Job] = []
        var applied = 0
        var skipped: String?
        for screen in screens {
            guard let id = IslandDisplays.displayID(of: screen), let url = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            if isOurs(url) { applied += 1; continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                  IslandBlackBarGeometry.canComposite(pathExtension: url.pathExtension) else {
                skipped = "Live wallpapers can’t get a black band: pick a still picture"
                continue
            }
            let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
            let original = Original(
                path: url.path,
                scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
                allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                fillColorHex: (options[.fillColor] as? NSColor).flatMap(Self.hex)
            )
            let scale = screen.backingScaleFactor
            let pixels = CGSize(width: (screen.frame.width * scale).rounded(), height: (screen.frame.height * scale).rounded())
            let band = IslandBlackBarGeometry.bandPixels(
                safeAreaTop: screen.safeAreaInsets.top,
                menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
                scale: scale
            )
            jobs.append(Job(displayID: id, original: original, pixels: pixels, band: band, directory: directory))
        }
        guard !jobs.isEmpty else {
            status = applied > 0 ? .on(displays: applied) : .skipped(skipped ?? "Nothing to change")
            return
        }
        status = .working
        work?.cancel()
        work = Task { [weak self] in
            var done = applied
            var failure: String?
            for job in jobs {
                let result = await Task.detached(priority: .utility) { Self.composite(job) }.value
                guard !Task.isCancelled, let self else { return }
                switch result {
                case .success(let url):
                    guard self.settings.blackMenuBar, let screen = IslandDisplays.screen(for: job.displayID) else { continue }
                    do {
                        // Remember the original before changing anything.
                        var record = job.original
                        record.savedAt = Date().timeIntervalSince1970
                        self.originals[url.path] = record
                        self.saveOriginals()
                        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                            .imageScaling: NSNumber(value: NSImageScaling.scaleAxesIndependently.rawValue),
                            .allowClipping: NSNumber(value: true),
                        ])
                        done += 1
                    } catch {
                        failure = "macOS didn’t accept the wallpaper (\(error.localizedDescription))"
                    }
                case .failure(let message):
                    failure = message
                }
            }
            if let failure {
                AppLog.log("Island: black menu bar: \(failure)")
                self?.status = done > 0 ? .on(displays: done) : .failed(failure)
            } else {
                self?.status = .on(displays: done)
            }
        }
    }

    // MARK: Restoring

    /// Puts back the original on every screen of the current Space that
    /// shows a generated picture.
    func restoreCurrentSpace() {
        for screen in NSScreen.screens {
            guard let url = NSWorkspace.shared.desktopImageURL(for: screen), isOurs(url) else { continue }
            guard let original = originals[url.path] ?? originals[url.standardizedFileURL.path] else {
                AppLog.log("Island: black menu bar: no record of the original for \(url.lastPathComponent)")
                continue
            }
            guard FileManager.default.fileExists(atPath: original.path) else {
                AppLog.log("Island: black menu bar: original wallpaper \(original.path) is gone")
                continue
            }
            var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
            if let scaling = original.scaling { options[.imageScaling] = NSNumber(value: scaling) }
            if let clipping = original.allowClipping { options[.allowClipping] = NSNumber(value: clipping) }
            if let hex = original.fillColorHex, let color = Self.color(hex) { options[.fillColor] = color }
            do {
                try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: original.path), for: screen, options: options)
            } catch {
                AppLog.log("Island: black menu bar: couldn’t restore the wallpaper (\(error.localizedDescription))")
            }
        }
    }

    /// Generated pictures the current Space shows right now.
    private var picturesInUse: Set<String> {
        Set(NSScreen.screens.compactMap { NSWorkspace.shared.desktopImageURL(for: $0) }.filter(isOurs).map(\.path))
    }

    private func saveOriginals() {
        // Keep the newest records by age, never one the current Space
        // still shows; old Spaces' pictures stay restorable.
        let keep = IslandBlackBarRecords.kept(savedAt: originals.mapValues { $0.savedAt ?? 0 },
                                              limit: Self.recordLimit, inUse: picturesInUse)
        if keep.count < originals.count { originals = originals.filter { keep.contains($0.key) } }
        if let data = try? JSONEncoder().encode(originals) { defaults.set(data, forKey: Self.originalsKey) }
        removeUnusedPictures()
    }

    /// Generated pictures no record points at and no screen shows (an older
    /// resolution or band height) go, off the main thread.
    private func removeUnusedPictures() {
        guard let directory = Self.directory else { return }
        let keep = Set(originals.keys).union(picturesInUse)
        Task.detached(priority: .background) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let paths = files.filter { $0.hasPrefix("blackbar-") }.map { directory.appendingPathComponent($0).path }
            for path in IslandBlackBarRecords.unusedPictures(paths, keep: keep) {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    // MARK: Compositing (off the main thread)

    struct Job: Sendable {
        var displayID: CGDirectDisplayID
        var original: Original
        var pixels: CGSize
        var band: Int
        var directory: URL
    }

    enum Result: Sendable {
        case success(URL)
        case failure(String)
    }

    nonisolated static func composite(_ job: Job) -> Result {
        let source = URL(fileURLWithPath: job.original.path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path)
        let stamp = [
            job.original.path, "\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
            "\(attributes?[.size] as? Int ?? 0)", "\(Int(job.pixels.width))x\(Int(job.pixels.height))",
            "\(job.band)", "\(job.original.scaling ?? 99)", "\(job.original.allowClipping ?? true)", job.original.fillColorHex ?? "",
        ].joined(separator: "|")
        let output = job.directory.appendingPathComponent("blackbar-\(fnv1a(stamp)).heic")
        if FileManager.default.fileExists(atPath: output.path) { return .success(output) }

        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, CGImageSourceGetPrimaryImageIndex(imageSource), nil) else {
            return .failure("Couldn’t read the wallpaper picture")
        }
        let width = Int(job.pixels.width), height = Int(job.pixels.height)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space.model == .rgb ? space : CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .failure("Couldn’t prepare the picture")
        }
        context.interpolationQuality = .high
        let fill = job.original.fillColorHex.flatMap(rgb) ?? (0, 0, 0)
        context.setFillColor(red: fill.0, green: fill.1, blue: fill.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let rect = IslandBlackBarGeometry.drawRect(
            image: CGSize(width: image.width, height: image.height),
            canvas: job.pixels,
            scaling: job.original.scaling,
            allowClipping: job.original.allowClipping
        )
        context.draw(image, in: rect)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height - job.band, width: width, height: job.band))
        guard let result = context.makeImage() else { return .failure("Couldn’t draw the picture") }

        do {
            try FileManager.default.createDirectory(at: job.directory, withIntermediateDirectories: true)
        } catch {
            return .failure("Couldn’t create the HideNotch folder")
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            return .failure("Couldn’t save the picture")
        }
        CGImageDestinationAddImage(destination, result, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return .failure("Couldn’t save the picture") }
        return .success(output)
    }

    nonisolated static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    nonisolated static func rgb(_ hex: String) -> (CGFloat, CGFloat, CGFloat)? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (CGFloat((value >> 16) & 0xff) / 255, CGFloat((value >> 8) & 0xff) / 255, CGFloat(value & 0xff) / 255)
    }

    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }

    static func color(_ hex: String) -> NSColor? {
        guard let (r, g, b) = rgb(hex) else { return nil }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
