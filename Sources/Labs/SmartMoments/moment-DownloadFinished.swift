import Foundation

// Smart Moments: "Download finished" (DESIGN.md moment 7).
//
// Trigger: DownloadsController moves an item to `.finished` (reported by
// SmartMomentsWiring through `SmartMomentsLiveSources.reportDownloadFinished`).
// Offer: "invoice.pdf · Sort into Invoices?"
// Actions, all through DownloadsController (it owns the files):
//   sortDownload   -> `sortWithSuggestion(_:)`; put back = `undo(_:)`, only the
//                     move this moment made, only while the band is up.
//                     On its own (auto mode) only when the suggestion came from
//                     the user's own rule, never from AI, never to a Space.
//   openFile       -> `open(_:)` (a tap only: an auto-opened download is a risk)
//   revealInFinder -> `reveal(_:)` (a tap only)
//   addToTray      -> `addToTray(_:)` (downloads only; other triggers keep the
//                     hook that was there before)
//   sendToSpace    -> `sendToSpace(_:)` (a tap only; other triggers keep the
//                     hook that was there before)
// Nothing here hides or quits an app, and nothing is deleted: Undo moves the
// file back to where it was downloaded.

/// What the moment needs from DownloadsController, as closures so tests can
/// use fakes. `live(downloads:)` builds it from the real controller.
@MainActor
struct DownloadFinishedMomentDeps {
    /// The finished item as it is now (its url follows a sort).
    struct Item: Equatable, Sendable {
        let url: URL
        let isActive: Bool
        /// Identifies the move SparkV made (nil = where it was downloaded).
        let move: DownloadFinishedMomentMove?
        let addedToTray: Bool
        let sentToSpace: Bool
    }

    struct Suggestion: Equatable, Sendable {
        let folderName: String
        /// True when the user's own rule chose the folder (false = AI pick).
        let fromRule: Bool
        /// The destination is a Space, not a folder (not undoable here).
        let isSpace: Bool
    }

    var item: @MainActor (UUID) -> Item?
    var suggestion: @MainActor (UUID) -> Suggestion?
    var sortWithSuggestion: @MainActor (UUID) -> Void
    var undoSort: @MainActor (UUID) -> Void
    var open: @MainActor (UUID) -> Void
    var reveal: @MainActor (UUID) -> Void
    var addToTray: @MainActor (UUID) -> Void
    var sendToSpace: @MainActor (UUID) -> Void
    var fileExists: @MainActor (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
}

/// The parts of a `DownloadMove` that identify it.
struct DownloadFinishedMomentMove: Equatable, Sendable {
    let from: URL
    let to: URL
    let date: Date
}

extension DownloadFinishedMomentDeps {
    /// The real controller (weak: the moment never keeps it alive).
    static func live(downloads: DownloadsController) -> DownloadFinishedMomentDeps {
        DownloadFinishedMomentDeps(
            item: { [weak downloads] id in
                guard let item = downloads?.item(id) else { return nil }
                return Item(
                    url: item.url, isActive: item.isActive,
                    move: item.move.map { DownloadFinishedMomentMove(from: $0.from, to: $0.to, date: $0.date) },
                    addedToTray: item.addedToTray, sentToSpace: item.sentToSpace
                )
            },
            suggestion: { [weak downloads] id in
                guard let suggestion = downloads?.suggestions[id] else { return nil }
                let fromRule: Bool = if case .rule = suggestion.origin { true } else { false }
                return Suggestion(
                    folderName: suggestion.destination.displayName, fromRule: fromRule,
                    isSpace: suggestion.destination == .space
                )
            },
            sortWithSuggestion: { [weak downloads] id in downloads?.sortWithSuggestion(id) },
            undoSort: { [weak downloads] id in downloads?.undo(id) },
            open: { [weak downloads] id in downloads?.open(id) },
            reveal: { [weak downloads] id in downloads?.reveal(id) },
            addToTray: { [weak downloads] id in downloads?.addToTray(id) },
            sendToSpace: { [weak downloads] id in downloads?.sendToSpace(id) }
        )
    }
}

/// Moves this moment made, by offer, so Undo puts back exactly that one.
@MainActor
final class DownloadFinishedMomentState {
    fileprivate var sorted: [UUID: (itemID: UUID, move: DownloadFinishedMomentMove)] = [:]
    /// Sorts that Undo could still put back (tests read it).
    var pendingPutBacks: Int { sorted.count }

