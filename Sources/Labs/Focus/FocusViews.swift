import AppKit
import SwiftUI

enum FocusPalette {
    /// Focus's own color: indigo (the macOS Focus color) in Apple, signal
    /// red in SparkV Red. Rings, the moon, the Start button.
    static var accent: Color { SparkVTheme.choose(apple: Color.indigo, sparkv: SparkVTheme.red) }
    /// Breaks keep their green: it means "rest", not decoration.
    static var rest: Color { SparkVTheme.success }
    static var card: Color { SparkVTheme.surface }
    static var line: Color { SparkVTheme.stroke }
}

/// Shared look for the labs-b views (Focus, Modes, Widgets, Screen Distance,
/// Onboarding, Live Translation, Fans, Notch Themes) in both appearances.
enum LabsBStyle {
    /// Fill behind a selected chip, segment or row: the soft white pill of
    /// the island header in Apple, a red wash in SparkV Red.
    static var selectedFill: Color { SparkVTheme.choose(apple: Color.white.opacity(0.16), sparkv: SparkVTheme.redSoft) }
    /// Border of a selected chip: none in Apple, a red hairline in SparkV Red.
    static var selectedStroke: Color { SparkVTheme.choose(apple: Color.clear, sparkv: SparkVTheme.red.opacity(0.7)) }
    /// Border of an unselected chip: none in Apple (flat grey pills), the
    /// hairline in SparkV Red.
    static var chipStroke: Color { SparkVTheme.choose(apple: Color.clear, sparkv: SparkVTheme.stroke) }
    /// Glyph of a hovered icon button: white in Apple, red in SparkV Red.
    static var hoverGlyph: Color { SparkVTheme.choose(apple: SparkVTheme.text, sparkv: SparkVTheme.red) }
    /// Fill behind a hovered icon button.
    static var hoverFill: Color { SparkVTheme.choose(apple: Color.white.opacity(0.12), sparkv: SparkVTheme.redSoft) }
    /// "On" fill of a small toggle pill or page dot: the accent (system
    /// blue) in Apple, red in SparkV Red.
    static var onFill: Color { SparkVTheme.accent }
    /// Warning / over-limit red: system red in Apple, brand red in SparkV Red.
    static var alert: Color { SparkVTheme.destructive }
    /// A card's ground behind a selected / running item, tinted with the
    /// feature's own color in Apple.
    static func activeCardFill(_ tint: Color) -> Color {
        SparkVTheme.choose(apple: tint.opacity(0.18), sparkv: SparkVTheme.redSoft)
    }
    static func activeCardStroke(_ tint: Color) -> Color {
        SparkVTheme.choose(apple: tint.opacity(0.40), sparkv: SparkVTheme.red.opacity(0.45))
    }
    /// Letter spacing for an eyebrow label: tight in Apple (SF Pro), the
    /// given wide spacing in SparkV Red (SF Mono).
    static func eyebrowTracking(_ sparkv: CGFloat) -> CGFloat { SparkVTheme.isApple ? min(sparkv, 0.4) : sparkv }
    /// A feature's tint in Apple, red in SparkV Red.
    static func tint(_ apple: Color) -> Color { SparkVTheme.choose(apple: apple, sparkv: SparkVTheme.red) }
}

/// Eyebrow label. SparkV Red: a short red dash, then a small uppercase
/// monospaced label ("— ROUNDS"), sparkv.si style. Apple: a plain small
/// uppercase SF Pro section label, no dash (System Settings style).
/// Shared by the labs-b views (Focus, Modes, Widgets, Screen Distance,
/// Onboarding, Live Translation).
struct LabsBEyebrow: View {
    let text: String
    var dash = true
    init(_ text: String, dash: Bool = true) {
        self.text = text
        self.dash = dash
    }

    var body: some View {
        HStack(spacing: 6) {
            if dash && !SparkVTheme.isApple {
                Capsule().fill(SparkVTheme.eyebrowDash).frame(width: 10, height: 1.5)
            }
            Text(text.uppercased())
                .font(SparkVTheme.eyebrow())
                .tracking(SparkVTheme.isApple ? 0.4 : 1.2)
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
        }
    }
}

