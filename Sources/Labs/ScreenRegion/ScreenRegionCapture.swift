import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One captured selection, ready for the results panel.
struct ScreenRegionCaptureResult: @unchecked Sendable {
    let image: CGImage
    /// PNG of `image` in the feature's temp folder (deleted with the panel).
    let fileURL: URL
    let selection: ScreenRegionSelection
    /// The app in front when the selection began (not SparkV).
    let appName: String?
    let windowTitle: String?

    var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
}

/// Screen Recording checks, display/window lists and the actual capture.
@MainActor
enum ScreenRegionCapture {
    enum Failure: LocalizedError, Equatable {
        case permissionDenied
        case noDisplay
        case windowGone
        case tooSmall
        case encodingFailed
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: "Allow Screen Recording for SparkV in System Settings, then try again"
            case .noDisplay: "Couldn't find that display any more"
            case .windowGone: "That window closed before it could be captured"
            case .tooSmall: "Select a larger area"
            case .encodingFailed: "Couldn't save the capture"
            case .failed(let message): "Screen capture failed: \(message)"
            }
        }
    }

    // MARK: Permission

    /// Seam for tests. Never shows a prompt.
    static var preflight: @MainActor () -> Bool = { PermissionCenter.shared.isGranted(.screenRecording) }

    /// Screen Recording granted. Never shows a prompt.
    static var hasPermission: Bool { preflight() }

    /// Asks for Screen Recording on behalf of `feature`. Call only from an
    /// explicit user action. PermissionCenter shows the system request at
    /// most once per code signature (queued with any other prompt), then
    /// opens System Settings, and offers a restart once it was asked.
    /// `completion` gets whether the grant is active now.
    static func requestPermission(from feature: String, completion: (@MainActor (Bool) -> Void)? = nil) {
        AppLog.log("\(feature): user asked for Screen Recording access")
        Task { @MainActor in
            let granted = await PermissionCenter.shared.ensure(.screenRecording, from: feature)
            completion?(granted)
        }
    }

    static func openScreenRecordingSettings(from feature: String = "Screen Region") {
        PermissionCenter.shared.openSettings(.screenRecording, from: feature)
    }

    /// A request already ran (or Settings opened) this session and the grant
    /// isn't active yet: Screen Recording applies after SparkV restarts.
    static var needsRelaunch: Bool { PermissionCenter.shared.screenRecordingNeedsRelaunch && !hasPermission }

    static func relaunch(from feature: String) {
        PermissionCenter.shared.relaunch(from: feature)
    }

    // MARK: Displays and windows

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func displays() -> [ScreenRegionDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return ScreenRegionDisplay(id: number.uint32Value, frame: screen.frame, scale: screen.backingScaleFactor)
        }
    }

    static func screen(for display: ScreenRegionDisplay) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id }
    }

    /// Normal on-screen windows of other apps, front-to-back, AppKit coordinates.
    /// Window titles are only present with Screen Recording access.
    static func onScreenWindows() -> [ScreenRegionWindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return ScreenRegionGeometry.windows(
            fromWindowList: list,
            primaryHeight: primaryHeight,
            excludingPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    // MARK: Capture

    /// Captures the selection at the display's native pixel density, without
    /// any SparkV window (overlay, notch, panels). Requires permission;
    /// checks it first so ScreenCaptureKit never prompts from here. The
    /// window list comes from PermissionCenter's short-lived cache, so
    /// back-to-back captures don't each count toward macOS 15's "bypass the
    /// private window picker" reminder.
    static func capture(_ selection: ScreenRegionSelection, from feature: String = "Screen Region") async throws -> CGImage {
        guard hasPermission else { throw Failure.permissionDenied }
        var content = try await shareableContent(from: feature)
        // A window or display newer than the cached list: read it once more.
        if !contains(selection, in: content) {
            PermissionCenter.shared.invalidateShareableContent()
            content = try await shareableContent(from: feature)
        }
        let started = Date()
        let image: CGImage
        switch selection {
        case .region(let rect, let display):
            guard ScreenRegionGeometry.isCapturable(rect) else { throw Failure.tooSmall }
            guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { throw Failure.noDisplay }
            let pid = ProcessInfo.processInfo.processIdentifier
            let ownApps = content.applications.filter { $0.processID == pid }
            let filter = SCContentFilter(display: scDisplay, excludingApplications: ownApps, exceptingWindows: [])
            let source = ScreenRegionGeometry.sourceRect(forAppKit: rect, displayFrame: display.frame)
            guard ScreenRegionGeometry.isCapturable(source) else { throw Failure.tooSmall }
            let infoScale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
            let scale = infoScale > 0 ? infoScale : display.scale
            let pixels = ScreenRegionGeometry.outputPixelSize(forSourceRect: source, scale: scale)
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = source
            configuration.width = Int(pixels.width)
            configuration.height = Int(pixels.height)
            configuration.scalesToFit = false
            configuration.showsCursor = false
            configuration.captureResolution = .best
            configuration.colorSpaceName = CGColorSpace.sRGB
            image = try await run { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }

        case .window(let id, _, let display, _, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw Failure.windowGone }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let info = SCShareableContent.info(for: filter)
            let scale = info.pointPixelScale > 0 ? CGFloat(info.pointPixelScale) : display.scale
            let size = info.contentRect.isEmpty ? window.frame.size : info.contentRect.size
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((size.width * scale).rounded()))
            configuration.height = max(1, Int((size.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.captureResolution = .best
            configuration.colorSpaceName = CGColorSpace.sRGB
            image = try await run { try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) }
        }
        AppLog.log("Screen Region: captured \(image.width)x\(image.height) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return image
    }

    private static func shareableContent(from feature: String) async throws -> SCShareableContent {
        do {
            return try await PermissionCenter.shared.shareableContent(from: feature)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLog.log("\(feature): shareable content failed: \(error.localizedDescription)")
            throw Failure.permissionDenied
        }
    }

    private static func contains(_ selection: ScreenRegionSelection, in content: SCShareableContent) -> Bool {
        switch selection {
        case .region(_, let display): content.displays.contains { $0.displayID == display.id }
        case .window(let id, _, _, _, _): content.windows.contains { $0.windowID == id }
        }
    }

    private static func run(_ body: () async throws -> CGImage) async throws -> CGImage {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.failed(error.localizedDescription)
        }
    }
}

// MARK: - Files

/// PNG files for captures: `$TMPDIR/SparkV-ScreenRegion/`.
enum ScreenRegionFiles {
    /// Set once at launch; tests point it at their own folder.
    nonisolated(unsafe) static var folder: URL =
        FileManager.default.temporaryDirectory.appendingPathComponent("SparkV-ScreenRegion", isDirectory: true)

    nonisolated static func writePNG(_ image: CGImage, name: String = UUID().uuidString) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name).appendingPathExtension("png")
        guard let data = pngData(image) else { throw ScreenRegionCapture.Failure.encodingFailed }
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated static func remove(_ url: URL?) {
        guard let url, url.path.hasPrefix(folder.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes every capture (start/stop) or those older than `age` seconds.
    nonisolated static func sweep(olderThan age: TimeInterval = 0) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for file in files {
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if age == 0 || date < cutoff { try? fm.removeItem(at: file) }
        }
    }

    /// Crops a full-display image to an AppKit rect (fallback path and tests).
    nonisolated static func crop(_ image: CGImage, toAppKit rect: CGRect, displayFrame: CGRect) -> CGImage? {
        let source = ScreenRegionGeometry.sourceRect(forAppKit: rect, displayFrame: displayFrame)
        let pixels = ScreenRegionGeometry.pixelRect(
            forSourceRect: source,
            displayPointSize: displayFrame.size,
            imagePixelSize: CGSize(width: image.width, height: image.height)
        )
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }
        return image.cropping(to: pixels)
    }

    /// Downscaled copy for model input.
    nonisolated static func downscaled(_ image: CGImage, maxLongEdge: CGFloat) -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let target = ScreenRegionGeometry.fitted(size, maxLongEdge: maxLongEdge)
        guard target != size,
              let context = CGContext(
                data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: target))
        return context.makeImage() ?? image
    }
}
