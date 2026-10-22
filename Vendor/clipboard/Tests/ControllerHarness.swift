import AppKit
import SwiftUI

// End-to-end harness for ClipboardController, compiled with the app's
// sources (minus NotchIslandApp.swift's @main and AppLog.swift, replaced by
// the stub in AppLogStub.swift so tests don't write the real log). Uses a
// private NSPasteboard(name:), a throwaway UserDefaults suite and a temp
// directory. paste() runs with `pasteKeystroke` stubbed, so no Cmd+V is
// ever posted, and `confirm` stubbed, so no alert is shown.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    if condition { passes += 1 } else { failures += 1; print("FAIL [\(line)] \(message)") }
}

@MainActor
func settle(_ seconds: Double = 1.0) async {
    try? await Task.sleep(for: .seconds(seconds))
}

@MainActor
func put(_ pasteboard: NSPasteboard, _ entries: [(String, Data)]) {
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    for (type, data) in entries { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
    pasteboard.writeObjects([item])
}

/// Renders a view offscreen (window never ordered in) to a PNG.
@MainActor
func snapshot<V: View>(_ view: V, size: CGSize, to url: URL) {
    let root = view
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
}

@main
struct ControllerHarness {
    @MainActor
    static func main() async {
        let pb = NSPasteboard(name: NSPasteboard.Name("com.notchisland.clipboard-ctl-tests.\(UUID().uuidString)"))
        let suite = "com.notchisland.clipboard-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-ctl-\(UUID().uuidString)")
        defer {
            pb.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
        let string = NSPasteboard.PasteboardType.string.rawValue

        let activities = ActivityCenter()
        let controller = ClipboardController(activities: activities, pasteboard: pb, defaults: defaults, directory: dir)
        var keystrokes = 0
        var keystrokeSawString: [String?] = []
        controller.pasteKeystroke = {
            keystrokes += 1
            keystrokeSawString.append(pb.string(forType: .string))
            return .pasted
        }
        var confirmAnswer = false
        var confirmTitles: [String] = []
        controller.confirm = { title, _, _ in confirmTitles.append(title); return confirmAnswer }
        controller.useCurrent(pasting: true)
        check(keystrokes == 0, "C click while off posts nothing")
        controller.start()
        check(controller.status == .off, "off by default")

        put(pb, [(string, Data("before opt-in".utf8))])
        await settle()
        check(controller.items.isEmpty, "nothing recorded while off")

        controller.setEnabled(true)
        await settle()
        check(controller.status == .running, "running after opt-in (\(controller.status))")
        check(controller.items.first?.text == "before opt-in", "turning on reads the current clipboard once")

        put(pb, [(string, Data("second".utf8))])
        await settle()
        check(controller.items.map(\.text) == ["second", "before opt-in"], "new copy recorded at the top")

        put(pb, [(string, Data("hunter2".utf8)), (ClipboardPolicy.concealedType, Data())])
        await settle()
        check(controller.items.count == 2 && controller.hiddenReason == .concealed, "concealed copy skipped and flagged")
        check(!controller.items.contains { $0.text == "hunter2" }, "password never stored")
        check(controller.hasUnrecordedCopy && !controller.clipboardMatchesCurrent, "concealed copy marks the clipboard as unrecorded")
        // C click now must paste the clipboard as is (the password), never an older item.
        controller.useCurrent(pasting: true)
        await settle(0.4)
        check(keystrokes == 1 && keystrokeSawString.last == "hunter2", "C click pastes the current (private) clipboard as is")
        check(pb.string(forType: .string) == "hunter2", "C click didn't overwrite the private copy")
        controller.useCurrent(pasting: false)
        await settle(0.3)
        check(pb.string(forType: .string) == "hunter2" && keystrokes == 1, "⌥-click on an unrecorded copy changes nothing")
        let indexText = (try? String(contentsOf: dir.appendingPathComponent("history.json"), encoding: .utf8)) ?? ""
        check(!indexText.contains("hunter2"), "password not on disk")

        // Transient / auto-generated pasteboards are never stored.
        put(pb, [(string, Data("transient secret".utf8)), (ClipboardPolicy.transientType, Data())])
        await settle()
        put(pb, [(string, Data("autogen secret".utf8)), (ClipboardPolicy.autoGeneratedType, Data())])
        await settle()
        put(pb, [(string, Data("1p secret".utf8)), ("com.agilebits.onepassword", Data())])
        await settle()
        check(!controller.items.contains { ["transient secret", "autogen secret", "1p secret"].contains($0.text ?? "") },
              "transient, auto-generated and password-manager copies not stored")

        put(pb, [(string, Data("before opt-in".utf8))])
        await settle()
        check(controller.items.count == 2 && controller.items.first?.text == "before opt-in", "duplicate moves to top")
        check(controller.items.first?.copyCount == 2, "duplicate count")
        check(controller.hiddenReason == nil, "hidden flag clears on a normal copy")
        check(controller.clipboardMatchesCurrent && !controller.hasUnrecordedCopy, "in sync after a recorded copy")
        controller.useCurrent(pasting: true)
        await settle(0.4)
        check(keystrokes == 2 && keystrokeSawString.last == "before opt-in", "C click pastes the current item")
        check(activities.current?.id == ClipboardController.activityID, "Pasted band posted")

        controller.setPaused(true)
        put(pb, [(string, Data("while paused".utf8))])
        await settle()
        check(controller.hasUnrecordedCopy, "copy while paused is flagged unrecorded")
        controller.useCurrent(pasting: true)
        await settle(0.4)
        check(pb.string(forType: .string) == "while paused" && keystrokeSawString.last == "while paused",
              "C click while paused pastes what's really on the clipboard")
        controller.setPaused(false)
        await settle()
        check(!controller.items.contains { $0.text == "while paused" }, "copies made while paused are not recorded")

        controller.ignoreNextCopy()
        put(pb, [(string, Data("ignored once".utf8))])
        await settle()
        put(pb, [(string, Data("after ignore".utf8))])
        await settle()
        check(!controller.items.contains { $0.text == "ignored once" }, "ignore next copy")
        check(controller.items.first?.text == "after ignore", "recording resumes after the ignored copy")

        // Copy an older item back: pasteboard holds it, no duplicate, moved to top.
        if let older = controller.items.first(where: { $0.text == "second" }) {
            controller.copy(older)
            await settle()
            check(pb.string(forType: .string) == "second", "copy-back writes the pasteboard")
            check(controller.items.first?.id == older.id, "copy-back moves the item to the top")
            check(controller.items.filter { $0.text == "second" }.count == 1, "copy-back adds no duplicate")
            check(controller.flashedItemID == nil || controller.flashedItemID == older.id, "flash id")
            check(activities.current?.id == ClipboardController.activityID, "Copied live activity posted")
        } else {
            check(false, "older item present")
        }

        // Pin, then persist across a new controller instance.
        if let first = controller.items.first { controller.togglePin(first) }
        await settle(0.5)
        let saved = controller.items
        controller.stop()
        let reopened = ClipboardController(activities: activities, pasteboard: pb, defaults: defaults, directory: dir)
        reopened.pasteKeystroke = { .notPasted("stub") }
        reopened.confirm = { _, _, _ in false }
        reopened.start()
        await settle()
        check(reopened.isEnabled, "enabled state persisted")
        check(reopened.items == saved, "history persisted across instances (\(reopened.items.count) vs \(saved.count))")
        check(reopened.pinned.count == 1, "pin persisted")

        // Excluding an app by declared source.
        reopened.exclude(bundleID: "com.example.secretapp")
        put(pb, [(string, Data("from secret app".utf8)), (ClipboardPolicy.sourceType, Data("com.example.secretapp".utf8))])
        await settle()
        check(!reopened.items.contains { $0.text == "from secret app" }, "user-excluded app skipped")

        // Image copy: thumbnail published.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 640, height: 400).fill()
        NSColor.systemOrange.setFill(); NSRect(x: 80, y: 80, width: 300, height: 200).fill()
        ("Invoice 4821" as NSString).draw(at: NSPoint(x: 100, y: 300),
                                          withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        put(pb, [(NSPasteboard.PasteboardType.png.rawValue, rep.representation(using: .png, properties: [:])!)])
        await settle(1.5)
        if let image = reopened.items.first, image.kind == .image {
            check(reopened.thumbnails[image.id] != nil, "image thumbnail published")
            check(image.displayTitle == "Image 640×400", "image title")
            check(image.recognizedText?.lowercased().contains("invoice 4821") == true,
                  "Vision read the image's text (\(image.recognizedText ?? "nil"))")
            check(reopened.filtered(query: "invoice 4821", filter: .all).first?.id == image.id, "image found by its text")
            check(!reopened.dragPayloads(for: image).isEmpty, "image drag payload (stored file)")
        } else {
            check(false, "image recorded")
        }
        // Rich text, link and file, for the snapshot below.
        put(pb, [(string, Data("Quarterly notes: revenue up 12%, ship the notch clipboard next sprint.".utf8)),
                 (NSPasteboard.PasteboardType.html.rawValue, Data("<b>Quarterly</b> notes".utf8))])
        await settle(0.7)
        put(pb, [(NSPasteboard.PasteboardType.URL.rawValue, Data("https://github.com/p0deje/Maccy".utf8)),
                 (ClipboardReader.urlNameType.rawValue, Data("Maccy – clipboard manager for macOS".utf8))])
        await settle(0.7)
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") as NSURL])
        await settle(0.7)
        check(reopened.items.prefix(3).map(\.kind) == [.file, .url, .richText], "file, link, rich text recorded")

        if let snapshotDir = ProcessInfo.processInfo.environment["CLIPBOARD_SNAPSHOT_DIR"] {
            snapshot(ClipboardTabView().environmentObject(reopened), size: CGSize(width: 508, height: 114),
                     to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("tab.png"))
            snapshot(HStack { ClipboardButton().environmentObject(reopened) }.padding(6),
                     size: CGSize(width: 140, height: 32),
                     to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("button.png"))
            snapshot(ClipboardActivityView(symbol: "doc.plaintext", title: "Copied", detail: "Quarterly notes: revenue up 12%…",
                                           thumbnail: nil).padding(.horizontal, 16),
                     size: CGSize(width: 400, height: 30),
                     to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("band.png"))
            let off = ClipboardController(activities: activities, pasteboard: pb,
                                          defaults: UserDefaults(suiteName: suite + ".off")!, directory: dir.appendingPathComponent("off"))
            snapshot(ClipboardTabView().environmentObject(off), size: CGSize(width: 508, height: 114),
                     to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("tab-off.png"))
            UserDefaults.standard.removePersistentDomain(forName: suite + ".off")
            // Agents hub (default 115 pt drawer: 508×69 content) hosting the C capsule.
            snapshot(AgentsHubView().environmentObject(NotchState()).environmentObject(reopened),
                     size: CGSize(width: 508, height: 69),
                     to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("hub.png"))
            // Unrecorded-copy state of the capsule.
            put(pb, [(string, Data("sekrit".utf8)), (ClipboardPolicy.concealedType, Data())])
            await settle()
            snapshot(HStack { ClipboardButton().environmentObject(reopened) }.padding(6),
                     size: CGSize(width: 140, height: 32),
                     to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("button-hidden.png"))
            // Narrow, text-heavy history to check card clipping.
            snapshot(ClipboardTabView().environmentObject(reopened), size: CGSize(width: 508, height: 114),
                     to: URL(fileURLWithPath: snapshotDir).appendingPathComponent("tab2.png"))
        }

        // Search and filters.
        check(reopened.filtered(query: "maccy", filter: .all).first?.kind == .url, "search finds the link by title")
        check(reopened.filtered(query: "QUARTERLY revenue", filter: .text).first?.kind == .richText, "multi-term search + text filter")
        check(reopened.filtered(query: "", filter: .images).allSatisfy { $0.kind == .image }, "image filter")
        check(reopened.filtered(query: "", filter: .pinned).allSatisfy(\.isPinned)
              && reopened.filtered(query: "", filter: .pinned).count == 1, "pinned filter")
        check(reopened.filtered(query: "", filter: .all).first?.isPinned == true, "pinned listed first in the tab")

        // Pasting rich text keeps its formatting (all representations written).
        var pastes = 0
        reopened.pasteKeystroke = { pastes += 1; return .notPasted("Allow Accessibility for SparkV to paste · ⌘V") }
        if let rich = reopened.items.first(where: { $0.kind == .richText }) {
            reopened.paste(rich)
            await settle(0.5)
            check(pastes == 1 && pb.data(forType: .html) != nil, "paste writes the HTML representation")
            check(reopened.items.first?.id == rich.id && reopened.items.first?.kind == .richText,
                  "failed paste keeps the rich item intact (no plain-text duplicate)")
            reopened.paste(rich, plainText: true)
            await settle(0.5)
            check(pb.data(forType: .html) == nil && pb.string(forType: .string)?.hasPrefix("Quarterly") == true,
                  "paste as plain text")
            check(reopened.items.filter { $0.kind == .richText }.count == 1, "plain paste adds no duplicate")
        } else {
            check(false, "rich item present")
        }

        // Unpinning/pinning round trip.
        if let link = reopened.items.first(where: { $0.kind == .url }) {
            reopened.togglePin(link)
            check(reopened.items.first { $0.id == link.id }?.isPinned == true, "pin")
            reopened.togglePin(reopened.items.first { $0.id == link.id }!)
            check(reopened.items.first { $0.id == link.id }?.isPinned == false, "unpin")
        }

        // The C button's history menu (built, never shown).
        let menu = ClipboardMenu.make(for: reopened)
        let titles = menu.items.map(\.title)
        check(titles.contains("Clear History…") && titles.contains("Pause History"), "menu has clear and pause")
        let numbered = menu.items.filter { $0.keyEquivalent == "1" }
        check(numbered.count == 2 && numbered.contains { $0.isAlternate && $0.keyEquivalentModifierMask == [.command, .option] },
              "⌘1 copies and ⌥⌘1 pastes the newest item")
        check(!titles.contains { $0.contains("NotchIsland") }, "menu says SparkV, not NotchIsland")

        // Clear asks first; cancel keeps everything.
        reopened.confirm = { title, _, _ in confirmTitles.append(title); return confirmAnswer }
        let beforeCancel = reopened.items.count
        confirmAnswer = false
        reopened.confirmAndClear()
        await settle(0.3)
        check(reopened.items.count == beforeCancel && confirmTitles.last == "Clear clipboard history?", "cancelled clear deletes nothing")
        confirmAnswer = true
        reopened.confirmAndClear()
        await settle(0.5)
        check(reopened.items.count == 1 && reopened.items.first?.isPinned == true, "clear keeps pins")
        reopened.confirmAndClear(includingPinned: true)
        await settle(0.5)
        check(reopened.items.isEmpty, "clear all")
        let blobs = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("blobs").path)) ?? []
        check(blobs.isEmpty, "clear all leaves no blobs")

        // Turning persistence off deletes the saved index, so it asks first.
        put(pb, [(string, Data("persist me".utf8))])
        await settle()
        confirmAnswer = false
        reopened.setPersistsHistory(false)
        await settle(0.3)
        check(reopened.persistsHistory, "declined: persistence stays on")
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path), "declined: index kept")
        confirmAnswer = true
        reopened.setPersistsHistory(false)
        await settle(0.3)
        check(!reopened.persistsHistory && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path),
              "accepted: index removed")
        reopened.setPersistsHistory(true)
        await settle(0.3)

        reopened.setEnabled(false)
        put(pb, [(string, Data("after off".utf8))])
        await settle()
        check(!reopened.items.contains { $0.text == "after off" } && reopened.status == .off, "turning off stops recording")
        reopened.stop()

        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
