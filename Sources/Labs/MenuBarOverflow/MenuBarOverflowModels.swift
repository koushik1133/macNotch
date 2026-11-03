import CoreGraphics
import Foundation

// Pure logic for Menu Bar Overflow: which menu bar extras the notch hides,
// how to name them, and how to match a pressed item again. Foundation and
// CoreGraphics only (tested).

/// One menu bar extra (status item) as Accessibility reports it.
struct MenuBarExtraItem: Identifiable, Equatable, Sendable {
    let pid: Int32
    /// Position among its app's extras (left to right).
    let index: Int
    let appName: String
    let bundleID: String?
    /// AXTitle / AXDescription / AXHelp, the best one.
    let label: String
    /// Global Accessibility coordinates (top-left origin of the main display).
    let frame: CGRect
    var isHidden: Bool

    var id: String { "\(pid):\(index):\(label)" }

    /// System items (Control Center, the clock, Spotlight, Siri).
    var isSystem: Bool {
        guard let bundleID else { return false }
        return MenuBarNaming.systemBundleIDs.contains(bundleID)
    }

    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == appName { return appName }
        return isSystem ? trimmed : trimmed
    }
}

/// A raw Accessibility read, before the hidden check.
struct MenuBarExtraRaw: Equatable, Sendable {
    var title: String?
    var description: String?
    var help: String?
    var identifier: String?
    var frame: CGRect
}

enum MenuBarGeometry {
    /// Converts an AppKit screen frame (bottom-left origin) to Accessibility
    /// coordinates (top-left origin of the primary display).
    static func axRect(fromAppKit rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The menu bar strip of a display in Accessibility coordinates and,
    /// on a notched display, the notch's horizontal span (between the
    /// auxiliary top areas).
    struct Display: Equatable, Sendable {
        var menuBar: CGRect
        var notch: ClosedRange<CGFloat>?
    }

    /// Hidden when the item sits (mostly) under the notch, is pushed off the
    /// display, or has no size. Items on other displays' menu bars are not
    /// hidden by this display.
    static func isHidden(_ frame: CGRect, displays: [Display]) -> Bool {
        if frame.width < 1 || frame.height < 1 { return true }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        // The display whose menu bar row this item is on (by y).
        let candidates = displays.filter { abs($0.menuBar.midY - center.y) <= max(24, $0.menuBar.height) }
        guard !candidates.isEmpty else {
            // Not on any menu bar row: pushed off (y), e.g. hidden by a divider.
            return true
        }
        for display in candidates {
            let bar = display.menuBar
            if center.x >= bar.minX, center.x <= bar.maxX {
                if let notch = display.notch {
                    let overlap = min(frame.maxX, notch.upperBound) - max(frame.minX, notch.lowerBound)
                    if overlap > frame.width * 0.4 { return true }
                }
                return false
            }
        }
        // Off the left or right edge of every menu bar.
        return true
    }

    /// The Accessibility item that best matches a remembered frame (the
    /// same item after the menu bar shifted a little).
    static func bestMatch(for target: CGRect, among frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        var best: (index: Int, distance: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let distance = abs(frame.midX - target.midX) + abs(frame.width - target.width) * 0.5
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best.map(\.index)
    }
}

enum MenuBarNaming {
    static let systemBundleIDs: Set<String> = [
        "com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.Spotlight", "com.apple.Siri",
        "com.apple.TextInputMenuAgent", "com.apple.notificationcenterui", "com.apple.weather.menu",
    ]

    /// The best human label: title, then description, then help, then the app.
    static func label(_ raw: MenuBarExtraRaw, appName: String) -> String {
        for candidate in [raw.title, raw.description, raw.help] {
            if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
               text.lowercased() != "status item", text.count <= 60 {
                return text
            }
        }
        return appName
    }

    /// An SF Symbol for system items (their own icons need Screen Recording).
    static func symbol(for label: String, isSystem: Bool) -> String? {
        let text = label.lowercased()
        let table: [(String, String)] = [
            ("wi-fi", "wifi"), ("wi‑fi", "wifi"), ("wifi", "wifi"), ("battery", "battery.75percent"),
            ("bluetooth", "dot.radiowaves.left.and.right"), ("control center", "switch.2"), ("control centre", "switch.2"),
            ("clock", "clock"), ("siri", "mic.circle"), ("spotlight", "magnifyingglass"), ("sound", "speaker.wave.2.fill"),
            ("volume", "speaker.wave.2.fill"), ("focus", "moon.fill"), ("do not disturb", "moon.fill"),
            ("display", "sun.max.fill"), ("brightness", "sun.max.fill"), ("now playing", "play.circle"),
            ("screen mirroring", "rectangle.on.rectangle"), ("airplay", "airplayvideo"), ("time machine", "clock.arrow.circlepath"),
            ("vpn", "lock.shield"), ("user", "person.crop.circle"), ("input", "keyboard"), ("keyboard", "keyboard"),
            ("weather", "cloud.sun.fill"), ("notification", "bell.badge"), ("accessibility", "accessibility"),
            ("stage manager", "squares.leading.rectangle"), ("hearing", "ear"), ("airdrop", "airplayaudio"),
        ]
        for (needle, symbol) in table where text.contains(needle) { return symbol }
        return isSystem ? "menubar.rectangle" : nil
    }

    /// Ordered left to right, hidden first when asked.
    static func sorted(_ items: [MenuBarExtraItem], hiddenFirst: Bool) -> [MenuBarExtraItem] {
        items.sorted { a, b in
            if hiddenFirst, a.isHidden != b.isHidden { return a.isHidden }
            return a.frame.minX < b.frame.minX
        }
    }
}
