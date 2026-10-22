# Universal Search: wiring for the lead

Everything lives in `Sources/Labs/UniversalSearch/`. No existing file was
edited. These steps add it to the app. No Info.plist keys or entitlements are
needed: the hotkey is Carbon `RegisterEventHotKey`, which needs no
Accessibility, and the mic goes through the existing `DictationController`.

## 1. build.sh

Add this next to the other `cp Sources/Labs/...` lines:

```zsh
cp Sources/Labs/UniversalSearch/*.swift "$WORK/src/"
```

The validate `tc.sh` also needs `UniversalSearch` in its `Sources/Labs/{...}`
list.

## 2. NotchState.swift: an Agents-hub tab

```swift
enum Tab: Hashable {
    // … existing cases …
    case clipboard
    case screenDistance
    /// Universal search (Agents hub tile).
    case search

    /// Tabs opened from the Agents hub rather than the header.
    static let agentTabs: Set<Tab> = [.agents, .uiAudit, .jobs, .screen, .promptRefiner, .browser, .clipboard, .screenDistance, .search]
}
```

(Keep any tabs other features add to `agentTabs`; only `.search` is new here.)

Drawer height: the drawer view sizes itself to the space it gets. In the
default 115 pt drawer on a 16-inch MacBook Pro (32 pt notch inset, so a
508×75 pt content area) it shows the search row and two results. For four
results, optionally add `.search` to the taller tabs in `NotchMetrics`:

```swift
static func expandedSize(for tab: NotchState.Tab) -> CGSize {
    CGSize(width: expandedSize.width, height: [.tray, .converter, .clipboard, .search].contains(tab) ? trayExpandedHeight : expandedSize.height)
}
```

In `isDropTargeted.didSet`, a drag over `.search` should flip to the Tray like
other tabs do, so leave that guard as it is.

## 3. NotchWindowController.swift

Add a property:

```swift
private let universalSearch: UniversalSearchController
```

In `init`, after `clipboard = ClipboardController(activities: activities)` (and
before `super.init(window: panel)`; `flow`, `tray`, `dictation` and
`meetingAssistant` are already set by then):

```swift
universalSearch = UniversalSearchController.live(
    flow: flow,
    meetings: meetingAssistant,
    clipboard: clipboard,
    tray: tray,
    spaces: SpaceStore.shared,
    dictation: dictation
)
```

`self` isn't available before `super.init`, so set the Flow opener after
`super.init(window: panel)`. Put this next to the other `… = { [weak self] … }` hooks:

```swift
universalSearch.openFlowHandler = { [weak self] target in
    // FlowView reads its section from this default when it is created.
    if case .flowNote = target { UserDefaults.standard.set("notes", forKey: "flow.section") }
    else { UserDefaults.standard.set("history", forKey: "flow.section") }
    self?.state.select(.flow)
    self?.setExpanded(true)
}
```

(Same pattern as `clipboard.onOpenTab`. If the Flow tab is already on screen,
its section doesn't change, because FlowView only reads the default when it's
created.)

(`openFlowHandler` is a settable property on the controller. Flow results
call it when they're opened.)

Add it to the SwiftUI environment with the other `.environmentObject(…)` calls:

```swift
.environmentObject(universalSearch)
```

Start it after the other Labs controllers (the line after
`[uiAudit.start, … clipboard.start].forEach { $0() }`):

```swift
universalSearch.start()
```

Stop it in `tearDown()`, after the Labs stop list:

```swift
universalSearch.stop()
```

`start()` registers the global shortcut (default ⌥Space) and indexes once.
`stop()` unregisters it.

## 4. NotchNookLayoutView.swift: drawer content

Add this case to the tab `switch` (around the `case .clipboard: ClipboardTabView()` line):

```swift
case .search: UniversalSearchDrawerView(controller: universalSearch)
```

Add the environment object to that view:

```swift
@EnvironmentObject private var universalSearch: UniversalSearchController
```

## 5. AgentsHubView.swift: hub tile

Put this first in `agents`, since it's the entry point:

```swift
Agent(tab: .search, title: "Search", systemImage: "magnifyingglass", tint: .indigo),
```

(`.mint` is already used by the Distance tile.)

## 6. Settings (gear) menu

In `SettingsMenu` (NotchNookLayoutView.swift), add the environment object:

```swift
@EnvironmentObject private var universalSearch: UniversalSearchController
```

Then add the submenu, for example right after `Menu("Spaces") { … }`:

```swift
UniversalSearchSettingsMenu(controller: universalSearch)
```

The submenu contains:
- Open Search…
- Global Shortcut on/off
- a shortcut picker (⌥Space, ⌃⌥Space, ⌥⇧Space, ⌘⇧Space, ⌃⌥F)
- Record Shortcut…
- per-source toggles (Spaces, Meetings, Flow, Clipboard, Tray)
- Allow Ask to Use My Groq Key (off by default)
- Clear Search History

## 7. Optional extras

- Header button: `Button { universalSearch.openPanel() } label: { Image(systemName: "magnifyingglass") }`
- Macro/built-in action: `universalSearch.togglePanel()`
- SHORTCUTS.md: add "⌥Space: Universal Search (configurable in Settings > Search)"

## Behaviour summary (for QA)

| Key | Action |
|---|---|
| ⌥Space (configurable) | Toggle the panel from anywhere. No Accessibility needed. |
| typing | Instant results grouped by source (Top Hit, then Spaces, Meetings, Flow, Clipboard, Tray), fuzzy ranked |
| ↑ ↓ / ⌃P ⌃N | Move the selection |
| ⌘↑ ⌘↓ | Jump between sections |
| ↩ | Open in place. Spaces item: Spaces window. Meeting: notes window. Flow: Flow tab. Clipboard: copies it back. Tray file: reveal in Finder. Tray text: copy. |
| ⌘↩ | Alternate action. Clipboard: paste into the front app. Tray file: open. Web page in Spaces: open the link. |
| ⌘C | Copy the item. Meetings copy their notes as Markdown. |
| ⌘1…⌘5 / ⌘0 | Show only one source / all sources |
| ⌘D | Cycle the date filter (also a chip). `in:meet`, `in:clip`, `date:week` work in the box. |
| ⇥ (or ⌘/) | Ask mode: on-device answer with [n] citations. Click a citation or a source row to open it. |
| mic | Dictate the query. A dictated question goes straight to Ask (from the drawer, Ask opens in the panel). |
| Drawer | Same box in the Agents hub: ↑↓ ↩ work, ⇥ or ↩ with no match asks in the panel, ⌘V/⌘X/⌘A/⌘Z edit, ⌘C copies the selected text or result, esc clears. |
| esc | Leave Ask, then clear the box, then close |
