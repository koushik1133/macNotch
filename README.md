# NotchIsland

A "Dynamic Island" for the MacBook Pro notch. Hover the notch and it springs open into a 540×115
drawer with media controls, two action capsules, a camera mirror, a tray, a dictation hub and a
voice assistant. It runs as an agent app (no Dock icon) in a non-activating panel, so opening it
never steals focus from the app you are in.

## Features

- **Media for any app.** Title, artist, artwork and the playing app's icon for whatever owns Now Playing:
  Safari and other browsers, Music, Spotify, Podcasts and so on. Previous, a single play/pause toggle,
  and next. macOS 15.4+ only lets Apple-signed processes read Now Playing, so the app runs Apple's
  `/usr/bin/perl` with the bundled [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter)
  framework, which streams JSON. If the adapter stops working, NotchIsland falls back to Apple Events
  for Music and Spotify and to media-key events for everything else.
- **Two action capsules.** Each runs a built-in action or any shortcut in your library:
  - **Dictate** toggles hands-free dictation. While it records, the capsule turns red and reads
    "Stop Dictation".
  - **Capture to Tray** closes the drawer and starts an interactive screenshot (drag to select, Space
    for a window, Esc to cancel). The capture goes straight into the tray.
  - **Shortcuts** run through `/usr/bin/shortcuts run` with a 60-second timeout. A capsule shows a
    spinner, then a green check or the error. A shortcut you renamed or deleted turns orange.

  To change a capsule, right-click it, or open the gear menu and pick **Button 1** or **Button 2**.
  See [SHORTCUTS.md](SHORTCUTS.md) for ten shortcuts worth putting on them.
