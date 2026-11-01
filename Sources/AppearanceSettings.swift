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

// MARK: - Look options

/// An sRGB color as three 0...1 components: what the accent picker stores.
struct LookRGB: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    /// "#RRGGBB" (or "RRGGBB"); nil when it isn't six hex digits.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }

    /// WCAG relative luminance (0 black ... 1 white).
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio between two colors (1 ... 21).
    static func contrast(_ a: LookRGB, _ b: LookRGB) -> Double {
        let la = a.luminance, lb = b.luminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `top` at `alpha` over this color (straight sRGB blend, as the screen shows it).
    func blended(with top: LookRGB, alpha: Double) -> LookRGB {
        LookRGB(red + (top.red - red) * alpha, green + (top.green - green) * alpha, blue + (top.blue - blue) * alpha)
    }

    static let white = LookRGB(1, 1, 1)
    static let black = LookRGB(0, 0, 0)
    /// macOS dark default accent (#0A84FF).
    static let systemBlue = LookRGB(10 / 255, 132 / 255, 1)

    /// `NSColor` resolved to sRGB in the dark appearance (nil if it can't be).
    static func resolved(_ color: NSColor) -> LookRGB? {
        var result: LookRGB?
        let resolve = {
            if let srgb = color.usingColorSpace(.sRGB) {
                result = LookRGB(Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
            }
        }
        if let dark = NSAppearance(named: .darkAqua) {
            dark.performAsCurrentDrawingAppearance(resolve)
        } else {
            resolve()
        }
        return result
    }
}

/// The accent for buttons, toggles, selection and links. "Look Default" is
/// the user's macOS accent in Apple and signal red in SparkV Red; a named
/// color or a custom one replaces it in both looks. Recording and
/// destructive red never change.
enum AccentChoice: String, CaseIterable, Identifiable, Sendable {
    case lookDefault
    case blue, purple, pink, red, orange, yellow, green, mint, indigo, graphite
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lookDefault: "Look Default"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .mint: "Mint"
        case .indigo: "Indigo"
        case .graphite: "Graphite"
        case .custom: "Custom"
        }
    }

    /// The macOS dark-mode system colors; nil for Look Default and Custom.
    var rgb: LookRGB? {
        switch self {
        case .lookDefault, .custom: nil
        case .blue: LookRGB(10 / 255, 132 / 255, 255 / 255)
        case .purple: LookRGB(191 / 255, 90 / 255, 242 / 255)
        case .pink: LookRGB(255 / 255, 55 / 255, 95 / 255)
        case .red: LookRGB(255 / 255, 69 / 255, 58 / 255)
        case .orange: LookRGB(255 / 255, 159 / 255, 10 / 255)
        case .yellow: LookRGB(255 / 255, 214 / 255, 10 / 255)
        case .green: LookRGB(48 / 255, 209 / 255, 88 / 255)
        case .mint: LookRGB(102 / 255, 212 / 255, 207 / 255)
        case .indigo: LookRGB(94 / 255, 92 / 255, 230 / 255)
        case .graphite: LookRGB(142 / 255, 142 / 255, 147 / 255)
        }
    }

    /// The named colors, in picker order (no Look Default, no Custom).
    static let swatches: [AccentChoice] = [.blue, .purple, .pink, .red, .orange, .yellow, .green, .mint, .indigo, .graphite]
}

/// Text size for the drawer (macOS has no Dynamic Type for apps like this).
/// The open drawer zooms its content by `factor`; windows that use the
/// `SparkVTheme.Scaled` fonts grow their text by the same amount.
enum TextSize: String, CaseIterable, Identifiable, Sendable {
    case standard
    case large
    case larger

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .large: "Large"
        case .larger: "Larger"
        }
    }

    var factor: CGFloat {
        switch self {
        case .standard: 1
        case .large: 1.12
        case .larger: 1.25
        }
    }

    /// Smallest text the scaled fonts draw at a size above Standard (HIG
    /// minimum for macOS body text is 10 pt).
    static let minimumPoints: CGFloat = 10
}

