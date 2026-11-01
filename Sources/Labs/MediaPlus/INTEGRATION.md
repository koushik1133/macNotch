# Media package (Labs/MediaPlus): wiring steps

Requirement ids: audio-output-switch, media-source-filter, media-like, media-controls, per-app-volume, lyrics, idle-home, media-gestures, audio-visualizer.

Owned files changed: `Sources/MediaEngine.swift`, `Sources/Labs/Media/MediaColumnV2.swift`. New lab: `Sources/Labs/MediaPlus/` (16 files). Every other change is a step below. Apply them in order. Each anchor was copied from the current source and occurs exactly once.

Validation: the 14 steps are applied by `scratchpad/req/tests-media/integration_steps.py` (it parses this file). `check <tree>` counts every anchor; `apply <tree>` writes nothing unless every anchor occurs exactly once. They were applied to a fresh copy of the work tree (`scratchpad/req/wired-media`), which typechecked in Swift 5 and Swift 6 with no errors in any file this package touches, and `check` passed against the live repo when this was written.

## What is new

| Piece | Where | What it does |
|---|---|---|
| Source filter | MediaEngine (`excludedSources`, `preferredSource`, `seenSources`, `setSource`, `forgetSource`; keys `NowPlaying.excludedBundleIDs` / `NowPlaying.preferredBundleID` / `NowPlaying.seenBundleIDs`) | An excluded app (matched on the app and its host, helpers included) never shows in the island and never gets play/pause or media keys. If Music or Spotify is open, it shows instead, read over Apple Events every 2 s, but only while the excluded app owns Now Playing and something plays or the drawer is open. A preferred player that is playing wins over another Now Playing app: the engine checks it once (rate-limited to every 3 s) and keeps polling only while it plays. Polls never prompt. Closed wings, Smart Moments and bookmarks all follow the filtered source. |
| Shuffle, repeat, ±15 s | MediaEngine (`setShuffle`, `setRepeat`, `skip15(forward:)`, `Command.skipBackward15/skipForward15/toggleShuffle/toggleRepeat`, `shuffleMode`, `repeatMode`, `reportsSkip15`) | These use MediaRemote through the adapter (`shuffle <mode>`, `repeat <mode>`, `send 12/13`), with optimistic state that reverts after 1.8 s if the player doesn't confirm it. When MediaRemote doesn't report the modes, Music and Spotify are read and set over Apple Events. The 15 s skip falls back to a plain seek. |
| Favorites | MediaEngine (`toggleLike`, `isLiked`, `canLike`, `spotifyLibrary`), Labs/MediaPlus/SpotifyLibrary.swift | Music: the track's `favorited` property (`loved` on older Music). The first tap may show the Automation prompt; the read when a track changes never prompts. Spotify: its Web API, after the user connects with their own free Client ID (OAuth PKCE; tokens in the keychain). Add to Playlist (Music) works for library tracks, and the column says "Add the song to your library first" when it can't. |
| Media column | Labs/Media/MediaColumnV2.swift | Shows a heart (when the player can like). Previous and next become 15 s back and forward for podcasts, audiobooks and anything 20 minutes or longer (Settings › Media). A ••• menu holds bookmarks, shuffle, repeat, ±15 s, Sound Output, lyrics, Add to Playlist and "Hide <App> in the Island". A notice line covers failed actions. Lyrics can replace the title and artist. Two-finger swipes and ←/→/Space work while the pointer is over the column. |
| Sound output | AudioOutputDevices.swift (`AudioOutputController.shared`) | Lists output devices (minus SparkV's own tap aggregates and meeting apps' loopbacks), AirPlay receivers (data sources) and, if Bluetooth is allowed, paired headphones that aren't connected. Picking headphones connects them and then switches. Switching sets the default output, and the alert device too when it was following the output. Core Audio listeners only, no polling. |
| App Volumes | AppVolumeEngine.swift, AppVolumeController.swift, AppVolumeViews.swift | Per-app 0–200 % volume via Core Audio process taps (`.mutedWhenTapped`) plus a private aggregate device and a realtime IO block (ramped gain, soft clip, no locks or allocation). A route exists only while its app plays at a level other than 100 %. It is rebuilt (after 1 s) only when a process of the app starts playing that its tap doesn't cover; helpers coming and going leave it alone. The headset microphone stream is switched off for the IO proc. A route that doesn't start or run, or that only delivers silence while System Audio Recording isn't granted, is undone at once, so an app is never left silent. Routes are rebuilt on output or sample-rate changes, removed on sleep, and removed synchronously on quit. |
| Lyrics | LyricsController.swift, LyricsViews.swift | LRCLIB `/api/get`, then `/api/search`, with a descriptive User-Agent. Lyrics saved in Music are read first and stay on the Mac. Results are cached per track in Application Support (misses for a week). There are three places to show them: the Home column (current and next line), a band under the closed notch while music plays (opt-in), and a Lyrics window where you click a line to seek. One wake-up per line, none while paused or hidden. "On screen" is window-aware (`mpReportsOnScreen`): closing the Lyrics window (kept, not released) stops lookups and line timing. The band under the notch is a `.media` live activity titled "Lyrics". Requests go through an ephemeral session with no URL cache. **Off until the user turns it on**, and the toggle says what is sent. |
| Idle Home | IdleHome.swift (`HomeMediaSlot`, `IdleHomeColumn`) | When no app has a track, or Music / Spotify are stopped (after a 3 s debounce), or media controls are off, Home shows the next meeting with Join, or a clock, plus quick-timer chips. A paused track keeps the player so it can be resumed. "Connect Music" stays visible. It redraws once a minute (the timer chip once a second while it runs). |
| Live bars + progress line | MediaVisualizer.swift (`MediaVisualizerController.shared`, `MediaLiveLevelBars`, `MediaClosedProgressLine`) | The bars beside the notch follow the real sound: Ambient Light's analyser when its engine is actually delivering (30 fps, 15 fps in Low Power Mode and when hot), otherwise Ambient Light's engine started only while the bars are visible and music plays (paused in Low Power Mode and when hot). One tap at most; Ambient Light gets 3 s to start before ours does. During silence the bars stand still and no frame timeline runs (one check a second for sound). Optional album color. A 1.5 pt progress line runs along the bottom of the closed pill and steps about 1 pt at a time (one redraw every length/width seconds, 1–10 s, nothing while paused). Reduce Motion gives still bars. |
| Gestures | MediaGestures.swift (`.mediaPointerControls()`) | Local scroll and key monitors exist only while the pointer is over the column, and are removed on exit or disappear. Horizontal swipes only, once per gesture, with momentum ignored. The swipe can skip tracks or seek 10 s or 15 s, and the direction can be reversed. Vertical scrolling passes through. |

