# Flow Canvas: wiring steps for the lead

Flow Canvas lives entirely in `Sources/Labs/FlowCanvas/`. Nothing outside the folder was edited, and nothing is wired up yet. The six steps below connect it to the app.

## 1. build.sh: compile the folder

Add this line next to the other `Labs` copies (after the `Converter` line):

```zsh
cp Sources/Labs/FlowCanvas/*.swift "$WORK/src/"
```

The folder also contains `INTEGRATION.md`, but `*.swift` skips it. There are no resources, no extra frameworks and no new linker flags. Flow Canvas uses only the system frameworks the app already links: SwiftUI, AppKit, PDFKit, Vision (through `TrayAIOCR`), FoundationModels (guarded with `#available(macOS 26)` / `canImport`) and Translation (through `TrayAITranslator`).

## 2. Header icon in the notch

In `NotchNookLayoutView.swift`, add the button to the header icon row (around the `IconTab(...)` list, for example after the Spaces tab):

```swift
FlowCanvasNotchButton(help: "Flow Canvas: turn anything into a workflow")
```

The button is 26×22 pt, uses SF Symbol `point.3.connected.trianglepath.dotted` with the same gray/white hover style as `IconTab`, and calls `FlowCanvasWindowController.shared.show()`. It is not a tab, so no `NotchState.Tab` case is needed.

If you would rather add a menu entry (for example in the gear menu or `AgentsHubView`):

```swift
Button("Flow Canvas…") { FlowCanvasWindowController.shared.show() }
```

## 3. Hooks: Tray → canvas, canvas → Tray, Converter → canvas

In `NotchWindowController.swift`, next to the existing `converter.onAddToTray = …` (around line 84):

```swift
// Canvas "Send to Tray" → the Tray (Markdown file written in FlowCanvas/Exports).
FlowCanvasWindowController.shared.onSendToTray = { [tray] urls in urls.forEach(tray.addFile) }
```

To send Tray items to the canvas (from a Tray context-menu item or a button):

```swift
FlowCanvasWindowController.shared.show(adding: FlowCanvasInput.from(trayItems: tray.items))      // all items
FlowCanvasWindowController.shared.show(adding: FlowCanvasInput.from(trayItems: [item]))          // one item
```

`FlowCanvasInput(trayItem:)` maps images to `.image`, files to `.pdf` or `.file` by extension, link text (`trayAILinkURL`) to `.url`, and other text to `.text`.

To send Converter results to the canvas (for example a "Send to Flow Canvas" button next to "Add to Tray" in `ConverterTabView`):

```swift
FlowCanvasWindowController.shared.show(adding: FlowCanvasInput.from(files: result.files))
```

Dropped files are copied into the canvas's assets folder. The originals are never moved or deleted.

Optional, Spaces: Flow Canvas does not reference Spaces types, so it compiles without them. To turn on the inspector's "Add to Spaces" export:

```swift
FlowCanvasWindowController.shared.onSendToSpace = { title, markdown, url in
    _ = SpaceStore.shared.addManual(title: title, text: markdown, url: url, spaceID: nil, kind: .note)
}
```

`SpaceStore.addManual(title:text:url:spaceID:kind:)` and `SpaceItemKind.note` exist in today's `Labs/Spaces`. The snippet files the result into the Inbox.

## 4. Settings: Groq opt-in toggle

Flow Canvas has its own opt-in, separate from Tray AI and Meetings. It is stored in `UserDefaults` under the key **`FlowCanvasAllowsGroq`** and defaults to **off**. While it is off:

- the keychain is never read (`ClickyKeychain.hasKey()` and `load()` are not called);
- all AI runs on this Mac: Apple Intelligence through FoundationModels, Vision OCR, Apple Translation, or the built-in rules.

The window already has the toggle, in the "On this Mac" engine menu at the top right. To also show it in the notch gear menu (`NotchNookLayoutView.swift`, next to "Allow Meeting Notes to Use My Groq Key"):

```swift
Toggle("Allow Flow Canvas to Use My Groq Key", isOn: $flowCanvasSettings.allowsGroq)
```

Declare it in that view as:

```swift
@ObservedObject private var flowCanvasSettings = FCSettingsModel.shared
```

`FCSettingsModel.shared` writes through to `FlowCanvasAllowsGroq`. When the toggle is on and Clicky's key exists, Flow Canvas sends text to `api.groq.com` using `openai/gpt-oss-120b` (and `qwen/qwen3.8-27b` for image descriptions). Nothing is sent anywhere else.

## 5. Info.plist and entitlements

No new keys are needed:

- Links are fetched with `URLSession`, like Tray AI already does. The app has no sandbox.
- Notes export uses `NSSharingService` (the Notes share extension), not Apple Events.
- Files are read only after the user drops or chooses them, and are copied into `~/Library/Application Support/SparkV/FlowCanvas/<id>-assets/`.

## 6. Where data lives

```
~/Library/Application Support/SparkV/FlowCanvas/<canvas-id>.json       canvas (Codable, "version": 1)
~/Library/Application Support/SparkV/FlowCanvas/<canvas-id>-assets/    copies of dropped images, PDFs and files
~/Library/Application Support/SparkV/FlowCanvas/Templates/<id>.json    user templates
~/Library/Application Support/SparkV/FlowCanvas/Exports/<canvas-id>/   files made for drag-out and Send to Tray
```

Deleting a canvas asks for confirmation first. It then moves only that canvas's JSON file and its assets folder to the Trash.

Saving needs no wiring: the open canvas autosaves 0.7 s after a change, when the window closes, and when SparkV quits (the editor observes `NSApplication.willTerminateNotification` itself).

Links: only `http`/`https` pages and local `file://` pages that the user puts on the canvas are read. Other schemes (`mailto:`, `ftp:`, app links) get a "Failed" card and are never requested. For YouTube, Loom and Vimeo links, the title comes from the provider's own oEmbed endpoint. The thumbnail loads from the image URL that endpoint returns, which is the provider's image CDN (for example `i.ytimg.com`). Transcripts are never fetched.

## Public API

```swift
enum FlowCanvasInput { case image(URL), pdf(URL), file(URL), url(URL), text(String) }
FlowCanvasInput.forFile(_:) / .from(trayItems:) / .from(files:) / init?(trayItem:)

@MainActor final class FlowCanvasWindowController {
    static let shared: FlowCanvasWindowController
    func show()
    func show(adding inputs: [FlowCanvasInput])
    var onSendToTray: (([URL]) -> Void)?
    var onSendToSpace: ((String, String, URL?) -> Void)?
    var isVisible: Bool
}

struct FlowCanvasNotchButton: View   // header icon, opens the window
```

## Keyboard shortcuts in the window

The app has no main menu, so the window's event monitor provides these shortcuts. When a text field has focus, the monitor also handles ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z and ⇧⌘Z for that field.

- **Undo / redo:** ⌘Z / ⇧⌘Z
- **Delete:** D or Delete
- **Fullscreen the selected card:** F
- **Zoom to selection:** Z
- **Fit all:** ⌘0
- **Zoom in / out:** ⌘+ / ⌘-, ⌘-scroll, or pinch
- **Pan:** scroll, Space-drag, ⌥-drag, or the H tool
- **Tools:** V select, C connect, R frame
- **New note:** N, or double-click empty canvas
- **Paste cards:** ⌘V
- **Duplicate:** ⌘D
- **Select all:** ⌘A
- **Run selected:** Return
- **Run all:** ⌘Return
- **Toggle inspector:** I
- **Back out:** Esc closes fullscreen, discards a plan, or clears the selection