/// How solid the island is while it rests with nothing to show. Applies only
/// on displays without a camera notch (on a notched display a see-through
/// island would show the cutout's edges), and never with Reduce Transparency.
enum RestingOpacity: String, CaseIterable, Identifiable, Sendable {
    case solid
    case soft
    case faint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .solid: "Solid"
        case .soft: "Soft (85 %)"
        case .faint: "Faint (60 %)"
        }
    }

    var value: Double {
        switch self {
        case .solid: 1
        case .soft: 0.85
        case .faint: 0.6
        }
    }
}

/// What the open drawer is made of. Black is the original island; Liquid
/// Glass (macOS 26 and later) lets the desktop show through a dark glass
/// while the band beside the camera stays black. Closed, the island is
/// always black so it matches the hardware notch.
enum DrawerMaterial: String, CaseIterable, Identifiable, Sendable {
    case black
    case liquidGlass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: "Black (Default)"
        case .liquidGlass: "Liquid Glass"
        }
    }
}

/// SparkV's own contrast boost on top of the system setting.
enum ContrastPreference: String, CaseIterable, Identifiable, Sendable {
    /// Higher contrast only while System Settings › Accessibility › Display ›
    /// Increase Contrast is on.
    case system
    /// Always the higher-contrast tokens.
    case higher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Follow System"
        case .higher: "Always Higher"
        }
    }
}

/// The macOS display accessibility switches the theme follows.
struct AccessibilityDisplay: Hashable, Sendable {
    var increaseContrast = false
    var reduceTransparency = false
    var differentiateWithoutColor = false

    /// Read from System Settings › Accessibility › Display (cheap property reads).
    static func read() -> AccessibilityDisplay {
        let workspace = NSWorkspace.shared
        return AccessibilityDisplay(
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        )
    }
}

/// Every look option besides the look itself, as one value: what the theme
/// tokens read. Like `AppearanceStyle.current` it is a lock-protected copy,
/// readable from any thread, so token reads stay cheap.
struct LookOptions: Hashable, Sendable {
    var accent: AccentChoice = .lookDefault
    var customAccent = LookRGB(94 / 255, 92 / 255, 230 / 255)
    /// The macOS accent, resolved in the dark appearance.
    var systemAccent = LookRGB.systemBlue
    var textSize: TextSize = .standard
    var restingOpacity: RestingOpacity = .solid
    var decorativeGlows = true
    var drawerMaterial: DrawerMaterial = .black
    var contrast: ContrastPreference = .system
    var display = AccessibilityDisplay()

    /// Higher-contrast tokens: SparkV's own switch or the system's.
    var highContrast: Bool { contrast == .higher || display.increaseContrast }
    var reduceTransparency: Bool { display.reduceTransparency }
    /// The SparkV Red hero glow behind windows. Off by the switch or by
    /// Reduce Transparency.
    var glowsAllowed: Bool { decorativeGlows && !display.reduceTransparency }
    /// Notch hover themes (they have their own Reduce Transparency versions).
    /// Ambient Light is a feature with its own switch and is left alone.
    var themesAllowed: Bool { decorativeGlows }
    /// The Album Glow island background: off with Decorative Glows off, with
    /// Reduce Transparency, and with higher contrast (artwork colors can
    /// lower the contrast of the text over it).
    var albumGlowAllowed: Bool { decorativeGlows && !display.reduceTransparency && !highContrast }
    /// Liquid Glass drawer in effect (chosen and not overridden by Reduce
    /// Transparency).
    var usesGlassDrawer: Bool { drawerMaterial == .liquidGlass && !display.reduceTransparency }

    /// The accent color's sRGB value for `style` (for contrast decisions).
    func accentRGB(for style: AppearanceStyle) -> LookRGB {
        switch accent {
        case .lookDefault: style == .apple ? systemAccent : LookRGB(240 / 255, 24 / 255, 34 / 255)
        case .custom: customAccent
        default: accent.rgb ?? systemAccent
        }
    }

