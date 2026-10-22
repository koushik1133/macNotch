# Reply Drafter: wiring steps for the lead

Everything lives in `Sources/Labs/ReplyDrafter/`. No existing file was edited and nothing is wired yet. The steps below connect it to the app. The folder reuses `ScreenRegionHotkey`, `ScreenRegionShortcut` and `ScreenRegionCapture` from `Labs/ScreenRegion`, `SpaceStore` from `Labs/Spaces`, and `TextInserter`, `TrayAIOCR`, `MeetingAIBackend`, `ClickyKeychain`, `ActivityCenter`, `ViewFlag`, `NotchHostingView` and `PushToTalkMonitor.syntheticEventTag` from `Sources/`.

## 1. build.sh

Add this next to the other `Labs` copies (after the `BrowserRecorder` line):

```zsh
cp Sources/Labs/ReplyDrafter/*.swift "$WORK/src/"
```

It needs no new frameworks, resources or linker flags. FoundationModels is used only through `MeetingAIBackend`, which already guards it with `#available(macOS 26)`.

## 2. Create, start and stop the controller (NotchWindowController.swift)

Add the property next to the other agents:

```swift
private let replyDrafter: ReplyDrafterController
```

Create it in `init`, after `screenDistance = ScreenDistanceController(activities: activities)` (it must be assigned before `super.init(window:)`):

```swift
replyDrafter = ReplyDrafterController(activities: activities)
```

Inject it into the root view by adding a line to the `.environmentObject(...)` chain (after `.environmentObject(screenDistance)`):

```swift
.environmentObject(replyDrafter)
```

Start it by adding `replyDrafter.start` to the existing start list (the line right after `clipboard.onOpenTab = …`). This also registers the ⌃⌥R hotkey through Carbon, so no extra install call is needed:

```swift
[uiAudit.start, jobAgent.start, screenRegion.start, promptRefiner.start, browserRecorder.start, clipboard.start, replyDrafter.start].forEach { $0() }
```

Stop it in `tearDown()` by adding `replyDrafter.stop` to the stop list:

```swift
[uiAudit.stop, jobAgent.stop, screenRegion.stop, promptRefiner.stop, browserRecorder.stop, clipboard.stop, replyDrafter.stop].forEach { $0() }
```

## 3. Agents hub tile and drawer page

`NotchState.swift`: add a tab case after `case screenDistance` and add it to `agentTabs`. Keep `.screenDistance` (and any tab another feature added meanwhile, e.g. `.fileDrop`, `.search`, `.downloads`); only append `.replyDrafter`:

```swift
case replyDrafter
// …
static let agentTabs: Set<Tab> = [.agents, .uiAudit, .jobs, .screen, .promptRefiner, .browser, .clipboard, .screenDistance, .replyDrafter]
```

The default drawer height (`NotchMetrics.expandedSize`, 540×115) fits the page, so `NotchMetrics.expandedSize(for:)` needs no change.

`AgentsHubView.swift`: add a tile to `agents`, after the Distance (`.screenDistance`) tile:

```swift
Agent(tab: .replyDrafter, title: "Reply", systemImage: "arrowshape.turn.up.left.fill", tint: .cyan),
```

`NotchNookLayoutView.swift`: add the drawer page to the `switch state.tab`, after `case .screenDistance: ScreenDistanceDrawerView()` (the switch must stay exhaustive, or the build fails):

```swift
case .replyDrafter: ReplyDrafterDrawerView()
```

The page fills the standard 540×115 pt drawer. It has a **Draft Reply ⌃⌥R** button, a tone menu, a settings gear, and quick toggles for "Write into box", "Fill subject", "Use Spaces", "Read screen" and "Groq". It reads `ReplyDrafterController` from the environment.

If the hub tile should draft a reply directly instead of opening the page, use this action for that one tile: `replyDrafter.draftReply()`.

## 4. Header button (optional)

`ReplyDrafterNotchButton()` is a 24×22 pt icon (same size and gray-to-white hover style as `IconTab`, SF Symbol `arrowshape.turn.up.left.fill`) that calls `draftReply()`. It needs the environment object from step 2 and is not a tab.

**Width budget:** on the 16-inch MacBook Pro each side of the camera housing has about 160 pt, and `HeaderRow`'s left group already uses 5 × 24 pt + 4 × 5 pt = 140 pt (the right group is as full, and grows while recording). One more icon (29 pt with spacing) would slide under the camera housing. So either skip the header icon (the hotkey, the Agents tile and the gear-menu item already cover it), or free a slot first (for example move `RecordMeetingButton` out of the right group) and add it there:

