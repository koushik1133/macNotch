import AppKit
import SwiftUI

// The open drawer's look: what it is made of (black or Liquid Glass), how
// big its content draws (Text Size), and how solid the resting island is on
// a display without a notch.

// MARK: - Text size: the larger drawer

/// Drawer geometry at the current text size. The content area under the
/// header zooms by `SparkVTheme.textScale` (every label, glyph and control
/// grows by the same amount, so no layout truncates); the header band beside
/// the camera housing and the closed island keep their size.
enum LookDrawerMetrics {
    /// Content inset on each side of the body (`NotchNookLayoutView` pads
    /// the content by 16 pt plus the flare, which lies outside the body).
    static let horizontalInset: CGFloat = 32

    /// The zoom the drawer's content draws at.
    static var zoom: CGFloat { SparkVTheme.textScale }

    /// `base` (a drawer body at Standard) grown so its content area, below a
    /// header of `header` points and above `bottomInset`, is `zoom` times as
    /// large. At zoom 1 it returns `base` unchanged.
    static func zoomed(_ base: CGSize, header: CGFloat, bottomInset: CGFloat = 8, zoom: CGFloat = zoom) -> CGSize {
        guard zoom != 1 else { return base }
        let contentWidth = max(0, base.width - horizontalInset)
        let contentHeight = max(0, base.height - header - bottomInset)
        return CGSize(
            width: (contentWidth * zoom + horizontalInset).rounded(),
            height: (header + contentHeight * zoom + bottomInset).rounded()
        )
    }
}

/// Draws `content` laid out at its Standard size and zoomed to fill the
/// space it is given: wrap the drawer's tab content in it. Text stays sharp
/// (SwiftUI draws it at the zoomed size); clicks, hover and drops follow the
/// zoom. At Standard it adds nothing.
struct LookDrawerZoom<Content: View>: View {
    var zoom: CGFloat = LookDrawerMetrics.zoom
    let content: Content

    init(zoom: CGFloat = LookDrawerMetrics.zoom, @ViewBuilder content: () -> Content) {
        self.zoom = zoom
        self.content = content()
    }

    var body: some View {
        if zoom == 1 {
            content
        } else {
            GeometryReader { proxy in
                content
                    .frame(width: proxy.size.width / zoom, height: proxy.size.height / zoom)
                    .scaleEffect(zoom, anchor: .topLeading)
            }
        }
    }
}

// MARK: - Drawer material

/// Offscreen renders can't show system glass (the window server composites
/// it). Test harnesses set `backdrop` to the picture behind the drawer; the
/// glass then draws as a software stand-in (that picture blurred under the
/// same dark tint). Always nil in the app.
enum LookDrawerDebug {
    @MainActor static var backdrop: NSImage?
}

/// The island's fill. Closed it is always pure black, like the hardware
/// notch. Open with Liquid Glass chosen (and Reduce Transparency off), the
/// body turns to a dark Liquid Glass (macOS 26+; a dark material on
/// macOS 15). On a notched display the band beside the camera housing stays
/// black and fades into the glass. Nothing here animates on its own or
/// polls: the glass is composited by the window server and costs nothing at
/// rest, and it is removed when the drawer closes.
///
/// While the drawer closes the black fill is back at once under the fading
/// glass, so the island never turns see-through and the camera's edges
/// never show.
///
/// Use in place of `shape.fill(SparkVTheme.islandBackground)`.
struct LookDrawerBackground<S: Shape>: View {
    let shape: S
    let isExpanded: Bool
    /// Height of the header band (the resting island's height).
    let headerHeight: CGFloat
    /// The island is on a display with a camera notch (`state.surface.hasNotch`).
    var hasNotch: Bool = true

    var body: some View {
        let glass = LookOptions.current.usesGlassDrawer && isExpanded
        ZStack(alignment: .top) {
            if !glass {
                // Back instantly when the drawer closes; fades out on open.
                shape.fill(SparkVTheme.islandBackground)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
            if glass {
                LookGlassFill(shape: shape)
                    .transition(.opacity)
                if hasNotch {
                    // The band beside the camera continues the black notch,
                    // then fades into the glass over 16 pt. No fade of its
                    // own: it is there whenever the glass is.
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: headerHeight / (headerHeight + 16)),
                            .init(color: .black.opacity(0), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: headerHeight + 16)
                    .allowsHitTesting(false)
                    .transition(.identity)
                }
            }
        }
    }

}

/// The drawer material's rules for what sits behind the body.
enum LookDrawerMaterial {
    /// Decorations behind the body (notch themes, Ambient Light) would show
    /// through the glass and make it re-blur every frame: they stay hidden
    /// while the glass drawer is open.
    static func hidesBackdrops(isExpanded: Bool) -> Bool {
        isExpanded && LookOptions.current.usesGlassDrawer
    }
}

/// Dark Liquid Glass in `shape`.
private struct LookGlassFill<S: Shape>: View {
    let shape: S

    var body: some View {
        if let picture = LookDrawerDebug.backdrop {
            // Software stand-in for renders: the backdrop, blurred and tinted.
            Color.clear
                .overlay {
                    Image(nsImage: picture)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 18, opaque: true)
                        .saturation(1.4)
                }
                .overlay(Color.black.opacity(LookGlass.tintOpacity))
                .overlay(
                    LinearGradient(colors: [Color.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
                )
                .clipShape(shape)
                .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(Color.black.opacity(LookGlass.tintOpacity)), in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(LookGlass.tintOpacity)))
                .environment(\.colorScheme, .dark)
        }
    }
}

// MARK: - Where the island is

/// The display the island is on, as the notch window last placed it
/// (`NotchWindowController.positionOverNotch` reports it; see
/// INTEGRATION.md step 4e). With IslandPlacement the island can sit on the
/// main display, a saved one or the pointer's, so "this Mac has a notch"
/// is not the same as "the island is on a notch".
@MainActor
enum LookIsland {
    /// The island's screen frame and visible frame; nil before the first
    /// placement or with no display (Built-in Only, lid closed).
    private(set) static var screenFrame: CGRect?
    private(set) static var visibleFrame: CGRect?
    /// The island's display has a camera notch.
    private(set) static var hasNotch: Bool?

    static func note(screen: NSScreen?, hasNotch: Bool) {
        screenFrame = screen?.frame
        visibleFrame = screen?.visibleFrame
        self.hasNotch = screen == nil ? nil : hasNotch
    }

    /// The island's screen (matched by frame), or a best guess before the
    /// first placement: the notched screen, else the main one.
    static var screen: NSScreen? {
        if let frame = screenFrame, let match = NSScreen.screens.first(where: { $0.frame == frame }) { return match }
        return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The island sits on a camera notch (a best guess before it is placed).
    static var isOnNotch: Bool {
        if let hasNotch { return hasNotch }
        return (screen?.safeAreaInsets.top ?? 0) > 0
    }
}

// MARK: - Resting opacity

/// How solid the closed island is while it rests with nothing to show.
enum LookResting {
    /// 1, or the chosen resting opacity when the island rests on a display
    /// without a camera notch (`hasNotch`: `state.surface.hasNotch`, so a
    /// mirror on another display uses its own) and Reduce Transparency is off.
    static func opacity(isResting: Bool, hasNotch: Bool) -> Double {
        opacity(isResting: isResting, hasNotch: hasNotch, options: LookOptions.current)
    }

    static func opacity(isResting: Bool, hasNotch: Bool, options: LookOptions) -> Double {
        guard isResting, !hasNotch, options.restingOpacity != .solid, !options.reduceTransparency else { return 1 }
        return options.restingOpacity.value
    }
}
