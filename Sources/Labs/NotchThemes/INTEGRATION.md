# Notch Themes: integration

Twelve hover themes for the island, picked in Settings. **Plain** (the black
island as it is today) stays the default, and with Plain selected nothing below
changes the window, the hot zones or the timing.

Files in this folder:

| File | What it holds |
| --- | --- |
| `NotchThemeCore.swift` | Contract: `NotchThemeID`, `NotchThemePhase`, `NotchThemeContext`, `NotchThemeSettings.shared` (UserDefaults `NotchTheme`, default `.plain`), `NotchThemeMetrics.maxOutset` (28 pt). |
| `NotchThemesGlass.swift`, `NotchThemesGlow.swift`, `NotchThemesMotion.swift` | The twelve `<Theme>NotchLayer(context:)` views. |
| `NotchThemeViews.swift` | `NotchThemeLayer` (switch), `NotchThemeBackdrop` (what the notch view uses), `NotchThemeHoverState`, `NotchThemeLayout`, `NotchThemeTiming`, `NotchThemePickerView`, `NotchThemeSettingsWindowController`, `NotchThemeMenuItems` / `NotchThemeMenu`, `NotchThemeAppearanceTile`. |

Layer geometry: a layer's frame is the island's drawable rect (body + flare on
both sides, the rect `IslandShape` is drawn in) grown by `maxOutset` on every
side, centered on the island. `NotchThemeBackdrop` sets this up and offsets the
layer up by `maxOutset`, so the top margin lies above the screen edge and the
window clips it.

## 1. build.sh

Add next to the other Labs lines:

```zsh
cp Sources/Labs/NotchThemes/*.swift "$WORK/src/"
```

## 2. NotchNookLayoutView.swift

In `body`, put the backdrop behind the island, **after** `.clipShape(shape)`
(so it isn't clipped) and **before** `.offset(x:)` (so it moves with uneven
wings):

```swift
        .frame(width: size.width + 2 * radii.top, height: size.height)
        .clipShape(shape)
        // Hover theme, behind and around the black body. Plain draws nothing.
        .background(alignment: .top) {
            NotchThemeBackdrop(
                isExpanded: state.isExpanded,
                bodySize: size,
                topRadius: radii.top,
                bottomRadius: radii.bottom
            )
        }
        // Uneven wings shift the body so the housing stays over the camera.
        .offset(x: closed?.xOffset ?? 0)
```

`NotchThemeBackdrop` builds the `NotchThemeContext` itself: phase from
`isExpanded` and `NotchThemeHoverState.shared.isHovered`, radii as passed,
pointer from the hover state, and Reduce Motion / Reduce Transparency from the
environment. It observes the hover state on its own, so pointer moves redraw
only the theme layer, not the island. The size and radii animate with the
island's existing spring because they come from the same transaction. The
hover flag can be set without `withAnimation`: each layer eases its own
hover change in (the geometry ones with `NotchThemeTiming.islandSpring`, the
same spring as `NotchMetrics.hoverAnimation`).

## 3. NotchWindowController.swift

### 3a. New properties

```swift
    /// Hover look and pointer for the notch theme layer.
    private let themeHover = NotchThemeHoverState.shared
    /// Pointer on the closed island, waiting out the theme's hover dwell.
    private var hoverDwellTask: Task<Void, Never>?
    /// "Preview on my notch" from the theme picker.
    private var themePreviewTask: Task<Void, Never>?
    private var themeObserver: AnyCancellable?
    /// Glow margin the panel was laid out with (0 for Plain).
    private var appliedThemeOutset: CGFloat = 0
```

### 3b. init: re-layout when the theme changes, handle the preview

After the `tabObserver = …` line:

```swift
        // A theme other than Plain needs a glow margin around the panel.
        themeObserver = NotchThemeSettings.shared.$theme.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.themeHover.isHovered = false
                self.themeHover.setPointer(nil)
                self.positionOverNotch()
            }
        }
```

In `observeSystemEvents()`:

