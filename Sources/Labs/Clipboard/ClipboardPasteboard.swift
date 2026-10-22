import AppKit

// Reading and writing pasteboards. Works on any NSPasteboard, so the test
// harness uses a private NSPasteboard(name:) and never touches .general.

/// Whether the app may read the general pasteboard without macOS showing
/// its "Paste from Other Apps" alert (macOS 15.4+ pasteboard privacy).
/// Checking it never reads any content.
enum ClipboardAccess: String, Sendable, Equatable {
    /// `.alwaysAllow`, or a system without pasteboard privacy.
    case allowed
    /// `.default`: never alerted yet. The first programmatic read may show
    /// the one-time system alert, so only read after the user turned the
    /// feature on.
    case firstUse
    /// `.ask`: every programmatic read would prompt; don't read automatically.
    case ask
    /// `.alwaysDeny`.
    case denied

    static func of(_ pasteboard: NSPasteboard) -> ClipboardAccess {
        if #available(macOS 15.4, *) {
            switch pasteboard.accessBehavior {
            case .alwaysAllow: return .allowed
            case .alwaysDeny: return .denied
            case .ask: return .ask
            case .default: return .firstUse
            @unknown default: return .ask
            }
        }
        return .allowed
    }

    /// Reading automatically (on every copy) is acceptable.
    var permitsAutomaticRead: Bool { self == .allowed || self == .firstUse }
}

enum ClipboardReader {
    enum Result: Sendable, Equatable {
        case capture(ClipboardCapture)
        case skipped(ClipboardPolicy.SkipReason)
    }