    static var current: LookOptions {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    private static let storage = OSAllocatedUnfairLock<LookOptions>(initialState: saved(defaults: .standard))

    // MARK: Persistence (UserDefaults, "SparkV.appearance.*")

    enum Key {
        static let accent = "SparkV.appearance.accent"
        static let customAccent = "SparkV.appearance.customAccent"
        static let textSize = "SparkV.appearance.textSize"
        static let restingOpacity = "SparkV.appearance.restingOpacity"
        static let decorativeGlows = "SparkV.appearance.decorativeGlows"
        static let drawerMaterial = "SparkV.appearance.drawerMaterial"
        static let contrast = "SparkV.appearance.contrast"
    }

    /// The saved options plus the live accessibility switches.
    static func saved(defaults: UserDefaults) -> LookOptions {
        var options = LookOptions()
        options.accent = defaults.string(forKey: Key.accent).flatMap(AccentChoice.init(rawValue:)) ?? .lookDefault
        if let hex = defaults.string(forKey: Key.customAccent), let rgb = LookRGB(hex: hex) { options.customAccent = rgb }
        options.textSize = defaults.string(forKey: Key.textSize).flatMap(TextSize.init(rawValue:)) ?? .standard
        options.restingOpacity = defaults.string(forKey: Key.restingOpacity).flatMap(RestingOpacity.init(rawValue:)) ?? .solid
        options.decorativeGlows = defaults.object(forKey: Key.decorativeGlows) as? Bool ?? true
        options.drawerMaterial = defaults.string(forKey: Key.drawerMaterial).flatMap(DrawerMaterial.init(rawValue:)) ?? .black
        options.contrast = defaults.string(forKey: Key.contrast).flatMap(ContrastPreference.init(rawValue:)) ?? .system
        options.display = AccessibilityDisplay.read()
        options.systemAccent = LookRGB.resolved(NSColor.controlAccentColor) ?? .systemBlue
        return options
    }

    func save(to defaults: UserDefaults) {
        defaults.set(accent.rawValue, forKey: Key.accent)
        defaults.set(customAccent.hex, forKey: Key.customAccent)
        defaults.set(textSize.rawValue, forKey: Key.textSize)
        defaults.set(restingOpacity.rawValue, forKey: Key.restingOpacity)
        defaults.set(decorativeGlows, forKey: Key.decorativeGlows)
        defaults.set(drawerMaterial.rawValue, forKey: Key.drawerMaterial)
        defaults.set(contrast.rawValue, forKey: Key.contrast)
    }
}

/// The Liquid Glass drawer's dark tint and the contrast model the tokens
/// are checked against. The glass shows a blur of whatever is behind the
/// drawer; the worst case for white text is a white window or wallpaper,
/// which under the tint reads as `lightestGround`. `textSecondary` (85 %
/// white) and `textTertiary` (75 %) reach 4.5:1 on it, bare or on a tile.
enum LookGlass {
    /// Black over the glass.
    static let tintOpacity: Double = 0.70
    /// The lightest thing text sits on in the glass drawer: a white
    /// backdrop under the tint, with a tile's white 8 % on top.
    static var lightestGround: LookRGB { ground(over: .white).blended(with: .white, alpha: 0.08) }
    /// `ground` behind the glass as the drawer shows it.
    static func ground(over backdrop: LookRGB) -> LookRGB { backdrop.blended(with: .black, alpha: tintOpacity) }
}

/// Everything a theme token depends on: a new value rebuilds the roots.
struct AppearanceIdentity: Hashable {
    var style: AppearanceStyle
    var options: LookOptions
}

// MARK: - Observable settings

/// Observable appearance choices for views and menus. Root views observe it
/// (see `followsAppearance()`), and rebuild when anything that changes a
/// theme token changes (look, accent, text size, contrast, Reduce
/// Transparency, ...), so every `SparkVTheme` token resolves again at once.
///
/// It also follows System Settings › Accessibility › Display live: Increase
/// Contrast and Reduce Transparency arrive by notification, nothing polls.
@MainActor
final class AppearanceSettings: ObservableObject {
    static let shared = AppearanceSettings()

    /// Posted on the main thread after any look option changes, for AppKit
    /// windows that set colors outside SwiftUI (e.g. a window's background
    /// color) and for the notch window, whose size follows the text size.
    static let didChangeNotification = Notification.Name("SparkV.AppearanceDidChange")
    /// `didChangeNotification`'s userInfo key: the `Option`s that changed
    /// (a `Set<String>` of their raw values).
    nonisolated static let changedOptionsKey = "changed"

    /// What a change notification can name.
    enum Option: String, Sendable {
        case style, accent, textSize, restingOpacity, decorativeGlows, drawerMaterial, contrast, display, systemAccent
        /// Options that change the notch window's size (Text Size grows the
        /// drawer, the glows and Reduce Transparency change the theme margin).
        static let geometry: Set<Option> = [.textSize, .decorativeGlows, .display]
    }

