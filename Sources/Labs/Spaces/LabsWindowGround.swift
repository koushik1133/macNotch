import AppKit
import SwiftUI

/// Keeps an AppKit window's own background (the strip under a transparent
/// title bar, resize edges) on the current look's window ground. The SwiftUI
/// root rebuilds itself through `followsAppearance()`; this covers the part
/// AppKit draws. Used by the Spaces, Downloads Rules, Quick Capture and
/// Sync to iPhone windows.
@MainActor
enum LabsWindowGround {
    /// Starts following the look for `window`. The observer holds the
    /// window weakly (each of these windows is made once and reused).
    static func follow(_ window: NSWindow, color: @escaping @MainActor @Sendable () -> NSColor = { NSColor(SparkVTheme.background) }) {
        window.backgroundColor = color()
        NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                window?.backgroundColor = color()
            }
        }
    }
}
