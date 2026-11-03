import SwiftUI

/// The Today tab. In the tall drawer (114 pt of content) it is the Planner:
/// a rail of pages (Today, Agenda, Reminders, Timers, Weather, Launcher).
/// At the normal height (69 pt) it keeps the classic layout: upcoming
/// meetings on the left, the timer on the right. Meeting recording lives in
/// the header (red record button).
struct TodayView: View {
    var body: some View {
        GeometryReader { geo in
            Group {
                if geo.size.height >= PlannerMetrics.minimumHeight {
                    PlannerPage()
                } else {
                    TodayCompactView()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

/// Meetings and the timer side by side (the short drawer).
struct TodayCompactView: View {
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
