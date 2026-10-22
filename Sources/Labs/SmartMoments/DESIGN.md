# Smart Moments

SparkV notices a moment (a call starts, a screen share begins, a download lands) and
offers a one-tap bundle of helpful actions in a notch band. Every moment and
every action can be turned on or off in Settings › Smart Moments. Each moment
also has **Ask first** (the default) or **Do automatically**.

Contracts live in `SmartMomentsModels.swift`. Wiring is in `INTEGRATION.md`.

## Research notes (what we borrowed, what we avoided)

| Product | Idea it gives Smart Moments | What we do differently |
|---|---|---|
| Apple Shortcuts personal automations (macOS Tahoe) | Event triggers: app open/quit, Focus on/off, Wi-Fi/Bluetooth/display connected, battery level, charger, file added to a folder. Each one can **Run Immediately** or **Run After Confirmation**. | Same two modes per moment (`ask` / `automatic`), but with a bundle of actions instead of a script, and every action has its own checkbox. |
| Focus filters | A Focus changes what apps show (only work calendars, a work Safari tab group). | Moments call `FocusController` and `ModeEngine` (DND, notification previews, modes) and **put back** only what they changed. |
| Raycast (My Schedule, Focus) | Next meeting at the top with Enter to join. Auto-join is **off by default** and shows a confirmation alert even when on. Focus sessions start from deeplinks or shortcuts. | Join is always a tap. Auto mode never joins, records or opens a call. |
| MeetingBar | Next meeting in the menu bar, one-click join, a shortcut to join the next meeting, an AppleScript hook to e.g. pause music when a meeting starts. | "Pause music on meeting start" is a built-in action with an automatic resume on meeting end. |
| Granola | A pop-up 1 minute before a calendar meeting (only events with 2+ attendees). Clicking it opens the call and notes and starts transcribing. Spots calls that aren't on the calendar from microphone use (Slack huddles, FaceTime). Notifications can be turned off per app. | MeetingDetector does the call detection. Smart Moments asks before any recording starts, and keeps the recording indicator visible. Per-app opt-out = per-moment toggle. |
| Krisp | Noise cancellation on during calls. | Out of scope (no audio processing). We check the mic, camera and AirPods battery before the call instead. |
| Muzzle / Zoom "block notifications while sharing" | Silences notifications only during screen sharing, zero cost when not sharing. Muzzle's known gap: no per-app control. | The screen-sharing moment hides notification previews **and** SparkV's own clipboard band, pauses music, and puts everything back when sharing stops. |
| Hazel / Keyboard Maestro Folder trigger | Watch Downloads. Wait until the download or copy completes. Sort by file type and leave unmatched files tagged for review. | Uses `DownloadsController`'s finished items and its suggested folder. Never moves a file without a tap unless the user turned on auto-sort there already. |
| Keyboard Maestro / BetterTouchTool | Triggers on app activation, device attach, clipboard change, named triggers. | Clipboard moment reads `ClipboardController`'s detected kind (link, code). App activation feeds the deep-work and presentation moments. |
| Fantastical | Join button on the upcoming-meeting alert. | The 2-minute moment has Join as its first chip. |

