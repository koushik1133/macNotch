import AppKit
import Combine
import SwiftUI

// Notch themes: the switch that draws the chosen theme behind the island, the
// Settings picker, its window and the gear-menu items. The twelve theme layers
// live in NotchThemesGlass.swift, NotchThemesGlow.swift and
// NotchThemesMotion.swift; NotchThemeCore.swift holds the shared contract.
// See INTEGRATION.md in this folder for how the notch window uses it.

// MARK: - Geometry

/// Where a theme layer sits relative to the island.
///
/// A layer's frame is the island's drawable rect (body plus the flare on each
/// side, the rect `IslandShape` is drawn in) grown by
/// `NotchThemeMetrics.maxOutset` on every side, and centered on it. The top
/// outset lies above the screen edge, so the panel clips it; only the sides
/// and the bottom show.
enum NotchThemeLayout {
    /// Extra room the notch panel needs on its left, right and bottom edges
    /// for this theme. Plain gets none, so its window is exactly as before.
    static func outset(for theme: NotchThemeID) -> CGFloat {
        theme == .plain || !LookOptions.current.themesAllowed ? 0 : NotchThemeMetrics.maxOutset
    }

    static func layerSize(bodySize: CGSize, topRadius: CGFloat) -> CGSize {
        let outset = NotchThemeMetrics.maxOutset
        return CGSize(width: bodySize.width + 2 * topRadius + 2 * outset, height: bodySize.height + 2 * outset)
    }

    static func layerSize(for context: NotchThemeContext) -> CGSize {
        layerSize(bodySize: context.bodySize, topRadius: context.topRadius)
    }

    /// The rect to draw `IslandShape` in, in the layer's coordinates.
    static func islandRect(for context: NotchThemeContext) -> CGRect {
        let outset = NotchThemeMetrics.maxOutset
        return CGRect(x: outset, y: outset, width: context.bodySize.width + 2 * context.topRadius, height: context.bodySize.height)
    }

    /// The black body without its flare, in the layer's coordinates.
    static func bodyRect(for context: NotchThemeContext) -> CGRect {
        islandRect(for: context).insetBy(dx: context.topRadius, dy: 0)
    }

    /// Converts a pointer given relative to the island's top center (x to the
    /// right, y downward, in points) into the layer's coordinates.
    static func layerPoint(fromIslandTopCenter offset: CGPoint, bodySize: CGSize, topRadius: CGFloat) -> CGPoint {
        let size = layerSize(bodySize: bodySize, topRadius: topRadius)
        return CGPoint(x: size.width / 2 + offset.x, y: NotchThemeMetrics.maxOutset + offset.y)
    }
}

/// How long the pointer rests on the closed notch, showing the hovered look,
/// before the drawer opens. Plain opens at once, as it always has.
enum NotchThemeTiming {
    static func hoverDwell(for theme: NotchThemeID) -> Duration {
        theme == .plain || !LookOptions.current.themesAllowed ? .zero : .milliseconds(350)
    }

    /// How long "Preview on my notch" holds the hovered look.
    static let previewDuration: Duration = .milliseconds(2600)

    /// The island's own spring (`NotchMetrics.hoverAnimation`). Layers whose
    /// geometry changes with the phase animate with it, so a hover change
    /// (which the host makes without an animation) still eases in, and an
    /// open or close (which the host animates with this same spring) stays in
    /// step with the body.
    static var islandSpring: Animation { NotchMetrics.hoverAnimation }
}

extension NotchThemeID {
    /// Themes that follow the pointer and need `NotchThemeContext.pointer`.
    var usesPointer: Bool {
        self == .dewdrop || self == .magneticRipple
    }