    /// The options a change notification names (all of them when it names none).
    nonisolated static func changedOptions(_ note: Notification) -> Set<Option> {
        guard let raw = note.userInfo?[changedOptionsKey] as? Set<String> else {
            return [.style, .accent, .textSize, .restingOpacity, .decorativeGlows, .drawerMaterial, .contrast, .display, .systemAccent]
        }
        return Set(raw.compactMap(Option.init(rawValue:)))
    }

    /// True when the notification's change resizes the notch window: use it
    /// to skip `resizeForTab` for an accent or look change.
    nonisolated static func affectsGeometry(_ note: Notification) -> Bool {
        !changedOptions(note).isDisjoint(with: Option.geometry)
    }

    @Published var style: AppearanceStyle {
        didSet {
            guard style != oldValue else { return }
            AppearanceStyle.current = style
            defaults.set(style.rawValue, forKey: AppearanceStyle.defaultsKey)
            post([.style])
        }
    }

    @Published var accent: AccentChoice { didSet { if accent != oldValue { commit(.accent) } } }
    @Published var customAccent: LookRGB { didSet { if customAccent != oldValue { commit(.accent) } } }
    @Published var textSize: TextSize { didSet { if textSize != oldValue { commit(.textSize) } } }
    @Published var restingOpacity: RestingOpacity { didSet { if restingOpacity != oldValue { commit(.restingOpacity) } } }
    @Published var decorativeGlows: Bool { didSet { if decorativeGlows != oldValue { commit(.decorativeGlows) } } }
    @Published var drawerMaterial: DrawerMaterial { didSet { if drawerMaterial != oldValue { commit(.drawerMaterial) } } }
    @Published var contrast: ContrastPreference { didSet { if contrast != oldValue { commit(.contrast) } } }
    /// System Settings › Accessibility › Display, kept current by notification.
    @Published private(set) var display: AccessibilityDisplay
    @Published private(set) var systemAccent: LookRGB

    /// The options as the tokens see them.
    var options: LookOptions {
        LookOptions(
            accent: accent, customAccent: customAccent, systemAccent: systemAccent, textSize: textSize,
            restingOpacity: restingOpacity, decorativeGlows: decorativeGlows, drawerMaterial: drawerMaterial,
            contrast: contrast, display: display
        )
    }

    /// Changes whenever a theme token would resolve differently.
    var identity: AppearanceIdentity { AppearanceIdentity(style: style, options: options) }

    /// Liquid Glass needs macOS 26; on macOS 15 the choice falls back to black.
    static var supportsLiquidGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    private let defaults: UserDefaults
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = AppearanceStyle.saved
        AppearanceStyle.current = saved
        style = saved
        let options = LookOptions.saved(defaults: defaults)
        accent = options.accent
        customAccent = options.customAccent
        textSize = options.textSize
        restingOpacity = options.restingOpacity
        decorativeGlows = options.decorativeGlows
        drawerMaterial = options.drawerMaterial
        contrast = options.contrast
        display = options.display
        systemAccent = options.systemAccent
        LookOptions.current = options
        observeSystem()
    }

    /// Back to the defaults: Apple look, system accent, Standard text, solid,
    /// glows on, black drawer, contrast following the system.
    func resetToDefaults() {
        style = .apple
        // One save and one rebuild for the options.
        batching = true
        accent = .lookDefault
        textSize = .standard
        restingOpacity = .solid
        decorativeGlows = true
        drawerMaterial = .black
        contrast = .system
        batching = false
        let options = options
        options.save(to: defaults)
        LookOptions.current = options
        post([.accent, .textSize, .restingOpacity, .decorativeGlows, .drawerMaterial, .contrast])
    }

    // MARK: Private

    /// Sets a custom accent color and selects it as one change (one save,
    /// one rebuild), as the color panel does.
    func setCustomAccent(_ rgb: LookRGB) {
        guard rgb != customAccent || accent != .custom else { return }
        batching = true
        customAccent = rgb
        accent = .custom
        batching = false
        commit(.accent)
    }

    /// While true, property changes wait for one `commit` at the end.
    private var batching = false

    /// Saves, refreshes the token copy and tells AppKit windows.
    private func commit(_ option: Option) {
        guard !batching else { return }
        let options = options
        options.save(to: defaults)
        LookOptions.current = options
        post([option])
    }

