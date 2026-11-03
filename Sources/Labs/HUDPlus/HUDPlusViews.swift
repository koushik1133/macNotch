import SwiftUI

// The HUD's forms other than the band: the wings beside the camera housing
// (bar or ring, each with a percentage), the floating pill and the edge bar
// for the overlay panel, and the small style thumbnails Settings picks from.
// Every form reads `HUDContent`, so the symbol, percentage and colors match
// the band's.

// MARK: - Wings

/// Leading wing: the HUD's icon. While the pointer is on it (and the HUD is
/// interactive) a soft circle says it can be clicked to mute.
struct HUDWingIcon: View {
    private let posted: HUDContent
    @ObservedObject private var pointer = HUDPointerState.shared
    @Environment(\.hudIslandDisplayID) private var islandDisplay

    init(content: HUDContent) {
        posted = content
    }

    var body: some View {
        let content = posted.live(pointer)
        let hovering = pointer.isHovering(.icon, in: .wings) && !content.isBrightness
        Image(systemName: content.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(HUDPalette.icon(content))
            .frame(width: 22, height: 22)
            .background(Circle().fill(SparkVTheme.hoverFill).opacity(hovering ? 1 : 0))
            .animation(SparkVMotion.hover(), value: hovering)
            .accessibilityLabel(content.isBrightness ? "Brightness" : (content.isMuted ? "Unmute" : "Mute"))
            .hudDrawn(posted.isDrawn(onIsland: islandDisplay))
    }
}

extension View {
    /// All Displays: keeps the HUD's space on every island but draws it only
    /// on the one it is for.
    func hudDrawn(_ drawn: Bool) -> some View {
        opacity(drawn ? 1 : 0).accessibilityHidden(!drawn)
    }
}

/// Trailing wing: a short level bar and the percentage. The bar thickens a
/// little while the pointer is on it, as a slider does.
struct HUDWingLevel: View {
    private let posted: HUDContent
    var showsPercent = true
    @ObservedObject private var pointer = HUDPointerState.shared
    @Environment(\.hudIslandDisplayID) private var islandDisplay

    init(content: HUDContent, showsPercent: Bool = true) {
        posted = content
        self.showsPercent = showsPercent
    }

    var body: some View {
        let content = posted.live(pointer)
        let active = pointer.isHovering(.level, in: .wings) || pointer.isDragging
        HStack(spacing: HUDIslandGeometry.wingGap) {
            HUDLevelBar(level: content.barLevel, fill: HUDPalette.fill(content), animates: !pointer.isDragging)
                .frame(width: HUDIslandGeometry.wingBarWidth, height: active ? 7 : 5)
                .animation(SparkVMotion.hover(), value: active)
            if showsPercent {
                HUDPercentText(content: content)
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityText)
        .hudDrawn(posted.isDrawn(onIsland: islandDisplay))
    }
}

/// Trailing wing, ring style: a 16 pt ring and the percentage.
struct HUDWingRing: View {
    private let posted: HUDContent
    var showsPercent = true
    @ObservedObject private var pointer = HUDPointerState.shared
    @Environment(\.hudIslandDisplayID) private var islandDisplay

    init(content: HUDContent, showsPercent: Bool = true) {
        posted = content
        self.showsPercent = showsPercent
    }

