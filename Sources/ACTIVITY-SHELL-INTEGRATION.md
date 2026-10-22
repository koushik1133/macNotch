# Live activity shell: compact wings, alert queue, tab crossfade

Owner files: `LiveActivity.swift`, `DictationActivityView.swift`,
`NotchNookLayoutView.swift` (root struct only), `NotchState.swift`
(`NotchMetrics`), `NotchWindowController.swift` (hot zone, tab resize),
`IslandShape.swift` (`IslandClosedLayout`).

## What changed

The closed island now works like the Dynamic Island:

- **Compact (default)**: the island grows *sideways* inside the menu-bar
  height. Leading view left of the camera housing, trailing view right of it.
  Each wing is measured and fitted to its content (30–112 pt, balanced when
  the two sides are within 14 pt). Nothing below the menu bar is covered.
- **Expanded**: the old band under the notch. Used only for
  - transient alerts (duration ≤ 8 s) that have no compact form,
  - `urgent` activities, `.expanded` presentation,
  - a 4 s "peek" when a persistent activity first appears without a compact
    form, or whenever its `peekKey` changes.
- **Alert queue**: alerts ≤ 8 s are queued by priority; their time only runs
  while they are on screen, so a notification no longer eats the charging
  alert. Duplicates coalesce by id. Equal priority is first come, first served
  (volume/brightness: newest wins, never replayed). A preempted alert comes back
  with its remaining time; an alert that waited 12 s is dropped as stale; the
  queue pauses while the drawer is open.
- **Persistent activities stay in the wings** while an alert plays in the band.
  A second persistent activity shows its `minimal` icon after the first one's
  trailing view. While one peeks in the band, the next keeps the wings.
- While dictation/Clicky hold the band, alerts that wanted it show compact.
- **Now playing (closed)**: artwork on the left wing; level bars on the right,
  plus the new track's title in a tiny marquee for 8 s after each track change.
- **Tabs** crossfade (opacity + 3 % scale + blur) and the drawer height springs
  between tabs; the panel shrinks only after the spring, so nothing is cut off.
- Hover hot zone = the island as drawn (wings included; the band only when its
  activity has `opensTab`). Hovering opens the drawer on the band's tab, else
  the compact activity's tab.

Source compatible: every existing `LiveActivity(...)` call still compiles and
works. Without a compact form an activity gets an automatic one (the kind's
symbol + `compactText` or a dot) and, if persistent, peeks for 4 s first.
Exception: an automatic activity whose band is taller than one line
(`height` > 30, e.g. MeetingAssistant's 48 pt answers, LiveTranslation's
captions) and has no compact form is text to read, so it keeps the band for as
long as it is posted; pass `presentation: .compact` to opt out.
`ActivityCenter.current` is now **the activity in the band** (nil while it is
compact), so `FileDropController`'s `activities.current?.height` stays correct.

## API

```swift
LiveActivity(
    id:, kind:, priority:, duration:, height:, opensTab:,   // as before
    presentation: .automatic | .compact | .expanded,       // default .automatic
    urgent: Bool,             // expanded for as long as it is posted urgent
    symbol: String?,          // automatic compact icon (default: kind's)
    tint: Color?,             // automatic icon/text tint
    compactText: String?,     // automatic trailing text: "8 min", "45%", "12:04"
    peekKey: String?          // change it to re-peek the band for 4 s
) { band view }
.compact { leading view } trailing: { trailing view }   // ~20 pt tall, ≤ 90 pt wide
.minimal { single icon }
.urgent(true) / .presentation(.compact) / .peeking(on: "now")

activities.peek(id:, for:)     // force a peek
activities.compact / .secondary / .queuedAlertIDs / .activeIDs
```

Helpers for compact views: `CompactLevelBar(level:tint:)`,
`CompactProgressRing(progress:tint:)`, `CompactMarquee(text:maxWidth:)`.

## Suggested adoption per feature (owners apply in their files)

Already adopted: `MeetingsController` (badge + "8 min"/"Now", peekKey
soon/now) and the Modes lab (see its INTEGRATION.md). Recommended for
meetings: no `urgent` at "Now" (the join window lasts 6 min, so an urgent band
would cover the page for that long, which is the original complaint); instead
`if isNow, !joined { activities.peek(id: id, for: 10) }` after posting.

**HUDController** (`postVolume`, `postBrightness`) — boring.notch inline OSD,
never covers content:
```swift
activities.post(LiveActivity(id: Self.volumeActivityID, kind: .volume, priority: 90,
                             duration: Self.hudDuration) { HUDActivityView(content: content) }
    .compact {
        Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
    } trailing: { CompactLevelBar(level: state.isMuted ? 0 : Double(state.volume ?? 0)) })
// brightness: "sun.max.fill" + CompactLevelBar(level: Double(value))
// postDevice (output switched): keep the band (it names the device).
```

**TimerController.updateActivity** / **FocusController.updateBand**:
```swift
LiveActivity(id: Self.activityID, kind: .timer, priority: 20, duration: nil, opensTab: .today,
             tint: TimerFormat.color(of: state.phase), compactText: snapshot.time) { TimerBandView(model: snapshot) }
    .compact { CompactProgressRing(progress: snapshot.progress, tint: snapshot.accent) }
        trailing: { Text(snapshot.time).font(.system(size: 12, weight: .semibold).monospacedDigit()) }
```
Celebrations (5 s) stay in the band (queued).

**MeetingAssistant.postRecordingActivity**:
```swift
LiveActivity(id: ActivityID.recording, kind: .meeting, priority: Self.recordingPriority,
             duration: nil, presentation: .compact) { MeetingRecordingBand(recorder: recorder, startedAt: started) }
    .compact { Circle().fill(Color.red).frame(width: 8, height: 8) }
        trailing: { TimelineView(.periodic(from: started, by: 1)) { ctx in
            Text(Duration.seconds(ctx.date.timeIntervalSince(started)).formatted(.time(pattern: .minuteSecond)))
                .font(.system(size: 12, weight: .semibold).monospacedDigit()) } }
```
Meeting answers (two lines, 48 pt): add `presentation: .expanded`.

**DownloadsController.updateProgressActivity**:
```swift
.compact { Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue) }
    trailing: { CompactProgressRing(progress: overallProgress, tint: .blue) }
```

**ScreenDistanceController.postBand** (too close): `urgent: true` while too close.

**ClipboardController** ("Copied" 1.8 s), **ScreenshotClipboard**,
**QuickCapture** toasts: `compactText: "Copied"` (+ `symbol:`) so they stay in
the wings and never cover the page.

**PowerMonitor** (battery/AirPods, 2.5–5 s): fine as is (queued band). For a
quieter look: `symbol: "battery.100percent.bolt", tint: .green, compactText: "82%"`.

**NotificationMonitor**: keep the band (the text needs reading); it is queued.

## Tests

Headless harness (fake clock, 41 checks, offscreen renders of every closed
state) lives in the session scratchpad: `round3/activity-shell/harness`.
