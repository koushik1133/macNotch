# Ambient Light: integration

Car-style mood lighting that follows the music (the BE 6 "Groove Me" show,
Mercedes ambient light sync, Hue Sync / DreamView bars): while music plays,
the island's outline glows and pulses, and optionally a thin light strip runs
along every screen edge. Modes: **Ambient** (slow breathing in album colors),
**Pulse** (bass), **Disco** (a new color per beat, max 3 flashes/s), **Wave**
(colors chase around the border at the song's tempo), **Off**.

Off by default. Nothing is captured until the user turns it on, and capture
runs only while `MediaEngine.isPlaying` is true (1.5 s grace on pause).

## Files

| File | What it holds |
| --- | --- |
| `AmbientLightModels.swift` | `AmbientLightMode`, `AmbientLightScope`, `AmbientBrandPalette`, `AmbientLightSettings.shared` (UserDefaults `AmbientLight.*`), `AmbientAudioFeatures`, `AmbientFeatureMailbox`, `AmbientLightStatus`. |
| `AmbientSpectralAnalyzer.swift` | vDSP FFT (2048 / hop 512): bass/mid/treble envelopes with auto gain, SuperFlux onsets, adaptive-threshold beats, autocorrelation BPM. No allocation per hop. |
| `AmbientAudioCapture.swift` | `AmbientSampleRing` (lock-free SPSC), `AmbientProcessTapSource` (Core Audio process tap + private aggregate device, realtime IO block that only copies), `AmbientScreenCaptureSource` (SCStream audio fallback via `PermissionCenter.shared.shareableContent`), `AmbientAudioPermission` (System Audio Recording status/request). |
| `AmbientAudioEngine.swift` | Starts/stops a source, runs analysis on a `.userInteractive` queue, skips stale audio (never > 60 ms behind). |
| `AmbientLightPalette.swift` | Album-art palette (first color = `ArtworkPalette.glowColor`, the island's own glow), brand fallbacks, Disco wheel, 256-step CGColor ramp (no per-frame allocation). |
| `AmbientLightChoreographer.swift` | Features + mode → `AmbientVisualFrame` (pure, time-based). Flash limiter, Reduce Motion, fade in/out. |
| `AmbientGlowLayers.swift` | Core Animation trees: `AmbientOutlineGlow` (halo with `shadowPath`, conic Wave band, core line) and `AmbientEdgeStrips`. |
| `AmbientNotchGlow.swift` | `AmbientNotchGlowBackdrop` (SwiftUI, behind the island) hosting a click-through `AmbientNotchGlowView`. |
| `AmbientScreenEdgeGlow.swift` | One click-through panel per screen (level `mainMenu - 1`, `sharingType = .none`, not in full-screen spaces), hidden over full-screen windows and while the screen is shared. |
| `AmbientLightController.swift` | `AmbientLightController.shared`: media/settings wiring, permission flow, one `CADisplayLink` (`NSScreen.displayLink`) driving every surface; Low Power / thermal / Reduce Motion. |
| `AmbientLightViews.swift` | `AmbientLightSettingsView`, `AmbientLightSettingsWindowController.shared`, `AmbientLightMenuItems`, `AmbientLightHubTile`. |
| `Tests/` | `run-tests.sh`: offline harness (synth drum loops, sweeps, silence; offscreen renderer timing). Not part of the app build. |

## 1. build.sh

Next to the other Labs lines (the glob doesn't pick up `Tests/`):

```zsh
cp Sources/Labs/AmbientLight/*.swift "$WORK/src/"
```

## 2. Info.plist

Without this key macOS silently delivers silence from the tap (no error):

```xml
	<key>NSAudioCaptureUsageDescription</key>
	<string>SparkV listens to what your Mac plays while Ambient Light is on, so the notch can glow with your music. The sound is analyzed on this Mac and never recorded.</string>
```

No new entitlement is needed (the app is unsandboxed; process taps aren't
gated by `com.apple.security.device.audio-input`).

## 3. NotchWindowController.swift

### 3a. Properties (next to `themeObserver`)

```swift
    /// Ambient Light needs the same glow margin as a notch theme.
    private var ambientObserver: AnyCancellable?
    /// Hides Ambient Light's screen edges while SparkV records the screen.
    private var ambientRecordingObserver: AnyCancellable?
```

### 3b. init, right after `themeObserver = …` (and after `liveTranslation.attach(to: meetingAssistant)`)

```swift
        AmbientLightController.shared.attach(media: media)
        ambientObserver = AmbientLightController.shared.$wantsNotchOutset
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.positionOverNotch() }
            }
        ambientRecordingObserver = screenRecorder.$phase
            .map(\.isRecording)
            .removeDuplicates()
            .sink { recording in
                AmbientLightController.shared.setEdgeSuppression(recording, reason: "screenRecording")
            }
```

### 3c. positionOverNotch: the glow margin

Replace

```swift
        let outset = NotchThemeLayout.outset(for: NotchThemeSettings.shared.theme)
```

with

```swift
        let outset = max(
            NotchThemeLayout.outset(for: NotchThemeSettings.shared.theme),
            AmbientLightController.shared.notchOutset
        )
```

Everything else (`appliedThemeOutset`, `interactiveFrame`, click-through in
the margin, `resizeForTab`) already uses `appliedThemeOutset`, so hot zones
and clicks stay exactly as with a theme. With Ambient Light off and the Plain
theme the panel is unchanged.

## 4. NotchNookLayoutView.swift

### 4a. The glow behind the island

Directly after the `NotchThemeBackdrop` background (so it sits behind the
theme, is not clipped by `.clipShape(shape)`, and moves with `.offset(x:)`):

```swift
        .background(alignment: .top) {
            NotchThemeBackdrop(
                isExpanded: state.isExpanded,
                bodySize: size,
                topRadius: radii.top,
                bottomRadius: radii.bottom
            )
        }
        // Ambient Light: music-synced glow around the island (nothing while off).
        .background(alignment: .top) {
            AmbientNotchGlowBackdrop(bodySize: size, topRadius: radii.top, bottomRadius: radii.bottom)
        }
        // Uneven wings shift the body so the housing stays over the camera.
        .offset(x: closed?.xOffset ?? 0)
```

The backdrop observes only `AmbientLightSettings.shared` (on/off). Per-frame
light never touches SwiftUI: the controller's display link writes layer
properties directly. Geometry changes (open/close, wings) animate the outline
with a Core Animation spring matching `NotchMetrics.hoverAnimation`.

### 4b. Gear menu

After `Menu("Notch Theme") { NotchThemeMenuItems() }`:

```swift
            Menu("Ambient Light") { AmbientLightMenuItems() }
```

## 5. AgentsHubView.swift

The 24 slots are full, so add a fourth row:

```swift
// AgentHubMetrics
    static let rows = 4
```

Cell (add `case ambientLight` to `Cell`, `case .ambientLight: "ambientLight"`
to `id`), grid position (e.g. after `.modes`):

```swift
            .modes,
            .ambientLight,
```

and in the `switch cell`:

```swift
                case .ambientLight:
                    // Click: on/off. Right-click: modes, edges, settings.
                    AmbientLightHubTile()
```

(Alternatively keep three rows and replace a tile; `AmbientLightHubTile`
needs no environment objects.)

## 6. Optional: suppress edges from other features

Any feature that shares the screen (a meeting app presenting, a SparkV
capture) can hide the edge strips:

```swift
AmbientLightController.shared.setEdgeSuppression(true, reason: "meetingScreenShare")
// …
AmbientLightController.shared.setEdgeSuppression(false, reason: "meetingScreenShare")
```

macOS Screen Sharing / Remote Management is detected on its own
(`CGSSessionScreenIsShared`), and windows covering a whole display hide the
strips on that display (checked on Space / app switches and every 2 s while
shown). Native full-screen Spaces never show them (no `.fullScreenAuxiliary`).

## 7. PermissionCenter: `.systemAudio` (requested)

Ambient Light reads System Audio Recording only through
`AmbientAudioPermission.preflight()` (never prompts) and asks only through
`AmbientAudioPermission.request()` from the user's click. To route both
through PermissionCenter (logging, one prompt at a time, Settings redirect,
Setup checklist), add this case. Edits in `Sources/PermissionCenter.swift`:

```swift
        // enum Permission
        /// System Audio Recording (process taps, macOS 14.4+).
        case systemAudio

        // key
            case .systemAudio: "systemAudio"

        // settingsURL
            case .systemAudio: anchor = "Privacy_AudioCapture"

        // SystemPermissionSystem.quickStatus
        case .systemAudio:
            switch AmbientAudioPermission.rawPreflight() {
            case .granted: return .granted
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            case .unknown: return .unknown
            }

        // SystemPermissionSystem.prompt
        case .systemAudio:
            _ = await AmbientAudioPermission.rawRequest()
```

(`standard` can stay as it is, or list `.systemAudio` to show it in Setup.)
Then in `Sources/Labs/AmbientLight/AmbientAudioCapture.swift` replace the two
routed functions' bodies:

```swift
    @MainActor
    static func preflight() -> State {
        state(PermissionCenter.shared.status(.systemAudio))
    }

    @MainActor
    static func request() async -> State {
        state(await PermissionCenter.shared.request(.systemAudio, from: "Ambient Light", openingSettings: true))
    }

    @MainActor
    private static func state(_ status: PermissionCenter.Status) -> State {
        switch status {
        case .granted: .granted
        case .denied, .restricted: .denied
        case .notDetermined, .limited: .notDetermined
        default: .unknown
        }
    }
```

Note `PermissionCenter.request` returns `.unknown` without prompting when the
TCC functions aren't available; Ambient Light then starts the tap from the
user's click, which shows the system prompt.

## Behaviour summary

- **Permission**: the System Audio Recording prompt appears only when the
  user turns Ambient Light on (toggle, menu, hub tile, mode card, "Allow…").
  If nothing is playing then, SparkV asks right away so later automatic
  starts are silent. Denied → System Settings › Privacy & Security › Screen &
  System Audio Recording opens from "Allow…". If the tap yields only digital
  zeros while music plays and the grant isn't confirmed, SparkV switches to
  ScreenCaptureKit audio when Screen Recording is already granted (never
  requested from here), otherwise shows "needs permission".
- **Output device changes** (AirPods connect) restart the tap on the new device.
- **Sleep / fast user switching** stop capture (including a start still in
  flight); wake / returning to the session re-evaluates. A display
  reconfiguration rebuilds the display link on the notch's screen.
- **Start/stop races**: every start carries a token; a superseded start
  never clears a newer one or stops its capture, and a start cancelled while
  the permission prompt is open stops the tap as soon as it comes up.
- **Reduce Motion**: steady glow, no beat response, 30 fps. **Low Power Mode** /
  serious thermal state: 30 fps. Ambient mode runs at 60 fps; Pulse / Disco /
  Wave at up to 120 fps on ProMotion.
- **Photosensitivity**: Disco changes color/flashes at most 3× per second
  (WCAG 2.3.1), stays ≥ 40 % bright between flashes, eases each flash out.
  Every mode goes through a flash guard: a brightness drop of more than 0.15
  is allowed at most once per 1/3 s, otherwise the light only fades slowly,
  so fast basslines can't strobe Pulse / Wave (and Disco's bass glow only
  fades slowly). Wave laps are capped at 0.5 per second.
- **Screenshots / recordings**: edge panels use `sharingType = .none`. (The
  notch glow is part of the notch panel and follows that panel's setting.)
  Recent macOS versions don't always honor `sharingType` for
  ScreenCaptureKit captures, so step 3b also hides the edges during SparkV's
  own recordings, and step 6 lets meeting features do the same.

## Tests

```zsh
Sources/Labs/AmbientLight/Tests/run-tests.sh
```

Builds into `$TMPDIR/ambient-light-tests`, no capture, no window on screen.