/// Dark agents-hub tile, matching the hub's `AgentTile`.
/// Apple: a Control Center tile; the glyph in the feature's own `tint`,
/// hover lifts the tile, a running feature gets a tint wash.
/// SparkV Red: monochrome glyph at rest, red glyph and a red wash on hover
/// or while the tile's feature is running.
struct LabsBHubTileBackground: View {
    let isActive: Bool
    let isHovered: Bool
    var tint: Color = .accentColor

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        if SparkVTheme.usesTileTints {
            shape
                .fill(isActive ? tint.opacity(isHovered ? 0.30 : 0.24) : Color.white.opacity(isHovered ? 0.14 : 0.08))
                .overlay(shape.strokeBorder(isActive ? tint.opacity(0.45) : Color.clear, lineWidth: 1))
                .animation(SparkVMotion.hover(), value: isHovered)
        } else {
            shape
                .fill(isActive || isHovered ? SparkVTheme.redSoft.opacity(isActive && isHovered ? 1.4 : 1) : SparkVTheme.surface)
                .overlay(shape.strokeBorder(isActive ? SparkVTheme.red.opacity(0.45) : SparkVTheme.stroke, lineWidth: 1))
                .animation(SparkVMotion.hover(), value: isHovered)
        }
    }

    /// Glyph color for the tile's icon.
    static func glyph(isActive: Bool, isHovered: Bool, tint: Color = .accentColor) -> Color {
        if SparkVTheme.usesTileTints { return tint }
        return isActive || isHovered ? SparkVTheme.red : SparkVTheme.textSecondary
    }

    /// Label color under the glyph.
    static func label(isActive: Bool, isHovered: Bool) -> Color {
        if SparkVTheme.usesTileTints { return Color.white.opacity(isActive || isHovered ? 1 : 0.82) }
        return isActive || isHovered ? SparkVTheme.text : SparkVTheme.textSecondary
    }
}

// MARK: - Bands under the notch

/// "Focusing 18:42" with a progress ring; the moon means Do Not Disturb is on.
struct FocusBandView: View {
    struct Model: Equatable {
        var title: String
        var time: String
        var progress: Double
        var isBreak: Bool
        var isPaused: Bool
        var round: String?
        var doNotDisturb: Bool
        /// Set for about a second after a session starts: the band shakes once.
        var kickedAt: Date? = nil
    }

    let model: Model

    var body: some View {
        let accent = model.isBreak ? FocusPalette.rest : FocusPalette.accent
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(SparkVTheme.stroke, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: model.isBreak ? "cup.and.saucer.fill" : "moon.fill")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(accent)
            }
            .frame(width: 15, height: 15)
            .frame(width: 34, height: 16)

            Text("\(model.title) \(model.time)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(model.isPaused ? SparkVTheme.textTertiary : SparkVTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                if model.isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                if let round = model.round {
                    Text(round)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .fixedSize()
                }
                if model.doNotDisturb {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .help("Do Not Disturb is on")
                }
            }
        }
        .padding(.horizontal, 16)
        .modifier(FocusKick(kickedAt: model.kickedAt))
    }
}

/// Five-second note when a round or a break ends.
struct FocusDoneBandView: View {
    let message: String
    let accent: Color
    var kickedAt: Date? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 16)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .modifier(FocusKick(kickedAt: kickedAt))
    }
}

/// The band's half of the screen "vibration": one quick, decaying wobble
/// with a small pulse, in step with the screen border's kick. Driven by a
/// TimelineView from a start date (no @State), so it plays once however
/// often the band is re-posted, and stops ticking once it is over.
struct FocusKick: ViewModifier {
    let kickedAt: Date?

    func body(content: Content) -> some View {
        if let kickedAt, Date().timeIntervalSince(kickedAt) < FocusGlowTiming.kick + 0.3 {
            TimelineView(FocusKickSchedule(start: kickedAt)) { context in
                let pose = FocusKick.pose(at: context.date.timeIntervalSince(kickedAt))
                content
                    .offset(x: pose.x)
                    .scaleEffect(pose.scale)
            }
        } else {
            content
        }
    }

    /// Offset (points) and scale `t` seconds into the kick; rest outside it.
    /// Half the border's amplitude: the band is small and sits by the camera.
    static func pose(at t: TimeInterval) -> (x: CGFloat, scale: CGFloat) {
        let delay = 0.05
        let d = FocusGlowTiming.kick
        guard t > delay, t < delay + d else { return (0, 1) }
        let xs = FocusGlowTiming.shakeX, ss = FocusGlowTiming.shakeScale
        let f = (t - delay) / d * Double(xs.count - 1)
        let i = min(xs.count - 2, Int(f))
        let u = CGFloat(f - Double(i))
        let x = (xs[i] + (xs[i + 1] - xs[i]) * u) * 0.5
        let s = ss[i] + (ss[i + 1] - ss[i]) * u
        // The band's pulse outward reads better than the border's squeeze.
        return (x, 1 + (1 - s) * 2.5)
    }
}

