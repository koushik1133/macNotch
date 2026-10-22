import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// Wallpapers for SparkV Modes.
//
// macOS only takes image files as wallpapers (NSWorkspace.setDesktopImageURL),
// so a solid colour or gradient is rendered once as a PNG at the screen's
// native pixel size and cached by a hash of what it shows. The same approach
// as Apple's own "Colors" wallpapers and the Shortcuts "Set Wallpaper" action:
// an exact-size image, set with clipping allowed, so nothing is scaled.
//
// Everything here is thread-safe (CoreGraphics + ImageIO only), so the engine
// can render a 6K wallpaper off the main thread.

// MARK: - Errors

enum ModeWallpaperError: LocalizedError, Equatable, Sendable {
    case invalidColor(String)
    case unknownPreset(String)
    case emptyPath
    case relativePath(String)
    case fileNotFound(String)
    case notAFile(String)
    case notAnImage(String)
    case unreadable(String)
    case invalidSize
    case renderFailed
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidColor(let hex): "\"\(hex)\" isn't a colour. Use a hex value like #0B1A33."
        case .unknownPreset(let id): "SparkV has no wallpaper preset called \"\(id)\"."
        case .emptyPath: "Choose an image for the wallpaper."
        case .relativePath(let path): "\(path) isn't a full path to an image."
        case .fileNotFound(let path): "The wallpaper image \(Self.name(path)) is missing. It may have been moved or deleted."
        case .notAFile(let path): "\(Self.name(path)) is a folder, not an image."
        case .notAnImage(let path): "\(Self.name(path)) isn't an image macOS can use as a wallpaper."
        case .unreadable(let path): "SparkV can't read \(Self.name(path)). Check its permissions."
        case .invalidSize: "The screen size is not valid."
        case .renderFailed: "SparkV couldn't draw the wallpaper."
        case .writeFailed(let reason): "SparkV couldn't save the wallpaper: \(reason)"
        }
    }

    private static func name(_ path: String) -> String {
        let last = URL(fileURLWithPath: path).lastPathComponent
        return last.isEmpty ? path : last
    }
}

// MARK: - Colour

/// An opaque sRGB colour parsed from "#RGB", "#RRGGBB" or "#RRGGBBAA"
/// (alpha is ignored: wallpapers are opaque).
struct ModeRGBColor: Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.lowercased().hasPrefix("0x") { text.removeFirst(2) }
        guard text.allSatisfy(\.isHexDigit) else { return nil }
        switch text.count {
        case 3:
            text = text.map { "\($0)\($0)" }.joined()
        case 6:
            break
        case 8:
            text = String(text.prefix(6))
        default:
            return nil
        }
        guard let value = UInt32(text, radix: 16) else { return nil }
        red = UInt8((value >> 16) & 0xFF)
        green = UInt8((value >> 8) & 0xFF)
        blue = UInt8(value & 0xFF)
    }

    /// "#RRGGBB", upper case.
    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }

    static func parse(_ hex: String) throws -> ModeRGBColor {
        guard let color = ModeRGBColor(hex: hex) else { throw ModeWallpaperError.invalidColor(hex) }
        return color
    }
}

// MARK: - Presets

struct ModeWallpaperPreset: Identifiable, Hashable, Sendable {
    /// Stable id stored in `ModeWallpaperChoice.builtIn(id)`.
    let id: String
    let name: String
    /// SF Symbol for pickers.
    let symbol: String
    /// What it draws: always `.solid` or `.gradient`.
    let rendering: ModeWallpaperChoice

    var choice: ModeWallpaperChoice { .builtIn(id) }
}

// MARK: - Factory

enum ModeWallpaperFactory {
    // Preset ids. The engine's built-in modes use these.
    static let pureBlackID = "black"
    static let deepNavyID = "navy"
    static let forestID = "forest"
    static let warmSunsetID = "sunset"
    static let minimalGreyID = "grey"

