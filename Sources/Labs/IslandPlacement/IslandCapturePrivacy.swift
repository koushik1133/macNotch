import AppKit
import Combine

/// "Hide SparkV from Screenshots & Screen Sharing" (off by default).
///
/// Sets `sharingType = .none` on the island and on SparkV's other floating
/// panels (toasts, the clipboard stack, search, the file shelf, Focus
/// cards…), so the window server leaves them out of captures while they
/// stay visible on screen. Panels are picked up as they appear (window
/// occlusion and key notifications, no polling). Titled windows (Settings,
/// Meeting Notes, Spaces) are left alone: people share those on purpose.
/// Windows that already exclude themselves (Clicky's pointer, the edge
/// glows) are never touched, so turning this off can't expose them.
///
/// Windows are tracked by weak reference and compared by identity, never by
/// address alone: AppKit reuses the memory of closed windows, so a new
/// panel at an old address must not inherit the old one's record.
///
/// Best effort: on macOS 15 and later some ScreenCaptureKit recorders,
/// including conferencing apps, may still capture these windows.
@MainActor
final class IslandCapturePrivacy {
    static let shared = IslandCapturePrivacy()
    /// Posted when the setting changes; `object` is nil.
    static let didChangeNotification = Notification.Name("SparkV.IslandCapturePrivacy.didChange")

    private let settings: IslandPlacementSettings
    private var observers: [NSObjectProtocol] = []
    private var settingObserver: AnyCancellable?
    /// Windows this class set to `.none` (restored to `.readOnly` when off).
    private var managed = IslandWeakWindowSet()
    /// Windows registered explicitly (the island and its mirrors).
    private var registered = IslandWeakWindowSet()

    init(settings: IslandPlacementSettings? = nil) {
        self.settings = settings ?? .shared
    }

    var isOn: Bool { settings.hideFromCapture }

    func start() {
        guard observers.isEmpty else { return }
        // A panel's occlusion changes when it is first ordered in.
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.consider(window)
                }
            }
            observers.append(token)
        }
        // A closed window's records go at once, before its address is reused.
        let close = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                self.managed.remove(window)
                self.registered.remove(window)
            }
        }
        observers.append(close)
        settingObserver = settings.$hideFromCapture.removeDuplicates().dropFirst().sink { [weak self] on in
            DispatchQueue.main.async {
                self?.applyAll()
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
                AppLog.log("Island: hide from capture \(on ? "on" : "off")")
            }
        }
        applyAll()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        settingObserver = nil
    }

    /// Always managed, whether or not it looks like a floating panel.
    func register(_ window: NSWindow) {
        registered.insert(window)
        apply(to: window)
    }

    func unregister(_ window: NSWindow) {
        registered.remove(window)
        if managed.contains(window) {
            window.sharingType = .readOnly
            managed.remove(window)
        }
    }

    /// Floating panels SparkV draws over other apps (borderless or
    /// non-activating, no title bar).
    static func isFloatingPanel(_ window: NSWindow) -> Bool {
        guard !window.styleMask.contains(.titled) else { return false }
        return window is NSPanel || window.styleMask.contains(.borderless)
    }

    private func consider(_ window: NSWindow) {
        guard registered.contains(window) || Self.isFloatingPanel(window) else { return }
        apply(to: window)
    }

    private func apply(to window: NSWindow) {
        let ours = managed.contains(window)
        // Already `.none` and not set by us: its owner hides it on purpose.
        // Decided now, from the window itself, never from a cached address.
        if IslandCaptureRule.isOwnerManaged(isManagedByUs: ours, isRegistered: registered.contains(window),
                                            alreadyHidden: window.sharingType == .none) { return }
        if isOn {
            if window.sharingType != .none { window.sharingType = .none }
            managed.insert(window)
        } else if ours {
            window.sharingType = .readOnly
            managed.remove(window)
        }
    }

    private func applyAll() {
        managed.prune()
        registered.prune()
        for window in NSApp.windows where registered.contains(window) || Self.isFloatingPanel(window) {
            apply(to: window)
        }
        if !isOn {
            for window in managed.windows { window.sharingType = .readOnly }
            managed.removeAll()
        }
    }
}

/// Weak references compared by identity: an entry matches only the very
/// window it was made for, never a later one at the same address.
@MainActor
struct IslandWeakWindowSet {
    private final class Box {
        weak var window: NSWindow?
        init(_ window: NSWindow) { self.window = window }
    }
    private var boxes: [ObjectIdentifier: Box] = [:]

    func contains(_ window: NSWindow) -> Bool {
        boxes[ObjectIdentifier(window)]?.window === window
    }

    mutating func insert(_ window: NSWindow) {
        boxes[ObjectIdentifier(window)] = Box(window)
    }

    mutating func remove(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let box = boxes[id], box.window == nil || box.window === window { boxes[id] = nil }
    }

    mutating func prune() {
        boxes = boxes.filter { $0.value.window != nil }
    }

    mutating func removeAll() { boxes.removeAll() }

    var windows: [NSWindow] { boxes.values.compactMap(\.window) }
}