Sources: [MacMost: Shortcuts automation in macOS Tahoe](https://macmost.com/an-introduction-to-shortcuts-automation-in-macos-tahoe.html),
[Granola notifications](https://docs.granola.ai/help-center/taking-notes/notifications),
[Raycast calendar manual](https://manual.raycast.com/calendar),
[Raycast 1.94 changelog](https://www.raycast.com/changelog/1-94-0),
[MeetingBar README](https://github.com/leits/meetingbar),
[How-To Geek: hide notifications while screen sharing](https://www.howtogeek.com/714118/how-to-hide-notifications-while-sharing-your-screen-in-a-video-call/),
[Keyboard Maestro Folder trigger](https://wiki.keyboardmaestro.com/_export/raw/trigger/Folder),
[MPU: Hazel rule examples](https://talk.macpowerusers.com/t/hazel-rule-examples/3308/18).

## Engine rules (apply to every moment)

1. **One band at a time.** A new offer replaces a lower-priority one. Higher
   priority waits in a queue of at most 3 and is dropped once it is stale
   (`expiresAfter`). Priority: lowBatteryRecording > meetingSoon >
   meetingStarted > screenSharing > meetingEnded > presentation > the rest.
2. **Ask first by default.** The band shows the moment title, one line of
   context, and a chip per enabled and available action. Chips start selected
   as configured in Settings. **Do it** runs the selected chips. **Not now**
   dismisses it. **Snooze** silences this moment for the rest of the day.
   Long-press or ⌥-click a chip runs only that chip.
3. **Do automatically** runs the enabled actions without asking and shows a
   short "Done: paused music, DND on · Undo" band for 6 s. **Consent actions
   are never run automatically.** Recording notes, live captions and
   translated captions are marked `needsConsent`. In auto mode they stay in
   the band as chips to tap. The only exception is when the user already turned on
   MeetingAssistant's own "Start recording automatically", which is consent
   that MeetingAssistant owns, not Smart Moments. Chips that open a window,
   a file, a link or the camera also stay chips, and so does any action a
   moment marks not auto-eligible for that trigger (`hooks.autoEligible`,
   e.g. a download sorted by an AI pick, Presentation mode on a new display).
4. **Never hide, quit or close apps.** No action does this. `ModeEngine`
   modes that include `hideApps` / `quitApps` are not started by a moment.
   Presentation mode uses a SparkV-safe mode, or only the DND and preview
   actions.
5. **Undo / restore.** Every action that changes system state has a
   `reversal` (pause music ↔ resume, DND on ↔ off, previews hidden ↔ shown,
   clipboard band hidden ↔ shown). The engine keeps a `MomentRestoreLedger` of
   what *it* changed. The matching end moment (meeting ended, sharing stopped,
   presentation ended) reverses only those entries. If the user changed the
   setting again in between (the music is already playing, DND was turned off
   by hand), nothing is touched.
6. **Permissions** go through `PermissionCenter` only. An action whose
   permission is missing shows as a dimmed chip "Allow camera". Tapping it
   calls `PermissionCenter` (respecting its launch-quiet period and settings
   cooldown). Auto mode skips it silently and never prompts for a permission.
7. **Cooldowns.** Each moment has a cooldown (`defaultCooldown`) keyed by the
   trigger's `dedupeKey` (the same meeting, file or app is offered once).
   A dismissal counts as handled. After 3 dismissals in a row the band adds
   "Turn off this moment?".
8. **Quiet conditions.** No offers during screen sharing except the
   screen-sharing moment itself and low battery. No offers while
   SparkV's own capture window is open. The clipboard and screenshot moments are
   off during screen sharing so copied content is never shown on a shared
   screen.
9. **Recording indicator.** Any action that starts mic or screen capture goes
   through MeetingAssistant / ScreenRecorderController, which keep their red
   indicator. Smart Moments never draws a recording state of its own.
10. **Nothing leaves the Mac** because of a moment. Actions that may use the
    cloud (Groq for captions, AI summaries) use the owning controller's
    existing opt-in (`allowGroq`, `allowGroqForMeetings`).
11. **Coordination with MeetingIntel.** For meeting moments the engine asks
    the `MeetingIntelBridge` (set in wiring) first. If MeetingIntel shows its
    own call-start prompt (notes, captions, brief), Smart Moments does
    not show a second band. It runs only its non-meeting-intel actions (pause
    music, DND, previews, mirror off), folded into MeetingIntel's prompt
    through `bridge.contribute(...)`, or silently in auto mode. Without a
    bridge, Smart Moments falls back to MeetingAssistant
    (`startDetectedCall`) and LiveTranslationController. MeetingAssistant's
    own `promptedCall` band is suppressed while a Smart Moments meeting
    offer is visible (see `INTEGRATION.md`).

## The moments

Each moment has a symbol, a default (all moments default to **on** and **Ask
first** unless noted), its actions (each a toggle, ☑ = on by default,
☐ = off by default), and its safeguards.

### 1. Meeting in 2 minutes `meetingSoon`
- **Trigger:** `MeetingsController` has a meeting with a link that starts in
  ≤ `meetingLeadMinutes` (default 2). Fired once per occurrence (`meeting.id`).
- **Offer:** "Standup in 2 min · Google Meet" with a big Join chip.
- **Actions:** ☑ Join (opens `meeting.link`) · ☑ Check yourself (opens the
  camera mirror) · ☑ Check mic, camera and AirPods (a strip showing mic
  permission and input device, camera availability, AirPods battery from
  PowerMonitor) · ☑ Agenda brief (MeetingIntel brief if present, else the
  event notes).
- **Safeguards:** Join is never automatic, even in auto mode. The mirror
  closes when the call starts if `mirrorOff` is on in Meeting started. The
  camera only runs while the mirror is visible. AirPods under 20 % show a
  warning chip.

### 2. Meeting started `meetingStarted`
- **Trigger:** `MeetingCallDetector` `.started(DetectedCall)` (Meet, Zoom,
  Teams, FaceTime, Slack…).
- **Offer:** "On a Zoom call · Design review". Chips are listed below.
- **Actions:** ☑ Record notes (MeetingAssistant.start) · ☑ Live captions ·
  ☐ Translate captions (LiveTranslation, target language from its settings) ·
  ☑ Pause music · ☑ Do Not Disturb · ☑ Hide notification previews ·
  ☑ Turn mirror off.
- **Safeguards:** Recording and both caption actions are consent actions, so
  they are never automatic. The band says "Let participants know you're
  recording". The coordination rules with MeetingIntel apply (rule 11).
  A call SparkV started recording itself is ignored.

### 3. Meeting ended `meetingEnded`
- **Trigger:** `.ended(DetectedCall)`.
- **Offer:** "Call ended · 34 min".
- **Actions:** ☑ Notes wrap-up (open the notes window or summary, shown only
  if notes were recorded) · ☑ Resume music · ☑ Do Not Disturb off ·
  ☑ Show notification previews.
- **Safeguards:** Reversals apply only to what the ledger says the start
  moment changed. If nothing was changed and nothing was recorded, no band
  appears. **Auto by default** for the reversal actions, since putting things
  back is what users expect. The wrap-up is a chip.

### 4. Screen sharing started `screenSharing`
- **Trigger:** a screen-capture app other than SparkV starts sharing
  (Zoom/Meet/Teams share, QuickTime, OBS, detected through the
  screen-capture indicator / `CGWindowList` sharing state reported in wiring).
  It ends when sharing stops.
- **Offer:** "Sharing your screen".
- **Actions:** ☑ Hide notification previews · ☑ Hide clipboard band
  (pauses `ClipboardController` banners, not history) · ☑ Pause music ·
  ☐ Do Not Disturb.
- **Safeguards:** **Auto by default** (the Muzzle pattern; hiding is the safe
  side). All of it is reversed when sharing ends. While sharing, every
  content-showing moment (clipboard, screenshot, download preview) is
  suppressed.

### 5. Low battery while recording `lowBatteryRecording`
- **Trigger:** battery ≤ `lowBatteryPercent` (default 15) on battery power
  while MeetingAssistant or ScreenRecorder is recording.
- **Offer:** "Battery 12 % · Your recording is still going". Urgent
  presentation.
- **Actions:** ☑ Save recording now (stops and saves safely) · ☑ Show
  time left · ☐ Turn on Low Power hint (opens Battery settings).
- **Safeguards:** Never stops a recording automatically. Fires again once at
  5 %. It ignores cooldowns and the quiet conditions.

### 6. Download finished `downloadFinished`
- **Trigger:** DownloadsController moves an item to finished.
- **Offer:** "invoice.pdf · Sort into Documents/Invoices?"
- **Actions:** ☑ Sort (the suggested folder, undoable) · ☑ Open · ☑ Show in
  Finder · ☐ Add to Tray · ☐ Send to Space.
- **Safeguards:** Defers to DownloadsController when its own activity band is
  on (no double band). It never moves a file automatically unless the user
  turned on Do automatically and the suggestion came from a rule, not from AI.
  Send to Space is user-initiated only.

### 7. Deep work `deepWork`
- **Trigger:** the same frontmost app (Xcode, Figma, VS Code, Pages…) for
  ≥ `deepWorkMinutes` (default 45) with input activity, no Focus session
  active, no call.
- **Offer:** "45 min in Xcode · Protect this flow?"
- **Actions:** ☑ Start a Focus session (FocusController) · ☑ Do Not
  Disturb · ☐ Pause music.
- **Safeguards:** Once per app per day. Browsers, Mail and Messages are
  excluded by default. Never blocks apps or sites on its own; FocusController's
  blocker follows its own settings.

### 8. Late night `lateNight`
- **Trigger:** after `lateNightHour` (default 23:00) and still active
  for 10 min.
- **Offer:** "It's late · Switch to Night mode?"
- **Actions:** ☑ Night mode (a ModeEngine mode named in Settings, default the
  built-in Night/Wind-down preset) · ☐ Lower brightness · ☐ Start a
  15-minute wind-down timer.
- **Safeguards:** Once per night. **Off by default.** Never applies a mode
  with hide or quit actions.

### 9. Presentation `presentation`
- **Trigger:** Keynote or PowerPoint enters play mode, or any app goes
  fullscreen on an external display or projector.
- **Offer:** "Presenting · Keynote".
- **Actions:** ☑ Presentation mode (DND, hide previews, pause music; or a
  ModeEngine mode the user picks) · ☑ Hide SparkV notch activities except
  the timer · ☐ Start a talk timer.
- **Safeguards:** **Auto by default** when Keynote/PowerPoint play mode is
  detected. Ask first for generic fullscreen (videos and games are often
  fullscreen too). Reversed when the presentation ends.

### 10. Copied code or link `copiedSmart`
- **Trigger:** ClipboardController records a link or code snippet (its
  content detector).
- **Offer:** a compact band: "Link copied · github.com".
- **Actions:** ☑ Open link · ☑ Clean link (removes utm_ and tracking
  parameters, then copies again) · ☐ Copy as Markdown link · ☑ Format code
  (trim and re-indent) · ☐ Send to Space.
- **Safeguards:** **Off by default** (it can get noisy). Never during screen
  sharing. Never for password-manager copies or concealed pasteboard types
  (ClipboardController already skips them). Never sends the content anywhere.

### 11. Screenshot taken `screenshotTaken`
- **Trigger:** a new file in the screenshot location (`com.apple.screencapture`
  location, default Desktop) or ScreenRegion capture.
- **Offer:** a thumbnail band.
- **Actions:** ☑ Copy image · ☑ Annotate (opens Markup / Preview) · ☑ Send to
  Space · ☐ Add to Tray · ☐ Extract text (local OCR).
- **Safeguards:** Never during screen sharing. Never uploads. Only Send to
  Space moves the file, and only on a tap.

### 12. External display connected `displayConnected`
- **Trigger:** a new display connects.
- **Offer:** "Connected to LG UltraFine".
- **Actions:** ☑ Hide notification previews · ☐ Presentation mode ·
  ☐ Move the notch island to this display.
- **Safeguards:** **Off by default.** Never changes display arrangement or
  resolution.

## Settings UI (Settings › Smart Moments)

- Master switch: "Smart Moments" (on).
- One row per moment: symbol, title, one-line trigger description, an on/off
  toggle, and a segmented control **Ask first | Do automatically**. Expanding
  the row shows each action as a checkbox with its permission state ("Needs
  camera access · Allow") and, for consent actions, the note
  "Always asks, records audio".
- Tunables under each moment where it applies: lead minutes (1–10), deep
  work minutes (20–120), late-night hour, low-battery percent, Night mode
  pick, Presentation mode pick.
- "Reset Smart Moments" puts back the defaults.

## Look

The band uses SparkVTheme tokens only. Its ground is `islandBackground`, chips
are `surface` with a `stroke` hairline, and a selected chip is `accentSoft`
with `accent` text (blue in Apple, signal red in SparkV Red). Consent chips
carry a small `recording`-red dot. The moment symbol sits in a circle tinted
with the moment's tint. Done/Undo toasts use `success`. The band is
compact-first, with a leading symbol and a trailing "3 actions" count, and
expands on hover.
