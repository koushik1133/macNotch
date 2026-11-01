import SwiftUI

// Bands shown under the notch for the meeting assistant (posted to
// ActivityCenter by MeetingAssistant). Each is laid out in roughly
// 360×height pt on a black background.

/// While recording: pulsing red dot, elapsed time, mic and system levels.
/// The first seconds also remind the user to tell participants.
struct MeetingRecordingBand: View {
    @ObservedObject var recorder: MeetingRecorder
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            HStack(spacing: 10) {
                MeetingPulsingDot(isOn: Int(elapsed) % 2 == 0)

                Text(elapsed < 10 ? "Let participants know you're recording" : "Recording meeting")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(elapsed < 10 ? SparkVTheme.warning : SparkVTheme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                MeetingLevelMeter(symbol: "mic.fill", level: recorder.micLevel)
                MeetingLevelMeter(symbol: "speaker.wave.2.fill", level: recorder.systemLevel)

                Text(MeetingFormat.clock(elapsed))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)

                if MeetingIntelCenter.current != nil {
                    Button {
                        MeetingIntelCenter.current?.bookmarkNow()
                    } label: {
                        Image(systemName: "bookmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                    .buttonStyle(SparkVPressStyle())
                    .help("Bookmark this moment")
                    .accessibilityLabel("Bookmark this moment")
                }
            }
        }
    }
}

/// After stopping, while the minutes are written.
struct MeetingSummarizingBand: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(SparkVTheme.progressTint)
            Text("Writing meeting notes…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// The pop-up when someone asks the user a question: the question on top,
/// the suggested answer (or "Thinking…") under it.
struct MeetingAnswerBand: View {
    let question: String
    let answer: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: answer == nil ? "questionmark.bubble.fill" : "lightbulb.fill")
                .font(.system(size: 15))
                .foregroundStyle(SparkVTheme.choose(apple: answer == nil ? Color.blue : Color.yellow, sparkv: SparkVTheme.red))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Q: \(question)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let answer {
                    Text(answer)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
                        Text("Thinking of an answer…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SparkVTheme.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One-line status: notes ready, nothing captured, a failure.
struct MeetingStatusBand: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .layoutPriority(1)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Pieces

/// Red dot that eases between bright and dim each time `isOn` flips.
struct MeetingPulsingDot: View {
    let isOn: Bool

    var body: some View {
        // Differentiate Without Color: a record glyph, not only a red dot.
        // Reduce Motion: steady.
        let pulses = !SparkVMotion.reduceMotion
        ZStack {
            if SparkVTheme.differentiateWithoutColor {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SparkVTheme.recording)
                    .opacity(isOn || !pulses ? 1 : 0.6)
            } else {
                Circle()
                    .fill(SparkVTheme.recording.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(isOn || !pulses ? 1 : 0.55)
                Circle()
                    .fill(SparkVTheme.recording)
                    .frame(width: 8, height: 8)
                    .opacity(isOn || !pulses ? 1 : 0.6)
            }
        }
        .frame(width: 14, height: 14)
        .animation(pulses ? .easeInOut(duration: 0.9) : nil, value: isOn)
        .accessibilityLabel("Recording")
    }
}

/// Small icon plus a five-bar level meter.
struct MeetingLevelMeter: View {
    let symbol: String
    /// 0…1
    let level: Float

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 8))
                .foregroundStyle(SparkVTheme.textTertiary)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<5, id: \.self) { index in
                    let threshold = Float(index) / 5
                    RoundedRectangle(cornerRadius: 1)
                        .fill(clamped > threshold ? SparkVTheme.choose(apple: Color.green, sparkv: SparkVTheme.red) : SparkVTheme.surfaceHover)
                        .frame(width: 2.5, height: 4 + CGFloat(index) * 2)
                }
            }
            .animation(SparkVMotion.easeOut(0.12), value: clamped)
        }
    }

    private var clamped: Float { min(1, max(0, level)) }
}
