import SwiftUI

/// Compact meeting control for the drawer (about 170×28pt): record/stop,
/// elapsed time or status, and a button that opens the notes window.
struct MeetingCapsuleView: View {
    @EnvironmentObject private var assistant: MeetingAssistant

    var body: some View {
        HStack(spacing: 6) {
            recordButton
            status
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                assistant.openNotesWindow()
            } label: {
                Text("Notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(SparkVTheme.surfaceHover))
                    .overlay(Capsule().strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
            }
            .buttonStyle(SparkVPressStyle())
            .help("Open meeting notes")
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Capsule().fill(SparkVTheme.surface))
        .overlay(Capsule().strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke))
    }

    private var recordButton: some View {
        Button {
            switch assistant.phase {
            case .recording: assistant.stop()
            case .idle, .failed: assistant.start(title: nil, calendarEventID: nil)
            case .summarizing: break
            }
        } label: {
            ZStack {
                Circle()
                    .fill(assistant.phase == .recording ? SparkVTheme.surfaceHover : SparkVTheme.recordingSoft)
                    .frame(width: 20, height: 20)
                if assistant.phase == .recording {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(SparkVTheme.recording)
                        .frame(width: 8, height: 8)
                } else if assistant.phase == .summarizing {
                    ProgressView().controlSize(.mini).tint(SparkVTheme.progressTint)
                } else {
                    Circle().fill(SparkVTheme.recording).frame(width: 9, height: 9)
                }
            }
        }
        .buttonStyle(SparkVPressStyle())
        .opacity(assistant.phase == .summarizing ? 0.5 : 1)
        .disabled(assistant.phase == .summarizing)
        .help(assistant.phase == .recording ? "Stop and write notes" : "Record a meeting")
        .accessibilityLabel(assistant.phase == .recording ? "Stop recording and write notes" : (assistant.phase == .summarizing ? "Writing notes" : "Record a meeting"))
    }

    @ViewBuilder
    private var status: some View {
        switch assistant.phase {
        case .recording:
            if let startedAt = assistant.current?.startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(startedAt)
                    HStack(spacing: 4) {
                        MeetingPulsingDot(isOn: Int(elapsed) % 2 == 0)
                            .scaleEffect(0.7)
                        Text(MeetingFormat.clock(elapsed))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(SparkVTheme.text)
                    }
                }
            }
        case .summarizing:
            label("Writing notes…", color: SparkVTheme.text)
        case .failed(let message):
            label(message, color: SparkVTheme.warning)
                .help(message)
        case .idle:
            label("Record meeting", color: SparkVTheme.textSecondary)
        }
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