## Settings sections (no arguments) and their panes

| Section | Pane |
|---|---|
| `MediaControlsSettingsSection` | Media |
| `MediaSourcesSettingsSection` | Media |
| `MediaGesturesSettingsSection` | Media |
| `LyricsSettingsSection` | Media |
| `SpotifyLikesSettingsSection` | Media |
| `SoundOutputSettingsSection` | System |
| `AppVolumeSettingsSection` | System |
| `ClosedIslandMediaSettingsSection` | Island |
| `IdleHomeSettingsSection` | Island |

Sections that need the MediaEngine read `MediaPlus.media` (set by `MediaPlus.start`), so the Settings window needs no environment object.

## Agents hub tiles (category: Media)

`SoundOutputHubTile` (a menu of outputs), `AppVolumeHubTile` (opens App Volumes, lit while a level applies) and `LyricsHubTile` (opens the Lyrics window). Step 10 adds them to `HubCatalog.packageTiles` with `category: .media`.

## Gear menu items

- `MediaPlusMenuItems`: the whole Media submenu (Sound Output, App Volumes…, Media Sources, Playback, Lyrics, Home When Nothing Plays, Closed Island). Step 7 adds it.
- Also usable on their own: `SoundOutputMenuItems`, `MediaSourcesMenuItems`, `MediaPlaybackMenuItems`, `LyricsMenuItems`.

## Hotkeys

There are no global hotkeys. ←/→ (15 s) and Space (play/pause) are local and only apply while the pointer is over the media column, the island has keyboard focus and no text field is editing. They don't clash with ⌃⌥J/R/S/T, ⌃⌥⇧R, ⌥Space, ⌘⇧V, ⌘1-9V or ⌃⌥C.

## Controllers

All controllers are `@MainActor` and are started by `MediaPlus.start(media:activities:)` and stopped by `MediaPlus.stop()` (steps 3–4): `AudioOutputController.shared`, `AppVolumeController.shared`, `LyricsController.shared`, `MediaVisualizerController.shared` and `SpotifyLibraryClient.shared`. None of them needs `.environmentObject`; views use `.shared`. The views do use the existing `MediaEngine`, `MeetingsController` and `TimerController` environment objects.

