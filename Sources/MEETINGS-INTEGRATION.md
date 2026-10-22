# Meetings: calendar peek and Join (integration notes)

Files: `MeetingsController.swift`, `MeetingsView.swift` (and the unchanged
`MeetingCapsuleView.swift`). Approach copied from MeetingBar
(leits/MeetingBar: `MeetingProvider.swift` regex catalogue, `MeetingOpener.swift`
for zoommtg:// and slack://join-huddle), with the Dynamic Island compact and
expanded forms from `LiveActivity`.

## What works with no wiring

- **Link detection**: Zoom (zoom.us, zoom.com, zoomgov, personal rooms,
  webinars, `zoommtg://`), Google Meet, Microsoft Teams (`/l/meetup-join/`,
  `/meet/<id>?p=`, teams.live.com, gov, `msteams:`), Webex, Slack huddles
  (`slack://join-huddle`), FaceTime, Around, Whereby. Outlook Safe Links and
  Google `url?q=` redirects are unwrapped. The event URL is checked first,
  then location, then notes.
- **Join** opens the app's own link when an app handles it (zoommtg://,
  msteams:, slack://), otherwise https in the default browser.
- **Peek**: from the heads-up time (1, 5, 10 or 15 min, default 10) before a
  meeting, `ActivityCenter` gets a persistent `.meeting` activity. It peeks in
  the band ("Standup  in 4 min  [Join]" with the app icon) and then rests in
  the wings (icon, "4 min"). From 1 min before until 5 min after the start it
  is `urgent` (the band stays out) with a green "Now" and Join. Hovering it
  opens the Today tab (`opensTab: .today`).
- **Today rows**: "Now" / "in 7 min" / time, title, Join (with the app's icon),
  and the existing Notes pill that starts meeting notes.
- **Join Next Meeting** on ⌃⌥J (Carbon hotkey via `ScreenRegionHotkey`, no
  permission needed; on by default, `meetings.joinShortcut`). It picks the
  meeting in its "Now" window, else one starting within 15 min, else one still
  running, else the next one today, and shows "Joining Standup on Zoom" (or
  "No meeting with a call link today") under the notch.
- After the user joins (row button or ⌃⌥J), that meeting's "Now" band stops
  being urgent and rests in the wings (icon + green "Now"), so it no longer
  covers the space under the notch.
- Calendar access granted elsewhere (the onboarding Permissions step, System
  Settings) is noticed within 5 s: while access isn't granted the controller
  re-reads `EKEventStore.authorizationStatus` every 5 s and starts
  monitoring on its own (no need to open the Today tab first).
- Declined, all-day, cancelled and "free" events are skipped.
- Settings are stored in `meetings.enabled`, `meetings.leadMinutes`,
  `meetings.joinShortcut`.

## Wiring for the integrator

1. **Settings menu** (`NotchNookLayoutView.swift`, `SettingsMenu`,
   inside `Menu("Meetings") { … }`, after "Meeting Notes…"): add

   ```swift
   Divider()
   MeetingsMenuItems(controller: meetings)
   ```

   `meetings` is the `MeetingsController` environment object `SettingsMenu`
   already has. This adds "Join Standup (Zoom)  ⌃⌥J", a "Heads-Up Before
   Meetings" picker (1/5/10/15 minutes) and a "Join Shortcut ⌃⌥J" toggle.

2. **Anywhere without the environment** (App Intents, a status item):
   `MeetingsController.current?.joinNextMeeting()`.

3. **Clicking Join in the band itself**: the panel ignores mouse events while
   collapsed and hovering the band opens the drawer, so the band's Join pill
   is a visual cue; the click lands on the Today row's Join (same place in the
   list, first row) or ⌃⌥J. No change is needed for that. If the band should
   ever take clicks, `NotchWindowController` would have to stop expanding on
   hover for `kind == .meeting`; not recommended.

No other file needs to change. `LiveActivity.swift` was not edited; this
code uses its `urgent`, `symbol`, `tint`, `compactText`, `peekKey`,
`.compact(leading:trailing:)` and `.minimal` API.