```swift
        observe(.notchThemePreviewRequested, on: .default) { $0.previewTheme() }
```

### 3c. positionOverNotch: grow the panel (left, right, bottom only)

Replace the panel-frame block at the end:

```swift
        // Sized to the current tab so a shorter drawer never leaves a
        // transparent strip below it that swallows clicks. A notch theme adds
        // a glow margin on the left, right and bottom (0 for Plain); the top
        // stays at the screen edge, so the island does not move.
        let outset = NotchThemeLayout.outset(for: NotchThemeSettings.shared.theme)
        appliedThemeOutset = outset
        let expanded = NotchMetrics.panelSize(for: state.tab)
        let panelFrame = NSRect(
            x: screenFrame.midX - expanded.width / 2 - outset,
            y: screenFrame.maxY - expanded.height - outset,
            width: expanded.width + 2 * outset,
            height: expanded.height + outset
        )
        panel.setFrame(panelFrame, display: true)
        if state.isExpanded { updateClickThrough() }
```

The island stays where it is: `NotchNookLayoutView` pins it top-center with
`.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)`.

### 3d. resizeForTab: compare against the grown height

```swift
        let target = NotchMetrics.panelSize(for: state.tab).height + appliedThemeOutset
```

### 3e. The interactive frame (the old panel frame) and click-through

Add:

```swift
    /// The panel minus the theme's glow margin: exactly the panel frame
    /// before themes existed. Hot zones and clicks use this.
    private var interactiveFrame: NSRect {
        guard let frame = window?.frame else { return .zero }
        let o = appliedThemeOutset
        return NSRect(x: frame.minX + o, y: frame.minY + o, width: frame.width - 2 * o, height: frame.height - o)
    }

    /// While the drawer is open, clicks in the glow margin fall through to
    /// whatever is below, as they did before the panel grew. With no margin
    /// (Plain, or a switch to Plain while the drawer is open) the open panel
    /// always takes clicks, exactly as before themes.
    private func updateClickThrough() {
        guard state.isExpanded else { return }
        let inside = appliedThemeOutset == 0
            || interactiveFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
        if window?.ignoresMouseEvents == inside { window?.ignoresMouseEvents = !inside }
    }
```

In `isPointerInHotZone()`, use the interactive frame instead of the window
frame:

```swift
        let hotZone = state.isExpanded ? interactiveFrame : collapsedHotZone
```

The collapsed hot zone is unchanged. (With Plain, `interactiveFrame` equals
`window.frame`, and `updateClickThrough` only keeps the open panel taking
clicks, which `setExpanded` already does.)

### 3f. handlePointer: the .hovered phase and the pointer

