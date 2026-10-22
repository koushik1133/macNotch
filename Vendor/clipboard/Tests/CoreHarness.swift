import AppKit
import UniformTypeIdentifiers

// Test harness for the clipboard-history core (model, policy, reader,
// writer, disk store). Uses only private NSPasteboard(name:) pasteboards and
// a temp directory; never touches NSPasteboard.general.
// Run: Vendor/clipboard/Tests/run-tests.sh

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    if condition {
        passes += 1
    } else {
        failures += 1
        print("FAIL [\(line)] \(message)")
    }
}

/// Records whether the pasteboard ever asked for an item's data.
final class SpyProvider: NSObject, NSPasteboardItemDataProvider {
    var requested: [String] = []
    let payload: [String: Data]
    init(_ payload: [String: Data]) { self.payload = payload }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        requested.append(type.rawValue)
        if let data = payload[type.rawValue] { item.setData(data, forType: type) }
    }
}

func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("com.notchisland.clipboard-tests.\(UUID().uuidString)"))
}

func write(_ pasteboard: NSPasteboard, _ entries: [(NSPasteboard.PasteboardType, Data)]) {
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    for (type, data) in entries { item.setData(data, forType: type) }
    pasteboard.writeObjects([item])
}

func capture(_ result: ClipboardReader.Result) -> ClipboardCapture? {
    if case .capture(let capture) = result { return capture }
    return nil
}

func skipReason(_ result: ClipboardReader.Result) -> ClipboardPolicy.SkipReason? {
    if case .skipped(let reason) = result { return reason }
    return nil
}

