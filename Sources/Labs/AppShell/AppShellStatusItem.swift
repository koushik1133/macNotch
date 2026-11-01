import AppKit
import SwiftUI

/// The optional menu bar icon (off by default): a monochrome template
/// symbol whose menu opens the drawer and Settings, checks for updates,
/// shows About and quits. ⌘-dragging it out of the menu bar turns the
/// setting off. On a crowded notched menu bar macOS may hide it behind the
/// notch; opening SparkV again (Finder, Spotlight) always reaches Settings.
@MainActor
final class StatusItemController: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = StatusItemController()
    static let visibleKey = "AppShell.statusItem.visible"

    @Published private(set) var isVisible: Bool

    private var item: NSStatusItem?
    private var visibilityObservation: NSKeyValueObservation?
    private var started = false

    private override init() {
        isVisible = UserDefaults.standard.bool(forKey: Self.visibleKey)
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        if isVisible { install() }
    }

    /// From applicationWillTerminate. The item is left in place: the
    /// process exit takes it out of the menu bar, while removeStatusItem
    /// would make macOS forget the position the user ⌘-dragged it to
    /// ("NSStatusItem Preferred Position SparkV.StatusItem"). Only turning
    /// the icon off removes it.
    func stop() {
        started = false
        visibilityObservation?.invalidate()
        visibilityObservation = nil
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        UserDefaults.standard.set(visible, forKey: Self.visibleKey)
        AppLog.log("Status item: \(visible ? "shown" : "hidden")")
        guard started else { return }
        visible ? install() : remove()
    }

    private func install() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "SparkV.StatusItem"
        item.behavior = .removalAllowed
        if let button = item.button {
            let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "SparkV")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "SparkV"
            button.setAccessibilityLabel("SparkV")
        }
        let menu = NSMenu(title: "SparkV")
        menu.delegate = self
        item.menu = menu
        item.isVisible = true
        // ⌘-drag out of the menu bar: macOS hides the item; follow it.
        visibilityObservation = item.observe(\.isVisible, options: [.new]) { _, change in
            guard change.newValue == false else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let controller = StatusItemController.shared
                    if controller.item != nil, controller.item?.isVisible == false { controller.setVisible(false) }
                }
            }
        }
        self.item = item
    }

    private func remove() {
        visibilityObservation?.invalidate()
        visibilityObservation = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Built fresh each time it opens, so the update line is current.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            menu.removeAllItems()
            for entry in AppShellMenus.shellMenu(includeHide: true).items {
                entry.menu?.removeItem(entry)
                menu.addItem(entry)
            }
        }
    }
}
