import AppKit
import Foundation

// Smart Moments › "Screenshot taken" (DESIGN.md moment 12): the action and
// put-back (Undo) handlers for its three default chips.
//
//   copyImage     -> the screenshot's PNG on NSPasteboard.general (TIFF on
//                    demand through ScreenshotClipboardTIFFProvider), after
//                    ClipboardController.ignoreNextCopy(). Hidden while
//                    Screenshot to Clipboard is on (it already copied it).
//                    Undo: the clipboard as it was before, only if nothing
//                    was copied since.
//   annotateImage -> opens the file in Preview (Markup) through NSWorkspace,
//                    after a tap only. No put-back: SparkV never closes or
//                    quits an app.
//   sendToSpace   -> SpaceIngestCenter.file(url, userInitiated: true), after
//                    a tap only. Undo: deletes the Space item this send
//                    created (SpaceStore.delete(itemID:), which removes only
//                    SparkV's own copy); an item that was already there
//                    (the Spaces screenshot watcher filed it) is left alone.
//
// Other triggers that share an action key (sendToSpace for downloads and
// copies) keep the hook and availability that were there before `install`.
//
// Call `install` after `SmartMomentsWiring.start()` (which sets the engine's
// hooks wholesale), see INTEGRATION.md "## Moment: ScreenshotTaken".

/// A Space item as this moment needs it.
struct ScreenshotTakenSpaceItemRef: Equatable, Sendable {
    let id: UUID
    let url: URL?
}

/// What the moment calls. `live(...)` maps it onto the app's controllers;
/// tests pass fakes.
@MainActor
struct ScreenshotTakenMomentDeps {
    /// ScreenshotClipboardController.isEnabled: every screenshot is already
    /// copied, so the Copy chip is hidden.
    var screenshotClipboardIsOn: @MainActor () -> Bool
    /// ClipboardController.ignoreNextCopy() (when its history is on), so the
    /// clipboard history doesn't record our writes as new copies.
    var ignoreNextCopy: @MainActor () -> Void
    var pasteboard: NSPasteboard
    /// PNG bytes of the image (ScreenshotClipboardController.pngData).
    var pngData: @MainActor (URL) -> Data?
    var fileExists: @MainActor (URL) -> Bool
    /// Opens the image in Preview for Markup; false = it couldn't.
    var openForMarkup: @MainActor (URL) -> Bool
    /// SpaceIngestCenter is running (else `file` would drop it silently).
    var spacesAvailable: @MainActor () -> Bool
    /// SpaceIngestCenter.file(url, userInitiated: true).
    var sendToSpaces: @MainActor (URL) -> Void
    /// SpaceStore.shared.items.
    var spaceItems: @MainActor () -> [ScreenshotTakenSpaceItemRef]
    /// SpaceStore.shared.delete(itemID:).
    var deleteSpaceItem: @MainActor (UUID) -> Void
    var sleep: @MainActor (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }
    /// Ingesting runs OCR first: Undo waits this long for the item to land.
    var spacesPutBackWait: TimeInterval = 30
    var spacesPollInterval: TimeInterval = 0.5
    /// A clipboard bigger than this isn't kept for Undo.
    var pasteboardSnapshotLimit = 64 << 20

    static func live(clipboard: ClipboardController?, screenshotClipboard: ScreenshotClipboardController?) -> ScreenshotTakenMomentDeps {
        ScreenshotTakenMomentDeps(
            screenshotClipboardIsOn: { [weak screenshotClipboard] in screenshotClipboard?.isEnabled ?? false },
            ignoreNextCopy: { [weak clipboard] in
                // A flag left set while history is off would swallow the
                // user's next real copy.
                guard let clipboard, clipboard.isEnabled else { return }
                clipboard.ignoreNextCopy()
            },
            pasteboard: .general,
            pngData: { ScreenshotClipboardController.pngData(for: $0) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) },
            openForMarkup: { url in
                let workspace = NSWorkspace.shared
                guard let preview = workspace.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
                    return workspace.open(url)
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                workspace.open([url], withApplicationAt: preview, configuration: configuration) { _, error in
                    guard error != nil else { return }
                    Task { @MainActor in AppLog.log("SmartMoments: Preview didn't open the screenshot") }
                }
                return true
            },
            spacesAvailable: { SpaceIngestCenter.current != nil },
            sendToSpaces: { SpaceIngestCenter.file($0, userInitiated: true) },
            spaceItems: { SpaceStore.shared.items.map { ScreenshotTakenSpaceItemRef(id: $0.id, url: $0.url) } },
            deleteSpaceItem: { SpaceStore.shared.delete(itemID: $0) }
        )
    }
}