```swift
// HeaderRow, right group, after RecordMeetingButton():
ReplyDrafterNotchButton()
```

Check the header at rest and while recording ("● 59:59") before shipping it.

## 5. Settings (gear menu)

In `SettingsMenu` (`NotchNookLayoutView.swift`), declare:

```swift
@EnvironmentObject private var replyDrafter: ReplyDrafterController
```

Then, inside `Menu("Agents") { … }`, add the menu items. The toggles bind to `ReplyDrafterSettings`, which is an `ObservableObject`. Use a small wrapper view so SwiftUI observes it:

```swift
Button("Draft Reply…  \(replyDrafter.shortcutLabel)") { replyDrafter.draftReply() }
ReplyDrafterMenuToggles(settings: replyDrafter.settings)
```

Add this wrapper struct at file scope in `NotchNookLayoutView.swift`:

```swift
private struct ReplyDrafterMenuToggles: View {
    @ObservedObject var settings: ReplyDrafterSettings
    var body: some View {
        Menu("Reply Drafter") {
            Toggle("Write Reply into the Message Box", isOn: $settings.autoInsert)
            Toggle("Fill an Empty Email Subject", isOn: $settings.fillSubject)
            Toggle("Use Spaces as Context", isOn: $settings.useSpaces)
            Toggle("Read the Window When Text Is Hidden", isOn: $settings.readScreen)
            Toggle("Shortcut \(settings.shortcut.displayString)", isOn: $settings.hotkeyEnabled)
            Toggle("Allow Reply Drafter to Use My Groq Key", isOn: $settings.allowGroq)
            Button("Tone & Name…") { ReplyDrafterSettingsWindow.shared.show(settings: settings) }
        }
    }
}
```

These settings are stored in `UserDefaults`:

| Key | Default |
|---|---|
| `ReplyDrafterAllowsGroq` | **false** |
| `ReplyDrafterAutoInsert` | true |
| `ReplyDrafterFillSubject` | true |
| `ReplyDrafterUseSpaces` | true |
| `ReplyDrafterReadScreen` | true |
| `ReplyDrafterHotkeyEnabled` | true |
| `ReplyDrafterTone`, `ReplyDrafterUserName`, `ReplyDrafterSignOff` | empty |
| `ReplyDrafterShortcut` | JSON `ScreenRegionShortcut`, default ⌃⌥R |

While `ReplyDrafterAllowsGroq` is off, the keychain is never read: `ClickyKeychain.hasKey()` and `load()` are not called.

## 6. Hotkey

The default hotkey is **⌃⌥R** (Control+Option+R). It is registered with `ScreenRegionHotkey`, the Carbon `RegisterEventHotKey` approach, so it needs no extra permission and the keystroke is consumed. It does not collide with ⌃⌥S (Ask Screen), ⌃⌥C (Quick Capture), ⌃⌥Space or ⌃⌥F (Universal Search). If another app owns ⌃⌥R, the log says so and the tile and button still work. Turn the hotkey off with `settings.hotkeyEnabled = false`. Change it with `settings.shortcut = ScreenRegionShortcut(...)`, which re-registers automatically.

## 7. Permissions, Info.plist and entitlements

- **Accessibility** (already used by dictation and TextInserter) is required to read the conversation and write the reply. Without it, the bar shows "Open Accessibility Settings", which only opens the Settings pane.
- **Screen Recording** is optional and only used for the fallback. It is checked with `CGPreflightScreenCaptureAccess()` and never prompts on its own. The bar's "Allow Screen Recording" button calls `ScreenRegionCapture.requestPermission()`, and only on that click.
- No new Info.plist keys. No new entitlements: the app is not sandboxed, and AX and CGEvent posting already work for TextInserter.

## 8. Behavior notes for QA

- Only ⌘A, ⌘↑, ⌘Z, ⇧⌘Z, Delete and the TextInserter ⌘V paste are ever posted. `ReplyKeys.post` only posts keys on its allowlist (A, Z, ↑, Delete); Return and Enter are not on it and are refused. Nothing clicks buttons in the other app.
- When Close is clicked, the text stays in the field as it is. Undo in the bar restores exactly what was there before. The signature and the quoted thread are never touched, including Apple Mail's and Outlook's, where the quoted message and an unmarked signature sit inside the message box (the range stops at "On … wrote:", "From:/Sent:", "-----Original Message-----", "> " lines and a trailing block that starts with your name).
- For Chromium and Electron apps (Slack, Discord, Teams, Chrome, Arc, Edge, Brave), the controller sets `AXManualAccessibility = true` on the app the first time. Electron documents this for assistive apps, and it is what makes their message text readable. It stays on until that app quits.
