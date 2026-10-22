# Quick Capture to Spaces + Screenshot to Clipboard

## What it does

**Quick capture (⌃⌥C, configurable).** One press saves the current context into the
right Space:

1. Text selected in the front app, read through Accessibility. Never a synthetic ⌘C,
   never the pasteboard. Password fields and SparkV itself are skipped. In a browser,
   the tab URL is added as the source, but only when Automation is already allowed
   (no prompt for a selection).
2. Otherwise, if the front app is Safari, Chrome, Arc, Edge or Brave, the current page:
   the same tab script, private-window rule and `TrayAIWeb.fetch` that Spaces uses.
3. Otherwise, an interactive screenshot: `/usr/sbin/screencapture -i -o` writes to
   SparkV's temp folder, never the user's screenshot folder. The tool starts only
   after the hotkey's ⌃⌥ are released (up to 1.5 s): in interactive mode Control held
   at mouse-up sends the shot to the clipboard instead of the file, and Option resizes
   the selection from its centre. On-device Vision OCR runs
   through `SpaceConnectors.imageInput`, the store copies the image, and the temp file
   is deleted.

The item goes through `SpaceStore.ingest`, so the Space agents route it. If they leave
it in the Inbox, quick capture applies the store's own filing suggestion
(`store.accept`). If there is no suggestion and the user chose "File to Last-Used
Space", it goes to the last-used Space. The band says "Saved to <Space> · selection".
A strip under the band offers **Change Space ▾** (`store.move`, so the agents learn
from it), **Open** (Spaces window on that Space) and **Undo**. Undo deletes a new
item, or moves an existing item back to where it was.

**Screenshot to clipboard (default off).** This watches the `com.apple.screencapture`
location, read with `SpaceConnectors.ScreenshotLocation.current()`, the same way
Spaces reads it. Each new screenshot goes on the clipboard: the PNG bytes right away,
plus TIFF supplied lazily for older apps. The file is kept. A band says "Copied
screenshot". The system screenshot settings are only read, never written. Only
files created in the last 2 minutes count, so an old "Screenshot …" file moved or
copied into the folder (Finder keeps its creation date) never replaces the clipboard.

Consent follows the Spaces rules. The Desktop, Documents, Downloads, iCloud Drive and
/Volumes are privacy-protected, so they are watched only after the user's go-ahead.
Turning the toggle on by hand counts as that go-ahead. If the folder later moves to a
protected place without consent, a "Watch <folder> for Screenshots" button appears.
Nothing prompts at launch.

## Approaches copied from shipping products

| Piece | Modelled on | Why |
|---|---|---|
| File first, then offer Undo / Change | Gmail "Undo Send", CleanShot X quick-access overlay, Mem's "capture now, organize later" | One keystroke and no picker. Fixing a wrong guess costs one click. |
| Fallback to the last destination | Notion Web Clipper keeps the last workspace or destination | Predictable when the agents aren't sure. Off by default (Inbox). |
| Selection → page → screenshot order | Raycast / PopClip-style "act on what's selected" | The most specific context wins. |
| Selection read: `AXSelectedText`, then `AXSelectedTextRange` + `AXStringForRange`, then the app's focused element, with `AXManualAccessibility` for Chromium/Electron and a short retry | Electron's accessibility docs, and the fallback order used by the selected-text crates and Tauri write-ups | Works in native, Chromium and Electron apps. The ⌘C fallback those tools use is deliberately dropped because it would change the user's clipboard. |
| Global hotkey through Carbon `RegisterEventHotKey` | sindresorhus/KeyboardShortcuts (MIT). The approach was already in `ScreenRegionHotkey`, which is reused here. | No Accessibility prompt, and the keystroke is consumed. |
| Interactive capture through `screencapture -i` | macOS ⌘⇧4 | Familiar crosshair, Space for a window, Esc to cancel. |
| Copy and keep the file | CleanShot X "copy and save" after-capture action | The image can be pasted right away and the file stays. |

No third-party code is vendored. Everything reuses SparkV building blocks:
`ScreenRegionHotkey`/`ScreenRegionShortcut`, `SpaceStore`, `SpaceConnectors`
(Browser, `imageInput`, `webInput`, `ScreenshotLocation`), `SpaceAppleEvents`,
`SpaceDirectoryWatcher`, `SpaceIngestCenter.waitUntilStable` and `color(hex:)`,
`SpaceFiledActivityView`, `TrayAIOCR`, `TrayAIWeb`, `ScreenRegionCapture.requestPermission`,
`NotchHostingView`, `ViewFlag`, `ActivityCenter`.

## Files

- `QuickCaptureModels.swift` holds the kinds, the planner (pure: what to capture, the
  selection input, fallback Space) and persisted settings.
- `QuickCaptureSelection.swift` is the Accessibility selection reader. It has a
  test seam and never logs text.
- `QuickCaptureScreenshot.swift` runs the interactive capture to a temp file, with
  seams for the tool and the permission check.
- `QuickCaptureController.swift` handles the hotkey, the capture pipeline, filing,
  Undo, Change Space and the band. It also prewarms Vision in the background 45 s
  after launch.
- `QuickCaptureToast.swift` is the non-activating action strip under the band and
  the Change Space NSMenu.
- `ScreenshotClipboard.swift` holds the screenshot watcher, the pasteboard writer
  and the "Copied screenshot" band.
- `QuickCaptureSettingsView.swift` holds the gear-menu items, the settings view, the
  shortcut recorder and the settings window.

## Privacy

- Selected text, page text and OCR text are never logged. Logs show only the kind,
  the character count and the domain.
- No network calls except the page download (same as Spaces' "Save Current Web Page").
  No Groq is used.
- Nothing is typed into other apps. The only pasteboard write is the opt-in
  screenshot copy.
- Private and incognito windows are refused.

## Known limits

- The band itself can't be clicked while the notch is collapsed (the panel ignores
  the mouse), which is why the actions live in their own strip below it.
- The macOS floating screenshot thumbnail delays the file by about 5 s, so the
  clipboard copy arrives when the file lands. Click the thumbnail away, or turn it off
  in the Screenshot app, for an instant copy.
- Selections in apps that expose no Accessibility text (some games, Java apps,
  canvases such as Google Docs) aren't readable. Those captures fall through to the
  page or the screenshot.
- Loading Vision's accurate text recognizer cold took 40–290 s on this Mac while
  other builds were running, and 0.2–0.5 s once warm. The background prewarm, the
  "Reading screenshot…" band and one OCR retry cover this.
