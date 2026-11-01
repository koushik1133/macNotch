import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which drags may open the closed notch and land in the drawer.
///
/// Before this, any left-button drag that reached the notch opened the
/// drawer and flipped it to the Tray: a Safari tab, a link, a text
/// selection or a window being moved. Now (by default) only drags that
/// carry files do: file URLs, file promises and image data, read from the
/// drag pasteboard's *types* (never its contents).
@MainActor
enum ShelfDragFilter {
    /// For the window controller's hover handler: may the closed notch open
    /// while the left button is down? True when no drag is going on.
    static func allowsHoverOpen(pressBeganInPanel: Bool,
                                buttons: Int = NSEvent.pressedMouseButtons,
                                setting: ShelfSettings.OpenOnDrag? = nil,
                                isFileDrag: (() -> Bool)? = nil) -> Bool {
        guard buttons & 1 != 0, !pressBeganInPanel else { return true }
        switch setting ?? ShelfSettings.shared.openOnDrag {
        case .anything: return true
        case .never: return false
        case .files: return isFileDrag?() ?? isFileDragInProgress()
        }
    }

    /// A file drag from another app is under way (the File Drop watcher's
    /// session check, which compares the drag pasteboard's change count with
    /// the one at mouse-down, so a stale pasteboard from an earlier drag
    /// never counts).
    static func isFileDragInProgress() -> Bool {
        if let controller = FileDropController.current { return controller.isFileDragLive }
        return FileDropDragWatcher.carriesFiles(on: NSPasteboard(name: .drag))
    }

    /// For a drop on the open drawer: does this drag carry files?
    static func dragCarriesFiles(_ info: DropInfo, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        // Not `.image` from DropInfo: a link's favicon would count.
        info.hasItemsConforming(to: [.fileURL]) || FileDropDragWatcher.carriesFiles(on: pasteboard)
    }

    /// The Converter takes what its own `accept` can read: file URLs, or
    /// image data that isn't a browser link's favicon. Promised files
    /// (Mail attachments) have neither, so they're refused up front instead
    /// of failing silently after the drop.
    static func converterAccepts(_ info: DropInfo, pasteboard: NSPasteboard = NSPasteboard(name: .drag)) -> Bool {
        if info.hasItemsConforming(to: [.fileURL]) { return true }
        let raw = Set((pasteboard.types ?? []).map(\.rawValue))
        guard raw.isDisjoint(with: FileDropDragWatcher.urlTypes) else { return false }
        return info.hasItemsConforming(to: [.image])
    }

    /// Tabs whose own drop handling takes links and text (the Tray keeps
    /// them; Spaces saves a link).
    static let textTabs: Set<NotchState.Tab> = [.tray, .spaces]

    /// Whether the drawer takes this drag on `tab`. Files: everywhere (other
    /// tabs flip to the Tray). Links and text: only on the Tray or Spaces
    /// the user opened, or anywhere with "Files, Links and Text".
    static func accepts(carriesFiles: Bool, carriesText: Bool, tab: NotchState.Tab,
                        setting: ShelfSettings.OpenOnDrag? = nil) -> Bool {
        if carriesFiles { return true }
        guard carriesText else { return false }
        return textTabs.contains(tab) || (setting ?? ShelfSettings.shared.openOnDrag) == .anything
    }
}

/// The open drawer's drop target, replacing `.onDrop(of:isTargeted:)` in
/// NotchNookLayoutView (see INTEGRATION.md). Same routing as before (Converter,
/// Spaces and File Drop keep their drops; everything else lands in the
/// Tray), plus the drag filter and real file-promise support.
struct ShelfDrawerDrop: DropDelegate {
    /// `.data` lets promised files (no file URL) through; the delegate
    /// decides what's welcome.
    static let types: [UTType] = [.fileURL, .image, .url, .text, .data]

    let state: NotchState
    let tray: TrayStore
    let converter: ConverterController
    let fileDrop: FileDropController

    private func isWelcome(_ info: DropInfo) -> Bool {
        // A card being dragged out of a SparkV shelf isn't a drop for the drawer.
        if TrayDragOut.isActive { return false }
        let files = ShelfDragFilter.dragCarriesFiles(info)
        let text = info.hasItemsConforming(to: [.url, .text])
        // The converter takes what it can read; the strip takes files only.
        if state.tab == .converter { return ShelfDragFilter.converterAccepts(info) }
        if state.tab == .fileDrop { return files }
        return ShelfDragFilter.accepts(carriesFiles: files, carriesText: text, tab: state.tab)
    }

    func validateDrop(info: DropInfo) -> Bool { isWelcome(info) }

    func dropEntered(info: DropInfo) {
        // Setting this flips other tabs to the Tray (NotchState).
        if isWelcome(info) { state.isDropTargeted = true }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isWelcome(info) ? .copy : .forbidden)
    }

    func dropExited(info: DropInfo) {
        state.isDropTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        state.isDropTargeted = false
        guard isWelcome(info) else { return false }
        let providers = info.itemProviders(for: Self.types)
        switch state.tab {
        case .converter:
            return converter.accept(providers)
        case .spaces:
            // Between the Space cards: file it in the Spaces Inbox.
            return SpacesDropIngestor.accept(providers, into: nil, store: SpaceStore.shared)
        case .fileDrop:
            return fileDrop.accept(providers)
        default:
            // Promised non-image files (Mail, Affinity, WeChat…) come through
            // AppKit's promise receiver, written straight to disk; images and
            // everything else through the item providers.
            let receivers = ShelfDropResolver.promiseReceivers(on: NSPasteboard(name: .drag))
            if !receivers.isEmpty, !ShelfDropResolver.promisesAreImages(receivers) {
                tray.acceptPromises(receivers)
            } else {
                tray.accept(providers)
            }
            return true
        }
    }
}
