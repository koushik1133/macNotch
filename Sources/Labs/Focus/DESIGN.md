# Focus mode: design note

One tap (header moon, Agents hub tile, gear menu) starts a focus session. The session:

- mutes notifications (macOS Do Not Disturb through the user's Shortcuts, plus SparkV's own previews),
- runs Pomodoro-style rounds on `TimerController`,
- shows a "Focusing 18:42" band under the notch,
- puts a calm overlay over apps and sites the user listed as distractions,
- ends with a recap: time focused, apps, documents, and what SparkV captured during the session. The on-device model writes the recap, and the session is saved with today and week stats.

## How production apps do it

| Topic | What working tools do | Source |
|---|---|---|
| Muting other apps | Since macOS 12 there is no public API to set a Focus. `INFocusStatusCenter` can only *read* the status, and only for apps with the Communication Notifications capability. Session's current guide has the user make Shortcuts named `session_start` and `session_end`, each with **Set Focus** (Do Not Disturb On or Off). Session runs them when a session starts and ends. Tuple's trigger directory uses the same idea with shortcuts named `dnd-on` and `dnd-off`. Session's older AppleScript method, which presses a global keyboard shortcut, is marked as superseded for macOS 11 and later. Writing `~/Library/DoNotDisturb/DB/*.json` does not change the Focus. | stayinsession.com/learn/apple-focus-with-session-shortcuts, stayinsession.com/learn/do-not-disturb-on-mac, tuple.app/triggers/directory/do-not-disturb, talk.automators.fm "Get current focus mode via script", developer.apple.com INFocusStatus |
| Distraction blocking | Raycast Focus (v1.89, 2025) starts a session with a goal, a duration, and apps and websites to block. Blocked items can be grouped into categories, and the user can **snooze** the block for an urgent message. Blocking is an overlay, not a kill. | raycast.com/changelog/macos/1-89-0, Raycast Focus launch notes |
| Pomodoro | 25-minute focus and 5-minute break by default, with a long break after 4 rounds. SparkV's `TimerController` already uses these values. | `TimerController.swift` (`Pomodoro`) |

## Decisions

1. **Do Not Disturb = two user-created Shortcuts** (`SparkV Focus On` and `SparkV Focus Off` by default, each with Set Focus › Do Not Disturb), run through the existing `ShortcutRunner` (`/usr/bin/shortcuts run`).
   - The settings window reads the library (`shortcuts list`), shows a 4-step guide, opens Shortcuts (`shortcuts://create-shortcut`), and has Test On and Test Off buttons.
   - If one of the common pairs other guides use (`dnd-on`/`dnd-off`, `session_start`/`session_end`, …) already exists, it is adopted automatically.
   - A missing shortcut is never run. The session still starts and shows a notice.
   - "Off" runs only if "on" succeeded during this session. That fact is saved in `active.json`, so a relaunch or crash still turns DND off at the end.
   - No system preference files are touched.
2. **SparkV's own previews are always muted.** `NotificationMonitor.isEnabled` is set to false at the start and restored at the end, but only if it was on before.
3. **Pomodoro reuses `TimerController`.** Focus keeps its own date-based `FocusSchedule` as the source of truth (focus, short break, long break, rounds, pause, +5 min, skip) and mirrors each phase into `TimerController.startTimer(minutes:)`. As a result the Today tab, the end chime and the scheduled notification all follow the session.
   - Pausing or resuming the timer from Today pauses or resumes Focus.
   - If the user starts a different timer, Focus keeps running without the mirror.
   - A countdown the user already had running when a phase starts is never taken over or reset. Focus then keeps time on its own and plays the chime itself.
   - The Focus band has priority 21, just above the timer's 20, so only one band shows.
   - The session ends after the last focus round. There is no trailing break; the summary offers a break instead.
4. **Activity tracking:**
   - `NSWorkspace.didActivateApplicationNotification` tracks the frontmost app.
   - With Accessibility already granted, the focused window's `AXDocument` (file name) or `AXTitle` is polled every 5 s, with a 0.25 s AX messaging timeout.
   - Window titles are never read from password managers or Keychain Access.
   - Only focus phases are counted. Breaks and pauses are not.
   - Nothing is prompted, and titles are never logged.
5. **Things captured during the session** (Flow dictations and notes, Tray items, meeting notes, Space items) are taken by sampling the existing stores every 5 s. An item counts only if its id wasn't there at the start.
   - The Tray holds only 5 items, so sampling catches items that are later evicted.
   - Space items keep their source's own date, so the id rule is what decides for them.
6. **Distractions.**
   - Apps are matched by bundle id.
   - Sites are matched by the front tab's host, read with the same AppleScript (`SpaceConnectors.Browser.tabScript`) and serial queue (`SpaceAppleEvents`) that Spaces uses. The tab is read every 2 s, and only while a supported browser is in front. The check never prompts; "Allow Site Checks in Browsers…" asks once, from a click.
   - The overlay is a non-activating panel just under the notch panel, over full-screen apps too. It offers Back to Work (returns to the last work app, or hides the distracting app or browser, never quits it), N More Minutes (snooze), and End Focus.
   - When a snooze runs out, the front app is checked again, so a snoozed app that is still in front gets the reminder again, as in Raycast Focus.
   - A site that comes back within a minute counts as the same distraction in the recap.
7. **Recap.**
   - An instant template version is shown first.
   - Then `MeetingAIBackend.onDevice` (FoundationModels, permissive guardrails for the user's own content, 180 tokens, 25 s timeout) rewrites it from names and counts only. Titles are clipped to 50 characters.
   - No network is used, so no Groq toggle is needed.
   - The template stays when the model is unavailable.
8. **Storage.** `~/Library/Application Support/SparkV/Focus/sessions.json` holds the last 500 sessions, with ISO dates. `active.json` holds the running session with exact dates, which lets it resume after a relaunch. A session that ran out while SparkV was closed is wrapped up at its planned end the next time SparkV launches.

## Screen effects

When focus starts, a break starts, or the session ends, a glowing border lights up the screen. The approach follows the edge light macOS 15 draws for Siri: a rounded-rect stroke filled with a slowly turning conic gradient, a wide blurred copy of it for the bloom, and a brief colour wash from the edges.

- **Window:** One borderless, click-through, non-activating panel per screen, at `.statusBar` level and ordered under the island. It is excluded from screen capture.
- **Kick:** A decaying 0.6 s wobble with a slight squeeze, shared by the border and the notch band (`FocusGlowTiming`), plus an optional haptic tap.
- **Colours:** Focus is blue and violet, the break is green and amber, and the end uses every colour, with confetti from the top edge when a session is completed.
- **Reduce Motion:** The border only fades.
- **Cost:** All animation is Core Animation, so it runs on the render server. The masks are blurred once at a low resolution, and the subtle mode runs at about 15 fps.

## Header footprint

Measured on the target 16-inch MacBook Pro, `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea` put the camera housing at 185 pt wide. That leaves 145.5 pt on each side of the 476 pt header. `FocusHeaderButton` therefore keeps the 24 x 22 pt IconTab footprint in every state. While running, it shows a progress ring around the moon instead of a wider time pill. The time is in its tooltip, its menu, the band and the hub tile.

## Not vendored

Nothing was copied. The approaches above are re-implemented with SparkV's own `ShortcutRunner`, `TimerController`, `SpaceAppleEvents` and `MeetingAIBackend`. No third-party code, assets or brand marks are used, and all icons are SF Symbols.
