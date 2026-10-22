import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Screenshot to clipboard: when on, every new screenshot macOS saves is
/// also put on the clipboard as an image (the file stays where it is), with
/// a small "Copied screenshot" band — CleanShot's "copy and save" after
/// capture, done without touching the system's screenshot settings.
///
/// The folder is the `com.apple.screencapture` location, read the way
/// Spaces reads it. Watching a privacy-protected folder (the Desktop by
/// default) needs the user's go-ahead first, the same rule as Spaces:
/// turning the toggle on by hand is that go-ahead; nothing prompts at launch.
@MainActor
final class ScreenshotClipboardController: ObservableObject {
    enum Keys {
        static let enabled = "QuickCapture.screenshotClipboard.enabled"
        static let consent = "QuickCapture.screenshotClipboard.consent"
        /// Code signature the consent was given under. macOS keeps the
        /// Files & Folders grant per signature: after a re-sign or move the
        /// first read would prompt again, so launch waits for a new go-ahead.
        static let consentSignature = "QuickCapture.screenshotClipboard.consentSignature"
        static let showsBand = "QuickCapture.screenshotClipboard.showsBand"
    }

    static let activityID = "quickcapture.screenshot"
    /// Pasteboard type other clipboard tools read to know who wrote it.
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    @Published private(set) var isEnabled: Bool
    @Published var showsBand: Bool { didSet { defaults.set(showsBand, forKey: Keys.showsBand) } }
    @Published private(set) var folder: URL
    @Published private(set) var isWatching = false
    /// On, but the folder is protected and the user hasn't said go yet.
    @Published private(set) var needsConsent = false
    @Published private(set) var copiedCount = 0
    @Published private(set) var lastCopied: URL?

    let activities: ActivityCenter
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    /// Seam for tests: the screenshot location (folder, custom prefix, extension).
    var locationProvider: () -> (folder: URL, prefix: String?, fileExtension: String) = {
        SpaceConnectors.ScreenshotLocation.current()
    }
    /// Seam for tests: whether a folder is behind the Files & Folders prompt.
    var isProtected: (URL) -> Bool = { SpaceConnectors.ScreenshotLocation.isPrivacyProtected($0) }
    /// Seam for tests: the running build's code signature.
    var signature: () -> String = { PermissionSignature.current }

    private var isRunning = false
    private var watcher: SpaceDirectoryWatcher?
    private var prefix: String?
    private var fileExtension = "png"
    private var seen: Set<String> = []
    private var refreshTask: Task<Void, Never>?
    /// Keeps the lazy TIFF provider alive while its item is on the pasteboard.
    private var provider: ScreenshotClipboardTIFFProvider?

