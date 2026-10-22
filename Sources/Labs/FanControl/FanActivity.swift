import SwiftUI

// The fan live activity: the island's wings show the fan speed and the
// hottest CPU reading while a fan is under manual control (or always, if
// the user picks that). A change in the number of manual fans, or the
// failsafe tripping, peeks the band below the notch for a few seconds.

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
            // Below meetings and HUDs; the failsafe outranks a running timer.
            priority: state.failsafe != nil ? 55 : 15,
            duration: nil,
            opensTab: opensTab,
            presentation: .compact,
            symbol: "fan.fill",
            tint: state.failsafe != nil ? SparkVTheme.destructive : (state.manualFans > 0 ? SparkVTheme.red : SparkVTheme.text),
            compactText: FanFormat.compactRPM(fastest),
            peekKey: state.failsafe != nil ? "failsafe" : "manual-\(state.manualFans)"
        ) {
            FanActivityBand(state: state)
        }
        .compact(leading: {
            FanGlyph(manual: state.manualFans > 0 || state.failsafe != nil, size: 12)
        }, trailing: {
            FanActivityTrailing(state: state, fastest: fastest)
        })
        .minimal {
            FanGlyph(manual: state.manualFans > 0, size: 11)
        }
    }
}
