# Color Picker: wiring steps for the integrator

A screen color picker for SparkV: one shortcut (**⌃⌥P**), one pick over any app,
website or display, and the color is already on the clipboard in the user's
default format. A short band under the notch confirms it. The Agents hub gets a
"Pick Color" tile, the gear menu a "Color Picker" submenu, and the drawer a
Color Picker page (formats, WCAG contrast, shades, palettes, recent colors).

Everything lives in `Sources/Labs/ColorPicker/`. No other file was edited. File
names are unique, so build.sh's flat `$WORK/src` copy is safe.

**Permissions: none.** Picking uses the public `NSColorSampler` (the system
loupe in the out-of-process ColorSampler.xpc). It reads one pixel after the
user's own gesture and needs no Screen Recording grant, so ad-hoc rebuilds
don't lose anything. No Info.plist keys, no entitlements, no PermissionCenter
entry.

**Idle cost: none.** No timers or polling. Only a Carbon hotkey is registered
(through `ScreenRegionHotkey`, no Accessibility needed). During a pick a single
20 s watchdog task waits to offer "Reset"; after a copy a 1.2 s task clears the
✓, and after a delete an 8 s task retires Undo.

All 20 edits below were applied to a fresh copy of the current sources
(build.sh, NotchState, NotchNookLayoutView, AgentsHubView, NotchWindowController)
by a script that reads this file, checks that every **Find** text occurs exactly
once, and replaces it. That copy typechecked with no errors in Swift 5 and in
Swift 6, and no warnings from the lab or the edited NotchWindowController.

## Files