/// Frames for the kick only: a finite schedule, so the TimelineView stops
/// redrawing once the wobble is over (`.animation` would keep ticking at the
/// display rate for as long as the band stays up, 5 to 8 seconds).
struct FocusKickSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        let end = start.addingTimeInterval(0.05 + FocusGlowTiming.kick + 0.02)
        let step = mode == .lowFrequency ? 0.25 : 1.0 / 60
        var dates: [Date] = []
        var t = max(startDate, start)
        while t < end {
            dates.append(t)
            t = t.addingTimeInterval(step)
        }
        dates.append(end)
        return dates
    }
}

/// Two-line wrap-up shown when a session ends.
struct FocusSummaryBandView: View {
    let record: FocusSessionRecord
    var kickedAt: Date? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.stars.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FocusPalette.accent)
                .frame(width: 34, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .modifier(FocusKick(kickedAt: kickedAt))
    }

    private var headline: String {
        let apps = record.apps.prefix(2).map(\.name)
        let base = "Focused \(FocusText.duration(record.focusedSeconds))"
        return apps.isEmpty ? base : base + " · " + apps.joined(separator: ", ")
    }

    private var detail: String {
        let made = FocusArtifact.Kind.allCases.compactMap { kind -> String? in
            let n = record.count(of: kind)
            return n > 0 ? kind.countLabel(n) : nil
        }
        if !made.isEmpty { return made.joined(separator: " · ") }
        let n = record.interruptions.count
        if n > 0 { return "\(n) distraction\(n == 1 ? "" : "s") caught" }
        return record.roundsCompleted > 1 ? "\(record.roundsCompleted) rounds done. Nice work." : "Nice work."
    }
}

// MARK: - Header button

/// Header icon with the same 24 x 22 footprint as the header's IconTabs in
/// both states, so the right group never grows toward the camera housing.
/// Idle: a moon that starts a session in one click. Focusing: a progress
/// ring around the moon (green cup on a break); clicking opens a menu
/// that leads with the time left, then Pause / +5 min / Skip / End.
struct FocusHeaderButton: View {
    @EnvironmentObject private var focus: FocusController
    @StateObject private var hover = ViewFlag()

    var body: some View {
        if focus.isActive {
            Menu {
                FocusControlsMenuItems(focus: focus)
            } label: {
                FocusHeaderRing(progress: focus.progress, isBreak: focus.phase?.isBreak == true,
                                isPaused: focus.isPaused, highlighted: hover.isOn)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hover.isOn = $0 }
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .help("\(focus.phaseTitle): \(focus.remainingText) left")
        } else {
            Button { focus.startSession() } label: {
                Image(systemName: "moon.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(hover.isOn ? LabsBStyle.hoverGlyph : SparkVTheme.inactiveGlyph)
                    .frame(width: 24, height: 22)
                    .background(Capsule().fill(hover.isOn ? LabsBStyle.hoverFill : Color.clear))
                    .contentShape(Capsule())
            }
            .buttonStyle(SparkVPressStyle())
            .onHover { hover.isOn = $0 }
            .animation(SparkVMotion.hover(), value: hover.isOn)
            .help("Focus: mute notifications and start a \(focus.settings.focusMinutes)-minute round")
        }
    }
}

/// The running-session menu shared by the header button and the hub tile.
struct FocusControlsMenuItems: View {
    @ObservedObject var focus: FocusController

    var body: some View {
        Text("\(focus.phaseTitle) · \(focus.remainingText) left\(focus.roundText.map { " · round \($0)" } ?? "")")
        Divider()
        Button(focus.isPaused ? "Resume" : "Pause") { focus.togglePause() }
        Button("Add 5 Minutes") { focus.addFiveMinutes() }
        Button(focus.phase == .focus ? "Finish This Round" : "Skip Break") { focus.skipPhase() }
        Divider()
        Button("End Focus and Show Summary") { focus.end() }
        Button("Focus Settings…") { FocusSettingsWindowController.shared.show(controller: focus) }
    }
}

private struct FocusHeaderRing: View {
    let progress: Double
    let isBreak: Bool
    let isPaused: Bool
    let highlighted: Bool