## Permissions (all through PermissionCenter, only from a click)

- Automation for Music or Spotify: the first favorite, shuffle, repeat or playlist tap.
- System Audio Recording: turning on Live Level Bars, or the first App Volume moved off 100 %.
- Bluetooth: "Allow Bluetooth…" in Sound Output, which lists paired headphones that aren't connected.

## What leaves the Mac (off until turned on)

- Lyrics: the title, artist, album and length go to lrclib.net, once per track and only while lyrics are on screen (Home column, the band, or an open Lyrics window).
- Spotify favorites: the track id goes to api.spotify.com when a track starts and when the heart is tapped. This only happens after the user connects Spotify, and never while "Show Favorite Button" is off (then nothing reads favorites at all).

## Steps
### 1. build.sh: compile the new lab

File: `build.sh`. Insert directly **after** this anchor (it occurs once):

```zsh
cp Sources/Labs/Media/*.swift "$WORK/src/"
```

this code:

```zsh
cp Sources/Labs/MediaPlus/*.swift "$WORK/src/"
```

Required first: `Labs/Media/MediaColumnV2.swift` now uses MediaPlus types.

### 2. AmbientLightController.swift: share the analyser output

File: `Sources/Labs/AmbientLight/AmbientLightController.swift`. Insert directly **after** this anchor (it occurs once):

```swift
    private let engine = AmbientAudioEngine()
```

this code:

```swift
    /// Live analyser output while capture runs (the Media visualizer's
    /// level bars read it instead of starting a second tap).
    var liveFeatures: AmbientAudioFeatures? { engine.isRunning ? engine.mailbox.load() : nil }
```

### 3. NotchWindowController.swift: start the Media controllers

File: `Sources/NotchWindowController.swift`. Insert directly **after** this anchor (it occurs once):

```swift
        AmbientLightController.shared.attach(media: media)
```

this code:

```swift
        // Media package (Labs/MediaPlus): outputs, app volumes, lyrics, live bars.
        MediaVisualizerController.shared.ambientFeatures = { AmbientLightController.shared.liveFeatures }
        MediaPlus.start(media: media, activities: activities)
```

### 4. NotchWindowController.swift: stop them before quitting

File: `Sources/NotchWindowController.swift`. Insert directly **before** this anchor (it occurs once):

```swift
        // Also ends the Now Playing adapter's perl process.
        media.stop()
```

this code:

```swift
        // Removes every App Volume tap and aggregate (synchronous).
        MediaPlus.stop()
```

### 5. NotchNookLayoutView.swift: Home's media slot (idle Home)

File: `Sources/NotchNookLayoutView.swift`. **Replace** this anchor (it occurs once):

```swift
            MediaColumnV2()
                .frame(width: 180, height: 69, alignment: .leading)
```

with:

```swift
            HomeMediaSlot()
                .frame(width: 180, height: 69, alignment: .leading)
```

`HomeMediaSlot` shows `MediaColumnV2` while something plays and the idle column otherwise.

### 6. NotchNookLayoutView.swift: progress line under the closed island

File: `Sources/NotchNookLayoutView.swift`. Insert directly **after** this anchor (it occurs once):

```swift
                ClosedIslandContent(layout: closed, restingHeight: state.collapsedSize.height, source: wingsSource)
                    .padding(.horizontal, radii.top)
                    .transition(.opacity)
            }
```

this code:

```swift
            // Track progress along the bottom of the closed pill (Settings ›
            // Island › Closed Island Music; draws nothing while off).
            if !state.isExpanded, wingsSource == .nowPlaying, closed?.band == nil {
                MediaClosedProgressLine(bottomRadius: radii.bottom)
                    .padding(.horizontal, radii.top)
            }
```

### 7. NotchNookLayoutView.swift: gear menu › Media

File: `Sources/NotchNookLayoutView.swift`. Insert directly **before** this anchor (it occurs once):

```swift
            Menu("Downloads") {
```

this code:

```swift
            Menu("Media") { MediaPlusMenuItems() }
```

If the app-shell package rebuilt the gear menu, put `Menu("Media") { MediaPlusMenuItems() }` next to Live Activities instead.

### 8. DictationActivityView.swift: live level bars beside the notch

File: `Sources/DictationActivityView.swift`. **Replace** this anchor (it occurs once):

```swift
            CompactLevelBars(isAnimating: media.isPlaying)
```

with:

```swift
            MediaLiveLevelBars(isAnimating: media.isPlaying)
```

Falls back to the existing decorative `CompactLevelBars` whenever live bars are off.

### 9. WidgetsTabView.swift: right-click the Home volume knob for outputs

File: `Sources/Labs/Widgets/WidgetsTabView.swift`. **Replace** this anchor (it occurs once):

```swift
        VolumeKnobWidget(compact: true)
    }
```

with:

```swift
        VolumeKnobWidget(compact: true)
            .contextMenu { SoundOutputMenuItems() }
    }
```

### 10. AgentsHubView.swift: the three Media hub tiles

File: `Sources/AgentsHubView.swift`. Insert directly **after** this anchor (it occurs once; it is the commented example inside `HubCatalog.packageTiles`, so other packages' entries can sit after it too):

```swift
            // HubPackageTile(info: HubTileInfo(id: "…", title: "…", systemImage: "…", tint: .blue, category: .system)) { AnyView(…HubTile()) },
```

this code:

```swift
            // Media package (Labs/MediaPlus).
            HubPackageTile(info: HubTileInfo(id: "soundOutput", title: "Output", systemImage: "hifispeaker.fill", tint: .blue,
                                             category: .media, help: "Sound output")) { AnyView(SoundOutputHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "appVolumes", title: "App Volumes", systemImage: "slider.horizontal.3", tint: .teal,
                                             category: .media, help: "Per-app volume"),
                           pinAction: { AppVolumeWindow.shared.show() }) { AnyView(AppVolumeHubTile()) },
            HubPackageTile(info: HubTileInfo(id: "lyrics", title: "Lyrics", systemImage: "quote.bubble.fill", tint: .pink,
                                             category: .media, help: "Synced lyrics"),
                           pinAction: { LyricsWindow.shared.show() }) { AnyView(LyricsHubTile()) },
```

Sound Output is a menu, so it has no pin action (it can't sit in the header).

### 11. NowPlayingActivityBridge.swift: live bars when music sits beside another activity

File: `Sources/Labs/Activities/NowPlayingActivityBridge.swift`. **Replace** this anchor (it occurs once):

```swift
                CompactLevelBars(isAnimating: media.isPlaying)
```

with:

```swift
                MediaLiveLevelBars(isAnimating: media.isPlaying)
```

Same as step 8 for the Activities package's Now Playing wings (music beside a timer or a call). Skip it if Labs/Activities isn't in the build yet; then those wings keep the decorative bars.

### 12. Info.plist: System Audio Recording purpose string

File: `Info.plist`. **Replace** this anchor (it occurs once):

```xml
	<string>SparkV listens to what your Mac plays while Ambient Light is on, so the notch can glow with your music. The sound is analyzed on this Mac and never recorded.</string>
```

with:

```xml
	<string>SparkV listens to what your Mac plays while Ambient Light or Live Level Bars are on, so the notch can glow and move with your music, and passes an app's sound through at the level you set in App Volumes. The sound is processed on this Mac and never recorded or sent anywhere.</string>
```

### 13. Info.plist: Bluetooth purpose string

File: `Info.plist`. **Replace** this anchor (it occurs once):

```xml
	<string>SparkV shows your AirPods and headphones' battery when they connect.</string>
```

with:

```xml
	<string>SparkV shows your AirPods and headphones' battery when they connect, and lists paired headphones in Sound Output so you can connect and switch to them.</string>
```

### 14. Info.plist: Apple Events purpose string (Music and Spotify)

File: `Info.plist`. **Replace** this anchor (it occurs once; it is the first sentence of `NSAppleEventsUsageDescription`, so the rest of that string is left as other packages wrote it):

```xml
SparkV reads the current track from Music and Spotify and sends play, pause and skip commands to them.
```

with:

```xml
SparkV reads the current track from Music and Spotify and sends play, pause and skip commands to them. When you ask, it also favorites the track, changes shuffle and repeat, adds the song to a Music playlist, reads lyrics saved in Music, and reads the Spotify track id so a connected Spotify account can save it.
```


## Settings window

The app-shell package builds the panes. Add the sections listed in the table above to the Media, System and Island panes. Each section is about 440 pt wide, has a card look, and uses native controls.

## Optional

- The HUD's output-device band could get `.contextMenu { SoundOutputMenuItems() }` too. It's a 2.5 s transient band, so it was left out.
- `MediaTicker` (Labs/Media) is still available for a 400 x 30 band.