| File | What it is |
| --- | --- |
| `ColorPickerMath.swift` | `CPColor` (extended sRGB, so P3 picks keep their out-of-gamut values), sRGB ↔ linear, Display P3, Oklab/OKLCH, CIELAB (D50), HSL/HSB, gamut mapping by OKLCH chroma reduction, ΔE in Oklab. `CPContrast`: WCAG 2 luminance on clamped linear sRGB, ratio, AA/AAA/large/non-text levels, APCA Lc (shown as "not yet a standard"), "suggest a passing color" (OKLCH lightness search, same hue). `CPShades`: 5 tints + base + 5 shades, and a 50…950 scale with the base at its nearest step. |
| `ColorPickerFormats.swift` | `CPFormat` (HEX, RGB, HSL, HSB, OKLCH, CSS Display P3, SwiftUI, UIKit, AppKit, Tailwind), `CPFormatter`, `CPParser` (hex, rgb/rgba, hsl, hsb/hsv and the HSB row's own `217°, 76%, 96%`, oklch, oklab, lab, color(display-p3/srgb), SwiftUI/UIKit/AppKit initializers, CSS names, Tailwind classes). OKLCH and P3 text use extra digits only when the short form would not read back to the same color (same hex inside sRGB, same Display P3 values within half a step outside it); "Precise HSL and HSB" does the same for HSL/HSB (off by default: whole numbers, as most people expect). The parser clamps like CSS (rgb/hsl/hex/color(srgb) to 0…1; oklch/oklab/lab lightness, then maps into Display P3) and refuses anything not finite or outside -0.5…1.5, so a pasted value can't poison the saved history. A nearest Tailwind class shows as "≈ red-500" on the row; the copy is the class. |
| `ColorPickerNames.swift` | The 148 CSS color keywords, the Tailwind v3.4 palette (22 hues × 50…950, plus black/white), nearest match by ΔE in Oklab, and a plain family name ("Dark Blue"). |
| `ColorPickerStore.swift` | History entry, palette, contrast pair, history/palette rules (last 30, deduped, newest first; Undo merges removed entries back by date), palette export (CSS variables, Tailwind `theme.colors`, JSON, Swift `extension Color`), UserDefaults keys `ColorPicker.*`. A failed save is logged to AppLog (it used to be swallowed). |
| `ColorPickerSampler.swift` | `CPColorSampling` protocol and `CPSystemSampler` (`NSColorSampler`): the default start that never activates SparkV, the compatibility start, and `CPProcessReset` (SIGTERM, then SIGKILL after 0.5 s, via libproc and kill(2)). `NSColor` → `CPColor` always goes through `usingColorSpace(.extendedSRGB)`. |
| `ColorPickerController.swift` | `ColorPickerController` (`ObservableObject`, `@MainActor`): `pickColor(into:)`, copy (text plus an `NSColor` in one pasteboard item, so color wells accept a paste), history, palettes, contrast, settings, hotkey, watchdog and reset, Undo of the last removal. |
| `ColorPickBand.swift` | The only file that touches `ActivityCenter` / `LiveActivity` / `NotchState`: `connect(activities:opensTab:)` and the band view (priority 66). |
| `ColorPickerComponents.swift` | Swatches, small buttons, ✓/✕ level badges, `Color(cp:)`. |
| `ColorPickerDrawerView.swift` | `ColorPickerDrawerView` (508×114 drawer page). |
| `ColorPickerHubTile.swift` | `ColorPickerHubTile` (Agents hub), `ColorPickerMenuItems` (gear menu, tile right-click), `ColorPickerSettingsItems`. |

## 1. build.sh

#### Edit 1 — `build.sh`: compile the lab

Find:
```zsh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```
Replace with:
```zsh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp Sources/Labs/ColorPicker/*.swift "$WORK/src/"
```

## 2. NotchState.swift

The page is designed for the tall drawer (508×114), and it is an Agents-hub
page, so the Agents header icon stays lit on it.

#### Edit 2a — `Sources/NotchState.swift`: the tab

Find:
```swift
        case fans

```
Replace with:
```swift
        case fans
        /// Color Picker: formats, contrast, shades, palettes (Agents hub tile; ⌃⌥P picks).
        case colorPicker

```

#### Edit 2b — `Sources/NotchState.swift`: an Agents hub page

Find:
```swift
            .focus, .search, .replyDrafter, .fileDrop, .downloads, .fans,
```
Replace with:
```swift
            .focus, .search, .replyDrafter, .fileDrop, .downloads, .fans, .colorPicker,
```

#### Edit 2c — `Sources/NotchState.swift`: the tall drawer

Find:
```swift
    static let tallTabs: Set<NotchState.Tab> = [.tray, .converter, .clipboard, .search, .downloads, .widgets, .replyDrafter, .fans]
```
Replace with:
```swift
    static let tallTabs: Set<NotchState.Tab> = [.tray, .converter, .clipboard, .search, .downloads, .widgets, .replyDrafter, .fans, .colorPicker]
```

## 3. NotchNookLayoutView.swift

#### Edit 3a — `Sources/NotchNookLayoutView.swift`: environment object for the page

Find:
```swift
    @EnvironmentObject private var downloads: DownloadsController
    /// Notch theme and island background (Labs/NotchThemes).
```
Replace with:
```swift
    @EnvironmentObject private var downloads: DownloadsController
    @EnvironmentObject private var colorPicker: ColorPickerController
    /// Notch theme and island background (Labs/NotchThemes).
```

#### Edit 3b — `Sources/NotchNookLayoutView.swift`: the drawer page (the switch must stay exhaustive)

Find:
```swift
        case .fans: FanTabView()
```
Replace with:
```swift
        case .fans: FanTabView()
        case .colorPicker: ColorPickerDrawerView(controller: colorPicker)
```

#### Edit 3c — `Sources/NotchNookLayoutView.swift`: environment object for the gear menu

Find:
```swift
    @EnvironmentObject private var screenRecorder: ScreenRecorderController
    @ObservedObject private var flowCanvasSettings = FCSettingsModel.shared
```
Replace with:
```swift
    @EnvironmentObject private var screenRecorder: ScreenRecorderController
    @EnvironmentObject private var colorPicker: ColorPickerController
    @ObservedObject private var flowCanvasSettings = FCSettingsModel.shared
```

#### Edit 3d — `Sources/NotchNookLayoutView.swift`: gear menu submenu

Find:
```swift
            Menu("Fans") { FanMenuItems() }
```
Replace with:
```swift
            Menu("Color Picker") { ColorPickerMenuItems(controller: colorPicker) }
            Menu("Fans") { FanMenuItems() }
```

The submenu has: "Pick Color ⌃⌥P", "Reset Color Picker" (only while a pick is
open), "Open Color Picker", "Convert Clipboard Color", "Copy Last Color As ▸",
then the settings: "Copy As" (default format), Lowercase Hex, Include # in Hex,
Comma CSS Syntax, Precise HSL and HSB, Remember the App Each Color Came From,
"Shortcut ▸" (on/off plus ⌃⌥P / ⌃⌥K / ⌃⌥E / ⌃⌥I / ⌃⌥⌘C), Start Picker in
Compatibility Mode (turned on by itself after a stuck pick is reset), and
Clear Recent Colors.

## 4. AgentsHubView.swift: the "Pick Color" tile

The hub has 26 cells in 32 slots (4 rows of 8), so one more fits without a new
row. The tile goes in row 4, directly before Fans (row 4 becomes Pick Color,
Fans, the "C" capsule). If you'd rather keep screen tools together, the same
`.colorPicker,` line can go right after the "Copy Text" entry instead; the grid
reflows on its own.

#### Edit 4a — `Sources/AgentsHubView.swift`: environment object

Find:
```swift
    @EnvironmentObject private var clipboard: ClipboardController
```
Replace with:
```swift
    @EnvironmentObject private var clipboard: ClipboardController
    @EnvironmentObject private var colorPicker: ColorPickerController
```

#### Edit 4b — `Sources/AgentsHubView.swift`: the cell case

Find:
```swift
        case fans
```
Replace with:
```swift
        case fans
        case colorPicker
```

#### Edit 4c — `Sources/AgentsHubView.swift`: the cell id

Find:
```swift
            case .fans: "fans"
```
Replace with:
```swift
            case .fans: "fans"
            case .colorPicker: "colorPicker"
```

#### Edit 4d — `Sources/AgentsHubView.swift`: the cell's place in the grid

Find:
```swift
            .smartMoments,
            .fans,
```
Replace with:
```swift
            .smartMoments,
            .colorPicker,
            .fans,
```

#### Edit 4e — `Sources/AgentsHubView.swift`: the tile

Find:
```swift
        case .fans:
            FanHubTile(onOpen: { openTab(.fans) })
```
Replace with:
```swift
        case .colorPicker:
            // Click: pick at once (the drawer collapses first). The chevron opens
            // the page; right-click for formats and settings.
            ColorPickerHubTile(controller: colorPicker, onOpen: { openTab(.colorPicker) })
        case .fans:
            FanHubTile(onOpen: { openTab(.fans) })
```

Optionally update the comment on `AgentHubMetrics.rows` from "26 cells" to "27 cells".

## 5. NotchWindowController.swift

#### Edit 5a — `Sources/NotchWindowController.swift`: the property

Find:
```swift
    private let downloads: DownloadsController
```
Replace with:
```swift
    private let downloads: DownloadsController
    private let colorPicker: ColorPickerController
```

#### Edit 5b — `Sources/NotchWindowController.swift`: create it

Find:
```swift
        downloads = DownloadsController(activities: activities)
```
Replace with:
```swift
        downloads = DownloadsController(activities: activities)
        colorPicker = ColorPickerController()
```

#### Edit 5c — `Sources/NotchWindowController.swift`: band, drawer collapse, open page

Find:
```swift
        universalSearch.openFlowHandler = { [weak self] target in
```
Replace with:
```swift
        // Color Picker: the band opens its page on hover; the drawer gets out
        // of the way before the loupe shows, so it can't tint the pixels.
        colorPicker.connect(activities: activities, opensTab: .colorPicker)
        colorPicker.onWillPick = { [weak self] in self?.forceCollapse() }
        colorPicker.onOpenDrawer = { [weak self] in
            self?.state.select(.colorPicker)
            self?.setExpanded(true)
        }
        universalSearch.openFlowHandler = { [weak self] target in
```

#### Edit 5d — `Sources/NotchWindowController.swift`: environment object

Find:
```swift
            .environmentObject(downloads)
```
Replace with:
```swift
            .environmentObject(downloads)
            .environmentObject(colorPicker)
```

#### Edit 5e — `Sources/NotchWindowController.swift`: start (registers ⌃⌥P only)

Find:
```swift
        downloads.start()
```
Replace with:
```swift
        downloads.start()
        // ⌃⌥P: pick a color. Registers the hotkey only; nothing else runs.
        colorPicker.start()
```

#### Edit 5f — `Sources/NotchWindowController.swift`: tearDown

Find:
```swift
        downloads.stop()
```
Replace with:
```swift
        downloads.stop()
        colorPicker.stop()
```

#### Edit 5g — `Sources/NotchWindowController.swift`: no hover-open while the loupe is up

Find:
```swift
        // Over the File Drop shelf during a file drag: let the drop land there.
        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }
```
Replace with:
```swift
        // The color loupe is up: don't open the drawer over the pixels being
        // picked (or let a pointer theme move under them).
        if colorPicker.isPicking {
            endThemeHover()
            themeHover.setPointer(nil)
            return
        }
        // Over the File Drop shelf during a file drag: let the drop land there.
        if !state.isExpanded, fileDrop.zoneContains(NSEvent.mouseLocation) { return }
```

The global mouse-moved monitor opens the drawer as soon as the pointer enters
the notch hot zone (the dwell can be zero), so aiming the loupe at, say, a
browser tab under the notch would open the drawer over the target or sample
it. While a pick is open the island stays shut and still.

## 6. Nothing else

- **Universal Search:** it has no command registry (it searches Spaces,
  meetings, Flow, clipboard and Tray content), so there is nothing to add.
- **Info.plist / entitlements / PermissionCenter:** nothing.
- **Hotkey:** ⌃⌥P by default, through `ScreenRegionHotkey` (Carbon
  `RegisterEventHotKey`, signature 'NIsr', its own id). ⌃⌥C, the research
  suggestion, is Quick Capture's, so it was not used. Checked against every
  SparkV shortcut: ⌃⌥C (Quick Capture), ⌃⌥J (join meeting), ⌃⌥R (Reply),
  ⌃⌥S (Ask Screen), ⌃⌥T (Copy Text), ⌃⌥⇧R (record), ⌃⌥1…5 (Modes),
  ⌥Space / ⌃⌥Space / ⌃⌥F (Search), ⌘⇧V (Clipboard stack), ⌃⌘V / ⌃⌘C
  (Dictation). Stored in `ColorPicker.shortcut`; the menus offer ⌃⌥P, ⌃⌥K,
  ⌃⌥E, ⌃⌥I and ⌃⌥⌘C, or off (`ColorPicker.hotkeyEnabled`). If macOS refuses
  the combination, the Shortcut submenu says so. **While a pick is open the
  shortcut stays registered even when it is off**, and is dropped again when
  the pick ends: a stuck loupe holds every click, so the shortcut is the one
  way out.
- **Band:** `LiveActivity` id `colorpicker`, kind `.notification`, priority 66
  (the same as Copy Text's band: above battery/AirPods 50 and meetings 60, so
  a shortcut pick is confirmed at once instead of waiting in the queue), 2 s,
  no compact form so it uses the band: `● #3B82F6  Copied · blue-500 · Blue`.
  The label never truncates; the value is capped at 230 pt. For the long
  formats (P3, SwiftUI, UIKit, AppKit) the band shows the hex and says
  "Copied as SwiftUI". Hovering it opens `.colorPicker`. Esc posts nothing. A
  wide-gamut pick adds "outside sRGB". After 20 s with the loupe open:
  `⚠ Picker still open  Stuck? Press ⌃⌥P to reset · Esc cancels` (6 s).
- **UserDefaults keys:** `ColorPicker.history` (last 30, JSON),
  `ColorPicker.palettes`, `ColorPicker.selectedPalette`,
  `ColorPicker.defaultFormat`, `ColorPicker.formatOptions`,
  `ColorPicker.contrast`, `ColorPicker.shortcut`, `ColorPicker.hotkeyEnabled`,
  `ColorPicker.section`, `ColorPicker.rememberApp`,
  `ColorPicker.needsActivationWorkaround` (the compatibility start). History stores colors, a
  date, the sampler's color-space name and (if on) the front app's name. It
  never stores screenshots or window titles.

## How a pick works (for review)

1. `pickColor()` (hotkey, tile, Pick button, menu). A second press while the
   loupe is open is ignored for 1 s, then posts "Picker still open · Esc
   cancels · press ⌃⌥P again to reset"; a third press resets.
2. `onWillPick` collapses the drawer, and Edit 5g keeps it from opening on
   hover until the pick ends.
3. **Default start (SparkV never becomes active).** `CPSystemSampler` orders in
   an invisible 1×1 titled **non-activating** panel (`orderFrontRegardless`,
   never key, no `NSApp.activate()`), and on the **next run-loop turn**
   (outside the SwiftUI action) calls `NSColorSampler().show`. Activating
   SparkV would change the pixels being sampled: the front app would switch
   its accent, selection, default-button, focus-ring and traffic-light colors
   to their grey inactive versions, a SparkV key/main window (Meeting Notes,
   Flow Canvas) could come forward over the target, and Stage Manager might
   switch stages.
   **Compatibility start (fallback).** For the macOS 27 report (Apple forums
   845184, FB24722293) where a sampler shown from SwiftUI inside a borderless
   window can leave ColorSampler.xpc holding every click, the reported
   workaround is a regular titled window with the app active. It is used only
   after the user had to reset a pick that started the default way (then
   `ColorPicker.needsActivationWorkaround` is set; the menu toggle turns it
   off again). It makes an invisible titled window key and main (so
   activation brings that window forward rather than another SparkV window),
   calls `NSApp.activate()`, waits for `didBecomeActiveNotification` (at most
   150 ms; on macOS 14+ activation is cooperative and asynchronous), shows the
   loupe on the next turn, and gives focus back to the previous app after the
   answer.
4. The answer (nil after Esc: nothing happens) is converted with
   `usingColorSpace(.extendedSRGB)`. Hex, rgb(), hsl() and WCAG clamp to sRGB
   (clamp before rounding, `round(v*255)`); P3/Swift/UIKit/AppKit outputs use
   Display P3 values when the color is outside sRGB. The first pick of a session
   logs the sampler's color space name to AppLog (to answer the research's
   "[verify]" about which space it returns).