    var body: some View {
        let accent = isPaused ? SparkVTheme.textTertiary : (isBreak ? FocusPalette.rest : FocusPalette.accent)
        ZStack {
            Circle().stroke(SparkVTheme.stroke, lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: isPaused ? "pause.fill" : (isBreak ? "cup.and.saucer.fill" : "moon.fill"))
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(accent)
        }
        .frame(width: 15, height: 15)
        .frame(width: 24, height: 22)
        .background(Capsule().fill(accent.opacity(highlighted ? 0.26 : 0.16)))
        .contentShape(Capsule())
    }
}

// MARK: - Agents hub tile

/// Same footprint as the hub's other tiles. Idle: one click starts focus.
/// Running: shows the time left; clicking calls `onOpen` (the Focus page),
/// or, when no Focus page is wired, opens the same menu as the header
/// button, so a stray click never ends a session.
struct FocusHubTile: View {
    @EnvironmentObject private var focus: FocusController
    var onOpen: (() -> Void)?
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Group {
            if focus.isActive && onOpen == nil {
                Menu {
                    FocusControlsMenuItems(focus: focus)
                } label: {
                    tileFace
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            } else {
                Button {
                    if focus.isActive { onOpen?() } else { focus.startSession() }
                } label: {
                    tileFace
                }
                .buttonStyle(SparkVPressStyle())
            }
        }
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(focus.isActive ? "\(focus.phaseTitle): \(focus.remainingText) left" : "Focus: mute notifications and start a Pomodoro")
    }

    private var tileFace: some View {
        VStack(spacing: 5) {
            Image(systemName: focus.isActive ? (focus.phase?.isBreak == true ? "cup.and.saucer.fill" : "moon.stars.fill") : "moon.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(focus.phase?.isBreak == true ? FocusPalette.rest : LabsBHubTileBackground.glyph(isActive: focus.isActive, isHovered: hover.isOn, tint: FocusPalette.accent))
            Text(focus.isActive ? focus.remainingText : "Focus")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(LabsBHubTileBackground.label(isActive: focus.isActive, isHovered: hover.isOn))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(LabsBHubTileBackground(isActive: focus.isActive, isHovered: hover.isOn,
                                           tint: focus.phase?.isBreak == true ? FocusPalette.rest : FocusPalette.accent))
        .contentShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous))
    }
}

// MARK: - Drawer page (optional Focus tab)

/// Fits the standard drawer content area (about 476 x 69 pt under the header).
struct FocusTabView: View {
    @EnvironmentObject private var focus: FocusController