    private func post(_ changed: Set<Option>) {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self,
                                        userInfo: [Self.changedOptionsKey: Set(changed.map(\.rawValue))])
    }

    /// Increase Contrast / Reduce Transparency and the macOS accent color
    /// arrive by notification; nothing polls.
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let display = workspace.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystem() }
        }
        tokens.append((workspace, display))
        let colors = NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystem() }
        }
        tokens.append((NotificationCenter.default, colors))
    }

    func refreshSystem() {
        let fresh = AccessibilityDisplay.read()
        let accentNow = LookRGB.resolved(NSColor.controlAccentColor) ?? .systemBlue
        guard fresh != display || accentNow != systemAccent else { return }
        if fresh != display {
            AppLog.log("Appearance: accessibility display changed (contrast \(fresh.increaseContrast), transparency \(fresh.reduceTransparency))")
        }
        var changed: Set<Option> = []
        if fresh != display { changed.insert(.display) }
        if accentNow != systemAccent { changed.insert(.systemAccent) }
        display = fresh
        systemAccent = accentNow
        LookOptions.current = options
        post(changed)
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
        content.id(appearance.identity)
    }
}

extension View {
    /// Wraps a root view (drawer, window, panel) so switching the look in
    /// the gear menu (or Increase Contrast in System Settings) redraws it
    /// immediately.
    func followsAppearance() -> some View {
        AppearanceRoot { self }
    }
}

/// The gear menu's Appearance submenu: one checkable item per look.
/// Use as `AppearanceMenu()` next to "Notch Theme". (`AppearanceMenuItems`
/// has every look option.)
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

/// Every look option for a menu: use as `Menu("Appearance") { AppearanceMenuItems() }`
/// in the gear menu (it replaces `AppearanceMenu()`), or in a context menu.
struct AppearanceMenuItems: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Picker("Look", selection: $appearance.style) {
            ForEach(AppearanceStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        Menu("Accent Color") {
            ForEach([AccentChoice.lookDefault] + AccentChoice.swatches) { choice in
                Toggle(choice == .lookDefault ? accentDefaultTitle : choice.title, isOn: Binding(
                    get: { appearance.accent == choice },
                    set: { if $0 { appearance.accent = choice } }
                ))
            }
            if appearance.accent == .custom {
                Toggle("Custom (\(appearance.customAccent.hex))", isOn: .constant(true))
            }
            Divider()
            Button("Custom Color…") { LookLayoutWindowController.shared.show(page: .appearance) }
        }
        Picker("Text Size", selection: $appearance.textSize) {
            ForEach(TextSize.allCases) { size in
                Text(size.title).tag(size)
            }
        }
        Picker("Drawer", selection: $appearance.drawerMaterial) {
            ForEach(DrawerMaterial.allCases) { material in
                Text(material.title).tag(material)
            }
        }
        Toggle("Decorative Glows", isOn: $appearance.decorativeGlows)
        Picker("Island at Rest (No Notch)", selection: $appearance.restingOpacity) {
            ForEach(RestingOpacity.allCases) { opacity in
                Text(opacity.title).tag(opacity)
            }
        }
        Picker("Contrast", selection: $appearance.contrast) {
            ForEach(ContrastPreference.allCases) { preference in
                Text(preference.title).tag(preference)
            }
        }
        Divider()
        Button("Appearance Settings…") { LookLayoutWindowController.shared.show(page: .appearance) }
    }

    private var accentDefaultTitle: String {
        appearance.style == .apple ? "Look Default (macOS Accent)" : "Look Default (Signal Red)"
    }
}

/// Puts an AppKit window on the current look's window ground: a vibrant
/// dark material behind SwiftUI content in Apple, the flat brand ground in
/// SparkV Red. With Reduce Transparency (or SparkV's higher contrast) the
/// ground is solid. Use as a window's `.background { AppearanceWindowBackground() }`.
struct AppearanceWindowBackground: View {
    var body: some View {
        let options = LookOptions.current
        if SparkVTheme.isApple && !options.reduceTransparency {
            VisualEffectBackdrop(material: .underWindowBackground)
                .overlay(SparkVTheme.background.opacity(options.highContrast ? 0.85 : 0.55))
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
