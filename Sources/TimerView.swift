import SwiftUI

/// The timer in the Today tab, sized for about 170×70 pt: a progress ring
/// on the left, the remaining time and controls on the right, presets in a menu.
struct TimerView: View {
    @EnvironmentObject private var timer: TimerController

    var body: some View {
        if timer.isEnabled {
            content
        } else {
            VStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.system(size: 16, weight: .medium))
                Text("Timer is off")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(SparkVTheme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            ring
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                header
                Text(timer.remainingText)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(timer.state.isPaused ? SparkVTheme.textTertiary : SparkVTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(SparkVTheme.surfaceHover, lineWidth: 4)
            Circle()
                .trim(from: 0, to: timer.progress)
                .stroke(timer.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: timer.progress)
            Image(systemName: phaseSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(timer.accent)
        }
    }

    private var phaseSymbol: String {
        switch timer.state.phase {
        case .focus: "brain.head.profile"
        case .shortBreak, .longBreak: "cup.and.saucer.fill"
        case .timer: "timer"
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(timer.phaseTitle.uppercased())
                .foregroundStyle(timer.accent)
            if let session = timer.sessionText {
                Text(session)
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
            if timer.isPending {
                Text("UP NEXT")
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
        .font(SparkVTheme.eyebrow(9))
        .tracking(0.8)
        .lineLimit(1)
    }

    private var controls: some View {
        HStack(spacing: 4) {
            presetMenu
            TimerControlButton(symbol: playSymbol, help: playHelp, isProminent: true) {
                timer.toggle()
            }
            TimerControlButton(symbol: "arrow.counterclockwise", help: "Reset") {
                timer.reset()
            }
            if timer.state.mode == .pomodoro {
                TimerControlButton(symbol: "forward.end.fill", help: "Skip to next phase") {
                    timer.skip()
                }
            } else {
                TimerControlButton(symbol: "plus", help: "Add 1 minute") {
                    timer.addMinute()
                }
            }
        }
    }

    private var playSymbol: String {
        timer.state.isRunning ? "pause.fill" : "play.fill"
    }

    private var playHelp: String {
        switch timer.state.status {
        case .idle: "Start"
        case .running: "Pause"
        case .paused: "Resume"
        }
    }

    private var presetMenu: some View {
        Menu {
            Button("Pomodoro (25 / 5)") { timer.startPomodoro() }
            Divider()
            ForEach(TimerController.presets, id: \.self) { minutes in
                Button("\(minutes) min") { timer.startTimer(minutes: minutes) }
            }
            if !timer.state.isIdle || timer.state.mode == .timer {
                Divider()
                Button("+1 min") { timer.addMinute() }
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 10, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 22)
        .background(Circle().fill(SparkVTheme.surface))
        .overlay(Circle().strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
        .tint(SparkVTheme.text)
        .help("Presets")
    }
}

/// Small round icon button for the timer's controls.
private struct TimerControlButton: View {
    let symbol: String
    let help: String
    var isProminent = false
    let action: () -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isProminent ? SparkVTheme.choose(apple: Color.black, sparkv: Color.white) : SparkVTheme.text)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isProminent ? prominentFill : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
                .overlay(Circle().strokeBorder(isProminent || SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(help)
    }

    /// Apple: a white play/pause disc like the Clock app's; SparkV Red: red.
    private var prominentFill: Color {
        if SparkVTheme.isApple { return Color.white.opacity(hover.isOn ? 0.85 : 1) }
        return hover.isOn ? SparkVTheme.redDeep : SparkVTheme.red
    }
}

// MARK: - Bands under the notch

/// Running timer band: a tiny ring, "Focus 18:42", and the session or state
/// on the right. Built from a snapshot because the band is re-posted every
/// second.
struct TimerBandView: View {
    struct Model {
        let title: String
        let time: String
        let progress: Double
        let accent: Color
        let isPaused: Bool
        let isPending: Bool
        let session: String?
    }

    let model: Model

    var body: some View {
        HStack(spacing: 10) {
            TimerMiniRing(progress: model.progress, accent: model.accent)
                .frame(width: 14, height: 14)
                .frame(width: 34, height: 16)

            Text("\(model.title) \(model.time)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(model.isPaused ? SparkVTheme.textTertiary : SparkVTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var trailing: some View {
        if model.isPaused {
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
        } else if model.isPending {
            Text("UP NEXT")
                .font(SparkVTheme.eyebrow(9.5))
                .tracking(0.6)
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
        } else if let session = model.session {
            Text(session)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize()
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
    }
}

private struct TimerMiniRing: View {
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
