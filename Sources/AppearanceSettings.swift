import AppKit
import os
import SwiftUI

/// The app's two looks. Apple (the default) is the native macOS / Dynamic
/// Island look: pure black island, white and grey SF Symbols, per-agent
/// colors, system-blue accent. SparkV Red is the sparkv.si brand look:
/// near-black ground and one signal red.
enum AppearanceStyle: String, CaseIterable, Identifiable, Sendable {
    case apple
    case sparkvRed

    var id: String { rawValue }

    /// Gear menu title.
    var title: String {
        switch self {
        case .apple: "Apple (Default)"
        case .sparkvRed: "SparkV Red"
        }
    }

    /// UserDefaults key the choice is saved under.
    static let defaultsKey = "AppearanceStyle"

    /// The look in effect, readable from any thread or actor. Backed by a
    /// lock-protected copy of the saved value, so the hundreds of theme
    /// token reads in a body pass don't each hit UserDefaults.
    static var current: AppearanceStyle {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    private static let storage = OSAllocatedUnfairLock<AppearanceStyle>(initialState: saved)

    /// The value saved in UserDefaults (Apple when nothing is saved yet).
    static var saved: AppearanceStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppearanceStyle.init(rawValue:)) ?? .apple
    }
}

/// Observable appearance choice for views and menus. Root views observe it
/// (see `followsAppearance()`), and rebuild when it changes, so every
/// `SparkVTheme` token resolves again at once.
@MainActor
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    /// Posted on the main thread after the look changes, for AppKit windows
    /// that set colors outside SwiftUI (e.g. a window's background color).
    static let didChangeNotification = Notification.Name("SparkV.AppearanceDidChange")

    @Published var style: AppearanceStyle {
        didSet {
            guard style != oldValue else { return }
            AppearanceStyle.current = style
            UserDefaults.standard.set(style.rawValue, forKey: AppearanceStyle.defaultsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    private init() {
        let saved = AppearanceStyle.saved
        AppearanceStyle.current = saved
        style = saved
    }
}

/// Rebuilds its content whenever the look changes. Theme tokens are static
/// (read in `body`), so a view only picks up a new look when it is built
/// again; a new identity does that for the whole tree under this root.
struct AppearanceRoot<Content: View>: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.id(appearance.style)
    }
}

extension View {
    /// Wraps a root view (drawer, window, panel) so switching the look in
    /// the gear menu redraws it immediately.
    func followsAppearance() -> some View {
        AppearanceRoot { self }
    }
}

/// The gear menu's Appearance submenu: one checkable item per look.
/// Use as `AppearanceMenu()` next to "Notch Theme".
struct AppearanceMenu: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Picker("Appearance", selection: $appearance.style) {
            ForEach(AppearanceStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
    }
}

/// Puts an AppKit window on the current look's window ground: a vibrant
/// dark material behind SwiftUI content in Apple, the flat brand ground in
/// SparkV Red. Use as a window's `.background { AppearanceWindowBackground() }`.
struct AppearanceWindowBackground: View {
    var body: some View {
        if SparkVTheme.isApple {
            VisualEffectBackdrop(material: .underWindowBackground)
                .overlay(SparkVTheme.background.opacity(0.55))
        } else {
            SparkVTheme.background
        }
    }
}

/// NSVisualEffectView for SwiftUI (window vibrancy in the Apple look).
struct VisualEffectBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
