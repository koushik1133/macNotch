import AppKit
import SwiftUI

/// Warm light behind the island tinted with the album art's vibrant color
/// (`MediaEngine.artworkTint`), like boring.notch's colored glow: a soft
/// radial bloom around the artwork plus a faint wash along the bottom edge.
/// Dims while paused, crossfades when the track changes, never takes clicks.
///
/// Place it directly above the island's black fill and below its content;
/// the island's clip shape keeps it inside.
struct MediaGlowBackground: View {
    enum Style {
        /// Open drawer: bloom centred on the media column's artwork.
        case drawer
        /// Closed pill: a small halo behind the left (artwork) flank.
        case pill
    }

    @EnvironmentObject private var media: MediaEngine
    var style: Style = .drawer
    /// Where the bloom is centred, in the view's unit space.
    var center: UnitPoint = UnitPoint(x: 0.098, y: 0.54)
    var intensity: Double = 1

    var body: some View {
        let tint = media.isShowingGlow ? media.artworkTint : nil
        ZStack {
            if let tint {
                glow(Color(nsColor: tint))
                    .id(Self.key(tint))
                    .transition(.opacity)
            }
        }
        .opacity(media.isPlaying ? 1 : 0.5)
        // Color changes take the plain `ease` curve; slow on purpose, since
        // this is ambient light following the track, not a UI response.
        .animation(SparkVMotion.hover(0.9), value: tint.map(Self.key))
        .animation(SparkVMotion.hover(0.6), value: media.isPlaying)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func glow(_ color: Color) -> some View {
        switch style {
        case .drawer:
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    RadialGradient(
                        colors: [color.opacity(0.42 * intensity), color.opacity(0.14 * intensity), .clear],
                        center: center,
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * 0.42
                    )
                    LinearGradient(
                        colors: [color.opacity(0.16 * intensity), .clear],
                        startPoint: .bottom,
                        endPoint: UnitPoint(x: 0.5, y: 0.45)
                    )
                }
            }
        case .pill:
            RadialGradient(
                colors: [color.opacity(0.55 * intensity), color.opacity(0.18 * intensity), .clear],
                center: center,
                startRadius: 0,
                endRadius: 34
            )
        }
    }

    /// Identity of a color for crossfades (NSColor isn't Hashable by value).
    static func key(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return String(format: "%.3f-%.3f-%.3f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }
}

extension MediaEngine {
    /// Something is loaded whose artwork can light the island.
    var isShowingGlow: Bool { source != .none && artwork != nil }
}