/// What each run changed, per offer, so its put-back restores exactly that.
@MainActor
final class ScreenshotTakenMomentState {
    struct ClipboardRecord {
        /// Each pasteboard item's (type, data) pairs, in order.
        let items: [[(NSPasteboard.PasteboardType, Data)]]
        /// changeCount right after our write: anything else means the user
        /// (or an app) copied since, and that copy stays.
        let changeCount: Int
    }

    struct SpaceRecord {
        let url: URL
        let itemsBefore: Set<UUID>
    }

    /// Only the latest few offers can still show Undo.
    static let keep = 4

    private(set) var clipboard: [UUID: ClipboardRecord] = [:]
    private(set) var spaces: [UUID: SpaceRecord] = [:]
    private var clipboardOrder: [UUID] = []
    private var spaceOrder: [UUID] = []
    /// Keeps the lazy TIFF provider alive while its item is on the pasteboard.
    fileprivate var tiffProvider: ScreenshotClipboardTIFFProvider?

    fileprivate func remember(_ record: ClipboardRecord, for offerID: UUID) {
        clipboard[offerID] = record
        clipboardOrder.removeAll { $0 == offerID }
        clipboardOrder.append(offerID)
        while clipboardOrder.count > Self.keep { clipboard[clipboardOrder.removeFirst()] = nil }
    }

    fileprivate func takeClipboard(_ offerID: UUID) -> ClipboardRecord? {
        clipboardOrder.removeAll { $0 == offerID }
        return clipboard.removeValue(forKey: offerID)
    }

    fileprivate func remember(_ record: SpaceRecord, for offerID: UUID) {
        spaces[offerID] = record
        spaceOrder.removeAll { $0 == offerID }
        spaceOrder.append(offerID)
        while spaceOrder.count > Self.keep { spaces[spaceOrder.removeFirst()] = nil }
    }

    fileprivate func takeSpace(_ offerID: UUID) -> SpaceRecord? {
        spaceOrder.removeAll { $0 == offerID }
        return spaces.removeValue(forKey: offerID)
    }
}