    static let presets: [ModeWallpaperPreset] = [
        ModeWallpaperPreset(id: pureBlackID, name: "Pure Black", symbol: "moon.fill",
                            rendering: .solid(colorHex: "#000000")),
        ModeWallpaperPreset(id: deepNavyID, name: "Deep Navy", symbol: "drop.fill",
                            rendering: .solid(colorHex: "#0B1A33")),
        ModeWallpaperPreset(id: forestID, name: "Forest", symbol: "leaf.fill",
                            rendering: .gradient(fromHex: "#16302B", toHex: "#08140F")),
        ModeWallpaperPreset(id: warmSunsetID, name: "Warm Sunset", symbol: "sun.horizon.fill",
                            rendering: .gradient(fromHex: "#FF7E5F", toHex: "#FEB47B")),
        ModeWallpaperPreset(id: minimalGreyID, name: "Minimal Grey", symbol: "square.fill",
                            rendering: .solid(colorHex: "#3A3A3C")),
    ]

    /// Finds a preset by id, forgiving case, spaces and old names
    /// ("Pure Black", "deep-navy", "minimalGray", "warm sunset gradient").
    static func preset(id raw: String) -> ModeWallpaperPreset? {
        let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        let aliases: [String: String] = [
            "black": pureBlackID, "pureblack": pureBlackID,
            "navy": deepNavyID, "deepnavy": deepNavyID,
            "forest": forestID, "forestgreen": forestID,
            "sunset": warmSunsetID, "warmsunset": warmSunsetID, "warmsunsetgradient": warmSunsetID,
            "grey": minimalGreyID, "gray": minimalGreyID, "minimalgrey": minimalGreyID, "minimalgray": minimalGreyID,
        ]
        guard let id = aliases[key] else { return nil }
        return presets.first { $0.id == id }
    }

    /// A friendly name for pickers and the activity band.
    static func title(for choice: ModeWallpaperChoice) -> String {
        if case .builtIn(let id) = choice, let preset = preset(id: id) { return preset.name }
        return choice.title
    }

    /// Turns a preset into the solid or gradient it draws; other choices are
    /// returned as they are.
    static func resolved(_ choice: ModeWallpaperChoice) throws -> ModeWallpaperChoice {
        guard case .builtIn(let id) = choice else { return choice }
        guard let preset = preset(id: id) else { throw ModeWallpaperError.unknownPreset(id) }
        return preset.rendering
    }

    /// ~/Library/Application Support/SparkV/Modes/Wallpapers
    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SparkV/Modes/Wallpapers", isDirectory: true)
    }

    /// The image file to pass to `NSWorkspace.setDesktopImageURL` for a
    /// screen of `size` pixels (use `pixelSize(of:)`). Solid colours and
    /// gradients are rendered and cached; a user's file is validated and
    /// returned as is (never copied or changed). Safe off the main thread.
    static func imageURL(for choice: ModeWallpaperChoice, screen size: CGSize) throws -> URL {
        try ModeWallpaperRenderer(directory: defaultDirectory).imageURL(for: choice, pixelSize: size)
    }

    /// Convenience for the main thread: renders at `screen`'s native size.
    @MainActor
    static func imageURL(for choice: ModeWallpaperChoice, screen: NSScreen) throws -> URL {
        try imageURL(for: choice, screen: pixelSize(of: screen))
    }

    /// The screen's backing size in pixels (a Retina 1512×982 point screen
    /// is 3024×1964).
    @MainActor
    static func pixelSize(of screen: NSScreen) -> CGSize {
        let scale = max(screen.backingScaleFactor, 1)
        return CGSize(width: (screen.frame.width * scale).rounded(), height: (screen.frame.height * scale).rounded())
    }

    /// Options for `setDesktopImageURL`: fill the screen, crop rather than
    /// letterbox, and for colours also set the fill colour so the edges never
    /// flash a different colour while the image loads.
    static func desktopOptions(for choice: ModeWallpaperChoice) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        switch (try? resolved(choice)) ?? choice {
        case .solid(let hex):
            if let color = ModeRGBColor(hex: hex) { options[.fillColor] = color.nsColor }
        case .gradient(let from, _):
            if let color = ModeRGBColor(hex: from) { options[.fillColor] = color.nsColor }
        case .file, .builtIn:
            break
        }
        return options
    }

    /// Top and bottom colours, for cheap SwiftUI swatches (nil for a file).
    static func swatchColors(for choice: ModeWallpaperChoice) -> (top: NSColor, bottom: NSColor)? {
        switch (try? resolved(choice)) ?? choice {
        case .solid(let hex):
            guard let color = ModeRGBColor(hex: hex) else { return nil }
            return (color.nsColor, color.nsColor)
        case .gradient(let from, let to):
            guard let top = ModeRGBColor(hex: from), let bottom = ModeRGBColor(hex: to) else { return nil }
            return (top.nsColor, bottom.nsColor)
        case .file, .builtIn:
            return nil
        }
    }

    /// A small in-memory preview (nothing is written to disk). For a file it
    /// is a thumbnail of the image; nil when the choice can't be shown.
    static func previewImage(for choice: ModeWallpaperChoice, size: CGSize = CGSize(width: 160, height: 100)) -> NSImage? {
        guard size.width >= 1, size.height >= 1, size.width.isFinite, size.height.isFinite else { return nil }
        guard let resolved = try? resolved(choice) else { return nil }
        let image: CGImage?
        switch resolved {
        case .file(let path):
            guard let url = try? validateImageFile(path: path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 2),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        default:
            image = try? ModeWallpaperRenderer.render(resolved, width: Int(size.width * 2), height: Int(size.height * 2))
        }
        guard let image else { return nil }
        return NSImage(cgImage: image, size: size)
    }

    /// Checks a user's wallpaper file: an absolute (or ~) path to a readable
    /// regular file that ImageIO can decode. Returns its standardized URL.
    static func validateImageFile(path raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ModeWallpaperError.emptyPath }
        var path = trimmed
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL { path = url.path }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw ModeWallpaperError.relativePath(trimmed) }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ModeWallpaperError.fileNotFound(path)
        }
        guard !isDirectory.boolValue else { throw ModeWallpaperError.notAFile(path) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { throw ModeWallpaperError.unreadable(path) }

        // The extension must be an image type and the bytes must decode.
        if let type = UTType(filenameExtension: url.pathExtension), !type.conforms(to: .image) {
            throw ModeWallpaperError.notAnImage(path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) > 0
        else { throw ModeWallpaperError.notAnImage(path) }
        return url
    }
}