    /// Bitmap types we keep, best first. PDF is deliberately absent: many
    /// apps put a PDF next to copied text.
    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
    ]
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    /// All types on all items, read without loading any content.
    static func types(of pasteboard: NSPasteboard) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let perItem = (pasteboard.pasteboardItems ?? []).flatMap(\.types)
        for type in perItem + (pasteboard.types ?? []) where seen.insert(type.rawValue).inserted {
            ordered.append(type.rawValue)
        }
        return ordered
    }

    /// Bundle id from `org.nspasteboard.source`, if the writer set one.
    static func declaredSource(of pasteboard: NSPasteboard) -> String? {
        let type = NSPasteboard.PasteboardType(ClipboardPolicy.sourceType)
        guard pasteboard.availableType(from: [type]) != nil,
              let value = pasteboard.string(forType: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Reads `pasteboard` into a capture, applying `policy` first to the
    /// types (so concealed data is never loaded) and then to the sizes.
    /// `frontmostBundleID` is the fallback source app.
    static func read(_ pasteboard: NSPasteboard, policy: ClipboardPolicy,
                     frontmostBundleID: String?, now: Date = Date()) -> Result {
        let changeCount = pasteboard.changeCount
        let types = types(of: pasteboard)
        // Markers first: the source string is read only for clean pasteboards.
        let markerDecision = policy.preflight(types: types, sourceBundleID: nil)
        if case .skip(let reason) = markerDecision { return .skipped(reason) }
        let source = declaredSource(of: pasteboard) ?? frontmostBundleID
        if case .skip(let reason) = policy.preflight(types: types, sourceBundleID: source) { return .skipped(reason) }

        let available = Set(types)
        func has(_ type: NSPasteboard.PasteboardType) -> Bool { available.contains(type.rawValue) }

        var capture = ClipboardCapture(
            changeCount: changeCount, types: types, string: nil, rtf: nil, html: nil,
            urlString: nil, urlTitle: nil, image: nil, fileURLs: [], sourceBundleID: source, capturedAt: now
        )

        if has(.fileURL) {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
            capture.fileURLs = (urls ?? []).filter(\.isFileURL)
        }
        if capture.fileURLs.isEmpty {
            if has(.string) { capture.string = pasteboard.string(forType: .string) }
            if has(.URL), let link = pasteboard.string(forType: .URL), ClipboardCapture.webLink(link) != nil {
                capture.urlString = link
                if has(urlNameType) { capture.urlTitle = pasteboard.string(forType: urlNameType) }
            }
            let text = capture.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Rich representations only matter for real text.
            if !text.isEmpty, ClipboardCapture.webLink(text) == nil {
                if has(.rtf) { capture.rtf = pasteboard.data(forType: .rtf) }
                if has(.html) { capture.html = pasteboard.data(forType: .html) }
            }
            // A bitmap only when there's no real text (cells copied from a
            // spreadsheet come with a picture of themselves).
            if text.isEmpty || ClipboardCapture.webLink(text) != nil,
               let type = imageTypes.first(where: has), let data = pasteboard.data(forType: type), !data.isEmpty {
                capture.image = ClipboardCapture.Image(type: type.rawValue, data: data)
            }
        }

        if case .skip(let reason) = policy.enforceLimits(&capture) { return .skipped(reason) }
        return .capture(capture)
    }
}

/// Everything needed to put an item back on a pasteboard (blob data loaded).
struct ClipboardPayload: Sendable {
    var item: ClipboardItem
    /// Pasteboard type raw value -> data.
    var data: [String: Data]
}

enum ClipboardWriter {
    /// Writes `payload` to `pasteboard` with every stored representation
    /// (or just plain text), tagged with our marker and the original source
    /// app. Returns the new change count.
    @discardableResult
    static func write(_ payload: ClipboardPayload, to pasteboard: NSPasteboard,
                      plainTextOnly: Bool = false, ownBundleID: String? = Bundle.main.bundleIdentifier) -> Int {
        let item = payload.item
        let marker = NSPasteboard.PasteboardType(ClipboardPolicy.ownMarkerType)
        let source = NSPasteboard.PasteboardType(ClipboardPolicy.sourceType)

        func tag(_ entry: NSPasteboardItem) {
            entry.setData(Data(), forType: marker)
            entry.setString(item.sourceBundleID ?? ownBundleID ?? "", forType: source)
        }

        pasteboard.clearContents()
        if plainTextOnly, let text = item.plainText {
            let entry = NSPasteboardItem()
            entry.setString(text, forType: .string)
            tag(entry)
            pasteboard.writeObjects([entry])
            return pasteboard.changeCount
        }

        switch item.kind {
        case .text, .richText:
            let entry = NSPasteboardItem()
            entry.setString(item.text ?? "", forType: .string)
            if let rtf = payload.data[NSPasteboard.PasteboardType.rtf.rawValue] { entry.setData(rtf, forType: .rtf) }
            if let html = payload.data[NSPasteboard.PasteboardType.html.rawValue] { entry.setData(html, forType: .html) }
            tag(entry)
            pasteboard.writeObjects([entry])
        case .url:
            let entry = NSPasteboardItem()
            let link = item.text ?? ""
            entry.setString(link, forType: .string)
            entry.setString(link, forType: .URL)
            if let title = item.title, !title.isEmpty { entry.setString(title, forType: ClipboardReader.urlNameType) }
            tag(entry)
            pasteboard.writeObjects([entry])
        case .image:
            let entry = NSPasteboardItem()
            for (type, data) in payload.data {
                entry.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            // Older apps only take TIFF; convert moderately sized images.
            if payload.data[NSPasteboard.PasteboardType.tiff.rawValue] == nil,
               let png = payload.data[NSPasteboard.PasteboardType.png.rawValue],
               (item.pixelWidth ?? 0) * (item.pixelHeight ?? 0) <= 12_000_000,
               let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                entry.setData(tiff, forType: .tiff)
            }
            tag(entry)
            pasteboard.writeObjects([entry])
        case .file:
            let urls = (item.fileURLs ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
            let entries: [NSPasteboardItem] = urls.map { url in
                let entry = NSPasteboardItem()
                entry.setString(url.absoluteString, forType: .fileURL)
                entry.setString(url.path, forType: .string)
                tag(entry)
                return entry
            }
            if !entries.isEmpty { pasteboard.writeObjects(entries) }
        }
        return pasteboard.changeCount
    }
}