The `.hovered` phase is the pointer on the closed island before the drawer
opens. Plain opens at once as today (`hoverDwell` is `.zero`); the other themes
wait 350 ms (the demos' timing) with the hover look on. Replace the
`if isPointerInHotZone() { … } else if state.isExpanded, collapseTask == nil {`
head of `handlePointer()` so it reads:

```swift
        if isPointerInHotZone() {
            collapseTask?.cancel()
            collapseTask = nil
            if !state.isExpanded {
                let dwell = NotchThemeTiming.hoverDwell(for: NotchThemeSettings.shared.theme)
                if dwell == .zero {
                    openFromHover()
                } else if hoverDwellTask == nil {
                    themeHover.isHovered = true
                    hoverDwellTask = Task { [weak self] in
                        try? await Task.sleep(for: dwell)
                        guard !Task.isCancelled, let self else { return }
                        self.hoverDwellTask = nil
                        guard !self.state.isExpanded, self.isPointerInHotZone(), !FaceUnlock.isUsingNotch else {
                            self.themeHover.isHovered = false
                            return
                        }
                        self.openFromHover()
                    }
                }
            }
        } else {
            endThemeHover()
            if state.isExpanded, collapseTask == nil {
                collapseTask = Task { [weak self] in
                    // … the existing collapse task body, unchanged …
                }
            }
        }
        updateClickThrough()
        updateThemePointer()
```

(Keep the existing early returns at the top of `handlePointer()`. In the
`FaceUnlock.isUsingNotch` branch also call `endThemeHover()`.)

Add the helpers:

```swift
    /// What entering the hot zone did before themes: open on the activity's tab.
    private func openFromHover() {
        if let tab = hoverTab {
            state.select(tab)
        }
        setExpanded(true)
    }

    private func endThemeHover() {
        hoverDwellTask?.cancel()
        hoverDwellTask = nil
        if themeHover.isHovered, themePreviewTask == nil { themeHover.isHovered = false }
    }

    /// Pointer for Dewdrop and Magnetic Ripple, relative to the island's top
    /// center; nil when it is more than `maxOutset` away from the island.
    private func updateThemePointer() {
        guard NotchThemeSettings.shared.theme.usesPointer else {
            themeHover.setPointer(nil)
            return
        }
        let zone = state.isExpanded ? interactiveFrame : collapsedHotZone
        let mouse = NSEvent.mouseLocation
        let reach = NotchThemeMetrics.maxOutset
        guard zone.insetBy(dx: -reach, dy: -reach).contains(mouse) else {
            themeHover.setPointer(nil)
            return
        }
        themeHover.setPointer(CGPoint(x: mouse.x - zone.midX, y: zone.maxY - mouse.y))
    }

    /// "Preview on my notch": the hovered look for a moment, without opening.
    private func previewTheme() {
        guard !state.isExpanded, NotchThemeSettings.shared.theme != .plain else { return }
        themePreviewTask?.cancel()
        themeHover.isHovered = true
        themePreviewTask = Task { [weak self] in
            try? await Task.sleep(for: NotchThemeTiming.previewDuration)
            guard !Task.isCancelled, let self else { return }
            self.themePreviewTask = nil
            if self.hoverDwellTask == nil, !self.state.isExpanded { self.themeHover.isHovered = false }
        }
    }
```

`zone.midX` is the island's center including uneven wings (the collapsed hot
zone is built from `notchRect.midX + layout.xOffset`), and `zone.maxY` is the
screen top, so the offset matches `NotchThemeLayout.layerPoint(fromIslandTopCenter:)`.
`setPointer` rounds to half a point and only publishes changes; for themes
that don't use the pointer it stays nil, so nothing redraws on mouse moves.

### 3g. setExpanded

Keep `window?.ignoresMouseEvents = !expanded` and add, after the
`withAnimation` block:

```swift
        if !expanded {
            themeHover.isHovered = false
            hoverDwellTask?.cancel()
            hoverDwellTask = nil
        } else {
            updateClickThrough()
        }
```

### 3h. tearDown

```swift
        hoverDwellTask?.cancel()
        themePreviewTask?.cancel()
```

## 4. Gear menu (NotchNookLayoutView.swift, `SettingsMenu`)

After `Menu("Modes") { ModesMenuItems() }`:

```swift
            Menu("Notch Theme") { NotchThemeMenuItems() }
```

(or `NotchThemeMenu()`, which is the same submenu). It lists the themes in
Basic / Glass / Glow / Motion sections with a checkmark on the current one
("Plain (Default)" first), then **Choose Theme…**, which opens the picker
window (`NotchThemeSettingsWindowController.shared.show()`, titled
"Notch Theme — SparkV"). Choosing applies immediately.

## 5. Optional: an Appearance tile

`NotchThemeAppearanceTile()` is a small button (mini island, "Notch Theme",
current theme name) that opens the picker. It can sit in the Agents hub or any
settings list. Nothing requires it.

## Check

- Plain: panel frame, hot zones, open timing and click-through are exactly as
  before (outset 0, dwell 0, `updateClickThrough` never makes the panel
  click-through).
- Another theme: the island doesn't move; glows show up to 28 pt to the sides
  and below; clicks in that margin reach the menu bar and apps; hovering shows
  the look for 350 ms, then the drawer opens; leaving before then turns it off.
- Switching themes in the menu or the picker re-lays the panel right away.
