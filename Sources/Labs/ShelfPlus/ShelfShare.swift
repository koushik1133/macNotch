import AppKit
import SwiftUI

/// The system Share menu for shelf items, with cross-platform senders first.
///
/// `NSSharingServicePicker` lists every installed share extension: AirDrop,
/// Messages, Mail, Notes… and NearDrop's "send with Quick Share" extension
/// when NearDrop is installed (Android). The picker's delegate moves those
/// nearby senders to the top and adds SparkV's own LocalSend sender
/// (Android, Windows, Linux), which opens the Nearby panel.
@MainActor
enum ShelfShare {
    /// What the share services get for tray items: files and images as their
    /// files, links as web URLs, other text as text.
    static func objects(for items: [TrayItem]) -> [Any] {
        items.compactMap { item -> Any? in
            switch item.kind {
            case .file, .image:
                guard let url = item.url, FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url as NSURL
            case .text:
                guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                if let link = item.webLink { return link as NSURL }
                return text as NSString
            }
        }
    }

    /// Files to hand to LocalSend for tray items (text goes as a .txt).
    static func fileURLs(for items: [TrayItem]) -> [URL] {
        items.compactMap { item -> URL? in
            switch item.kind {
            case .file, .image:
                guard let url = item.url, FileManager.default.fileExists(atPath: url.path) else { return nil }
                return url
            case .text:
                guard let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return AirDrop.temporaryTextFile(text)
            }
        }
    }

    static let localSendTitle = "LocalSend (Android, Windows, Linux)…"

    /// Titles of share services that reach Android / Windows devices.
    static let nearbyServiceMarkers = ["neardrop", "quick share", "localsend", "nearby"]

    static func isNearbyService(title: String) -> Bool {
        let lowered = title.lowercased()
        return nearbyServiceMarkers.contains { lowered.contains($0) }
    }

    /// The services in menu order: nearby senders first when the setting is
    /// on, then the system's order; SparkV's LocalSend sender after them.
    static func ordered(_ proposed: [NSSharingService], promote: Bool, localSend: NSSharingService?) -> [NSSharingService] {
        var list = proposed
        if promote {
            let nearby = list.filter { isNearbyService(title: $0.title) }
            list.removeAll { isNearbyService(title: $0.title) }
            list = nearby + list
        }
        if let localSend {
            let insertAt = promote ? list.prefix(while: { isNearbyService(title: $0.title) }).count : list.count
            list.insert(localSend, at: insertAt)
        }
        return list
    }

    /// A "Share" menu item (submenu of services) for an NSMenu.
    static func menuItem(for objects: [Any], localSendFiles: @escaping () -> [URL]) -> NSMenuItem {
        let picker = NSSharingServicePicker(items: objects)
        let delegate = ShelfSharePickerDelegate(localSendFiles: localSendFiles)
        picker.delegate = delegate
        // The picker keeps its delegate weakly.
        retain(delegate, for: picker)
        let item = picker.standardShareMenuItem
        item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        return item
    }

    /// Shows the share picker next to the pointer (from a SwiftUI button or menu).
    static func presentAtPointer(_ objects: [Any], localSendFiles: @escaping () -> [URL]) {
        guard !objects.isEmpty else {
            NSSound.beep()
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.contains(mouse) && $0.contentView != nil }),
              let view = window.contentView else {
            NSSound.beep()
            return
        }
        let point = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
        let rect = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        let picker = NSSharingServicePicker(items: objects)
        let delegate = ShelfSharePickerDelegate(localSendFiles: localSendFiles)
        picker.delegate = delegate
        retain(delegate, for: picker)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    // MARK: Delegate lifetime

    private static var delegates: [ObjectIdentifier: ShelfSharePickerDelegate] = [:]
    private static var order: [ObjectIdentifier] = []

    /// Keeps the last few picker delegates alive (a menu item's picker lives
    /// as long as its menu; the oldest are dropped).
    private static func retain(_ delegate: ShelfSharePickerDelegate, for picker: NSSharingServicePicker) {
        let key = ObjectIdentifier(picker)
        delegates[key] = delegate
        order.append(key)
        while order.count > 8 {
            delegates[order.removeFirst()] = nil
        }
    }
}

/// Orders the services, adds "LocalSend (Nearby)…", and brings the chosen
/// service's window forward (an agent app's share sheets otherwise open
/// behind the frontmost app).
@MainActor
final class ShelfSharePickerDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let localSendFiles: () -> [URL]

    init(localSendFiles: @escaping () -> [URL]) {
        self.localSendFiles = localSendFiles
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any],
                              proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        let files = localSendFiles
        let localSend = NSSharingService(
            title: ShelfShare.localSendTitle,
            image: NSImage(systemSymbolName: "wave.3.right.circle", accessibilityDescription: nil) ?? NSImage(),
            alternateImage: nil
        ) {
            MainActor.assumeIsolated { LocalSendPanelController.shared.open(files: files()) }
        }
        return ShelfShare.ordered(proposedServices, promote: ShelfSettings.shared.promoteNearby, localSend: localSend)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else { return }
        AppLog.log("Share: chose \(service.title)")
        // Mail, Messages, AirDrop… show a window of this app, which has to
        // be active or it opens behind the frontmost app. SparkV's own
        // LocalSend panel shows itself.
        if service.title != ShelfShare.localSendTitle {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        AppLog.log("Share: shared \(items.count) item(s) with \(sharingService.title)")
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        AppLog.log("Share: \(sharingService.title) failed: \(error.localizedDescription)")
    }
}