    var body: some View {
        let content = posted.live(pointer)
        let active = pointer.isHovering(.level, in: .wings) || pointer.isDragging
        HStack(spacing: HUDIslandGeometry.wingGap) {
            ZStack {
                Circle().stroke(SparkVTheme.surfaceHover, lineWidth: active ? 3 : 2.5)
                Circle()
                    .trim(from: 0, to: content.barLevel)
                    .stroke(HUDPalette.fill(content), style: StrokeStyle(lineWidth: active ? 3 : 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(pointer.isDragging ? nil : SparkVMotion.easeOut(SparkVMotion.Duration.press), value: content.barLevel)
            }
            .frame(width: HUDIslandGeometry.ringSize, height: HUDIslandGeometry.ringSize)
            .animation(SparkVMotion.hover(), value: active)
            if showsPercent {
                HUDPercentText(content: content)
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityText)
        .hudDrawn(posted.isDrawn(onIsland: islandDisplay))
    }
}

/// "63%" (or "Muted") at a fixed width, so the wing doesn't twitch as the
/// digits change.
struct HUDPercentText: View {
    let content: HUDContent

    var body: some View {
        Text(content.percentText)
            .font(.system(size: content.isMuted ? 10 : 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(HUDPalette.percent(content))
            .lineLimit(1)
            .fixedSize()
            .frame(width: HUDIslandGeometry.wingPercentWidth, alignment: .leading)
    }
}

// MARK: - Overlay forms

/// The iOS-style pill: icon, bar (with the display or device name above it),
/// percentage, on a black capsule.
struct HUDPillView: View {
    let content: HUDContent
    var showsPercent = true

    static let size = HUDOverlayLayout.pillSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: content.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HUDPalette.icon(content))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                if let caption = content.captionText {
                    Text(caption)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HUDLevelBar(level: content.barLevel, fill: HUDPalette.fill(content))
                    .frame(height: 6)
            }
            if showsPercent {
                Text(content.percentText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(HUDPalette.percent(content))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 18)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(HUDOverlayBackground(shape: Capsule()))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityText)
    }
}

/// The edge bar: percentage on top, a vertical bar filling upward, icon at
/// the bottom, on a slim black capsule.
struct HUDEdgeBarView: View {
    let content: HUDContent
    var showsPercent = true

    static let size = HUDOverlayLayout.edgeBarSize

    var body: some View {
        VStack(spacing: 10) {
            Text(showsPercent ? (content.isMuted ? "Mute" : "\(HUDStepMath.percent(content.barLevel))") : " ")
                .font(.system(size: content.isMuted ? 9.5 : 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(HUDPalette.percent(content))
                .lineLimit(1)
                .fixedSize()
                .frame(height: 13)
            HUDVerticalLevelBar(level: content.barLevel, fill: HUDPalette.fill(content))
                .frame(width: 6)
                .frame(maxHeight: .infinity)
            Image(systemName: content.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HUDPalette.icon(content))
                .frame(height: 16)
        }
        .padding(.vertical, 16)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(HUDOverlayBackground(shape: Capsule()))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(content.accessibilityText)
    }
}

/// A track filling from the bottom (edge bar).
struct HUDVerticalLevelBar: View {
    let level: Double
    let fill: Color

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let filled = level <= 0 ? 0 : max(proxy.size.width, height * level)
            ZStack(alignment: .bottom) {
                Capsule().fill(SparkVTheme.surfaceHover)
                Capsule().fill(fill).frame(height: min(height, filled))
            }
            .animation(SparkVMotion.easeOut(SparkVMotion.Duration.press), value: level)
        }
    }
}

/// Black like the island, with a hairline and a soft shadow so it reads on
/// light wallpapers and windows too.
struct HUDOverlayBackground<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(SparkVTheme.choose(apple: Color.black.opacity(0.88), sparkv: Color(red: 9 / 255, green: 9 / 255, blue: 10 / 255).opacity(0.94)))
            .overlay(shape.strokeBorder(SparkVTheme.choose(apple: Color.white.opacity(0.12), sparkv: SparkVTheme.brandRed.opacity(0.28)), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.35), radius: 12, y: 5)
    }
}

// MARK: - Style thumbnails (Settings)

/// A tiny schematic of a screen with the HUD drawn where the style puts it,
/// for the style picker.
struct HUDStyleThumbnail: View {
    let style: HUDStyle
    var isSelected = false
    var edge: HUDEdge = .right

    /// Height; the width follows the space (about 80–96 pt).
    static let height: CGFloat = 54

    var body: some View {
        let accent = SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red)
        ZStack(alignment: .top) {
            // The screen.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
            // Menu bar.
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(height: 9)
            schematic(accent: accent)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? SparkVTheme.accent : Color.white.opacity(0.10), lineWidth: isSelected ? 2 : 1)
        )
    }

    @ViewBuilder
    private func schematic(accent: Color) -> some View {
        // Zoomed on the top of the screen, where every style but the edge
        // bar lives, so the forms are big enough to tell apart.
        switch style {
        case .inline:
            island(width: 70, height: 11) {
                HStack(spacing: 0) {
                    speaker.frame(width: 16)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        Capsule().fill(Color.white.opacity(0.22)).frame(width: 14, height: 3)
                            .overlay(alignment: .leading) { Capsule().fill(accent).frame(width: 9, height: 3) }
                        Capsule().fill(Color.white.opacity(0.7)).frame(width: 5, height: 2)
                    }
                    .frame(width: 22)
                }
            }
        case .ring:
            island(width: 70, height: 11) {
                HStack(spacing: 0) {
                    speaker.frame(width: 16)
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        ZStack {
                            Circle().stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                            Circle().trim(from: 0, to: 0.62).stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 7, height: 7)
                        Capsule().fill(Color.white.opacity(0.7)).frame(width: 5, height: 2)
                    }
                    .frame(width: 22)
                }
            }
        case .band:
            island(width: 70, height: 24) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        speaker
                        Capsule().fill(Color.white.opacity(0.22)).frame(height: 3)
                            .overlay(alignment: .leading) { Capsule().fill(accent).frame(width: 26, height: 3) }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 12)
                }
            }
        case .pill:
            VStack(spacing: 6) {
                notchOnly
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .overlay {
                        HStack(spacing: 4) {
                            speaker
                            Capsule().fill(Color.white.opacity(0.22)).frame(height: 3)
                                .overlay(alignment: .leading) { Capsule().fill(accent).frame(width: 18, height: 3) }
                        }
                        .padding(.horizontal, 7)
                    }
                    .frame(width: 54, height: 14)
            }
        case .edgeBar:
            ZStack(alignment: edge == .right ? .trailing : .leading) {
                notchOnly.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                Capsule().fill(Color.black)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .overlay(alignment: .bottom) {
                        Capsule().fill(accent).frame(width: 3, height: 20).padding(.bottom, 4)
                    }
                    .frame(width: 10, height: 36)
                    .padding(.horizontal, 7)
                    .padding(.top, 8)
                    .frame(maxHeight: .infinity)
            }
        case .hidden:
            VStack(spacing: 0) {
                notchOnly
                Spacer()
                Image(systemName: "eye.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer()
            }
        }
    }

    private var speaker: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 6, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.9))
    }

    private var notchOnly: some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3)
            .fill(Color.black)
            .frame(width: 28, height: 9)
    }

    private func island<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4)
            .fill(Color.black)
            .overlay(content())
            .frame(width: width, height: height)
    }
}
