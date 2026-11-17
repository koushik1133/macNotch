import SwiftUI

// The fan live activity (Show in the Notch: Always): the island's wings
// show the fan speed and the hottest CPU reading.

extension FanController {
    /// Call once, after `start()`: `FanController.shared.connect(activities: activities)`.
    func connect(activities center: ActivityCenter, opensTab: NotchState.Tab? = nil) {
        activitySink = { [weak center] state in
            guard let center else { return }
            guard let state else {
                center.dismiss(id: FanLiveActivity.id)
                return
            }
            center.post(FanLiveActivity.make(state, opensTab: opensTab))
        }
        activitySink?(activityState)
    }
}

enum FanLiveActivity {
    static let id = "fans"

    static func make(_ state: FanActivityState, opensTab: NotchState.Tab?) -> LiveActivity {
        let fastest = state.rpms.compactMap { $0 }.max()
        return LiveActivity(
            id: id,
            kind: .battery,
            // Below meetings, HUDs and timers.
            priority: 15,
            duration: nil,
            opensTab: opensTab,
            presentation: .compact,
            symbol: "fan.fill",
            tint: SparkVTheme.text,
            compactText: FanFormat.compactRPM(fastest),
            peekKey: nil
        ) {
            FanActivityBand(state: state)
        }
        .compact(leading: {
            FanGlyph(size: 12)
        }, trailing: {
            FanActivityTrailing(state: state, fastest: fastest)
        })
        .minimal {
            FanGlyph(size: 11)
        }
    }
}
