# Notch widgets: wiring steps for the lead

Everything lives in `Sources/Labs/Widgets/`. No existing file was edited. The folder is self-contained: every model has a `shared` instance, so nothing needs to be created in `NotchWindowController` or injected as an environment object.

## What it contains

| File | What it is |
| --- | --- |
| `WidgetsCatalog.swift` | `WidgetKind` (the 5 widgets), `WidgetsSettings` (which widgets show, in order, in UserDefaults `SparkV.widgets.enabled`), `WidgetGridLayout` (the adaptive packer), and shared pieces (`WidgetCard`, `WidgetRing`, `WidgetSparkline`, `WidgetSamplingLoop`, `.whileVisible`). |
| `WorldClockWidget.swift` | World clocks (up to 3 cities, `SparkV.widgets.worldClocks`), time-zone search, and the city editor. |
| `VolumeKnobWidget.swift` | Rotary volume knob on the CoreAudio default output (`kAudioDevicePropertyVolumeScalar`, main element or channels 1+2, same as `SystemKeyInterceptor`'s VolumeControl), plus property listeners and haptic detents. |
| `HabitsWidget.swift` | Daily habits (up to 6, `SparkV.widgets.habits`, JSON): a 7-day grid, streaks, and the habit editor. |
| `SystemGaugesWidget.swift` | CPU (`host_processor_info` deltas), memory used plus pressure (`host_statistics64` and `kern.memorystatus_vm_pressure_level`), and thermal state. |
| `NetworkSpeedWidget.swift` | Down/up throughput from `getifaddrs` byte deltas (loopback, VPN `utun`, AWDL and bridges excluded; 32-bit wrap handled). |
| `WidgetsTabView.swift` | `WidgetsTabView` (grid, rail, edit page) and `WidgetsHomeAccessory` (the knob for Home). |

All sampling happens only while a view is on screen. The gauges and network samplers are reference-counted 2 s loops that start in `onAppear` and stop in `onDisappear` (the second reading comes after 0.6 s, so CPU and throughput show within a glance instead of "--" for 2 s). The knob adds its CoreAudio listeners on appear and removes them on disappear, and its scroll monitor exists only while the pointer hovers over it. The world clock and habit views use `TimelineView(.everyMinute)`, which only ticks while it is visible. Closing the drawer removes the tab content, so everything stops.

## 1. build.sh: compile the folder

Next to the other `Labs` lines:

```zsh
cp Sources/Labs/Widgets/*.swift "$WORK/src/"
```

There are no new frameworks or linker flags: CoreAudio, Darwin and AppKit are autolinked. The only type used from outside the folder is `ViewFlag` (`NotchState.swift`).

## 2. NotchState.swift: a tab

Add a case to `NotchState.Tab`:

```swift
        /// Notch widgets: world clocks, volume knob, habits, system gauges, network speed.
        case widgets
```

The widgets are designed for the **tall** drawer (508x114 pt content: a 4x2 grid of ~116x54 pt cells with all five widgets). Add `.widgets` to the tall list in `NotchMetrics.expandedSize(for:)`:

```swift
        CGSize(width: expandedSize.width, height: [.tray, .converter, .clipboard, .agents, .search, .downloads, .widgets].contains(tab) ? trayExpandedHeight : expandedSize.height)
```

If you keep it at the normal height (508x69), it still works. The grid becomes 4x1, the widgets shrink to their small sizes, and the rest moves to a second page that the rail's chevrons switch to.

### Header icon (recommended) or hub tile

**Header icon (recommended).** The left header group measures 128 of 161.5 pt, so one more 24 pt `IconTab` fits (128 + 2 + 24 = 154). Widgets are everyday glanceables, so they belong next to Home. In `NotchNookLayoutView.swift` `HeaderRow`, after the Home icon:

```swift
            IconTab(systemImage: "rectangle.3.group.fill", tab: .widgets, help: "Widgets: world clocks, volume, habits, system and network")
```

**Agents hub tile (alternative).** `AgentsHubView` is a full 8x2 grid (16 cells), so a tile has to replace a cell. To do that, add `.widgets` to `NotchState.Tab.agentTabs` and replace a cell in `AgentsHubView.cells`, for example:

```swift
            .agent(Agent(tab: .widgets, title: "Widgets", systemImage: "rectangle.3.group.fill", tint: .orange)),
```

## 3. NotchNookLayoutView.swift: draw the tab

In the tab `switch`:

```swift
                        case .widgets: WidgetsTabView()
```

`WidgetsTabView()` uses `WidgetsSettings.shared` and `WidgetModels.live`. The other parameters exist for tests and renders.

The drawer's `onDrop` already falls through to `tray.accept`, which is fine: widgets take no drops.

## 4. Home view: the widget beside the media

The Home row (`FeaturesGrid`) uses 404 of 508 pt: media 180, macros 130, mirror 60, four 8 pt spacers and two dividers. That leaves about 104 pt, so a 56x56 widget plus a divider fits. The **volume knob** fits best: it pairs with the playback controls, needs no label, and is 56 pt like the artwork. In `FeaturesGrid.body`, after `MediaColumn()`:

```swift
            MediaColumn()
                .frame(width: 180, alignment: .leading)
            Spacer(minLength: 8)
            WidgetsHomeAccessory()          // 56x56 volume knob
            Spacer(minLength: 8)
            ColumnDivider()
```

The total becomes 404 + 56 + 16 = 476 of 508. If a media progress bar or another agent's addition also widens Home, use the knob alone in place of the mirror column (both are 56-60 pt wide).

## Interaction summary (for release notes)

- **Grid adapts to the space.** Each widget starts at its largest size that fits (habits 2x2, clocks/system/network 2x1, knob 1x1) and steps down when space runs out. The network sparkline shrinks first and the habit grid last. If even the smallest sizes overflow, the rest goes on a further page, and each page then grows its widgets into free cells. Free cells show an "Add widget" tile when some widgets are hidden.
- **Rail (right edge).** The slider button opens the edit page (Widgets / Cities / Habits). Chevrons and dots appear when there is more than one page.
- **Right-click a widget** to move it earlier or later, hide it, or open its editor.
- **Knob.** Drag around it, or scroll over it (trackpad or wheel), to change the volume. Click it to mute. Each 1/16 step gives a haptic detent, with a stronger one at 0% and 100%. Turning the knob up unmutes. VoiceOver can adjust it too.
- **Habits.** Click any box from the last 7 days. "Today" rolls over at local midnight. A streak stays alive until the end of a missed day.
- **Clocks.** Search by city, zone name ("Pacific Time"), abbreviation or common city aliases (San Francisco, Bengaluru, Mumbai, Beijing, ...). The defaults skip the Mac's own zone.
