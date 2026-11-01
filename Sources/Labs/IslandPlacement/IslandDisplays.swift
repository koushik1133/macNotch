import AppKit
import CoreGraphics
import IOKit

/// Reads displays for the resolver (public CoreGraphics and AppKit only).
@MainActor
enum IslandDisplays {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Stable across reboots, replugs and KVM switches, unlike the
    /// CGDirectDisplayID.
    static func uuid(for id: CGDirectDisplayID) -> String {
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return "display-\(id)" }
        let uuid = unmanaged.takeRetainedValue()
        return (CFUUIDCreateString(nil, uuid) as String?) ?? "display-\(id)"
    }

    static func info(for screen: NSScreen) -> IslandDisplayInfo? {
        guard let id = displayID(of: screen) else { return nil }
        return IslandDisplayInfo(
            id: id,
            uuid: uuid(for: id),
            name: screen.localizedName,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            hasNotch: screen.safeAreaInsets.top > 0,
            isMain: CGDisplayIsMain(id) != 0
        )
    }

    static func current() -> [IslandDisplayInfo] {
        NSScreen.screens.compactMap(info(for:))
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == id }
    }

    static func screen(containing point: NSPoint) -> NSScreen? {
        // NSRect.contains excludes maxY: the pointer pinned to the top row
        // of a display sits exactly there.
        NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(point) }
    }

    /// False only in clamshell mode: a Mac with a lid whose built-in panel
    /// isn't lit. A Mac mini, Studio or iMac-less desktop never counts as
    /// clamshell, so "Hide in Clamshell Mode" can't hide its island.
    static func builtInActive() -> Bool {
        var count: UInt32 = 0
        var lit = false
        if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetActiveDisplayList(count, &ids, &count) == .success {
                lit = ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
            }
        }
        return IslandClamshell.builtInActive(builtInLit: lit, hasLid: hasLid)
    }

    /// The power manager reports a clamshell state only on Macs with a lid
    /// (public IOKit, read once).
    static let hasLid: Bool = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return true }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return value != nil
    }()

    static func metrics(of screen: NSScreen) -> IslandScreenMetrics {
        IslandScreenMetrics(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxRightWidth: screen.auxiliaryTopRightArea?.width,
            backingScale: screen.backingScaleFactor
        )
    }

    /// Displays in CG coordinates, for matching window bounds.
    static func bounds() -> [IslandDisplayBounds] {
        NSScreen.screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            return IslandDisplayBounds(id: id, bounds: CGDisplayBounds(id), safeAreaTop: screen.safeAreaInsets.top)
        }
    }
}

/// The island's display, for SparkV's other windows near the notch (the
/// Quick Capture toast, the File Drop shelf, Focus cards), so they land on
/// the same screen as the island. See INTEGRATION.md.
@MainActor
enum IslandScreen {
    /// Set by NotchWindowController whenever it lays the island out.
    static var displayID: CGDirectDisplayID?
    /// The island is hidden or ignores hover (no shelf over it then).
    static var isSuppressed = false

    /// The island's screen; before the first layout, the old heuristic
    /// (notched display, else the main one).
    static var current: NSScreen? {
        if let displayID, let screen = IslandDisplays.screen(for: displayID) { return screen }
        return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    /// Where a drop shelf may appear: nil while the island is hidden.
    static var shelfScreen: NSScreen? {
        isSuppressed ? nil : current
    }
}