// MARK: - Renderer

/// Renders and caches wallpaper PNGs in one folder. Tests point it at a
/// temporary folder; the app uses `ModeWallpaperFactory.defaultDirectory`.
struct ModeWallpaperRenderer: Sendable {
    /// Bump to re-render every cached file after a drawing change.
    static let renderVersion = 1
    static let filePrefix = "sparkv-wallpaper-"
    /// Largest side we render (6K Pro Display XDR is 6016; leave headroom).
    static let maxSide = 16_384

    let directory: URL

    func imageURL(for choice: ModeWallpaperChoice, pixelSize: CGSize) throws -> URL {
        let resolved = try ModeWallpaperFactory.resolved(choice)
        if case .file(let path) = resolved {
            return try ModeWallpaperFactory.validateImageFile(path: path)
        }
        let (width, height) = try Self.dimensions(pixelSize)
        // Validate colours before touching the disk.
        _ = try Self.colors(for: resolved)

        let url = directory.appendingPathComponent(Self.fileName(for: resolved, width: width, height: height))
        let fileManager = FileManager.default
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 {
            // Mark it recently used so pruning keeps it.
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return url
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ModeWallpaperError.writeFailed(error.localizedDescription)
        }
        let image = try Self.render(resolved, width: width, height: height)
        try Self.writePNG(image, to: url)
        return url
    }