- **Wispr-style dictation.** Hold **fn** to talk and let go to finish. Double-tap fn for hands-free,
  then press fn again to stop. **Esc** cancels. Your words appear live in a band under the notch,
  and its hint names the key that stops a hands-free session. The text is formatted on-device and
  inserted where your cursor is. The hold key and the **AI Formatting** switch are in gear › Dictation.
  See [The fn key](#the-fn-key) if fn opens the emoji picker or another dictation app.
- **Flow hub** (waveform icon in the header). Everything you dictated, newest first, with the app
  you dictated into. Click an entry to copy it, or delete one or clear the history. **Notes** is a
  scratch pad for text you want to keep. **⌃⌘V** pastes your last dictation again and **⌃⌘C** copies it,
  from any app. History and notes stay on your Mac.
- **Clicky assistant** (cursor-rays icon in the header). Hold **⌃⌥** (Control-Option), ask a question
  out loud and let go. The question appears under the notch as you speak, then "Thinking…", then the
  answer. The Clicky panel keeps your recent questions and answers, has a button to ask without the
  keys, and is where you add a Groq API key (free tier works). With a key, Clicky sends the screenshot
  to a Groq vision model (Qwen 3.6 by default, Llama 4 Scout optional) and can point at what to click.
  Without one it reads the screen's text on-device and asks Apple Intelligence, which can't see icons
  or images.

  > **Privacy:** speech is transcribed on-device for both dictation and Clicky. With an API key set,
  > the screenshot under your mouse and your question go to Groq's API under your key, only while you
  > ask. The key sits in its own Keychain item that only Clicky's network code reads, and it is sent
  > only to api.groq.com. Without a key nothing leaves the Mac.
- **Camera mirror.** A circular, mirrored FaceTime HD preview. The camera stops when the drawer closes,
  when you switch to the Tray, and when the Mac locks or sleeps.
- **Tray.** Holds your last 5 screenshots, text snippets, links and files, newest first, and keeps them
  across relaunches. Drop anything on the notch (screenshot thumbnails included), or use **Paste**
  (clipboard), **Capture** (screenshot) and **Add…** (file picker). Click an item to copy it,
  double-click to open it, drag it out to use it elsewhere, or right-click for Show in Finder and
  Remove. Images are copied into `~/Library/Application Support/NotchIsland/Tray`. Files stay where
  they are.
- **Face Unlock**, from [glance](https://github.com/jonnyoo/glance). Enrollment runs inside the notch on
  first launch, or later from gear › Set Up Face Unlock…. glance recognizes your face with an on-device
  ArcFace model and liveness checks, then types your login password, which it stores encrypted, into
  the lock screen.

  > **Security warning:** glance is not as secure as Face ID or Touch ID. It uses your Mac's standard
  > webcam and is built for convenience, not high-security authentication. Don't use it on a Mac
  > where a look-alike or a determined attacker with physical access is a concern.
- Launch at Login and Quit are in the gear menu.

## Header

The header shares the band beside the camera cutout. **Nook** and **Tray** are on the left. On the
right are **Flow** (waveform), **Clicky** (cursor with rays) and the gear. The selected tab is white
and the others are gray. The drawer remembers the tab you picked when it closes. The exception is a
Tray that opened because you dragged a file over the drawer: it goes back to the tab you were on.
The Flow and Clicky icons are SF Symbols, not the Wispr Flow or Clicky logos.

The drawer also closes by itself when Face Unlock needs the notch, for example after gear › Set Up
Face Unlock…, so it never sits under glance's overlay.

## The fn key

Dictation listens for fn (Globe) by default, but macOS also gives that key a job. In **System
Settings › Keyboard**, set **Press 🌐 key to** to **Do Nothing**, and in **Keyboard › Dictation**
change or turn off the macOS dictation shortcut if it uses fn. Otherwise every press also opens the
emoji picker or Apple's dictation. To avoid fn altogether, pick **Right Option** in gear › Dictation ›
Hold to Talk.

**Wispr Flow** is installed on this Mac and also uses fn. With both running, one fn press starts two
dictations. Quit Wispr Flow, or change its hotkey in its own settings, before you dictate with
NotchIsland.

## Build

No Xcode needed. The Command Line Tools are enough:

```bash
./build.sh            # release → build/NotchIsland.app
./build.sh debug
open build/NotchIsland.app
```

`build.sh` compiles glance into a static `GlanceKit` module with glance's own settings (default
MainActor isolation, approachable concurrency, macOS 15). It then compiles the app, builds
`MediaRemoteAdapter.framework` with clang, copies glance's resources and the ArcFace model, and signs
everything ad hoc with the Hardened Runtime. It stages the work in a temporary folder, because iCloud
Desktop sync otherwise changes files during the build.

With Xcode 26 or later: `brew install xcodegen && xcodegen`, open `NotchIsland.xcodeproj` and pick
your signing team. `project.yml` defines the same two targets and a script phase that builds the
adapter framework.

The code avoids `@State`, `#Preview` and `@Entry`, whose macro plugins ship only with Xcode. Use
`@StateObject` with `ViewFlag` (in `NotchState.swift`) for small pieces of view state.

## Permissions

macOS asks for each one the first time you use the feature:

| Permission | Used for |
| --- | --- |
| Camera | Mirror and Face Unlock. Video stays on your Mac. |
| Microphone | Dictation and Clicky questions |
| Speech Recognition | Dictation and Clicky transcripts |
| Accessibility | Watching the dictation and Clicky keys, typing the result into the focused app, Face Unlock typing your password at the lock screen, and the media-key fallback |
| Screen Recording | Capture to Tray and the tray's Capture button (`screencapture -i`) |
| Automation (Music, Spotify) | Only the fallback used when the Now Playing adapter fails. If you denied it, play opens Privacy & Security › Automation. |

Shortcuts ask for their own permissions (Calendars, Notes and so on) under the Shortcuts app.

Ad-hoc builds get a new signature on every rebuild, so macOS may ask again after each one. Sign with a
Developer ID, or a team in Xcode, to make the grants stick. To see what the app is doing, read
`~/Library/Logs/NotchIsland.log`.

## Files

| File | Role |
| --- | --- |
| `Sources/NotchIslandApp.swift`, `AppDelegate.swift` | Agent-app entry point. Starts the notch and Face Unlock. |
| `Sources/NotchPanel.swift` | Borderless, non-activating `NSPanel` at status-bar level |
| `Sources/NotchWindowController.swift` | Positions the panel over the notch. Hover expands it; it collapses 0.5 s after you leave, on sleep and lock, or when Face Unlock takes the notch. Creates the dictation, Flow and Clicky objects and wires up the built-in actions. |
| `Sources/NotchState.swift` | Geometry (`NotchMetrics`), tab state (Nook, Tray, Flow, Clicky) and `ViewFlag` |
| `Sources/NotchNookLayoutView.swift` | The island: header and its tab icons, gear menu, media, capsules, mirror |
| `Sources/MediaEngine.swift` | Now Playing through the adapter, plus the Apple Events and media-key fallbacks |
| `Sources/MacroController.swift` | Capsule assignments (saved in UserDefaults) and the built-in actions |
| `Sources/ShortcutRunner.swift` | `shortcuts run` and `shortcuts list` via `Process`, with a timeout |
| `Sources/DictationController.swift`, `DictationFormatter.swift`, `PushToTalkMonitor.swift`, `TextInserter.swift` | Dictation engine: hold-key monitor, on-device transcription, formatting, insertion |
| `Sources/DictationActivityView.swift` | `NotchActivityView`, the live band under the closed notch for dictation and Clicky |
| `Sources/FlowStore.swift` | Flow hub: dictation history, notes and the Flow panel |
| `Sources/Clicky*.swift`, `VisionClient.swift` | Clicky assistant: its controller, panel and the Groq API client |
| `Sources/CameraMirrorView.swift` | `AVCaptureSession` and the mirrored, aspect-fill preview |
| `Sources/TrayView.swift` | Tray store (5 items, persisted) and its views |
| `Sources/AppLog.swift` | `AppLog.log(_:)` writes to `~/Library/Logs/NotchIsland.log` |
| `Vendor/glance/` | Face Unlock sources, resources and ArcFace model, built as `GlanceKit`. See `PORTING.md`. |
| `Vendor/mediaremote-adapter/` | Now Playing adapter: Objective-C framework and `mediaremote-adapter.pl` |
| `Info.plist`, `NotchIsland.entitlements` | `LSUIElement`, usage strings, Hardened Runtime entitlements (camera, Apple Events, no sandbox) |
| `build.sh`, `project.yml` | Command Line Tools build and XcodeGen project |

## Customizing

- Capsules: right-click a capsule or use the gear menu. Assignments are saved in UserDefaults
  (`MacroSlots`). Out of the box they are Dictate and Capture to Tray.
- Sizes and timing: `NotchMetrics` in `Sources/NotchState.swift`.

## Credits and licenses

- **glance** by Jonathan Zhou, MIT. See `Vendor/glance/LICENSE`, shipped as `glance-LICENSE` in the app.
- **mediaremote-adapter** by Jonas van den Berg and contributors, BSD 3-Clause. See
  `Vendor/mediaremote-adapter/LICENSE`, shipped next to the framework.
- **ArcFace model:** converted from InsightFace `w600k_mbf`. InsightFace's pretrained weights are
  licensed for **non-commercial use only**, so a commercial build needs a different model.

Upstream commits are recorded in each vendor folder's `UPSTREAM_COMMIT`.

## Not in this repository

- **Face Unlock** (`Vendor/glance`, the GlanceKit module and its ArcFace model) is not published here. `build.sh` expects it at `Vendor/glance`; without it, the Face Unlock code in `AppDelegate.swift`, `NotchWindowController.swift` and `NotchNookLayoutView.swift` must be removed before building.
- **Node packages** for the UI audit and browser recorder runners: run `npm install` in `Vendor/ui-audit` and `Vendor/browser-recorder`.