@MainActor
enum ScreenshotTakenMoment {
    /// Registers Copy, Annotate and Send to Space for screenshots, and the
    /// put-backs of Copy and Send to Space. Returns the state (tests read it).
    @discardableResult
    static func install(on engine: SmartMomentsController, deps: ScreenshotTakenMomentDeps) -> ScreenshotTakenMomentState {
        let state = ScreenshotTakenMomentState()
        var h = engine.hooks

        // Copy -------------------------------------------------------------------
        chain(.copyImage, in: &h, isAvailable: { _ in !deps.screenshotClipboardIsOn() }) { url, context in
            guard deps.fileExists(url), let png = deps.pngData(url) else { return .skipped("Screenshot is gone") }
            let board = deps.pasteboard
            let before = snapshot(board, limit: deps.pasteboardSnapshotLimit)
            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            let provider = ScreenshotClipboardTIFFProvider(png: png)
            item.setDataProvider(provider, forTypes: [.tiff])
            deps.ignoreNextCopy()
            board.clearContents()
            guard board.writeObjects([item]) else { return .failed("Couldn't copy it") }
            state.tiffProvider = provider
            if let before {
                state.remember(.init(items: before, changeCount: board.changeCount), for: context.offerID)
            }
            return .done("Copied")
        }
        chainPutBack(.copyImage, on: engine) { _, context in
            guard let record = state.takeClipboard(context.offerID) else { return .skipped("Nothing to put back") }
            let board = deps.pasteboard
            guard board.changeCount == record.changeCount else { return .skipped("Copied something else since") }
            deps.ignoreNextCopy()
            board.clearContents()
            let items = record.items.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty, !board.writeObjects(items) { return .failed("Couldn't put the clipboard back") }
            state.tiffProvider = nil
            return .done("Clipboard put back")
        }

        // Annotate ------------------------------------------------------------------
        chain(.annotateImage, in: &h, isAvailable: { _ in true }) { url, context in
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard deps.fileExists(url) else { return .skipped("Screenshot is gone") }
            return deps.openForMarkup(url) ? .done("Opened in Preview") : .failed("Couldn't open Preview")
        }

        // Send to a Space -----------------------------------------------------------
        chain(.sendToSpace, in: &h, isAvailable: { _ in deps.spacesAvailable() }) { url, context in
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard deps.fileExists(url) else { return .skipped("Screenshot is gone") }
            guard deps.spacesAvailable() else { return .skipped("Spaces isn't running") }
            let before = Set(deps.spaceItems().map(\.id))
            deps.sendToSpaces(url)
            state.remember(.init(url: url, itemsBefore: before), for: context.offerID)
            return .done("Sent to Spaces")
        }
        chainPutBack(.sendToSpace, on: engine) { _, context in
            guard let record = state.takeSpace(context.offerID) else { return .skipped("Nothing to put back") }
            var waited: TimeInterval = 0
            while true {
                let added = deps.spaceItems().filter { item in
                    !record.itemsBefore.contains(item.id) && item.url.map { samePath($0, record.url) } == true
                }
                if !added.isEmpty {
                    for item in added { deps.deleteSpaceItem(item.id) }
                    return .done("Removed from Spaces")
                }
                guard waited < deps.spacesPutBackWait else { return .skipped("Already in Spaces") }
                await deps.sleep(deps.spacesPollInterval)
                waited += deps.spacesPollInterval
            }
        }

        engine.hooks = h
        return state
    }

    // MARK: - Helpers

    /// Runs `body` for screenshots; every other trigger keeps the hook and
    /// availability that were registered before.
    private static func chain(
        _ action: MomentAction, in h: inout SmartMomentsHooks,
        isAvailable: @escaping @MainActor (URL) -> Bool,
        _ body: @escaping @MainActor (URL, MomentActionContext) async -> MomentActionResult
    ) {
        let previousRun = h.actions[action]
        let previousAvailable = h.isAvailable[action]
        h.actions[action] = { context in
            guard case .screenshotTaken(let url) = context.trigger else {
                guard let previousRun else { return .skipped("Not available") }
                return await previousRun(context)
            }
            return await body(url, context)
        }
        h.isAvailable[action] = { trigger in
            guard case .screenshotTaken(let url) = trigger else {
                guard previousRun != nil else { return false }
                return previousAvailable?(trigger) ?? true
            }
            return isAvailable(url)
        }
    }

    private static func chainPutBack(
        _ action: MomentAction, on engine: SmartMomentsController,
        _ body: @escaping @MainActor (URL, MomentActionContext) async -> MomentActionResult
    ) {
        let previous = engine.putBack[action]
        engine.putBack[action] = { context in
            guard case .screenshotTaken(let url) = context.trigger else {
                guard let previous else { return .skipped("Nothing to put back") }
                return await previous(context)
            }
            return await body(url, context)
        }
    }

    /// The pasteboard's items and data, or nil when it is bigger than `limit`.
    static func snapshot(_ board: NSPasteboard, limit: Int) -> [[(NSPasteboard.PasteboardType, Data)]]? {
        var total = 0
        var result: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in board.pasteboardItems ?? [] {
            var pairs: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > limit { return nil }
                pairs.append((type, data))
            }
            if !pairs.isEmpty { result.append(pairs) }
        }
        return result
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
            || a.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }
}
