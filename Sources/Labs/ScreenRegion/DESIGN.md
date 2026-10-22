# Screen Region Assistant ("Ask about screen") — design note

Select any visible region (or a window), then get an explanation, extracted
text, a translation, a web search or a suggested next step for it. On-device
by default.

## How shipping tools do it (research)

| Tool | Trigger | Selection | Answer surface | Notes we copy |
|---|---|---|---|---|
| macOS `screencapture -i` (man screencapture(1), local man page) | ⌘⇧4 | drag a rect; **Space toggles window mode**; **Esc cancels** | file/clipboard | Exactly the interaction model users already know: crosshair, dimmed outside, size readout, Space = window pick, Esc = cancel. |
| Gemini in Chrome "Select from screen" ([Android Authority](https://androidauthority.com/chrome-select-from-screen-3681130), [Digital Trends](https://www.digitaltrends.com/computing/gemini-in-chrome-can-now-see-exactly-what-youre-looking-at-on-screen/)) | side panel → Add → Select from screen | draw boxes over the page | side panel chat | Selection becomes an *attachment* to a free-form prompt; the panel stays next to the content. |
| Google Circle to Search ([Android Central](https://www.androidcentral.com/apps-software/how-use-circle-to-search)) | long-press home | circle/scribble/tap | bottom sheet over the app | Tap selects a whole object (we: a click with no drag picks the window under the pointer); results appear over the app, dismiss returns you exactly where you were. |
| Apple Visual Intelligence on Mac ([MacRumors guide](https://www.macrumors.com/guide/ios-26-visual-intelligence), [Apple framework docs](https://developer.apple.com/documentation/visualintelligence)) | ⌘⇧6 / screenshot toolbar | area of the screen | small window with **contextual buttons** ("Ask", "Image Search", data-detector actions such as dates, links) | Quick-action chips + data-detector chips (links, emails, phones, dates) under the answer. |
| ChatGPT for macOS ([MacRumors how-to](https://macrumors.com/how-to/use-chatgpt-app-for-macos-mac)) | ⌥Space companion | active window or whole desktop | floating companion window | Window capture of a *specific* window even if occluded → we use `SCContentFilter(desktopIndependentWindow:)` in window mode. |
| Raycast Screen Awareness ([manual](https://manual.raycast.com/ai/screen-awareness)) | hotkey | focused window / **Selected Area** / entire screen | AI chat with an attachment card | Privacy rules we follow: capture only on explicit request, nothing stored, show what was captured (thumbnail + app name), Screen Recording optional/checked first. |

## Platform facts (from the macOS 27 SDK headers, CLT)

* `SCStreamConfiguration.sourceRect` — "specified in **points in the display's
  logical coordinate system**" (top-left origin, display-local).
  `width/height` are output **pixels** → set them to `sourceRect × backingScale`
  for Retina-exact crops. (ScreenCaptureKit/SCStream.h)
* `SCScreenshotManager.captureImage(contentFilter:configuration:)` (macOS 14+)
  with a display filter that **excludes our own app** → the overlay and the notch
  are never in the picture. `captureImage(in:)` (15.2+) exists but can't exclude
  our windows, so it is not used.
* Window mode: `SCContentFilter(desktopIndependentWindow:)` +
  `ignoreShadowsSingleWindow`; front-to-back ordering + bounds come from
  `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` (documented front-to-back,
  Quartz top-left coordinates).
* Coordinates: AppKit global = bottom-left of the primary screen, y up; Quartz
  global (CGWindow bounds, SCWindow.frame, CGDisplayBounds) = top-left of the
  primary screen, y down. `quartzY = primaryHeight − appKitMaxY`. All of this
  lives in `ScreenRegionGeometry` (pure, unit-tested).
* FoundationModels on macOS 27 adds `Attachment(cgImage)` as a
  `PromptRepresentable` and `LanguageModelCapabilities.vision`. When
  `SystemLanguageModel.default.capabilities.contains(.vision)` the on-device
  model *sees* the crop; otherwise it gets Vision OCR text + classifier labels
  (TrayAIOCR). Streaming via `streamResponse(to:)` snapshots.
* Global hotkey: Carbon `RegisterEventHotKey` — what
  [sindresorhus/KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)
  (MIT) uses: no Accessibility permission, no prompt, and the key is consumed
  (⌃⌥S doesn't also type into the front app). Written from Apple's public
  Carbon headers; no code copied.

## Decisions

* **Selection UX** = `screencapture -i`: one borderless non-activating
  `NSPanel` per display at `.screenSaver` level, crosshair cursor, dim outside
  with an even-odd hole, live "W × H" badge, Space toggles window pick, Esc /
  right-click cancels, a click without a drag picks the window under the
  pointer. A drag stays on the display where it started (one capture = one
  display, Retina scale is per display).
* **Permission first**: `CGPreflightScreenCaptureAccess()` before showing the
  overlay (never prompts). If missing, the drawer/panel shows "Allow Screen
  Recording", which calls `CGRequestScreenCaptureAccess()` **only on that click**.
* **Results**: our own small dark glass panel anchored beside the selection
  (right → left → below → above → clamped), because `TrayAIPanelController`
  only takes `[TrayItem]`, centers itself at the top of the screen and uses the
  Tray's Groq setting. We still offer **Open in Tray AI** (temporary
  `TrayItem` of kind `.image`, never added to the tray) and **Save to Tray**
  as hooks the lead wires.
* **AI routing** (per action):
  * Extract text → Vision OCR only (always local, instant).
  * Translate / Search the web → our own `TrayAIEngine()` instance (reuses
    Translation framework, query building, deterministic fallbacks). The web
    search URL opens only when the user clicks **Open**.
  * Explain / What is this? / Summarize / Suggest next action / free-form →
    Groq vision if *our* opt-in is on and Clicky's key exists; else on-device
    FoundationModels, streamed, with the image attached when the model has
    vision; else OCR text; else deterministic fallback via `TrayAIEngine`.
* **Groq opt-in = its own setting `screenRegion.allowGroq`, default off.** Not
  `TrayAISettings.allowGroq`: tray items are files the user deliberately handed
  to Tray AI, while a screen region can be *anything* on screen (mail,
  passwords, DMs). The project's privacy rule also requires each non-Clicky
  feature to have its own opt-in. The toggle sits in the results panel with a
  one-line disclosure; turning it on never reads the keychain until a request
  actually runs.
* **Safety**: screen text is treated as data (system prompt says so); the
  assistant only *suggests* actions — nothing is executed, typed or clicked;
  data-detector chips (http/https/mailto/tel links, copy) run only on click.
  Captures live in `$TMPDIR/SparkV-ScreenRegion/`; the last one is kept
  10 minutes after its panel closes (drawer "Reopen"), replaced by the next
  capture, and everything is deleted on `stop()` and swept on `start()`.
  Nothing is logged except sizes, timings and which path answered.

## Verified

* macOS 27 on this Mac: the on-device model reports `.vision` and answered
  "What is this?" about a synthetic 404 page from the attached image
  (streamed, ~11 s). Vision OCR read all three synthetic lines exactly.