    fileprivate func remember(offer: UUID, item: UUID, move: DownloadFinishedMomentMove) {
        // The engine forgets put-backs once the band goes; keep this small.
        if sorted.count >= 20 { sorted.removeAll() }
        sorted[offer] = (item, move)
    }
}

@MainActor
enum DownloadFinishedMoment {
    /// Registers the moment's action and put-back handlers on the engine.
    /// Call after the shared hooks are installed: it replaces the download
    /// handlers and keeps the earlier Add to Tray / Send to Space handlers
    /// for screenshots and copies. Returns the state (tests read it).
    @discardableResult
    static func install(on engine: SmartMomentsController, deps: DownloadFinishedMomentDeps) -> DownloadFinishedMomentState {
        let state = DownloadFinishedMomentState()
        var h = engine.hooks

        func itemID(_ trigger: MomentTrigger) -> UUID? {
            if case .downloadFinished(let id, _, _) = trigger { return id }
            return nil
        }
        /// The finished file, still on disk.
        func present(_ id: UUID) -> DownloadFinishedMomentDeps.Item? {
            guard let item = deps.item(id), !item.isActive, deps.fileExists(item.url) else { return nil }
            return item
        }

        // Sort ------------------------------------------------------------------

        h.actions[.sortDownload] = { context in
            guard let id = itemID(context.trigger) else { return .skipped("Nothing to sort") }
            guard let item = present(id) else { return .skipped("The file isn't there any more") }
            guard item.move == nil else { return .skipped("Already sorted") }
            guard let suggestion = deps.suggestion(id) else { return .skipped("No suggestion") }
            // On its own only by the user's own rule; an AI pick or a Space
            // (Send to Space is user-initiated only) waits for a tap.
            if !context.userInitiated, !suggestion.fromRule || suggestion.isSpace { return .skipped("Needs a tap") }
            deps.sortWithSuggestion(id)
            if suggestion.isSpace {
                return deps.item(id)?.sentToSpace == true ? .done("Sent to Spaces") : .failed("Couldn't send it")
            }
            guard let move = deps.item(id)?.move else { return .failed("Couldn't move it") }
            state.remember(offer: context.offerID, item: id, move: move)
            return .done("Moved to \(suggestion.folderName)")
        }
        h.isAvailable[.sortDownload] = { trigger in
            guard let id = itemID(trigger), let item = present(id) else { return false }
            return item.move == nil && deps.suggestion(id) != nil
        }
        // In "Do automatically" an AI pick or a Space stays a chip for a tap.
        h.autoEligible[.sortDownload] = { trigger in
            guard let id = itemID(trigger), let suggestion = deps.suggestion(id) else { return false }
            return suggestion.fromRule && !suggestion.isSpace
        }
        engine.putBack[.sortDownload] = { context in
            guard let record = state.sorted.removeValue(forKey: context.offerID) else { return .skipped("Not moved") }
            guard let item = deps.item(record.itemID), item.move == record.move else {
                return .skipped("Moved again since") // the user's own later move stays
            }
            guard deps.fileExists(record.move.to) else { return .skipped("The file isn't there any more") }
            deps.undoSort(record.itemID)
            guard deps.item(record.itemID)?.move == nil else { return .failed("Couldn't move it back") }
            return .done("Put back in \(record.move.from.deletingLastPathComponent().lastPathComponent)")
        }

        // Open / Show in Finder (a tap only) ------------------------------------

        h.actions[.openFile] = { context in
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard let id = itemID(context.trigger) else { return .skipped("Nothing to open") }
            guard present(id) != nil else { return .skipped("The file isn't there any more") }
            deps.open(id)
            return .done("Opened")
        }
        h.isAvailable[.openFile] = { trigger in itemID(trigger).flatMap(present) != nil }

        h.actions[.revealInFinder] = { context in
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard let id = itemID(context.trigger) else { return .skipped("Nothing to show") }
            guard present(id) != nil else { return .skipped("The file isn't there any more") }
            deps.reveal(id)
            return .done("Shown in Finder")
        }
        h.isAvailable[.revealInFinder] = { trigger in itemID(trigger).flatMap(present) != nil }

        // Tray and Spaces: downloads here, everything else as before ----------

        chain(.addToTray, in: &h, isAvailable: { trigger in
            guard let id = itemID(trigger) else { return nil }
            return present(id) != nil
        }) { context in
            guard let id = itemID(context.trigger) else { return nil }
            guard let item = present(id) else { return .skipped("The file isn't there any more") }
            guard !item.addedToTray else { return .skipped("Already in the Tray") }
            deps.addToTray(id)
            return deps.item(id)?.addedToTray == true ? .done("Added to the Tray") : .failed("The Tray isn't available")
        }

        chain(.sendToSpace, in: &h, isAvailable: { trigger in
            guard let id = itemID(trigger) else { return nil }
            return present(id) != nil
        }) { context in
            guard let id = itemID(context.trigger) else { return nil }
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard present(id) != nil else { return .skipped("The file isn't there any more") }
            deps.sendToSpace(id)
            return deps.item(id)?.sentToSpace == true ? .done("Sent to Spaces") : .failed("Couldn't send it")
        }

        engine.hooks = h
        return state
    }

    /// Installs `mine` for download triggers (it returns nil for others) and
    /// keeps the previous hook and availability for every other trigger.
    private static func chain(
        _ action: MomentAction, in h: inout SmartMomentsHooks,
        isAvailable mineAvailable: @escaping @MainActor (MomentTrigger) -> Bool?,
        _ mine: @escaping @MainActor (MomentActionContext) async -> MomentActionResult?
    ) {
        let previousRun = h.actions[action]
        let previousAvailable = h.isAvailable[action]
        h.actions[action] = { context in
            if let result = await mine(context) { return result }
            guard let previousRun else { return .skipped("Not available") }
            return await previousRun(context)
        }
        h.isAvailable[action] = { trigger in
            if let available = mineAvailable(trigger) { return available }
            guard previousRun != nil else { return false }
            return previousAvailable?(trigger) ?? true
        }
    }
}