    init(activities: ActivityCenter, defaults: UserDefaults = .standard, pasteboard: NSPasteboard = .general) {
        self.activities = activities
        self.defaults = defaults
        self.pasteboard = pasteboard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        showsBand = defaults.object(forKey: Keys.showsBand) as? Bool ?? true
        folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        updateWatcher()
        // The location can change in the Screenshot app's Options menu.
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.updateWatcher()
            }
        }
    }

    func stop() {
        isRunning = false
        refreshTask?.cancel()
        refreshTask = nil
        updateWatcher()
    }

    /// The settings toggle. Turning it on by hand is the go-ahead to watch a
    /// protected folder (may show the Files & Folders prompt once).
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Keys.enabled)
        if enabled { giveConsent() }
        updateWatcher()
    }

    /// Explicit go-ahead for a protected folder (e.g. after the location changed).
    func allowWatching() {
        giveConsent()
        updateWatcher()
    }

    private func giveConsent() {
        defaults.set(true, forKey: Keys.consent)
        defaults.set(signature(), forKey: Keys.consentSignature)
    }

    /// Consent given under this build's signature. Consent from before the
    /// signature was recorded is adopted once (same build, same grant).
    private var hasConsent: Bool {
        guard defaults.bool(forKey: Keys.consent) else { return false }
        guard let given = defaults.string(forKey: Keys.consentSignature) else {
            defaults.set(signature(), forKey: Keys.consentSignature)
            return true
        }
        return given == signature()
    }

    func refreshLocation() { updateWatcher() }

    private func updateWatcher() {
        let wanted = isRunning && isEnabled
        let location = locationProvider()
        folder = location.folder
        prefix = location.prefix
        fileExtension = location.fileExtension
        let protected = isProtected(location.folder)
        let consented = hasConsent
        needsConsent = wanted && protected && !consented
        guard wanted, !protected || consented else {
            watcher?.stop()
            watcher = nil
            isWatching = false
            return
        }
        if watcher?.url == location.folder { return }
        watcher?.stop()
        let watcher = SpaceDirectoryWatcher(url: location.folder) { [weak self] urls in
            Task { @MainActor in self?.filesAppeared(urls) }
        }
        watcher.start()
        self.watcher = watcher
        isWatching = true
        AppLog.log("Screenshot clipboard: watching \(location.folder.lastPathComponent)")
    }

    // MARK: - New screenshots

    /// Internal for the tests (the watcher calls it with new paths).
    func filesAppeared(_ urls: [URL]) {
        guard isRunning, isEnabled else { return }
        let prefix = prefix
        let fileExtension = fileExtension
        for url in urls where !seen.contains(url.path) {
            let name = url.lastPathComponent
            // macOS writes ".Screenshot …" first and renames it when done.
            guard !name.hasPrefix(".") else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "bmp"].contains(ext) else { continue }
            let byName = SpaceConnectors.ScreenshotLocation.isScreenshotName(name, customPrefix: prefix, fileExtension: fileExtension)
            seen.insert(url.path)
            Task { [weak self] in
                // The watcher only reports names it hadn't listed, so `seen`
                // just guards the stabilising wait; a file later deleted and
                // re-created under the same name (e.g. "Screenshot.png" with
                // dates off) is copied again.
                defer { self?.seen.remove(url.path) }
                guard await SpaceIngestCenter.waitUntilStable(url, timeout: 10) else { return }
                guard byName || SpaceConnectors.ScreenshotLocation.hasScreenCaptureAttribute(url) else { return }
                // Only screenshots taken just now: an old "Screenshot …" file
                // moved or copied into the folder must not replace the clipboard.
                guard Self.isFresh(url) else { return }
                self?.copy(url)
            }
        }
    }

    /// Puts the image on the pasteboard: PNG right away (the file's own bytes
    /// when it is a PNG), TIFF on demand for older apps.
    @discardableResult
    func copy(_ url: URL) -> Bool {
        guard let png = Self.pngData(for: url) else {
            AppLog.log("Screenshot clipboard: couldn't read \(url.lastPathComponent)")
            return false
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = ScreenshotClipboardTIFFProvider(png: png)
        item.setDataProvider(provider, forTypes: [.tiff])
        if let id = Bundle.main.bundleIdentifier { item.setString(id, forType: Self.sourceType) }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        self.provider = provider
        copiedCount += 1
        lastCopied = url
        if showsBand { postBand(for: url) }
        return true
    }

    /// How old (by creation date) a file may be and still count as a new
    /// screenshot. macOS creates the file when it writes it, up to ~5 s after
    /// the capture with the floating thumbnail on; Finder moves and copies
    /// keep the original creation date.
    nonisolated static let freshness: TimeInterval = 120

    nonisolated static func isFresh(_ url: URL, now: Date = Date()) -> Bool {
        guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { return false }
        return now.timeIntervalSince(created) <= freshness
    }

    nonisolated static func pngData(for url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }
        if url.pathExtension.lowercased() == "png", data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }

    private func postBand(for url: URL) {
        let thumbnail = TrayAIOCR.loadImage(at: url, maxPixel: 96).map { NSImage(cgImage: $0, size: .zero) }
        activities.post(LiveActivity(id: Self.activityID, kind: .notification, priority: 46, duration: 2.5) {
            ScreenshotClipboardBandView(thumbnail: thumbnail)
        })
    }
}

/// Supplies TIFF only when an app asks for it (a Retina TIFF is large).
final class ScreenshotClipboardTIFFProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let png: Data

    init(png: Data) { self.png = png }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let image = NSImage(data: png), let tiff = image.tiffRepresentation else { return }
        item.setData(tiff, forType: .tiff)
    }
}

/// Band under the notch: thumbnail, "Copied screenshot", "paste anywhere".
struct ScreenshotClipboardBandView: View {
    let thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                }
            }
            .frame(width: 22, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
            Text("Copied screenshot")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
            Text("· paste anywhere")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.success)
        }
        .padding(.horizontal, 16)
    }
}
