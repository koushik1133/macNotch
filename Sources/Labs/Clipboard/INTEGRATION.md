# Clipboard stack: integration

The stack works on its own. `ClipboardController.start()` (which
`NotchWindowController` already calls) installs the global shortcuts, and
`stop()` removes them. **No other file has to change.** The steps below are
optional extras.

## What ships in Sources/Labs/Clipboard

| File | What it holds |
|---|---|
| `ClipboardHotkeys.swift` | `ClipboardChordMachine`, a pure state machine for ⌘+N+V and ⌘⇧V, and `ClipboardHotkeys`, an active `CGEventTap` on its own thread. Same pattern as `PushToTalkMonitor`. Needs Accessibility. |
| `ClipboardStackModel.swift` | Keyboard model of the panel, placement math (`ClipboardStackPlacement`), and the AX caret lookup (`ClipboardCaretLocator`). |
| `ClipboardStackPanel.swift` | The non-activating panel, its controller and its SwiftUI views (rows, preview). |
| `ClipboardContentDetector.swift` | Pure smart-type detector: link, email, phone, colour, path, code. Also colour conversions and the action list. |
| `ClipboardSmartViews.swift` | Swatch, type badge, action chips, and the NSMenu entries for actions. |

Changes to existing files in this folder:

- **Controller:** stack API, settings, smart content cache.
- **Paster:** gained a `target:` and `keepCommand:` path.
- **Tab cards:** stack numbers, swatch cards, monospaced code, a hover action button, and actions in the context menu.
- **C menu:** a "Latest copy" actions section, "Open Clipboard Stack", stack-numbered ⌘1…9 entries, and two settings toggles.
- **Tab header:** a stack button.

## Shortcuts

| Keys | Action |
|---|---|
| ⌘ held, 1–9, then V | Paste history item N (1 = newest). |
| ⌘⇧V | Open or close the stack panel at the text caret, or at the pointer when there is no caret. |

How the chord works:

- When you press ⌘ plus a digit, the keystroke is held for up to 400 ms.
- If V follows while ⌘ is still down, both keys are swallowed and the item is pasted.
- Anything else replays the held ⌘+digit in its original order: another key, ⌘ released, a second modifier, or the timeout. So ⌘1–9 tab switching keeps working.
- ⌘+N is only held while history is on **and** has at least N items. With history off, the tap passes every key straight through.
- Holding V a little too long after the chord (or after ⌘⇧V) never autorepeats into extra pastes, and never closes the panel ⌘⇧V just opened. Autorepeats of a key the app already received always pass, so no key is left stuck down.
- Without Accessibility (or with a stale grant after an ad hoc rebuild), the tap can't start. The C menu then shows **Allow Accessibility for ⌘+Number+V…** under "Open Clipboard Stack", and the tap starts on its own a few seconds after the grant.

The panel's own keys:

| Keys | Action |
|---|---|
| ↑ / ↓ / scroll wheel | Move the selection |
| ↩ | Paste |
| ⇧↩ | Paste as plain text |
| ⌘↩ or ⌘C | Copy only |
| ⌘1–9 | Paste that row |
| Space or → | Preview |
| ⌫ | Delete (a pinned item needs a second press) |
| P, ⌘P or ⌥P | Pin |
| ⌘O | Run the first smart action |
| Typing or / | Filter |
| Esc | Clear the search, then close |

## Settings

Both settings are `UserDefaults` booleans and default to **on**.

| Key | Setter | Menu item (C menu › Clipboard Settings) |
|---|---|---|
| `Clipboard.stackChordEnabled` | `setStackChordEnabled(_:)` | "⌘ + Number + V Pastes From History" |
| `Clipboard.stackPanelShortcutEnabled` | `setStackPanelShortcutEnabled(_:)` | "⌘⇧V Opens the Clipboard Stack" |

When both are off, the tap is uninstalled.

Optional: a central Settings / Shortcuts screen can bind these two toggles:

```swift
Toggle("⌘ + number + V pastes from clipboard history", isOn: Binding(
    get: { clipboard.stackChordEnabled }, set: { clipboard.setStackChordEnabled($0) }))
Toggle("⌘⇧V opens the clipboard stack", isOn: Binding(
    get: { clipboard.stackPanelShortcutEnabled }, set: { clipboard.setStackPanelShortcutEnabled($0) }))
```

## Optional wiring for other owners

- **SHORTCUTS.md:** add ⌘+1…9+V and ⌘⇧V under Clipboard. Note that ⌘⇧V replaces "Paste and Match Style" while history is on, and that it can be turned off.
- **AgentsHubView or another launcher:** call `clipboard.showStackPanel()` to open the stack at the caret.
- **Onboarding / permissions:** the shortcuts need Accessibility, the same grant dictation and paste use. Without it, `ClipboardHotkeys` retries every 3 s, which costs one `AXIsProcessTrusted()` call, and starts by itself once the user grants it. No restart is needed.
- **UniversalSearch:** it can reuse `ClipboardContentDetector.detect(_:)` and `actions(for:)` to show "Open" / "Call" / swatches on clipboard results.

## Privacy

The stack is the same history. Concealed, transient and auto-generated
copies, and copies from excluded apps, are never stored, so they never get
a number.

- **Pastes:** ⌘+N+V writes the item to the pasteboard with the existing own-write marker, then posts ⌘V tagged with `PushToTalkMonitor.syntheticEventTag`. That is the same path as the menu's paste.
- **Copy as RGB/HSL:** the colour actions write plain text, so the copy joins the history as item 1.
- **Caret lookup:** the panel reads only the focused element's selected-range bounds over Accessibility. It never reads the element's text.
