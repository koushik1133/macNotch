import AppKit
import Quartz

/// Quick Look for Tray items (Space, or the card menu's Quick Look).
///
/// The preview panel is the system's shared QLPreviewPanel. It is ordered
/// front without taking key status, so keystrokes keep going to the Tray
/// (Space and Esc close it, the arrow keys page through the items) and
/// SparkV never activates or steals focus from the frontmost app. Its level
/// sits above the notch panel (`.statusBar`), or it would open behind it.
/// While it is up, the window controller keeps the drawer open
/// (`isVisible`, see INTEGRATION.md).
@MainActor
final class TrayQuickLook: NSObject {
    static let shared = TrayQuickLook()

    /// What is being previewed, in order.
    private(set) var urls: [URL] = []
    /// Tray item id per URL, for the zoom-from-card effect.
    private(set) var itemIDs: [UUID] = []
    /// The card views, for the zoom-from-card effect (weak).
    private var cardViews: [UUID: WeakView] = [:]
    /// Called when the shown item changes from inside the panel (its own arrows).
    var onIndexChange: ((Int) -> Void)?
    /// Zoom out of the card (a click) or appear at once (Space, Reduce Motion).
    private(set) var zoomsFromCard = true

    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    /// True while the preview panel is on screen.
    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    var currentIndex: Int {
        guard QLPreviewPanel.sharedPreviewPanelExists() else { return 0 }
        return QLPreviewPanel.shared().currentPreviewItemIndex
    }

    func register(_ view: NSView, for id: UUID) {
        cardViews[id] = WeakView(view)
        cardViews = cardViews.filter { $0.value.view != nil }
    }

    /// Shows (or updates) the preview. `start` is the index to open on.
    /// `fromKeyboard`: keyboard-triggered UI appears instantly, so no zoom
    /// out of the card.
    func show(urls: [URL], itemIDs: [UUID], start: Int = 0, fromKeyboard: Bool = false) {
        guard !urls.isEmpty else { return }
        zoomsFromCard = !fromKeyboard && !SparkVMotion.reduceMotion
        self.urls = urls
        self.itemIDs = itemIDs
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.delegate = self
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.collectionBehavior.insert(.canJoinAllSpaces)
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(start, 0), urls.count - 1)
        if !panel.isVisible {
            panel.orderFront(nil)
            // Some systems only show the panel when it's key: then it has
            // to be, and SparkV has to be active for it to take keys.
            if !panel.isVisible {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
            }
        }
        AppLog.log("Tray: Quick Look on \(urls.count) item(s)")
    }

    func select(index: Int) {
        guard isVisible, urls.indices.contains(index) else { return }
        QLPreviewPanel.shared().currentPreviewItemIndex = index
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// Space while it's up closes it; otherwise opens on `urls`.
    func toggle(urls: [URL], itemIDs: [UUID], start: Int = 0, fromKeyboard: Bool = false) {
        if isVisible { close() } else { show(urls: urls, itemIDs: itemIDs, start: start, fromKeyboard: fromKeyboard) }
    }

    fileprivate func url(at index: Int) -> URL? {
        urls.indices.contains(index) ? urls[index] : nil
    }

    func sourceFrame(at index: Int) -> NSRect {
        guard zoomsFromCard, itemIDs.indices.contains(index), let view = cardViews[itemIDs[index]]?.view,
              let window = view.window, window.isVisible else { return .zero }
        let inWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }
}

// The panel calls its data source and delegate on the main thread.
extension TrayQuickLook: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated { self.url(at: index) }
        return url.map { $0 as NSURL }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        let target = (item as? NSURL) as URL?
        return MainActor.assumeIsolated {
            guard let target, let index = urls.firstIndex(of: target) else { return .zero }
            return sourceFrame(at: index)
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Arrow keys inside the panel (when the user clicked into it): keep
        // the Tray selection in step.
        guard let event, event.type == .keyDown else { return false }
        let code = event.keyCode
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard code == 123 || code == 124 || code == 125 || code == 126 else { return }
                TrayQuickLook.shared.onIndexChange?(TrayQuickLook.shared.currentIndex)
            }
        }
        return false
    }
}