    /// Cached wallpapers this renderer made, newest first.
    func cachedFiles() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return contents
            .filter { $0.lastPathComponent.hasPrefix(Self.filePrefix) && $0.pathExtension == "png" }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Removes old cached wallpapers SparkV rendered, keeping the newest
    /// `keepingNewest` and any in `protecting` (e.g. the current desktop
    /// images and the restore snapshot). Only touches files named
    /// "sparkv-wallpaper-*.png" in this folder. Returns how many it removed.
    @discardableResult
    func pruneCache(keepingNewest: Int = 40, protecting: Set<URL> = []) -> Int {
        let protected = Set(protecting.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        var removed = 0
        for url in cachedFiles().dropFirst(max(keepingNewest, 0)) {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard !protected.contains(path) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: Pieces (internal for tests)

    static func cacheKey(for resolved: ModeWallpaperChoice, width: Int, height: Int) -> String {
        let description: String
        switch resolved {
        case .solid(let hex):
            description = "solid|\(ModeRGBColor(hex: hex)?.hex ?? hex)"
        case .gradient(let from, let to):
            description = "gradient|\(ModeRGBColor(hex: from)?.hex ?? from)|\(ModeRGBColor(hex: to)?.hex ?? to)"
        case .file(let path):
            description = "file|\(path)"
        case .builtIn(let id):
            description = "builtIn|\(id)"
        }
        let input = "v\(renderVersion)|\(description)|\(width)x\(height)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    static func fileName(for resolved: ModeWallpaperChoice, width: Int, height: Int) -> String {
        "\(filePrefix)\(cacheKey(for: resolved, width: width, height: height)).png"
    }

    static func dimensions(_ size: CGSize) throws -> (Int, Int) {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            throw ModeWallpaperError.invalidSize
        }
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        // Keep the aspect ratio if a side is over the limit.
        let scale = min(1, Double(maxSide) / Double(max(width, height)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    static func colors(for resolved: ModeWallpaperChoice) throws -> (top: ModeRGBColor, bottom: ModeRGBColor) {
        switch resolved {
        case .solid(let hex):
            let color = try ModeRGBColor.parse(hex)
            return (color, color)
        case .gradient(let from, let to):
            return (try ModeRGBColor.parse(from), try ModeRGBColor.parse(to))
        case .file, .builtIn:
            throw ModeWallpaperError.renderFailed
        }
    }

    /// Draws a solid colour or a top-to-bottom gradient. Gradients use an
    /// 8×8 ordered dither so dark ramps (navy to black) don't band.
    static func render(_ resolved: ModeWallpaperChoice, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, width <= maxSide, height <= maxSide else { throw ModeWallpaperError.invalidSize }
        let (top, bottom) = try colors(for: resolved)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ),
              let data = context.data
        else { throw ModeWallpaperError.renderFailed }

        let bytesPerRow = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)

        if top == bottom {
            context.setFillColor(top.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            let start = (Double(top.red), Double(top.green), Double(top.blue))
            let end = (Double(bottom.red), Double(bottom.green), Double(bottom.blue))
            let span = Double(max(height - 1, 1))
            // Bayer thresholds in [-0.5, 0.5).
            var thresholds = [Double](repeating: 0, count: 64)
            for y in 0..<8 {
                for x in 0..<8 {
                    thresholds[y * 8 + x] = (Double(bayer8(x, y)) + 0.5) / 64 - 0.5
                }
            }
            // Row 0 of the buffer is the top of the image.
            for row in 0..<height {
                let t = Double(row) / span
                let r = start.0 + (end.0 - start.0) * t
                let g = start.1 + (end.1 - start.1) * t
                let b = start.2 + (end.2 - start.2) * t
                let line = pixels + row * bytesPerRow
                let thresholdRow = (row & 7) * 8
                for x in 0..<width {
                    let d = thresholds[thresholdRow + (x & 7)]
                    let p = line + x * 4
                    p[0] = quantize(r + d)
                    p[1] = quantize(g + d)
                    p[2] = quantize(b + d)
                    p[3] = 255
                }
            }
        }
        guard let image = context.makeImage() else { throw ModeWallpaperError.renderFailed }
        return image
    }

    private static func quantize(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, value.rounded())))
    }

    /// Classic 8×8 Bayer matrix value (0...63).
    private static func bayer8(_ x: Int, _ y: Int) -> Int {
        var value = 0
        var bit = 4
        var xx = x
        var yy = y ^ x
        for _ in 0..<3 {
            value |= ((yy & 1) << (bit + 1)) | ((xx & 1) << bit)
            xx >>= 1
            yy >>= 1
            bit -= 2
        }
        return value
    }

    /// Writes beside the target and renames, so the Dock never reads a
    /// half-written file.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)-\(url.lastPathComponent)")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ModeWallpaperError.writeFailed("can't create \(url.lastPathComponent)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temporary)
            throw ModeWallpaperError.writeFailed("can't encode PNG")
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            // Another thread rendered the same file first: that's fine.
            if FileManager.default.fileExists(atPath: url.path) { return }
            throw ModeWallpaperError.writeFailed(error.localizedDescription)
        }
    }
}