    /// One line for the picker card.
    var blurb: String {
        switch self {
        case .plain: "The original black island. No highlight."
        case .liquidGlassBubble: "A soap-bubble rim with a turning sheen and a soft swell."
        case .frostedHalo: "A ring of frosted glass blooms around the notch."
        case .dewdrop: "A water drop rides the rim and follows your pointer."
        case .glassPill: "A clear glass shell that rounds the island into a pill."
        case .redRim: "A signal-red rim draws itself up both sides."
        case .conicSweep: "A red-to-white border spins around the outline."
        case .breathingPulse: "A red heartbeat ring spreads out from the edge."
        case .neonTube: "A red neon tube flickers on and lights the wall."
        case .magneticRipple: "Glass rings ripple out from the pointer."
        case .aurora: "A slow, blurred glow in red, magenta and blue."
        case .particleSpark: "Red sparks race around the outline."
        case .minimalHairline: "A 1 px hairline and a soft lifting shadow."
        }
    }

    static func themes(in family: Family) -> [NotchThemeID] {
        allCases.filter { $0.family == family }
    }
}

extension NotchThemeID.Family: Identifiable {
    var id: String { rawValue }
    /// Order in the picker and the menu.
    static let ordered: [NotchThemeID.Family] = [.basic, .glass, .glow, .motion]
}

extension Notification.Name {
    /// Posted by "Preview on my notch". The notch window shows the hovered
    /// look of the selected theme for `NotchThemeTiming.previewDuration`.
    static let notchThemePreviewRequested = Notification.Name("SparkV.NotchThemePreviewRequested")
}

// MARK: - Hover state from the notch window

/// What the notch window knows about the pointer, for the theme layer. The
/// island's own view does not observe this, so pointer moves only redraw the
/// theme layer.
@MainActor
final class NotchThemeHoverState: ObservableObject {
    static let shared = NotchThemeHoverState()

    /// Pointer on the closed island, before the drawer opens.
    @Published var isHovered = false
    /// Pointer relative to the island's top center (x right, y down, points),
    /// or nil when it is not near the island. Only set for themes that use it.
    @Published private(set) var pointerFromTopCenter: CGPoint?

    /// Rounds to half a point so tiny moves don't redraw the layer.
    func setPointer(_ point: CGPoint?) {
        let rounded = point.map { CGPoint(x: ($0.x * 2).rounded() / 2, y: ($0.y * 2).rounded() / 2) }
        if rounded != pointerFromTopCenter { pointerFromTopCenter = rounded }
    }
}

// MARK: - The theme switch

/// Draws one theme around the island: the chosen one by default, or `theme`
/// when given (the picker's previews). Plain draws nothing. The frame is the
/// island's drawable rect grown by `maxOutset` on every side (see
/// `NotchThemeLayout`), and the layer never takes clicks.
struct NotchThemeLayer: View {
    let context: NotchThemeContext
    private let fixedTheme: NotchThemeID?
    @ObservedObject private var settings = NotchThemeSettings.shared

    init(context: NotchThemeContext, theme: NotchThemeID? = nil) {
        self.context = context
        fixedTheme = theme
    }

