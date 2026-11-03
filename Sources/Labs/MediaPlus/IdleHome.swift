import AppKit
import SwiftUI

/// Home's first column: the media player, or, when nothing plays (or media
/// controls are turned off), the next meeting / a clock with quick timers.
/// "Nothing plays" means no Now Playing app, or Music / Spotify stopped; a
/// paused track keeps the player so it can be resumed.
/// Drop-in for `MediaColumnV2()` in FeaturesGrid (same 180 x 69 frame).
///
/// Becoming idle waits 3 s (the source reads "none" between tracks and while
/// the adapter restarts); something starting to play swaps back at once.
/// "Connect Music" stays visible: it's how access is granted.
struct HomeMediaSlot: View {
    @EnvironmentObject private var media: MediaEngine
    @ObservedObject private var settings = MediaPlusSettings.shared
    @StateObject private var idle = IdleHomeModel()

    var body: some View {
        ZStack(alignment: .leading) {
            if idle.showsIdle {
                IdleHomeColumn(mode: settings.showsMediaControls ? settings.idleMode : .upNext)
                    .transition(.sparkVCrossfade)
            } else {
                MediaColumnV2()
                    .transition(.sparkVCrossfade)
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut(SparkVMotion.Duration.standard)), value: idle.showsIdle)
        .onAppear { idle.update(wantsIdle: wantsIdle, immediately: true) }
        .onChange(of: wantsIdle) { _, wants in idle.update(wantsIdle: wants, immediately: false) }
    }

    private var wantsIdle: Bool {
        IdleHomeDecision.showsIdle(mode: settings.idleMode, showsMediaControls: settings.showsMediaControls, source: sourceKind)
    }

    private var sourceKind: IdleHomeDecision.SourceKind {
        switch media.source {
        case .none: return .none
        case .needsPermission, .denied: return .needsPermission
        case .player:
            // Apple Events "stopped" player: nothing to control.
            if media.isPlaying { return .playing }
            return media.isStoppedPlayer ? .stoppedPlayer : .paused
        case .app:
            return media.isPlaying ? .playing : .paused
        }
    }
}

/// Debounces the swap to the idle column.
@MainActor
final class IdleHomeModel: ObservableObject {
    @Published private(set) var showsIdle = false
    private var task: Task<Void, Never>?

    func update(wantsIdle: Bool, immediately: Bool) {
        task?.cancel()
        task = nil
        guard wantsIdle else {
            if showsIdle { showsIdle = false }
            return
        }
        if immediately {
            showsIdle = true
            return
        }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IdleHomeDecision.idleDelay))
            guard !Task.isCancelled else { return }
            self?.showsIdle = true
        }
    }
}

/// 180 x 69: the next meeting with a Join pill (or a large clock), and two
/// quick-timer chips. Redraws once a minute while visible.
struct IdleHomeColumn: View {
    let mode: IdleHomeMode
    @EnvironmentObject private var meetings: MeetingsController
    @EnvironmentObject private var timer: TimerController
    /// Fixed clock for offscreen renders.
    var previewDate: Date? = nil

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = previewDate ?? context.date
            VStack(alignment: .leading, spacing: 0) {
                if mode == .upNext, let meeting = nextMeeting(now: now) {
                    meetingCard(meeting, now: now)
                } else {
                    clock(now: now)
                }
                Spacer(minLength: 0)
                chips
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func nextMeeting(now: Date) -> CalendarMeeting? {
        guard meetings.isEnabled, meetings.access == .granted else { return nil }
        return meetings.meetings.first { $0.end > now }
    }

    // MARK: Meeting

    private func meetingCard(_ meeting: CalendarMeeting, now: Date) -> some View {
        let timing = meetings.timing(for: meeting)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color(.sRGB, red: meeting.calendarColor.red, green: meeting.calendarColor.green,
                                blue: meeting.calendarColor.blue, opacity: 1))
                    .frame(width: 6, height: 6)
                Text(timing.hasStarted ? "NOW" : "UP NEXT")
                    .font(SparkVTheme.eyebrow(9))
                    .tracking(LabsBStyle.eyebrowTracking(1.0))
                    .foregroundStyle(timing.hasStarted ? SparkVTheme.accent : SparkVTheme.textTertiary)
            }
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(text: meeting.title, font: MediaColumnV2.titleFont)
                        .frame(height: 16)
                    Text(Self.when(meeting, timing: timing))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if meeting.link != nil {
                    Button { meetings.join(meeting) } label: { MeetingJoinPill(isNow: timing.isJoinMoment || timing.hasStarted) }
                        .buttonStyle(SparkVPressStyle())
                        .help("Join \(meeting.title)")
                        .accessibilityLabel("Join \(meeting.title)")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    static func when(_ meeting: CalendarMeeting, timing: MeetingTiming) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let start = formatter.string(from: meeting.start)
        switch timing {
        case .upcoming(let minutes):
            if minutes < 60 { return "\(start) · in \(minutes) min" }
            return "\(start) · in \(minutes / 60) h \(minutes % 60 == 0 ? "" : "\(minutes % 60) min")".trimmingCharacters(in: .whitespaces)
        case .now: return "\(start) · starting now"
        case .inProgress: return "Until \(formatter.string(from: meeting.end))"
        case .ended: return start
        }
    }

    // MARK: Clock

    private func clock(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 24, weight: .semibold, design: SparkVTheme.isApple ? .default : .monospaced).monospacedDigit())
                .tracking(-0.4)
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(now, format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Timer chips

    private var chips: some View {
        HStack(spacing: 5) {
            if timer.state.isRunning, previewDate == nil {
                // Counts down once a second, only while it runs.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    IdleChip(title: TimerFormat.clock(timer.state.remaining(at: context.date)), systemImage: "pause.fill",
                             isActive: true, help: "Pause the timer") { timer.toggle() }
                }
            } else if timer.state.isRunning || timer.state.isPaused {
                IdleChip(title: TimerFormat.clock(timer.state.remaining(at: previewDate ?? Date())),
                         systemImage: timer.state.isPaused ? "play.fill" : "pause.fill",
                         isActive: true, help: timer.state.isPaused ? "Resume the timer" : "Pause the timer") { timer.toggle() }
            } else {
                IdleChip(title: "25 min", systemImage: "play.fill", help: "Start a 25-minute focus timer") { timer.startPomodoro() }
                IdleChip(title: "5 min", systemImage: "timer", help: "Start a 5-minute timer") { timer.startTimer(minutes: 5) }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 20)
    }
}

/// A small capsule button in the idle column.
private struct IdleChip: View {
    let title: String
    let systemImage: String
    var isActive = false
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(isActive ? SparkVTheme.text : (hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary))
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(isActive ? LabsBStyle.selectedFill : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(Capsule().strokeBorder(isActive ? LabsBStyle.selectedStroke : LabsBStyle.chipStroke, lineWidth: 1))
            .contentShape(Capsule())
            .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