func pngData(width: Int, height: Int, red: CGFloat = 1) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(red: red, green: 0.3, blue: 0.2, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func utf8(_ s: String) -> Data { Data(s.utf8) }

@main
struct CoreHarness {
    static func main() async {
        let policy = ClipboardPolicy()
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // MARK: Access gate on a named pasteboard (always allowed).
        check(ClipboardAccess.of(pb) == .allowed, "named pasteboards are always readable")

        // MARK: Plain text
        write(pb, [(.string, utf8("Hello world\nsecond line"))])
        var cap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: "com.apple.TextEdit"))
        check(cap?.kind == .text, "plain text -> .text (got \(String(describing: cap?.kind)))")
        check(cap?.string == "Hello world\nsecond line", "plain text content")
        check(cap?.sourceBundleID == "com.apple.TextEdit", "frontmost app is the fallback source")

        // MARK: Rich text (RTF + string) and HTML + string
        let rtf = NSAttributedString(string: "Bold text", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        let rtfData = rtf.rtf(from: NSRange(location: 0, length: rtf.length), documentAttributes: [:])!
        write(pb, [(.string, utf8("Bold text")), (.rtf, rtfData)])
        cap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))
        check(cap?.kind == .richText, "rtf + string -> .richText")
        check(cap?.rtf == rtfData, "rtf data captured")
        write(pb, [(.string, utf8("Hi")), (.html, utf8("<b>Hi</b>"))])
        cap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))
        check(cap?.kind == .richText && cap?.html == utf8("<b>Hi</b>"), "html + string -> .richText")

        // MARK: URLs
        write(pb, [(.string, utf8("  https://www.example.com/path?q=1 \n"))])
        cap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))
        check(cap?.kind == .url, "single web link string -> .url")
        write(pb, [(.URL, utf8("https://apple.com/mac")), (ClipboardReader.urlNameType, utf8("Mac - Apple"))])
        cap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))
        check(cap?.kind == .url && cap?.urlTitle == "Mac - Apple", "public.url + url-name -> .url with title")
        write(pb, [(.string, utf8("see https://apple.com for more"))])
        check(capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))?.kind == .text,
              "sentence containing a link stays .text")

        // MARK: Images
        let png = pngData(width: 400, height: 300)
        write(pb, [(.png, png)])
        cap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))
        check(cap?.kind == .image && cap?.image?.type == "public.png", "png -> .image")
        let tiff = NSBitmapImageRep(data: png)!.tiffRepresentation!
        write(pb, [(.tiff, tiff)])
        let tiffCapture = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))
        check(tiffCapture?.kind == .image && tiffCapture?.image?.type == "public.tiff", "tiff -> .image")
        // Safari "Copy Image": bitmap + link text -> image.
        write(pb, [(.tiff, tiff), (.string, utf8("https://example.com/cat.png"))])
        check(capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))?.kind == .image,
              "bitmap + link -> .image")
        // Spreadsheet cells: text + a picture of them -> text, bitmap not read.
        write(pb, [(.string, utf8("A1\tB1")), (.tiff, tiff)])
        cap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))
        check(cap?.kind == .text && cap?.image == nil, "text + bitmap -> .text, image skipped")
        // PDF alone is not an image.
        write(pb, [(.pdf, utf8("%PDF-1.4"))])
        check(skipReason(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil)) == .empty, "pdf only -> skipped")

        // MARK: Files
        let fileA = tmp.appendingPathComponent("a.txt")
        let fileB = tmp.appendingPathComponent("b.txt")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try? utf8("a").write(to: fileA)
        try? utf8("b").write(to: fileB)
        pb.clearContents()
        pb.writeObjects([fileA as NSURL, fileB as NSURL])
        cap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))
        check(cap?.kind == .file && cap?.fileURLs.count == 2, "two file URLs -> .file")

        // MARK: Privacy: marker types are skipped and their data never loaded
        for (marker, expected) in [
            (ClipboardPolicy.concealedType, ClipboardPolicy.SkipReason.concealed),
            (ClipboardPolicy.transientType, .transient),
            (ClipboardPolicy.autoGeneratedType, .autoGenerated),
            ("com.agilebits.onepassword", .ignoredType),
            (ClipboardPolicy.ownMarkerType, .ownWrite),
        ] {
            pb.clearContents()
            let item = NSPasteboardItem()
            let spy = SpyProvider([NSPasteboard.PasteboardType.string.rawValue: utf8("hunter2"), marker: Data()])
            item.setDataProvider(spy, forTypes: [.string, NSPasteboard.PasteboardType(marker)])
            pb.writeObjects([item])
            let result = ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil)
            check(skipReason(result) == expected, "\(marker) -> \(expected) (got \(result))")
            check(!spy.requested.contains(NSPasteboard.PasteboardType.string.rawValue),
                  "\(marker): secret string was never requested (requested \(spy.requested))")
        }
        // A marker on the second item still counts.
        pb.clearContents()
        let first = NSPasteboardItem(); first.setString("plain", forType: .string)
        let second = NSPasteboardItem(); second.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardPolicy.concealedType))
        pb.writeObjects([first, second])
        check(skipReason(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil)) == .concealed,
              "concealed marker on any item is honoured")

        // Excluded apps: declared source and frontmost fallback.
        write(pb, [(.string, utf8("pw")), (NSPasteboard.PasteboardType(ClipboardPolicy.sourceType), utf8("com.1password.1password"))])
        check(skipReason(ClipboardReader.read(pb, policy: policy, frontmostBundleID: "com.apple.Safari")) == .excludedApp,
              "org.nspasteboard.source in exclusion list -> skipped")
        write(pb, [(.string, utf8("pw"))])
        check(skipReason(ClipboardReader.read(pb, policy: policy, frontmostBundleID: "com.apple.keychainaccess")) == .excludedApp,
              "frontmost Keychain Access -> skipped")
        var custom = policy
        custom.excludedBundleIDs.insert("com.example.secret")
        check(skipReason(ClipboardReader.read(pb, policy: custom, frontmostBundleID: "com.example.secret")) == .excludedApp,
              "user-added exclusion")
        // Universal Clipboard only when opted out.
        write(pb, [(.string, utf8("from iPhone")), (NSPasteboard.PasteboardType(ClipboardPolicy.remoteClipboardType), Data())])
        check(capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil)) != nil, "remote clipboard recorded by default")
        custom.ignoresRemoteClipboard = true
        check(skipReason(ClipboardReader.read(pb, policy: custom, frontmostBundleID: nil)) == .remoteClipboard, "remote clipboard ignored when set")

        // Size limits.
        var small = policy
        small.maxTextBytes = 10
        small.maxRichBytes = 5
        write(pb, [(.string, utf8("this is longer than ten bytes"))])
        check(skipReason(ClipboardReader.read(pb, policy: small, frontmostBundleID: nil)) == .tooLarge, "oversized text skipped")
        write(pb, [(.string, utf8("short")), (.html, utf8("<p>too long html</p>"))])
        cap = capture(ClipboardReader.read(pb, policy: small, frontmostBundleID: nil))
        check(cap?.kind == .text && cap?.html == nil, "oversized html dropped, plain text kept")
        small.maxImageBytes = 100
        write(pb, [(.png, png)])
        check(skipReason(ClipboardReader.read(pb, policy: small, frontmostBundleID: nil)) == .tooLarge, "oversized image skipped")

        // MARK: Disk store: ingest, thumbnails, TIFF -> PNG
        let storeDir = tmp.appendingPathComponent("store")
        let store = ClipboardDiskStore(directory: storeDir)
        _ = await store.load()
        let perms = (try? FileManager.default.attributesOfItem(atPath: storeDir.path)[.posixPermissions] as? Int) ?? 0
        check(perms == 0o700, "store directory is 0700 (got \(String(perms, radix: 8)))")

        func ingest(_ entries: [(NSPasteboard.PasteboardType, Data)], at date: Date = Date()) async -> ClipboardItem? {
            write(pb, entries)
            guard var c = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: "com.apple.TextEdit")) else { return nil }
            c.capturedAt = date
            return await store.ingest(c)
        }

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        guard let textItem = await ingest([(.string, utf8("Hello"))], at: base),
              let richItem = await ingest([(.string, utf8("Hello")), (.rtf, rtfData)], at: base + 1),
              let imageItem = await ingest([(.tiff, tiff)], at: base + 2),
              let urlItem = await ingest([(.URL, utf8("https://apple.com")), (ClipboardReader.urlNameType, utf8("Apple"))], at: base + 3)
        else {
            check(false, "ingest returned nil")
            print("\(passes) passed, \(failures) failed")
            exit(1)
        }
        pb.clearContents(); pb.writeObjects([fileA as NSURL])
        var fileCap = capture(ClipboardReader.read(pb, policy: policy, frontmostBundleID: nil))!
        fileCap.capturedAt = base + 4
        let fileItem = await store.ingest(fileCap)!

        check(textItem.fingerprint == richItem.fingerprint, "text and rich text of the same string share a fingerprint")
        check(richItem.blobs[UTType.rtf.identifier] != nil, "rich text stores an RTF blob")
        check(imageItem.blobs[UTType.png.identifier] != nil && imageItem.blobs[UTType.tiff.identifier] == nil,
              "TIFF stored as PNG")
        check(imageItem.pixelWidth == 400 && imageItem.pixelHeight == 300, "image pixel size recorded")
        check(imageItem.thumbnailBlob != nil, "thumbnail made")
        if let thumb = store.thumbnailData(for: imageItem), let rep = NSBitmapImageRep(data: thumb) {
            check(max(rep.pixelsWide, rep.pixelsHigh) <= ClipboardDiskStore.thumbnailPixelSize, "thumbnail is downsampled")
        } else {
            check(false, "thumbnail readable")
        }
        check(urlItem.kind == .url && urlItem.title == "Apple" && urlItem.displayTitle == "Apple", "url item with title")
        check(fileItem.kind == .file && fileItem.displayTitle == "a.txt", "file item")

        // MARK: History: dedupe, pin carry-over, capacity
        var history = ClipboardHistory()
        history.insert(textItem)
        let pinResult = history.setPinned(id: textItem.id, true)
        check(pinResult.ok, "pin ok")
        let removedByDup = history.insert(richItem)
        check(history.items.count == 1, "duplicate replaced, not added (count \(history.items.count))")
        check(removedByDup.map(\.id) == [textItem.id], "old duplicate returned for blob cleanup")
        check(history.items.first?.id == richItem.id && history.items.first?.isPinned == true, "newest copy wins and keeps the pin")
        check(history.items.first?.copyCount == 2, "copy count carried over")
        check(history.items.first?.firstCopiedAt == base, "first copy date carried over")
        history.insert(imageItem)
        history.insert(urlItem)
        history.insert(fileItem)
        check(history.latest?.id == fileItem.id, "latest is the newest")
        history.bump(id: imageItem.id, at: base + 10)
        check(history.latest?.id == imageItem.id && history.latest?.copyCount == 2, "bump moves to top")

        var capped = ClipboardHistory(unpinnedLimit: 30, pinnedLimit: 2)
        var evicted: [ClipboardItem] = []
        for index in 0..<35 {
            let item = ClipboardItem(id: UUID(), kind: .text, text: "item \(index)", title: nil, fileURLs: nil, blobs: [:],
                                 thumbnailBlob: nil, pixelWidth: nil, pixelHeight: nil, sourceBundleID: nil,
                                 copiedAt: base + Double(index), firstCopiedAt: base + Double(index), copyCount: 1,
                                 isPinned: false, fingerprint: "fp\(index)", byteCount: 6)
            evicted += capped.insert(item)
            if index == 0 || index == 1 { _ = capped.setPinned(id: item.id, true) }
        }
        check(capped.unpinned.count == 30, "30 unpinned kept (got \(capped.unpinned.count))")
        check(capped.pinned.count == 2, "pinned survive eviction")
        check(evicted.count == 3, "3 oldest unpinned evicted (got \(evicted.count))")
        check(capped.setPinned(id: capped.unpinned[0].id, true).ok == false, "pin limit enforced")
        let found = capped.filtered(query: "ITEM 3")
        check(!found.isEmpty && found.allSatisfy { ($0.text ?? "").contains("3") }, "search: all terms, case-insensitive")
        check(capped.filtered(query: "item 34").map(\.text) == ["item 34"], "search narrows to one")
        check(capped.filtered(query: "").prefix(2).allSatisfy(\.isPinned), "pinned listed first")
        check(history.filtered(query: "", kinds: [.image]).map(\.id) == [imageItem.id], "kind filter")
        check(history.filtered(query: "a.txt").map(\.id) == [fileItem.id], "search matches file names")
        let cleared = capped.clear(keepingPinned: true)
        check(cleared.count == 30 && capped.items.count == 2, "clear keeps pins")

        // MARK: Persistence round trip
        await store.discard(removedByDup)
        await store.save(history.items)
        let reopened = ClipboardDiskStore(directory: storeDir)
        let loaded = await reopened.load()
        check(loaded == history.items, "index round-trips (\(loaded.count) vs \(history.items.count))")
        let blobNames = (try? FileManager.default.contentsOfDirectory(atPath: storeDir.appendingPathComponent("blobs").path)) ?? []
        check(!blobNames.contains { $0.hasPrefix(textItem.id.uuidString) }, "discarded duplicate left no blobs")
        // An orphan blob is pruned on load.
        let orphan = storeDir.appendingPathComponent("blobs/\(UUID().uuidString).png")
        try? Data([1, 2, 3]).write(to: orphan)
        _ = await ClipboardDiskStore(directory: storeDir).load()
        check(!FileManager.default.fileExists(atPath: orphan.path), "orphan blob pruned")
        // An item whose blob vanished is dropped on load.
        if let name = imageItem.blobs.values.first {
            try? FileManager.default.removeItem(at: storeDir.appendingPathComponent("blobs/\(name)"))
        }
        let afterLoss = await ClipboardDiskStore(directory: storeDir).load()
        check(!afterLoss.contains { $0.id == imageItem.id } && afterLoss.count == history.items.count - 1,
              "item with missing blob dropped")
        // Non-persisting store never writes the index.
        let memDir = tmp.appendingPathComponent("mem")
        let memStore = ClipboardDiskStore(directory: memDir, persistsIndex: false)
        await memStore.save(history.items)
        check(!FileManager.default.fileExists(atPath: memDir.appendingPathComponent("history.json").path),
              "persistsIndex=false writes no index")
        await reopened.removeAll()
        check(await ClipboardDiskStore(directory: storeDir).load().isEmpty, "removeAll wipes history")

        // MARK: Writer round trip (re-reading with markers stripped)
        let writePB = makePasteboard()
        defer { writePB.releaseGlobally() }
        guard let rich2 = await ingest([(.string, utf8("Bold text")), (.rtf, rtfData), (.html, utf8("<b>Bold text</b>"))]),
              let image2 = await ingest([(.png, png)])
        else { check(false, "ingest 2"); exit(1) }
        var payload = await store.payload(for: rich2)
        ClipboardWriter.write(payload, to: writePB, ownBundleID: "com.notchisland.test")
        check(writePB.string(forType: .string) == "Bold text", "writer: plain string")
        check(writePB.data(forType: .rtf) == rtfData, "writer: rtf")
        check(writePB.data(forType: .html) == utf8("<b>Bold text</b>"), "writer: html")
        check(writePB.types?.contains(NSPasteboard.PasteboardType(ClipboardPolicy.ownMarkerType)) == true, "writer: own marker")
        check(writePB.string(forType: NSPasteboard.PasteboardType(ClipboardPolicy.sourceType)) == "com.apple.TextEdit",
              "writer: source app kept")
        check(skipReason(ClipboardReader.read(writePB, policy: policy, frontmostBundleID: nil)) == .ownWrite,
              "reader recognises our own write")
        ClipboardWriter.write(payload, to: writePB, plainTextOnly: true)
        check(writePB.data(forType: .rtf) == nil && writePB.string(forType: .string) == "Bold text", "plain-text copy drops rtf")

        payload = await store.payload(for: image2)
        ClipboardWriter.write(payload, to: writePB)
        check(writePB.data(forType: .png) == png, "writer: png bytes")
        check(writePB.data(forType: .tiff) != nil, "writer: tiff added for older apps")

        payload = await store.payload(for: urlItem)
        ClipboardWriter.write(payload, to: writePB)
        check(writePB.string(forType: .URL) == "https://apple.com" && writePB.string(forType: ClipboardReader.urlNameType) == "Apple",
              "writer: url + title")

        payload = await store.payload(for: fileItem)
        ClipboardWriter.write(payload, to: writePB)
        let urls = writePB.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        check(urls?.map(\.standardizedFileURL) == [fileA.standardizedFileURL], "writer: file url")

        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