    var body: some View {
        HStack(spacing: 14) {
            ring
            if focus.isActive { runningControls } else { idleControls }
            Spacer(minLength: 0)
            todayColumn
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accent: Color { focus.phase?.isBreak == true ? FocusPalette.rest : FocusPalette.accent }

    private var ring: some View {
        ZStack {
            Circle().stroke(SparkVTheme.stroke, lineWidth: 4)
            Circle()
                .trim(from: 0, to: focus.isActive ? focus.progress : 0)
                .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(focus.isActive ? focus.remainingText : FocusText.clock(TimeInterval(focus.settings.focusMinutes * 60)))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
                    .minimumScaleFactor(0.7)
                Image(systemName: focus.phase?.isBreak == true ? "cup.and.saucer.fill" : "moon.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: 58, height: 58)
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(FocusSettings.presets, id: \.focus) { preset in
                    let selected = focus.settings.focusMinutes == preset.focus && focus.settings.shortBreakMinutes == preset.rest
                    Button {
                        focus.settings.focusMinutes = preset.focus
                        focus.settings.shortBreakMinutes = preset.rest
                    } label: {
                        Text("\(preset.focus)/\(preset.rest)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(selected ? SparkVTheme.text : SparkVTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill(selected ? LabsBStyle.selectedFill : SparkVTheme.surface))
                            .overlay(Capsule().strokeBorder(selected ? LabsBStyle.selectedStroke : LabsBStyle.chipStroke, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(SparkVPressStyle())
                    .help("\(preset.focus) min focus, \(preset.rest) min break")
                }
                Menu {
                    ForEach([1, 2, 3, 4, 0], id: \.self) { n in
                        Button(n == 0 ? "Until I Stop" : "\(n) Round\(n == 1 ? "" : "s")") { focus.settings.rounds = n }
                    }
                } label: {
                    Text(focus.settings.rounds == 0 ? "∞" : "\(focus.settings.rounds)×")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(Capsule().fill(SparkVTheme.surface))
                        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Rounds per session")
            }
            HStack(spacing: 6) {
                Button { focus.startSession() } label: {
                    Label("Start Focus", systemImage: "moon.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(FocusPalette.accent))
                        .shadow(color: SparkVTheme.isApple ? Color.clear : SparkVTheme.red.opacity(0.35), radius: 6, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(SparkVPressStyle())
                .help("Mute notifications and start a \(focus.settings.focusMinutes)-minute round")
                settingsButton
            }
        }
    }

    private var settingsButton: some View {
        Button { FocusSettingsWindowController.shared.show(controller: focus) } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(SparkVTheme.surface))
                .overlay(Circle().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if focus.doNotDisturbNotice != nil {
                        Circle().fill(SparkVTheme.warning).frame(width: 7, height: 7)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .help(focus.doNotDisturbNotice ?? "Focus settings: durations, Do Not Disturb, distractions")
    }

    private var runningControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(focus.phaseTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(SparkVTheme.text)
                if let round = focus.roundText {
                    Text(round)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                if focus.active?.didEnableDoNotDisturb == true {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .help("Do Not Disturb is on")
                }
                Text("· \(FocusText.compact(focus.focusedSoFar)) focused")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            HStack(spacing: 6) {
                FocusRoundButton(systemImage: focus.isPaused ? "play.fill" : "pause.fill", help: focus.isPaused ? "Resume" : "Pause") { focus.togglePause() }
                FocusRoundButton(systemImage: "goforward.5", help: "Add 5 minutes") { focus.addFiveMinutes() }
                FocusRoundButton(systemImage: "forward.end.fill", help: focus.phase == .focus ? "Finish this round" : "Skip break") { focus.skipPhase() }
                Button { focus.end() } label: {
                    Text("End")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Capsule().fill(SparkVTheme.surface))
                        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(SparkVPressStyle())
                .help("End focus and show the summary")
            }
        }
    }

    private var todayColumn: some View {
        let stats = focus.stats()
        return VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 4) {
                Text("TODAY")
                    .font(SparkVTheme.eyebrow(8.5))
                    .tracking(LabsBStyle.eyebrowTracking(1.0))
                    .foregroundStyle(SparkVTheme.textTertiary)
                Text(FocusText.compact(stats.todaySeconds + (focus.isActive ? focus.focusedSoFar : 0)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
            }
            FocusWeekBars(days: stats.days.map(\.seconds), accent: FocusPalette.accent)
                .frame(width: 64, height: 16)
            Text("WEEK \(FocusText.compact(stats.weekSeconds))")
                .font(SparkVTheme.eyebrow(8.5))
                .tracking(LabsBStyle.eyebrowTracking(1.0))
                .foregroundStyle(SparkVTheme.textTertiary)
        }
        .help("Focus time today and over the last 7 days")
    }
}

struct FocusRoundButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
                .overlay(Circle().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
    }
}

/// Seven tiny bars, oldest day first.
struct FocusWeekBars: View {
    let days: [TimeInterval]
    let accent: Color
    var maxHeight: CGFloat = 16

    var body: some View {
        let peak = max(days.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, seconds in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(seconds > 0 ? accent.opacity(index == days.count - 1 ? 1 : 0.55) : SparkVTheme.stroke)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, CGFloat(seconds / peak) * maxHeight))
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - Summary card

struct FocusSummaryCard: View {
    @ObservedObject var controller: FocusController
    let record: FocusSessionRecord
    var onClose: () -> Void

    var body: some View {
        let stats = controller.stats()
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 10) {
                FocusStatTile(value: FocusText.compact(record.focusedSeconds), label: "focused", tint: FocusPalette.accent)
                FocusStatTile(value: "\(record.apps.count)", label: record.apps.count == 1 ? "app" : "apps", tint: SparkVTheme.text)
                FocusStatTile(value: "\(record.artifacts.count)", label: "created", tint: SparkVTheme.text)
                FocusStatTile(value: "\(record.interruptions.count)", label: "blocked", tint: SparkVTheme.text)
            }
            summaryText
            if !record.apps.isEmpty { appsSection }
            if !record.documents.isEmpty { documentsSection }
            if !record.artifacts.isEmpty { artifactsSection }
            footer(stats)
        }
        .padding(18)
        .frame(width: 400, alignment: .leading)
        .background(
            ZStack {
                SparkVTheme.background
                SparkVTheme.glow.opacity(0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous).strokeBorder(FocusPalette.line))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                LabsBEyebrow("SparkV / Focus")
                Text(record.endReason == .stopped ? "Focus session ended" : "Focus session complete")
                    .font(SparkVTheme.title(18))
                    .tracking(-0.4)
                    .foregroundStyle(SparkVTheme.text)
                Text(FocusText.timeRange(record.startedAt, record.endedAt) + (record.mutedSystemNotifications ? " · Do Not Disturb was on" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(SparkVTheme.surface))
                    .overlay(Circle().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
            }
            .buttonStyle(SparkVPressStyle())
            .help("Close")
        }
    }

    private var summaryText: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(FocusPalette.accent)
                Text(controller.isSummarizing && controller.lastSummary?.id == record.id ? "Writing your recap…" : "Recap · \(record.summaryBy)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            Text(record.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(SparkVTheme.text.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke))
    }

    private var appsSection: some View {
        let peak = max(record.apps.first?.seconds ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            FocusSectionTitle("Apps")
            ForEach(record.apps.prefix(4)) { app in
                HStack(spacing: 8) {
                    FocusAppIcon(bundleID: app.bundleID)
                        .frame(width: 16, height: 16)
                    Text(app.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SparkVTheme.text.opacity(0.88))
                        .lineLimit(1)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(FocusPalette.accent.opacity(app.id == record.apps.first?.id ? 0.9 : 0.5))
                            .frame(width: max(4, geo.size.width * CGFloat(app.seconds / peak)), height: 5)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 12)
                    Text(FocusText.compact(app.seconds))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private var documentsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            FocusSectionTitle("Worked on")
            ForEach(record.documents.prefix(3)) { doc in
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textTertiary)
                    Text(doc.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SparkVTheme.text.opacity(0.88))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(doc.appName)
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var artifactsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            FocusSectionTitle("Captured in SparkV")
            ForEach(record.artifacts.prefix(5)) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.kind.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .frame(width: 14)
                    Text(item.title.isEmpty ? item.kind.label : item.title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SparkVTheme.text.opacity(0.88))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(item.kind.label)
                        .font(.system(size: 10))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
            }
            if record.artifacts.count > 5 {
                Text("+ \(record.artifacts.count - 5) more")
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }

    private func footer(_ stats: FocusStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = controller.doNotDisturbNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.warning)
            }
            HStack(spacing: 8) {
                Button { controller.startBreak(); onClose() } label: {
                    Label("\(controller.settings.shortBreakMinutes)-min Break", systemImage: "cup.and.saucer.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(SparkVTheme.surface))
                        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 1))
                }
                .buttonStyle(SparkVPressStyle())
                Button { onClose(); controller.startSession() } label: {
                    Label("Another Round", systemImage: "moon.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(FocusPalette.accent))
                }
                .buttonStyle(SparkVPressStyle())
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Today \(FocusText.compact(stats.todaySeconds))")
                    Text("Week \(FocusText.compact(stats.weekSeconds))")
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }
}

struct FocusStatTile: View {
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .semibold).monospacedDigit())
                .tracking(-0.3)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(SparkVTheme.eyebrow(8.5))
                .tracking(LabsBStyle.eyebrowTracking(0.8))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke))
    }
}

struct FocusSectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        LabsBEyebrow(text)
    }
}

struct FocusAppIcon: View {
    let bundleID: String

    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .foregroundStyle(SparkVTheme.textTertiary)
        }
    }
}

// MARK: - Windows in both looks

/// AppKit side of a labs-b window (Focus, Modes, Fans, Onboarding,
/// Screen Distance): puts the window on the current look's ground and keeps
/// it there when the look changes. The SwiftUI root does the rest with
/// `followsAppearance()` and `LabsBWindowGround`.
@MainActor
enum LabsBWindowAppearance {
    static func follow(_ window: NSWindow) {
        window.backgroundColor = NSColor(SparkVTheme.windowBackground)
        NotificationCenter.default.addObserver(
            forName: AppearanceSettings.didChangeNotification, object: nil, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                window?.backgroundColor = NSColor(SparkVTheme.windowBackground)
            }
        }
    }
}

/// SwiftUI ground of a labs-b window: macOS vibrancy (dark under-window
/// material) in Apple, the flat brand ground with its soft red glow in
/// SparkV Red.
struct LabsBWindowGround: View {
    var glow: Double = 0.8

    var body: some View {
        if SparkVTheme.isApple {
            AppearanceWindowBackground()
        } else {
            ZStack {
                SparkVTheme.background
                SparkVTheme.glow.opacity(glow).allowsHitTesting(false)
            }
        }
    }
}