5. Copy in the default format (one pasteboard item: the text plus an `NSColor`),
   band, history.
6. If no answer arrives within 20 s, `mayBeStuck` turns the tile into "Reset",
   replaces the page's Pick button with "Reset Picker", and posts the band
   "Picker still open · Stuck? Press ⌃⌥P to reset · Esc cancels"; one press of
   the shortcut then resets. Reset sends SIGTERM to the current user's
   ColorSampler process (found with libproc, no shell) and SIGKILL after
   0.5 s only to the same PIDs if they are still running. ColorSampler.xpc is
   one per user (ServiceType = User), so **Reset resets the system color loupe
   for all apps** (the system color panel's eyedropper too); it only runs when
   the user asks for it.
7. Undo (history strip, 8 s) puts back only what was removed (an entry, a
   cleared history, a palette, a palette color) into the lists as they are
   now, so picks and palette edits made since stay.

## Tests (outside the app)

The lab's tests live outside the repo (they are not compiled into the app):
- pure logic, 278 checks (formats for #3B82F6 match the research spec, P3 and
  OKLCH round trips, OKLCH of 4,000 random wide-gamut colors reads back
  within half a step in Display P3, precise HSL/HSB always read back, WCAG
  3.68:1 for #3B82F6 on white, APCA reference values, parser for every
  written format including the HSB row, a fuzz of extreme numbers in every
  function (nil or finite and JSON-encodable), CSS clamping, Tailwind and CSS
  names, history and palette rules, Undo merge, old saved options still
  decode, exports);
- the controller with a fake sampler, a private pasteboard and throwaway
  defaults suites, 129 checks (copy + NSColor on the pasteboard, Esc copies
  nothing, P3 conversion agrees with AppKit/ColorSync, re-entry guard, reset
  ignores a late answer, the compatibility flag, the watchdog band, Undo
  after newer picks and palette edits plus its expiry, malformed colors
  never reach the history and later saves still persist, the long-format
  band, the shortcut held during a pick while off, persistence of every
  key). It also runs the real `CPSystemSampler` with a stand-in loupe: the
  default start orders in a non-activating, never-key, invisible panel,
  doesn't activate the app and shows the loupe on the next turn; the
  compatibility start waits for activation and gives up after 150 ms; a
  reset before the loupe shows drops the session. `CPProcessReset` ends a
  stand-in process with SIGTERM and escalates to SIGKILL only for one that
  ignores SIGTERM;
- offscreen renders in both looks of every drawer section, empty states, a
  pick open, a pick that may be stuck, the widest shortcut, every format row
  (sRGB, wide gamut, and comma + precise HSL), the tile and the bands.

## Not done (next steps)

- The opt-in ScreenCaptureKit "precision loupe" (Engine B: live readout, pixel
  grid, Space to freeze, ⌘C inside the loupe) is not built; the system loupe
  is the only engine.
- Tailwind v4 (OKLCH) table, meodai/color-names, Smart Formats per app, custom
  format templates, aperture averaging, `sparkv://` URL scheme and .ase /
  .colorset export are not built.
- ⌘1…⌘9 format switching is not wired (the drawer panel is non-activating).
- Not run with a real loupe yet. On macOS 27 check: (1) the default start
  over a native app (pick a selected row, a default button, the window's
  accent: the colors must be the active ones) and whether the click-capture
  bug shows up; (2) if it does, that Reset recovers and the compatibility
  start then avoids it; (3) both starts over a full-screen app and with
  Stage Manager on; (4) that the drawer stays shut when the loupe crosses the
  notch (Edit 5g).
