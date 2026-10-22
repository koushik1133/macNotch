import SwiftUI

/// The Today tab: upcoming meetings on the left, the timer on the right.
/// Meeting recording lives in the header (red record button).
struct TodayView: View {
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let intel = MeetingIntelCenter.current {
                    MeetingStartTodaySlot(coordinator: intel.coordinator) { MeetingsView() }
                } else {
                    MeetingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Rectangle()
                .fill(SparkVTheme.choose(apple: Color.white.opacity(0.15), sparkv: SparkVTheme.stroke))
                .frame(width: 1, height: 52)
            TimerView()
                .frame(width: 170)
        }
    }
}
