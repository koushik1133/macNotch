import SwiftUI

/// The timer in the Today tab: about 170×70 pt (or taller in the Planner's
/// Today page). A progress ring on the left, the time and controls on the
/// right, presets in a menu, and dots to switch between timers when there
/// are several. A ringing timer swaps in Stop and Snooze.
struct TimerView: View {
    @EnvironmentObject private var timer: TimerController

    var body: some View {
        Group {
            if !timer.isEnabled {
                VStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 16, weight: .medium))
                    Text("Timer is off")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(SparkVTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else if let ringing = timer.ringing {
                TimerRingingView(ringing: ringing)
                    .transition(.sparkVCrossfade)
            } else {
                GeometryReader { geo in
                    TimerSlot(entry: timer.focusedEntry, tall: geo.size.height >= 88)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .transition(.sparkVCrossfade)
            }
        }
        .animation(SparkVMotion.easeOut(SparkVMotion.Duration.standard), value: timer.ringing)
    }
}

/// One timer in the Today slot.
private struct TimerSlot: View {
    @EnvironmentObject private var timer: TimerController
    let entry: TimerEntry
    let tall: Bool

    var body: some View {
        TimerClock(entry: entry) { date in
            HStack(spacing: tall ? 10 : 8) {
                TimerRing(entry: entry, date: date, lineWidth: tall ? 5 : 4, glyphSize: tall ? 17 : 14)
                    .frame(width: tall ? 58 : 46, height: tall ? 58 : 46)

                VStack(alignment: .leading, spacing: tall ? 4 : 3) {
                    header(date)
                    Text(entry.timeText(at: date))
                        .font(.system(size: tall ? 26 : 22, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .tracking(-0.5)
                        .foregroundStyle(entry.isPaused ? SparkVTheme.textTertiary : SparkVTheme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    TimerControls(entry: entry)
                    if tall, let footer = footer(date) {
                        Text(footer)
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(entry.spoken(at: date))
        }
    }

    private func header(_ date: Date) -> some View {
        HStack(spacing: 4) {
            Text(entry.title.uppercased())
                .foregroundStyle(entry.accent)
                .truncationMode(.tail)
                .layoutPriority(1)
            if let session = entry.session {
                Text(session)
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .fixedSize()
            }
            if entry.isPending(at: date) {
                Text("UP NEXT")
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .fixedSize()
            }
            Spacer(minLength: 2)
            if timer.entries.count > 1 {
                TimerPageDots()
            }
        }
        .font(SparkVTheme.eyebrow(9))
        .tracking(0.8)
        .lineLimit(1)
    }

    /// Tall slot only: what comes next.
    private func footer(_ date: Date) -> String? {
        switch entry.kind {
        case .pomodoro:
            let next = Pomodoro.next(after: entry.countdown.phase, completedFocus: entry.countdown.completedFocus).phase
            let minutes = Int(Pomodoro.duration(of: next) / 60)
            return "Then \(TimerFormat.longName(of: next).lowercased()), \(minutes) min"
        case .countdown:
            guard let end = entry.countdown.endsAt else {
                return entry.countdown.isPaused ? "Paused" : "\(TimerDurationParser.spoken(entry.countdown.duration)) timer"
            }
            return "Ends at \(MeetingsController.timeFormatter.string(from: end))"
        case .stopwatch:
            guard !entry.stopwatch.laps.isEmpty else { return entry.stopwatch.isIdle ? "Stopwatch" : "No laps yet" }
            return "Lap \(entry.stopwatch.laps.count + 1) · \(TimerFormat.elapsed(entry.stopwatch.currentLap(at: date)))"
        }
    }
}

/// Redraws its content once a second while the timer runs, lined up with
/// the moments the reading changes; a paused or idle timer draws once.
/// `TimelineView` only ticks while it is on screen.
struct TimerClock<Content: View>: View {
    let entry: TimerEntry
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if entry.isRunning {
            TimelineView(.periodic(from: TimerFormat.tickAnchor(for: entry, now: Date()), by: 1)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }
}

/// Progress ring with the timer's glyph in the middle.
struct TimerRing: View {
    let entry: TimerEntry
    let date: Date
    var lineWidth: CGFloat = 4
    var glyphSize: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(SparkVTheme.surfaceHover, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: entry.progress(at: date))
                .stroke(entry.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Constant motion between ticks: linear, and none under Reduce Motion.
                .animation(SparkVMotion.reduceMotion || entry.kind == .stopwatch && entry.progress(at: date) < 0.02 ? nil : .linear(duration: 0.3), value: entry.progress(at: date))
            Image(systemName: entry.symbol)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(entry.accent)
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// Play/pause, reset and the kind's third button, behind the preset menu.
struct TimerControls: View {
    @EnvironmentObject private var timer: TimerController
    let entry: TimerEntry
    var showsMenu = true

    var body: some View {
        HStack(spacing: 4) {
            if showsMenu { TimerPresetMenu(entry: entry) }
            TimerControlButton(symbol: entry.isRunning ? "pause.fill" : "play.fill", help: playHelp, isProminent: true) {
                timer.toggle(entry.itemID)
            }
            TimerControlButton(symbol: "arrow.counterclockwise", help: "Reset") {
                timer.reset(entry.itemID)
            }
            .disabled(entry.isIdle && entry.kind != .pomodoro)
            switch entry.kind {
            case .pomodoro:
                TimerControlButton(symbol: "forward.end.fill", help: "Skip to next phase") { timer.skip() }
            case .countdown:
                TimerControlButton(symbol: "plus", help: "Add 1 minute") { timer.add(seconds: 60, to: entry.itemID) }
            case .stopwatch:
                TimerControlButton(symbol: "flag.fill", help: "Lap") {
                    if let id = entry.itemID { timer.lap(id) }
                }
                .disabled(!entry.isRunning)
            }
        }
    }

    private var playHelp: String {
        if entry.isRunning { return "Pause \(entry.title)" }
        return entry.isIdle ? "Start \(entry.title)" : "Resume \(entry.title)"
    }
}

/// The ≡ menu: presets for the main timer, new timers and stopwatches, and
/// the entry's own actions.
struct TimerPresetMenu: View {
    @EnvironmentObject private var timer: TimerController
    let entry: TimerEntry
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Menu {
            TimerPresetItems(entry: entry)
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .background(Circle().fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
        .overlay(Circle().strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .tint(SparkVTheme.text)
        .onHover { hover.isOn = $0 }
        .help("Presets and more timers")
        .accessibilityLabel("Timer presets and more timers")
    }
}

/// Menu content shared by the ≡ button and the Planner's timer cards.
struct TimerPresetItems: View {
    @EnvironmentObject private var timer: TimerController
    let entry: TimerEntry

    var body: some View {
        if entry.isPrimary {
            Button("Pomodoro (\(Pomodoro.focusMinutes) / \(Pomodoro.shortBreakMinutes))") { timer.startPomodoro() }
            Divider()
            ForEach(TimerController.presets, id: \.self) { minutes in
                Button("\(minutes) min") { timer.startCountdown(seconds: TimeInterval(minutes * 60)) }
            }
            Menu("More") {
                ForEach(TimerController.morePresets, id: \.self) { minutes in
                    Button(minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60) h" : (minutes > 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")) {
                        timer.startCountdown(seconds: TimeInterval(minutes * 60))
                    }
                }
            }
            if !entry.isIdle || entry.kind == .countdown {
                Divider()
                Button("+1 min") { timer.add(seconds: 60, to: nil) }
                Button("+5 min") { timer.add(seconds: 300, to: nil) }
            }
        } else if let id = entry.itemID {
            if entry.kind == .countdown {
                Button("+1 min") { timer.add(seconds: 60, to: id) }
                Button("+5 min") { timer.add(seconds: 300, to: id) }
            } else if entry.isRunning {
                Button("Lap") { timer.lap(id) }
            }
            Divider()
            Button("Remove \(entry.title)") { timer.remove(id) }
        }
        Divider()
        Menu("New Timer") {
            ForEach([1, 3, 5, 10, 15, 30, 60], id: \.self) { minutes in
                Button(minutes == 60 ? "1 h" : "\(minutes) min") { timer.addCountdown(seconds: TimeInterval(minutes * 60)) }
            }
        }
        .disabled(!timer.canAddTimer)
        Button("New Stopwatch") { timer.addStopwatch() }
            .disabled(!timer.canAddTimer)
        Button("All Timers…") { PlannerRouter.shared.show(.timers) }
    }
}

/// Dots in the header: one per timer, the shown one filled. Click to switch.
/// Past four timers, a "2/7" capsule that steps to the next one instead.
struct TimerPageDots: View {
    @EnvironmentObject private var timer: TimerController
    static let maxDots = 4

    var body: some View {
        let entries = timer.entries
        let current = timer.focusedEntry.id
        if entries.count > Self.maxDots {
            let index = entries.firstIndex { $0.id == current } ?? 0
            Button {
                timer.focusedID = entries[(index + 1) % entries.count].itemID
            } label: {
                HStack(spacing: 2) {
                    Text("\(index + 1)/\(entries.count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    Image(systemName: "chevron.right").font(.system(size: 6.5, weight: .bold))
                }
                .foregroundStyle(SparkVTheme.textSecondary)
                .padding(.horizontal, 5)
                .frame(height: 13)
                .background(Capsule().fill(SparkVTheme.surface))
                .contentShape(Capsule())
            }
            .buttonStyle(SparkVPressStyle())
            .fixedSize()
            .help("Show the next timer")
            .accessibilityLabel("Timer \(index + 1) of \(entries.count). Show the next one")
        } else {
            dots(entries, current: current)
        }
    }

    private func dots(_ entries: [TimerEntry], current: String) -> some View {
        HStack(spacing: 2) {
            ForEach(entries) { entry in
                Button {
                    // A click: no animation needed, the slot swaps at once.
                    timer.focusedID = entry.itemID
                } label: {
                    Circle()
                        .fill(entry.id == current ? SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.red) : Color.white.opacity(entry.isIdle ? 0.18 : 0.4))
                        .frame(width: 5, height: 5)
                        .frame(width: 9, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SparkVPressStyle())
                .help(entry.title)
                .accessibilityLabel("Show \(entry.title)")
                .accessibilityAddTraits(entry.id == current ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

/// A finished countdown that keeps ringing: Stop and Snooze.
struct TimerRingingView: View {
    @EnvironmentObject private var timer: TimerController
    @ObservedObject private var preferences = TimerPreferences.shared
    let ringing: TimerRinging

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(TimerFormat.countdownColor.opacity(0.18))
                TimerRingingGlyph(size: 18)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Text(ringing.displayTitle.uppercased())
                    .font(SparkVTheme.eyebrow(9))
                    .tracking(0.8)
                    .foregroundStyle(TimerFormat.countdownColor)
                    .lineLimit(1)
                Text("Time’s up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                HStack(spacing: 5) {
                    TimerTextButton(title: "Stop", isProminent: true) { timer.stopRinging() }
                    TimerTextButton(title: "Snooze \(preferences.snoozeMinutes)m") { timer.snooze() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ringing.doneSentence)
    }
}

/// The ringing bell; it wiggles unless Reduce Motion is on.
struct TimerRingingGlyph: View {
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: "bell.and.waves.left.and.right.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(TimerFormat.countdownColor)
            .symbolEffect(.wiggle, options: .repeating, isActive: !SparkVMotion.reduceMotion)
            .accessibilityLabel("Ringing")
    }
}

/// Small round icon button for the timer's controls.
struct TimerControlButton: View {
    let symbol: String
    let help: String
    var isProminent = false
    var size: CGFloat = 22
    let action: () -> Void

    @StateObject private var hover = ViewFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .bold))
                // Play and pause morph into each other instead of swapping.
                .contentTransition(.symbolEffect(.replace))
                .animation(SparkVMotion.easeOut(SparkVMotion.Duration.small), value: symbol)
                .foregroundStyle(isProminent ? SparkVTheme.choose(apple: Color.black, sparkv: Color.white) : SparkVTheme.text)
                .frame(width: size, height: size)
                .background(Circle().fill(isProminent ? prominentFill : (hover.isOn && isEnabled ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
                .overlay(Circle().strokeBorder(isProminent || SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
                .opacity(isEnabled ? 1 : 0.4)
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    /// Apple: a white play/pause disc like the Clock app's; SparkV Red: red.
    private var prominentFill: Color {
        if SparkVTheme.isApple { return Color.white.opacity(hover.isOn ? 0.85 : 1) }
        return hover.isOn ? SparkVTheme.redDeep : SparkVTheme.red
    }
}

/// Capsule text button (Stop, Snooze, Start).
struct TimerTextButton: View {
    let title: String
    var isProminent = false
    var height: CGFloat = 22
    let action: () -> Void

    @StateObject private var hover = ViewFlag()
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isProminent ? SparkVTheme.choose(apple: Color.black, sparkv: Color.white) : SparkVTheme.text)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: height)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(isProminent || SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
                .opacity(isEnabled ? 1 : 0.45)
                .animation(SparkVMotion.hover(), value: hover.isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .fixedSize()
        .onHover { hover.isOn = $0 }
    }

    private var fill: Color {
        if isProminent {
            if SparkVTheme.isApple { return Color.white.opacity(hover.isOn ? 0.85 : 1) }
            return hover.isOn ? SparkVTheme.redDeep : SparkVTheme.red
        }
        return hover.isOn && isEnabled ? SparkVTheme.surfaceHover : SparkVTheme.surface
    }
}

// MARK: - Bands under the notch

/// Running timers band: a tiny ring, "Focus 18:42", up to two more timers
/// ("· Tea 03:12"), and the state on the right. Draws from value snapshots
/// through `TimerClock`, so nothing re-posts it every second.
struct TimerBandView: View {
    let entries: [TimerEntry]

    var body: some View {
        if let lead = entries.first {
            TimerClock(entry: lead) { date in
                HStack(spacing: 10) {
                    TimerMiniRing(progress: lead.progress(at: date), accent: lead.accent)
                        .frame(width: 14, height: 14)
                        .frame(width: 34, height: 16)

                    HStack(spacing: 6) {
                        Text("\(lead.title) \(lead.timeText(at: date))")
                            .foregroundStyle(lead.isPaused ? SparkVTheme.textTertiary : SparkVTheme.text)
                            .lineLimit(1)
                            .layoutPriority(1)
                        ForEach(entries.dropFirst().prefix(2)) { other in
                            Text("· \(other.title) \(other.timeText(at: date))")
                                .foregroundStyle(SparkVTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .leading)

                    trailing(lead, date)
                }
                .padding(.horizontal, 16)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entries.map { $0.spoken(at: date) }.joined(separator: "; "))
            }
        }
    }

    @ViewBuilder
    private func trailing(_ lead: TimerEntry, _ date: Date) -> some View {
        if entries.count > 3 {
            Text("+\(entries.count - 3)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
        } else if lead.isPaused {
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
        } else if lead.isPending(at: date) {
            Text("UP NEXT")
                .font(SparkVTheme.eyebrow(9.5))
                .tracking(0.6)
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
        } else if let session = lead.session {
            Text(session)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
        }
    }
}

/// Left wing: the soonest timer's ring.
struct TimerCompactLeading: View {
    let entry: TimerEntry

    var body: some View {
        TimerClock(entry: entry) { date in
            CompactProgressRing(progress: entry.progress(at: date), tint: entry.accent)
        }
        .accessibilityHidden(true)
    }
}

/// Right wing: its time, and "+2" when more timers run.
struct TimerCompactTrailing: View {
    let entry: TimerEntry
    let extraCount: Int

    var body: some View {
        TimerClock(entry: entry) { date in
            HStack(spacing: 3) {
                Text(entry.timeText(at: date))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(entry.isPaused ? SparkVTheme.textSecondary : Color.white)
                    .lineLimit(1)
                    .fixedSize()
                if extraCount > 0 {
                    Text("+\(extraCount)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .padding(.horizontal, 3)
                        .frame(height: 13)
                        .background(Capsule().fill(SparkVTheme.surfaceHover))
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.spoken(at: date) + (extraCount > 0 ? ", and \(extraCount) more" : ""))
        }
    }
}

/// Five-second celebration when a phase or timer ends.
struct TimerDoneBandView: View {
    let message: String
    let accent: Color

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

            Image(systemName: "party.popper.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.choose(apple: Color.yellow, sparkv: SparkVTheme.red))
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

/// A countdown is ringing: hover opens Today, where Stop and Snooze are.
struct TimerRingingBandView: View {
    /// "Tea is done", "Tea and Eggs are done".
    let sentence: String

    var body: some View {
        HStack(spacing: 10) {
            TimerRingingGlyph(size: 13)
                .frame(width: 34, height: 16)

            Text(sentence)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("Hover to stop")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

struct TimerMiniRing: View {
    let progress: Double
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(SparkVTheme.surfaceHover, lineWidth: 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Gear menu

/// Items for `Menu("Timers") { TimerMenuItems(controller: timer) }`.
struct TimerMenuItems: View {
    @ObservedObject var controller: TimerController
    @ObservedObject private var preferences = TimerPreferences.shared

    var body: some View {
        if let ringing = controller.ringing {
            Button("Stop \(ringing.displayTitle)") { controller.stopRinging() }
            Button("Snooze \(preferences.snoozeMinutes) Minutes") { controller.snooze() }
            Divider()
        }
        Button(toggleTitle) { controller.toggle() }
            .disabled(!controller.isEnabled)
        Button("Start Pomodoro (\(Pomodoro.focusMinutes) / \(Pomodoro.shortBreakMinutes))") { controller.startPomodoro() }
            .disabled(!controller.isEnabled)
        Menu("Start Countdown") {
            ForEach(TimerController.presets + [30, 45, 60], id: \.self) { minutes in
                Button(minutes == 60 ? "1 hour" : "\(minutes) minutes") { controller.startCountdown(seconds: TimeInterval(minutes * 60)) }
            }
        }
        .disabled(!controller.isEnabled)
        Menu("New Timer") {
            ForEach([1, 3, 5, 10, 15, 30, 60], id: \.self) { minutes in
                Button(minutes == 60 ? "1 hour" : "\(minutes) minutes") { controller.addCountdown(seconds: TimeInterval(minutes * 60)) }
            }
        }
        .disabled(!controller.isEnabled || !controller.canAddTimer)
        Button("New Stopwatch") { controller.addStopwatch() }
            .disabled(!controller.isEnabled || !controller.canAddTimer)
        Button("All Timers…") { PlannerRouter.shared.show(.timers) }
        Divider()
        Toggle("Show Timers Beside the Notch", isOn: $preferences.showsBesideNotch)
        Toggle("Ring Until Stopped", isOn: $preferences.ringsUntilStopped)
        Toggle("Start / Pause Shortcut  \(TimerController.hotkeyShortcut.displayString)", isOn: $preferences.hotkeyEnabled)
    }

    private var toggleTitle: String {
        let key = preferences.hotkeyEnabled && controller.isHotkeyRegistered ? "  \(TimerController.hotkeyShortcut.displayString)" : ""
        switch controller.state.status {
        case .idle: return "Start \(controller.primaryEntry.title)" + key
        case .running: return "Pause \(controller.primaryEntry.title)" + key
        case .paused: return "Resume \(controller.primaryEntry.title)" + key
        }
    }
}