    var body: some View {
        let theme = fixedTheme ?? settings.theme
        if theme != .plain {
            let size = NotchThemeLayout.layerSize(for: context)
            NotchThemeSwitch(theme: theme, context: context)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct NotchThemeSwitch: View {
    let theme: NotchThemeID
    let context: NotchThemeContext

    var body: some View {
        switch theme {
        case .plain: EmptyView()
        case .liquidGlassBubble: LiquidGlassBubbleNotchLayer(context: context)
        case .frostedHalo: FrostedHaloNotchLayer(context: context)
        case .dewdrop: DewdropNotchLayer(context: context)
        case .glassPill: GlassPillNotchLayer(context: context)
        case .redRim: RedRimNotchLayer(context: context)
        case .conicSweep: ConicSweepNotchLayer(context: context)
        case .breathingPulse: BreathingPulseNotchLayer(context: context)
        case .neonTube: NeonTubeNotchLayer(context: context)
        case .magneticRipple: MagneticRippleNotchLayer(context: context)
        case .aurora: AuroraNotchLayer(context: context)
        case .particleSpark: ParticleSparkNotchLayer(context: context)
        case .minimalHairline: MinimalHairlineNotchLayer(context: context)
        }
    }
}

/// The theme layer as the notch view uses it: builds the context from the
/// island's geometry, the hover state and the accessibility settings, and
/// centers the layer on the island. Put it in `.background(alignment: .top)`
/// of the island's frame. Plain draws nothing and adds no layout.
struct NotchThemeBackdrop: View {
    let isExpanded: Bool
    /// Body size without the flare (the `size` NotchNookLayoutView computes).
    let bodySize: CGSize
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    @ObservedObject private var settings = NotchThemeSettings.shared
    @ObservedObject private var hover = NotchThemeHoverState.shared
    @ObservedObject private var energy = SparkVEnergy.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        // Plain while Appearance › Decorative Glows is off, and while the
        // Liquid Glass drawer is open (it would show through the glass and
        // make it re-blur every frame).
        let theme = settings.effectiveTheme
        if theme != .plain, !LookDrawerMaterial.hidesBackdrops(isExpanded: isExpanded) {
            let phase: NotchThemePhase = isExpanded ? .open : (hover.isHovered ? .hovered : .resting)
            let pointer: CGPoint? = theme.usesPointer && phase != .resting
                ? hover.pointerFromTopCenter.map {
                    NotchThemeLayout.layerPoint(fromIslandTopCenter: $0, bodySize: bodySize, topRadius: topRadius)
                }
                : nil
            NotchThemeLayer(
                context: NotchThemeContext(
                    phase: phase,
                    bodySize: bodySize,
                    topRadius: topRadius,
                    bottomRadius: bottomRadius,
                    pointer: pointer,
                    // A hot Mac or sleeping displays: the still look.
                    reduceMotion: reduceMotion || energy.pausesDecoration,
                    reduceTransparency: reduceTransparency,
                    lowPower: energy.isConstrained
                ),
                theme: theme
            )
            // Center on the island: the top outset goes above the screen edge.
            .offset(y: -NotchThemeMetrics.maxOutset)
            .transition(.opacity)
        }
    }
}

// MARK: - Picker (Settings)

/// Settings page: every theme as a card with a live mini preview. Choosing a
/// card applies it to the notch at once.
struct NotchThemePickerView: View {
    @ObservedObject private var settings = NotchThemeSettings.shared

    private let columns = Array(repeating: GridItem(.flexible(minimum: 170), spacing: 14, alignment: .top), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                backgroundRow
                ForEach(NotchThemeID.Family.ordered) { family in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(family.rawValue.uppercased())
                            .font(SparkVTheme.eyebrow())
                            .tracking(LabsBStyle.eyebrowTracking(1.2))
                            .foregroundStyle(SparkVTheme.textTertiary)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(NotchThemeID.themes(in: family)) { theme in
                                NotchThemeCard(theme: theme, isSelected: settings.theme == theme) {
                                    settings.theme = theme
                                }
                            }
                        }
                    }
                }
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 34)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
        .background(LabsBWindowGround(glow: 0).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(SparkVTheme.isApple ? "APPEARANCE" : "SPARKV / APPEARANCE")
                    .font(SparkVTheme.eyebrow())
                    .tracking(SparkVTheme.isApple ? 0.4 : 1.2)
                    .foregroundStyle(SparkVTheme.choose(apple: SparkVTheme.textTertiary, sparkv: SparkVTheme.red))
                Text("Notch Theme")
                    .font(SparkVTheme.title(26))
                    .tracking(-0.4)
                    .foregroundStyle(SparkVTheme.text)
                Text("How the island lights up when your pointer reaches the notch. Hover a card to see it; click to use it.")
                    .font(SparkVTheme.body(12.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    NotificationCenter.default.post(name: .notchThemePreviewRequested, object: nil)
                } label: {
                    Label("Preview on my notch", systemImage: "sparkles")
                }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .disabled(settings.effectiveTheme == .plain)
                .help("Shows the selected theme's hover look on the real notch for a moment.")
                Text(!LookOptions.current.themesAllowed ? "Decorative Glows is off in Appearance."
                     : (settings.theme == .plain ? "Plain has no hover look." : "Or just point at your notch."))
                    .font(SparkVTheme.caption())
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    /// What fills the island: the album-art glow or plain black.
    private var backgroundRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BACKGROUND")
                .font(SparkVTheme.eyebrow())
                .tracking(LabsBStyle.eyebrowTracking(1.2))
                .foregroundStyle(SparkVTheme.textTertiary)
            HStack(spacing: 14) {
                Picker("Background", selection: $settings.background) {
                    ForEach(NotchBackgroundStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Text(settings.background == .albumGlow && settings.effectiveBackground != .albumGlow
                     ? "Album Glow is paused: Decorative Glows is off, or Reduce Transparency or higher contrast is on."
                     : (settings.background == .albumGlow
                        ? "A soft glow tinted from the playing track's album art."
                        : "Pure black, the original island."))
                    .font(SparkVTheme.caption())
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
        }
    }

    private var footer: some View {
        Text("Themes animate only while you point at the notch or the drawer is open, and follow Reduce Motion and Reduce Transparency in System Settings › Accessibility.")
            .font(SparkVTheme.caption())
            .foregroundStyle(SparkVTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Hover state of one picker card (no `@State` with the Command Line Tools).
@MainActor
final class NotchThemeCardModel: ObservableObject {
    @Published var isHovered = false
    /// Pointer over the preview, relative to the island's top center (points
    /// at the island's real size).
    @Published var pointer: CGPoint?
}

private struct NotchThemeCard: View {
    let theme: NotchThemeID
    let isSelected: Bool
    let select: () -> Void
    @StateObject private var model = NotchThemeCardModel()

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 9) {
                // Every card shows its theme's hover look, still (the Reduce
                // Motion version) so twelve previews cost nothing; hovering a
                // card plays it live.
                NotchThemeMiniPreview(
                    theme: theme,
                    phase: .hovered,
                    animated: model.isHovered,
                    pointer: model.pointer,
                    onPointer: { model.pointer = $0 }
                )
                .frame(height: NotchThemeMiniPreview.height)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

                HStack(spacing: 6) {
                    Text(theme.title)
                        .font(SparkVTheme.headline(12.5))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    if theme == .plain {
                        Text("Default")
                            .font(SparkVTheme.caption(9.5))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(SparkVTheme.surfaceHover))
                    }
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.white, SparkVTheme.accent)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 18)
                Text(theme.blurb)
                    .font(SparkVTheme.caption(10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                    .fill(isSelected ? SparkVTheme.choose(apple: SparkVTheme.surfaceHover, sparkv: SparkVTheme.redSoft.opacity(0.55)) : (model.isHovered ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                    .strokeBorder(isSelected ? SparkVTheme.accent : LabsBStyle.chipStroke, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hovering in
            withAnimation(SparkVMotion.hover()) { model.isHovered = hovering }
            if !hovering { model.pointer = nil }
        }
        .accessibilityLabel(theme.title + (theme == .plain ? ", default" : ""))
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint(theme.blurb)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small wallpaper with a menu bar and the island at its resting size,
/// scaled down, with the theme drawn around it as on the real notch.
struct NotchThemeMiniPreview: View {
    static let height: CGFloat = 92
    static let scale: CGFloat = 0.5
    /// The real resting island (see NotchMetrics.collapsedSize and radii).
    static let bodySize = CGSize(width: 220, height: 38)
    static let topRadius: CGFloat = 8
    static let bottomRadius: CGFloat = 12

    let theme: NotchThemeID
    let phase: NotchThemePhase
    /// False draws the still (Reduce Motion) version of the look.
    var animated: Bool = true
    var pointer: CGPoint? = nil
    var onPointer: ((CGPoint?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let scale = Self.scale
        let islandWidth = Self.bodySize.width + 2 * Self.topRadius
        let context = NotchThemeContext(
            phase: phase,
            bodySize: Self.bodySize,
            topRadius: Self.topRadius,
            bottomRadius: Self.bottomRadius,
            pointer: theme.usesPointer && phase != .resting
                ? pointer.map { NotchThemeLayout.layerPoint(fromIslandTopCenter: $0, bodySize: Self.bodySize, topRadius: Self.topRadius) }
                : nil,
            reduceMotion: reduceMotion || !animated,
            reduceTransparency: reduceTransparency
        )

        GeometryReader { proxy in
            ZStack(alignment: .top) {
                NotchThemeWallpaper()
                NotchThemeMenuBarStrip(height: Self.bodySize.height * scale)

                IslandShape(topRadius: Self.topRadius, bottomRadius: Self.bottomRadius)
                    .fill(Color.black)
                    .frame(width: islandWidth, height: Self.bodySize.height)
                    .background(alignment: .top) {
                        NotchThemeLayer(context: context, theme: theme)
                            .offset(y: -NotchThemeMetrics.maxOutset)
                    }
                    .scaleEffect(scale, anchor: .top)
                    .frame(width: islandWidth * scale, height: Self.bodySize.height * scale, alignment: .top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onContinuousHover(coordinateSpace: .local) { hover in
                guard let onPointer, theme.usesPointer else { return }
                switch hover {
                case .active(let location):
                    onPointer(CGPoint(x: (location.x - proxy.size.width / 2) / scale, y: location.y / scale))
                case .ended:
                    onPointer(nil)
                }
            }
        }
        .clipped()
        .allowsHitTesting(onPointer != nil)
    }
}

/// A colorful stand-in desktop, drawn once and cached.
struct NotchThemeWallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.20, blue: 0.52),
                    Color(red: 0.55, green: 0.22, blue: 0.62),
                    Color(red: 0.96, green: 0.45, blue: 0.36),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                let w = proxy.size.width
                let h = proxy.size.height
                Circle()
                    .fill(Color(red: 0.20, green: 0.75, blue: 0.85).opacity(0.75))
                    .frame(width: w * 0.55, height: w * 0.55)
                    .position(x: w * 0.12, y: h * 0.95)
                    .blur(radius: 18)
                Circle()
                    .fill(Color(red: 1.0, green: 0.78, blue: 0.35).opacity(0.7))
                    .frame(width: w * 0.42, height: w * 0.42)
                    .position(x: w * 0.92, y: h * 0.18)
                    .blur(radius: 16)
                Ellipse()
                    .fill(Color(red: 0.95, green: 0.25, blue: 0.45).opacity(0.55))
                    .frame(width: w * 0.6, height: h * 0.5)
                    .position(x: w * 0.6, y: h * 0.82)
                    .blur(radius: 20)
            }
        }
        .drawingGroup()
    }
}

/// A translucent menu bar with a few placeholder items on each side.
private struct NotchThemeMenuBarStrip: View {
    let height: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "apple.logo")
                .font(.system(size: 7, weight: .semibold))
            Capsule().frame(width: 12, height: 3)
            Capsule().frame(width: 8, height: 3)
            Spacer()
            Capsule().frame(width: 7, height: 3)
            Capsule().frame(width: 10, height: 3)
        }
        .foregroundStyle(Color.white.opacity(0.75))
        .padding(.horizontal, 7)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.18))
        .accessibilityHidden(true)
    }
}

/// A compact Settings tile: the current theme's name and a button to the
/// picker. Optional; see INTEGRATION.md.
struct NotchThemeAppearanceTile: View {
    @ObservedObject private var settings = NotchThemeSettings.shared
    @StateObject private var hover = NotchThemeCardModel()

    var body: some View {
        Button {
            NotchThemeSettingsWindowController.shared.show()
        } label: {
            HStack(spacing: 8) {
                IslandShape(topRadius: 3, bottomRadius: 5)
                    .fill(Color.black)
                    .overlay(
                        IslandShape(topRadius: 3, bottomRadius: 5)
                            .stroke(settings.theme == .plain ? SparkVTheme.stroke : SparkVTheme.choose(apple: Color.white.opacity(0.7), sparkv: SparkVTheme.red), lineWidth: 1)
                    )
                    .frame(width: 30, height: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Notch Theme")
                        .font(SparkVTheme.headline(11.5))
                        .foregroundStyle(SparkVTheme.text)
                    Text(settings.theme.title)
                        .font(SparkVTheme.caption(10))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(hover.isHovered ? SparkVTheme.surfaceHover : SparkVTheme.surface)
            )
            .animation(SparkVMotion.hover(), value: hover.isHovered)
            .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isHovered = $0 }
        .help("Choose how the notch lights up on hover")
    }
}

// MARK: - Window

/// The picker in its own dark window, opened from the gear menu.
@MainActor
final class NotchThemeSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = NotchThemeSettingsWindowController()
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // SparkV is an agent app: become a regular app while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: NotchThemePickerView().followsAppearance())
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.title = "Notch Theme — SparkV"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        LabsBWindowAppearance.follow(window)
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 860, height: 520)
        window.setContentSize(NSSize(width: 920, height: 760))
        window.center()
        window.setFrameAutosaveName("SparkV.NotchTheme")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Gear menu

/// Items for the gear menu's "Notch Theme" submenu: every theme with a
/// checkmark on the current one, then "Choose Theme…". Use inside
/// `Menu("Notch Theme") { NotchThemeMenuItems() }`, or use `NotchThemeMenu`.
struct NotchThemeMenuItems: View {
    @ObservedObject private var settings = NotchThemeSettings.shared

    var body: some View {
        ForEach(NotchThemeID.Family.ordered) { family in
            Section(family.rawValue) {
                ForEach(NotchThemeID.themes(in: family)) { theme in
                    Toggle(theme == .plain ? "Plain (Default)" : theme.title, isOn: Binding(
                        get: { settings.theme == theme },
                        set: { isOn in if isOn { settings.theme = theme } }
                    ))
                }
            }
        }
        Section("Background") {
            ForEach([NotchBackgroundStyle.black, .albumGlow]) { style in
                Toggle(style == .black ? "Black (Default)" : style.title, isOn: Binding(
                    get: { settings.background == style },
                    set: { isOn in if isOn { settings.background = style } }
                ))
            }
        }
        Divider()
        Button("Choose Theme…") { NotchThemeSettingsWindowController.shared.show() }
    }
}

/// The whole "Notch Theme" submenu.
struct NotchThemeMenu: View {
    var body: some View {
        Menu("Notch Theme") { NotchThemeMenuItems() }
    }
}

// MARK: - Settings section

/// Settings › Appearance: the notch theme (with its still preview) and the
/// island background, with a way to the full picker.
struct NotchThemeSettingsSection: View {
    @ObservedObject private var settings = NotchThemeSettings.shared
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                NotchThemeMiniPreview(theme: settings.theme, phase: .hovered, animated: false)
                    .frame(width: 190, height: NotchThemeMiniPreview.height)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(SparkVTheme.stroke))
                    .opacity(settings.effectiveTheme == settings.theme ? 1 : 0.45)
                    .accessibilityLabel("Preview of \(settings.theme.title)")
                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.theme.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                    Text(settings.theme.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if settings.theme != .plain, settings.effectiveTheme == .plain {
                        Label("Paused: Decorative Glows is off.", systemImage: "pause.circle")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(SparkVTheme.warning)
                    }
                    HStack(spacing: 8) {
                        Button("Choose Theme…") { NotchThemeSettingsWindowController.shared.show() }
                        Button("Preview on My Notch") {
                            NotificationCenter.default.post(name: .notchThemePreviewRequested, object: nil)
                        }
                        .disabled(settings.effectiveTheme == .plain)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
            Picker(selection: $settings.background) {
                Text("Black").tag(NotchBackgroundStyle.black)
                Text("Album Glow").tag(NotchBackgroundStyle.albumGlow)
            } label: {
                Text("Island Background")
                Text(backgroundNote)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Notch Theme")
        } footer: {
            LookFormFooter("How the island lights up when your pointer reaches the notch.")
        }
    }

    private var backgroundNote: String {
        if settings.background == .albumGlow, settings.effectiveBackground != .albumGlow {
            return "Paused: Decorative Glows is off, or Reduce Transparency or higher contrast is on."
        }
        return settings.background == .albumGlow
            ? "A soft glow from the playing track's artwork behind Home."
            : "Pure black, the original island."
    }
}
