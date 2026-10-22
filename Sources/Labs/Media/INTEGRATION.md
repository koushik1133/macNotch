# Media: wiring steps for the lead

The media upgrade lives in `Sources/MediaEngine.swift` (already edited, compiles on its own) and `Sources/Labs/Media/` (new views and the bookmark store). No other file was touched.

The three steps below were applied by script to a snapshot of the current app (`scratchpad/round3/media/integ.py`) and typechecked clean in Swift 5 and Swift 6.

## What is new

| Piece | Where | What it does |
|---|---|---|
| `PlaybackTiming`, `MediaEngine.timing` / `elapsedTime` / `duration` / `canSeek` / `seek(to:)` / `skip(by:)` | MediaEngine.swift | Position is anchored as elapsed-at-timestamp plus rate, the MediaRemote model that boring.notch also uses. The adapter stream now runs with `--micros` so timestamps are exact. `seek` calls `mediaremote-adapter.pl seek <µs>` (MRMediaRemoteSetElapsedTime). If that fails, or when the adapter is down, it falls back to Apple Events `set player position` for Music and Spotify. It never asks for permission on its own. The scrubber moves at once, and stale reports are ignored for up to 2.5 s until the player confirms. |
| `MediaEngine.artworkTint` | MediaEngine.swift (`ArtworkPalette`) | A vibrant color taken from the artwork: hue buckets over a 32x32 thumbnail, weighted by saturation. Monochrome covers fall back to a soft neutral. |
| `MediaEngine.trackKey`, `sourceBundleID` | MediaEngine.swift | The bookmark identity: app, title and artist, normalized. |
| `MediaColumnV2` | Labs/Media/MediaColumnV2.swift | A drop-in replacement for `MediaColumn`. It shows the artwork with the app badge (click opens the app), a scrolling title and artist, ◀◀ ▶/❚❚ ▶▶ (one play/pause toggle) and a bookmark menu, with the scrubber underneath. It is sized for 170–180 x 69 pt. |
| `MediaScrubber` | Labs/Media/MediaScrubber.swift | A thin 3 pt bar interpolated at 30 fps in a `TimelineView` that pauses with playback. On hover it grows to 5 pt and gets a knob; drag or click to seek. Elapsed and remaining labels sit at each end. Bookmarks appear as ticks, and the pointer snaps to a tick within 6 pt, so clicking a tick jumps to it exactly. A live stream shows "LIVE". |
| `MediaBookmarkStore` | Labs/Media/MediaBookmarkStore.swift | A `.shared` store saved as JSON in `~/Library/Application Support/SparkV/MediaBookmarks.json`. Writes are atomic. A bookmark within 1.5 s of an existing one merges into it. An unreadable file is renamed aside rather than deleted. |
| `MarqueeText` | Labs/Media/MarqueeText.swift | One line that scrolls when it doesn't fit: it rests for 2 s, then glides at 30 pt/s with eased start and stop, and wraps seamlessly. Edges fade. It honors Reduce Motion, and long Telugu titles no longer end in "…". |
| `MediaGlowBackground` | Labs/Media/MediaGlowBackground.swift | Album-art glow in two styles: `.drawer` (a bloom on the artwork plus a wash along the bottom edge) and `.pill`. It dims while paused, crossfades between tracks and never takes clicks. |
| `MediaTicker` | Labs/Media/MediaColumnV2.swift | An optional "Title · Artist" marquee with tiny artwork and a 2 pt progress line, for a 400 x 30 activity band. |

Bookmark menu, using the bookmark icon to the right of ▶▶:
- **Bookmark This Moment**
- **Bookmark with Note…**: an inline field replaces the transport row. Return saves and Esc cancels.
- **Jump To** (the list)
- **Remove** (one bookmark, or all for this track)

The icon fills once the track has bookmarks and bounces when one is saved.

## 1. build.sh

Add this next to the other `Labs` copies:

```zsh
cp Sources/Labs/Media/*.swift "$WORK/src/"
```

## 2. NotchNookLayoutView.swift: swap the column

In `FeaturesGrid`, replace this:

```swift
            MediaColumn()
                .frame(width: 180, alignment: .leading)
```

with this:

```swift
            MediaColumnV2()
                .frame(width: 180, height: 69, alignment: .leading)
```

The old `MediaColumn` and `MediaButton` become unused private types. Delete them whenever convenient; leaving them produces no warning.

## 3. NotchNookLayoutView.swift: the glow

In `NotchNookLayoutView.body`, insert the glow directly after `shape.fill(Color.black)`. That puts it above the black fill and below all content, and the existing `.clipShape(shape)` keeps it inside the island:

```swift
        ZStack(alignment: .top) {
            shape.fill(Color.black)

            // Album-art glow (boring.notch style), under all content.
            if state.isExpanded, state.tab == .nook {
                MediaGlowBackground(center: UnitPoint(
                    x: (16 + radii.top + MediaColumnV2.artworkSide / 2) / (size.width + 2 * radii.top),
                    y: (state.collapsedSize.height + MediaColumnV2.artworkSide / 2) / size.height
                ))
                .transition(.opacity)
            } else if !state.isExpanded, wingsSource == .nowPlaying {
                MediaGlowBackground(style: .pill, center: UnitPoint(
                    x: (radii.top + 22) / (size.width + 2 * radii.top),
                    y: 0.5
                ), intensity: 0.8)
                .transition(.opacity)
            }
            ...
```

The `.drawer` center is the artwork's center: 16 pt padding plus the flare plus half of the 48 pt artwork, under the 38 pt header. The pill halo sits behind the leading artwork wing. Drop the `else if` branch if you want the closed pill to stay pure black.

## Optional

- **Compact pill marquee.** `DictationActivityView.swift` already has `CompactMarquee`, which sizes itself to its text. Keep it there, because the wing width depends on that. Use `MarqueeText` wherever the width is fixed by the layout.
- **Activity band.** `MediaTicker()` fits a 400 x 30 band (`NotchActivityView`), for example for a "now playing" peek.
- **Keyboard skip.** `media.skip(by: ±15)` is ready if you want ←/→ shortcuts while the drawer is open.

## Nothing else changes

- No new environment objects: views use the existing `MediaEngine` and `MediaBookmarkStore.shared`.
- No new permissions or entitlements. Seeking through the adapter needs nothing extra, and the Apple Events fallback only runs when Automation is already granted.
- The new adapter flag `--micros` takes effect when the app next launches. A stream already running from the previous build is reaped by the existing orphan check, because its pkill pattern still matches.

## Validator fixes (no wiring change)

- `MediaEngine`: a pause and a resume that both arrive without a new position (some web players) no longer jump the scrubber back to the old anchor.
- `MediaEngine`: an adapter seek the player ignores (MRMediaRemoteSetElapsedTime has no result, and the adapter only reports changes) now falls back to the player's last reported position after 2.6 s, instead of leaving the scrubber at the optimistic spot. A seek that lands a little off target (keyframe snapping) shows the real position after the same window.
- `MediaColumnV2`: "Bookmark with Note…" makes the island panel key, so typing goes straight into the note field without an extra click.
- `MediaScrubber`: VoiceOver reads "1:23 of 3:35" and can adjust ±10 s.
