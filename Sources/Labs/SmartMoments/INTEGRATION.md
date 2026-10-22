# Smart Moments: wiring

Everything Smart Moments needs from the app is in `SmartMomentsWiring.swift`
(engine, live sources, band presenter, and one hook per action, each calling
the controller that owns it). The app only creates it, starts it, stops it,
and shows its menu. The edits below are exact. They were applied to a copy of
the app's sources and typechecked under Swift 6 and Swift 5 (no errors).

Files: `SmartMomentsModels.swift` (contracts), `SmartMomentsEngine.swift`
(`SmartMomentsController`), `engine-Detectors.swift` (trigger rules),
`engine-LiveSources.swift` (system observers), `SmartMomentsWiring.swift`
(app wiring and hooks), `SmartMomentsViews.swift` (band, toast, menu, hub
tile), `ui-SmartMomentsSettings.swift` (Settings window), and one
`moment-<Name>.swift` per moment (MeetingSoon, MeetingStarted, MeetingEnded,
Presentation, ScreenSharing, DownloadFinished, ScreenshotTaken), each with a
`<Name>Moment.install(on:deps:)`. All seven are installed by
`SmartMomentsWiring.installMoments()` (§6), so the app-side edits are only
§1-§5 below.

## 1. build.sh

After the line `cp Sources/Labs/CloudSync/*.swift "$WORK/src/"` add:

```sh
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
```

## 2. NotchWindowController.swift

### 2a. Property

After `private let downloads: DownloadsController` add:

```swift
    private var smartMoments: SmartMomentsWiring?
```

### 2b. Create it

Right after `super.init(window: panel)` (before the root view is built, so
the gear menu finds it) add:

```swift
        smartMoments = SmartMomentsWiring(app: SmartMomentsAppControllers(
            media: media, camera: camera, screenDistance: screenDistance, activities: activities,
            power: power, timer: timer, meetings: meetings, notifications: notifications,
            meetingAssistant: meetingAssistant, liveTranslation: liveTranslation,
            screenRecorder: screenRecorder, clipboard: clipboard, focus: focus, downloads: downloads,
            screenshotClipboard: screenshotClipboard, tray: tray,
            openTab: { [weak self] tab in
                self?.state.select(tab)
                self?.setExpanded(true)
            }
        ))
```

### 2c. Start it

At the end of `init()`, after
`FanController.shared.connect(activities: activities, opensTab: .fans)` add:

```swift
        // After the meeting assistant, downloads and clipboard started: it
        // chains onto their events.
        smartMoments?.start()
```

`start()` installs the shared hooks and then every moment (§6). Nothing else
per moment goes in NotchWindowController (only §4's MeetingIntel lines once
that lab is built).

### 2d. Stop it

In `tearDown()`, right before `downloads.stop()` add:

```swift
        smartMoments?.stop()
```

### 2e. Quit: put back what is in effect

Replace

```swift
        (screenRecorder.phase != .idle && screenRecorder.phase != .selecting)
            || ModeEngine.shared.activeModeID != nil
```

with

```swift
        (screenRecorder.phase != .idle && screenRecorder.phase != .selecting)
            || ModeEngine.shared.activeModeID != nil
            || (smartMoments?.hasWorkToFinishBeforeQuit ?? false)
```

and in `finishWorkBeforeQuit(timeout:)`, right after
`screenRecorder.stop()   // recording: stop and save; ...` add:

```swift
        // Do Not Disturb, previews and presentation mode go back before quitting.
        await smartMoments?.prepareForQuit()
```

## 3. Gear menu (NotchNookLayoutView.swift)

After the line `Menu("Modes") { ModesMenuItems() }` add:

```swift
            if let smartMoments = SmartMomentsWiring.current {
                SmartMomentsMenu(settings: smartMoments.settings)
            }
```

The submenu has the master switch, one switch per moment (by group) and
"Smart Moments Settings…", where each moment and each action is turned on or
off and set to Ask first or Automatic.

## 4. MeetingIntel (when Sources/Labs/MeetingIntel is built)

MeetingIntel shows its own call prompt (record notes, captions, translate,
with the brief). Smart Moments then keeps only the other chips (pause music,
Do Not Disturb, hide previews, mirror off) in its band, so nothing is offered
twice. Without this step Smart Moments offers Record notes and captions itself
(through MeetingAssistant and Live Translation) and hides MeetingAssistant's
own "Notes?" prompt while its band offers them.

After MeetingIntel's own §6 lines in `init()` (once `meetingIntel` exists) and
after 2b above, add:

```swift
        let intelStart = meetingIntel.coordinator
        smartMoments?.connectMeetingIntel(SmartMomentsMeetingIntelLink(
            wantsOffer: { [weak intelStart] call in intelStart?.wantsOffer(for: call) ?? false },
            start: { [weak intelStart, weak meetingAssistant] action in
                guard let intelStart, let assistant = meetingAssistant else { return .failed("Unavailable") }
                if let session = intelStart.session {
                    var plan = session.plan
                    switch action {
                    case .liveCaptions: plan.captions = true
                    case .translateCaptions: plan.captions = true; plan.translate = true
                    default: return .skipped("Already recording")
                    }
                    intelStart.changePlan(plan)
                    return .done(action == .translateCaptions ? "Translating captions" : "Captions on")
                }
                let plan: MeetingStartPlan = switch action {
                case .recordNotes: .notes
                case .translateCaptions: .translated
                default: .captionsOnly
                }
                intelStart.choose(plan, remember: false)
                return assistant.isRecording ? .done("Recording") : .skipped("Starting in MeetingIntel")
            }
        ))
```

### 4b. MeetingIntel extras for the moments

Also when MeetingIntel is built: right after 2b (before `smartMoments?.start()`
in 2c, because `start()` installs the moments), add the lines below. Meeting
soon's Agenda brief then shows MeetingIntel's brief (falling back to the
invite notes), and Meeting ended's wrap-up chip opens MeetingIntel's wrap-up.
Without them each moment uses its own fallback.

```swift
        smartMoments?.meetingIntelExtras = SmartMomentsMeetingIntelExtras(
            meetingBrief: { [weak meetingAssistant] meeting in
                guard MeetingIntelPreferences.shared.showBrief, let assistant = meetingAssistant else { return nil }
                let brief = await MeetingBriefBuilder.build(
                    title: meeting.title, calendarEventID: meeting.eventID, event: meeting,
                    library: assistant.library, spaces: SpaceStore.shared,
                    calendarGranted: PermissionCenter.shared.isGranted(.calendars), now: Date()
                )
                let lines = brief.bandLines(max: MeetingSoonMoment.briefLineLimit).map(\.text)
                return lines.isEmpty ? nil : lines
            },
            openWrapUp: { MeetingWrapUpController.current?.openWindow(meetingID: $0) },
            presentWrapUp: { MeetingWrapUpController.current?.present(meetingID: $0, session: nil, sidecar: nil) }
        )
```

For the call-start prompt itself use the `MeetingStartedMoment.current?.connect(...)`
lines in "Moment: MeetingStarted" below (they replace §4's
`connectMeetingIntel(...)` block; use one or the other, not both).

## 5. Agents hub tile (optional, AgentsHubView.swift)

All 24 hub slots are used, so the tile needs a fourth row (the drawer grows
by one row of tiles). The gear submenu (§3) works without it.

```swift
// enum Cell: add after `case fans`
        case smartMoments
// Cell.id: add after `case .fans: "fans"`
            case .smartMoments: "smartMoments"
// cells: add before `.fans,`
            .smartMoments,
// body switch: add before `case .fans:`
                case .smartMoments:
                    if let smartMoments = SmartMomentsWiring.current {
                        SmartMomentsHubTile(settings: smartMoments.settings)
                    }
// AgentHubMetrics: replace `static let rows = 3` with
    static let rows = 4
```

## 6. Moments: what `start()` installs (already in SmartMomentsWiring.swift)

`SmartMomentsWiring.start()` calls `installHooks()` (the shared hooks) and
then `installMoments()`, which is this, exactly. The order matters: Meeting
started before Meeting ended (which wraps its reversals), Presentation
before Screen sharing, and Screen sharing after both meeting moments (so a
share's hold also covers their put-backs). Meeting soon, Download finished
and Screenshot taken only replace hooks for their own triggers and chain the
rest, so their place doesn't matter.

```swift
    private func installMoments() {
        let app = app
        let intel = meetingIntelExtras
        MeetingSoonMoment.install(on: engine, deps: .live(
            meetings: app.meetings, camera: app.camera, screenDistance: app.screenDistance,
            activities: app.activities, openTab: app.openTab, meetingIntelBrief: intel?.meetingBrief
        ))
        MeetingStartedMoment.install(on: engine, deps: MeetingStartedDeps(
            assistant: app.meetingAssistant, translation: app.liveTranslation, media: app.media,
            focus: app.focus, notifications: app.notifications, camera: app.camera
        ))
        MeetingEndedMoment.install(on: engine, deps: .live(
            assistant: app.meetingAssistant, media: app.media, focus: app.focus, notifications: app.notifications,
            openWrapUp: intel?.openWrapUp, presentWrapUp: intel?.presentWrapUp
        ))
        PresentationMoment.install(on: engine, deps: .live(
            settings: settings, media: app.media, focus: app.focus,
            notifications: app.notifications, timer: app.timer
        ))
        ScreenSharingMoment.install(on: engine, deps: .live(
            media: app.media, notifications: app.notifications, clipboard: app.clipboard,
            activities: app.activities, sharing: sources.$isScreenSharing.eraseToAnyPublisher()
        ))
        DownloadFinishedMoment.install(on: engine, deps: .live(downloads: app.downloads))
        ScreenshotTakenMoment.install(on: engine, deps: .live(
            clipboard: app.clipboard, screenshotClipboard: app.screenshotClipboard
        ))
    }
```

Shared deps: every `.live(...)` takes the controllers from
`SmartMomentsAppControllers` (2b), plus `settings` and `sources` from the
wiring itself, plus the optional `meetingIntelExtras` (4b). The "Wiring line"
in each moment section below is that moment's line from this function; it
is already applied, so don't add it again.

"Do automatically": an action runs on its own only when
`MomentAction.isAutoEligible` (not consent, not always-ask, not
`MomentEngineRules.chipOnlyInAuto`) and the moment's
`hooks.autoEligible[action]?(trigger)` doesn't say false; otherwise it stays a
chip for a tap. Download finished uses it for an AI pick or a Space (Sort
waits for a tap), Presentation for a new display.

The Headphones connected moment was removed (product decision); saved
settings that still mention it load fine and the entry is ignored.

## What each action calls

| Action | Calls | Rule |
|---|---|---|
| joinMeeting | `MeetingsController.join(_:)` | tap only |
| openMirror / mirrorOff | `CameraController.start()` (after `ScreenDistanceController.yieldCamera()`), opens the drawer on `.nook` / `.stop()` | mirror on: tap only |
| checkDevices | `PermissionCenter.isGranted` mic/camera + default output name (Meeting soon adds devices and AirPods battery, see its section) | read only |
| recordNotes | `MeetingAssistant.startDetectedCall()` (or `start(title:calendarEventID:)`) | consent, tap only |
| liveCaptions / translateCaptions | starts the recording if needed, then `LiveTranslationController` `isEnabled`, `showsCaptionWindow`, `showsOriginal`; put back to the previous values when the call ends | consent, tap only |
| notesWrapUp | `MeetingAssistant.openNotesWindow(meetingID:)` | tap only |
| pauseMusic / resumeMusic | `MediaEngine.send(.togglePlayPause)` guarded by `isPlaying` | skipped when already so |
| doNotDisturbOn/Off | `FocusController.doNotDisturb.turnOn/turnOff` with the Focus shortcuts | hidden when the shortcuts are missing; a Focus session's DND is left alone |
| hide/showNotificationPreviews | `NotificationMonitor.isEnabled` | |
| hide/showClipboardBand | `ClipboardController.setShowsBannerForEveryCopy(_:)` | history keeps recording |
| saveRecordingNow | `MeetingAssistant.stop()` / `ScreenRecorderController.stop()` | tap only |
| showBatteryTimeLeft / openBatterySettings | `PowerMonitor.battery` / System Settings › Battery | settings: tap only |
| sortDownload | `DownloadsController.sortWithSuggestion(_:)`; Undo = `undo(_:)` | automatic only for the user's own rules (`hooks.autoEligible`; otherwise a chip) |
| openFile / revealInFinder / addToTray / sendToSpace | `DownloadsController`, `TrayStore.addFile`, `SpaceIngestCenter.file`, `SpaceStore.addManual` | open/reveal/Space: tap only |
| startFocusSession / windDownTimer | `FocusController.startSession()` / `TimerController.startTimer(minutes: 15)` | |
| nightMode / presentationMode | `ModeEngine.activate(_:)` (never a mode that hides or quits apps); default presentation = DND + hide previews + pause music; put back when it ends | on a new display: tap only |
| lowerBrightness | `LiveModeSystem.setBrightness` (built-in display), Undo restores | |
| cleanLink / copyAsMarkdownLink / formatCode / openLink | `MomentTextTools` + pasteboard (`ignoreNextCopy` first) | local only |
| copyImage / annotateImage / extractText | pasteboard / Preview / `TrayAIOCR` (on-device) | copy hidden while Screenshot to Clipboard is on |
| showAgendaBrief / talkTimer | Meeting soon / Presentation moments (see their sections) | tap only / timer idle only |
| quietNotchActivities, moveIslandToDisplay | no owner API yet: no hook, so no chip; Settings says "Not available yet" | |

Every permission check goes through `PermissionCenter` (the engine reads
`hooks.permissionGranted`, which is `PermissionCenter.shared.isGranted`, and
asks only after a chip tap, through `PermissionCenter.shared.request`).

## Tests

`/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/smartmoments/engine/tests/run.sh`
builds the engine, detectors and live sources against stubs and fakes (no app
launch) and checks every moment (`SWIFT_VERSION=5 run.sh` for Swift 5).
Each moment has its own runner (real engine + that moment file against fake
controllers) under
`/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/moments/<Name>/run.sh`
(MeetingSoon, MeetingStarted, MeetingEnded, presentation, ScreenSharing,
DownloadFinished, ScreenshotTaken), listed in each moment's section below.

## Moment: DownloadFinished

File: `moment-DownloadFinished.swift`. `DownloadFinishedMoment.install(on:deps:)`
registers the moment's handlers on `SmartMomentsController` through
`DownloadFinishedMomentDeps.live(downloads:)` (weak `DownloadsController`). It
replaces the download hooks of `installHooks()` and keeps the earlier Add to
Tray / Send to Space hooks for screenshots and copies (chained by trigger).
The trigger is unchanged: `installReports()` reports each finished item once
via `SmartMomentsLiveSources.reportDownloadFinished` (skipped while
DownloadsController's own band is on or a rule already moved it).

Wiring line (already applied in `SmartMomentsWiring.installMoments()`, §6; it runs right after `installHooks()`):

```swift
        DownloadFinishedMoment.install(on: engine, deps: .live(downloads: app.downloads))
```

| Action | Calls | Rule |
|---|---|---|
| sortDownload | `DownloadsController.sortWithSuggestion(_:)`, checks `item(_:).move` | file must still be there and not sorted yet; automatic only for the user's own rule (`.rule` origin), never an AI pick or a Space; needs `.downloadsFolder` (PermissionCenter, through the engine) |
| put back (Undo) | `DownloadsController.undo(_:)` | only the move this offer made (same from/to/date), only while the band is up; a later move by the user stays |
| openFile | `DownloadsController.open(_:)` (current location, follows a sort) | a tap only |
| revealInFinder | `DownloadsController.reveal(_:)` | a tap only |
| addToTray | `DownloadsController.addToTray(_:)`, checks `addedToTray` | off by default |
| sendToSpace | `DownloadsController.sendToSpace(_:)`, checks `sentToSpace` | a tap only, off by default |

Chips are hidden when the file is gone or still downloading. Tests:
`/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/moments/DownloadFinished/run.sh`
(`SWIFT_VERSION=5` for Swift 5): real file moves in a temp folder against a
fake DownloadsController.

## Moment: ScreenshotTaken

`moment-ScreenshotTaken.swift` (`ScreenshotTakenMoment`) replaces the
screenshot hooks of `installHooks()` for Copy, Annotate and Send to Space,
adds the put-backs (Undo) for Copy and Send to Space, and keeps the earlier
Send to Space hook for downloads and copies (chained by trigger, so the order
next to `DownloadFinishedMoment.install` doesn't matter). Add to Tray and Copy
text stay as they are. The trigger is unchanged
(`SmartMomentsLiveSources.reportScreenshot(url:)`, Spotlight's screen captures).

Wiring line (already applied in `SmartMomentsWiring.installMoments()`, §6; it runs right after `installHooks()`):

```swift
        ScreenshotTakenMoment.install(on: engine, deps: .live(clipboard: app.clipboard, screenshotClipboard: app.screenshotClipboard))
```

| Action | Calls | Rule |
|---|---|---|
| copyImage | PNG from `ScreenshotClipboardController.pngData(for:)` on `NSPasteboard.general` (TIFF on demand, `ScreenshotClipboardTIFFProvider`), after `ClipboardController.ignoreNextCopy()` (only while its history runs) | hidden while Screenshot to Clipboard is on; may run automatically |
| put back (Undo) | the clipboard's earlier items and types, written back after `ignoreNextCopy()` | only if nothing was copied since (`changeCount`), only while the band is up; a clipboard over 64 MB isn't kept |
| annotateImage | `NSWorkspace.open(_:withApplicationAt:configuration:)` with Preview (`com.apple.Preview`), else `NSWorkspace.open(_:)` | a tap only; no put-back (SparkV never closes or quits apps) |
| sendToSpace | `SpaceIngestCenter.file(url, userInitiated: true)` | a tap only; hidden while `SpaceIngestCenter.current` is nil |
| put back (Undo) | `SpaceStore.shared.delete(itemID:)` for the item this send created (new id, same file), waiting up to 30 s for OCR to land it | an item already in Spaces (the screenshot watcher filed it) stays; the screenshot file itself is never touched |

Undo shows on the auto-run "Done" band and after a single chip runs while the
band is still up; "Do it" closes the band (engine rule), so there is nothing
left to undo then. Tests:
`/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/moments/ScreenshotTaken/run.sh`
(`SWIFT_VERSION=5` for Swift 5): the real engine and the live deps against a
private pasteboard and fake Clipboard/ScreenshotClipboard/Spaces controllers.

## Moment: MeetingEnded

`moment-MeetingEnded.swift` (`MeetingEndedMoment`) registers the handlers for
Notes wrap-up, Resume music, Do Not Disturb off and Show notification previews
for `.meetingEnded(call, recordedMeetingID:)`, plus their Undo put-backs. It
wraps the hooks already there (never replaces them for another moment): it
watches "Meeting started"'s pause / DND on / hide previews to record which
call changed what (and which player was paused), and lets the earlier handler
(SmartMomentsWiring's, or moment-MeetingStarted.swift's owning reversal) do
the work after its checks. The trigger is unchanged (`installReports()`
chains `MeetingCallDetector.onEvent` and reads the recorded meeting id before
MeetingAssistant handles `.ended`).

Wiring line (already applied in `SmartMomentsWiring.installMoments()`, §6; it runs right after `installHooks()`),
after the `MeetingStartedMoment.install` line when that one is there (installed
earlier it still works, from the engine's ledger):

```swift
        MeetingEndedMoment.install(on: engine, deps: .live(
            assistant: app.meetingAssistant, media: app.media, focus: app.focus, notifications: app.notifications
        ))
```

When `Sources/Labs/MeetingIntel` is built, §4b passes these two closures
through `meetingIntelExtras`, so `installMoments()` ends up making exactly
this call (the wrap-up chip then opens MeetingIntel's wrap-up):

```swift
        MeetingEndedMoment.install(on: engine, deps: .live(
            assistant: app.meetingAssistant, media: app.media, focus: app.focus, notifications: app.notifications,
            openWrapUp: { MeetingWrapUpController.current?.openWindow(meetingID: $0) },
            presentWrapUp: { MeetingWrapUpController.current?.present(meetingID: $0, session: nil, sidecar: nil) }
        ))
```

| Action | Calls | Rule |
|---|---|---|
| notesWrapUp | still recording (started by hand, so it didn't stop with the call): `MeetingAssistant.stop()` (writes the minutes, opens them) + MeetingIntel `present(meetingID:…)`; minutes being written: `present` (waits for them); else `MeetingWrapUpController.openWindow(meetingID:)`, without MeetingIntel `MeetingAssistant.openNotesWindow(meetingID:)` | a tap only (never in auto mode); shown only when the call was recorded (`record(id:)` or live) |
| resumeMusic | `MediaEngine.send(.togglePlayPause)` (through the earlier hook) | only if "Meeting started" paused it for this call (`DetectedCall.key`), music is still paused and the same player (`sourceBundleID`) owns Now Playing; a share or presentation that paused since owns it |
| doNotDisturbOff | `FocusController.doNotDisturb.turnOff` (moment-MeetingStarted's resolved off shortcut, else `settings.dndOffShortcut`) | only if "Meeting started" turned it on for this call; left on while a Focus session (`active.didEnableDoNotDisturb`) or an active ModeEngine mode with `.doNotDisturb(true)` holds it |
| showNotificationPreviews | `NotificationMonitor.isEnabled = true` | only if "Meeting started" hid them for this call and they are still hidden; a running Focus session restores them itself |
| put back (Undo) | pause again / DND on shortcut / `isEnabled = false` | only what that band changed, only from a tap while the band is up; music only if the same player still plays |

The reversals run automatically by default (DESIGN.md); with the moment off,
snoozed or quiet, the engine still puts the call's changes back silently and
the same checks apply. No band when nothing was changed and nothing was
recorded. No permission is asked. Tests:
`/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/moments/MeetingEnded/run.sh`
(`SWIFT_VERSION=5` for Swift 5): the real engine and moment file against fake
controllers (63 checks).

## Moment: MeetingStarted

`moment-MeetingStarted.swift` (`MeetingStartedMoment`) registers the handlers
for Record notes, Live captions, Translate captions, Pause music, Do Not
Disturb, Hide notification previews and Turn mirror off for
`.meetingStarted(DetectedCall)`, their reversals / put-backs, and the
MeetingIntel hand-off. It wraps the hooks already there: other moments
(screen sharing, presentation, deep work) keep SmartMomentsWiring's hooks, and
the reversals it wraps run its own restore only for what it changed.

Wiring line (already applied in `SmartMomentsWiring.installMoments()`, §6; it runs right after `installHooks()`)
(before the `MeetingEndedMoment.install` line):

```swift
        MeetingStartedMoment.install(on: engine, deps: MeetingStartedDeps(
            assistant: app.meetingAssistant, translation: app.liveTranslation, media: app.media,
            focus: app.focus, notifications: app.notifications, camera: app.camera
        ))
```

When `Sources/Labs/MeetingIntel` is built, use this in NotchWindowController
instead of §4's `connectMeetingIntel(SmartMomentsMeetingIntelLink(...))`,
right after `smartMoments?.start()` (2c). MeetingIntel's start prompt is then
the only band for the call: the quiet chips are folded into it and run when
the user starts a session there (in "Do automatically" they already ran);
"Not now" runs nothing.

```swift
        let intelStart = meetingIntel.coordinator
        MeetingStartedMoment.current?.connect(MeetingStartedIntelLink(
            willPrompt: { [weak intelStart] call in
                guard let c = intelStart, c.prefs.isEnabled, c.assistant.detectCalls, !c.assistant.autoStartDetectedCalls,
                      MeetingStartCoordinator.isIdle(c.assistant.phase) else { return false }
                return c.prefs.rule(for: MeetingKindKey(call: call)) != .never
            },
            isOn: { [weak intelStart] in intelStart?.prefs.isEnabled ?? false },
            stages: intelStart.$stage.map { stage -> MeetingStartedIntelStage in
                switch stage {
                case .idle: .idle
                case .prompting(let call), .countingDown(let call, _, _): .offering(callKey: call.key)
                case .live(let s): .live(callKey: s.callKey, plan: MeetingStartedPlan(
                    notes: s.plan.keepNotes, captions: s.plan.captions, translate: s.plan.translate))
                }
            }.eraseToAnyPublisher(),
            start: { [weak intelStart] plan, call in
                guard let c = intelStart else { return }
                let p = MeetingStartPlan(keepNotes: plan.notes, captions: plan.captions, translate: plan.translate, targetLanguage: nil)
                if c.offeredCall?.key == call.key { c.choose(p, remember: false) }
                else { c.startManually(title: call.title, calendarEventID: call.calendarEventID, plan: p) }
            },
            changePlan: { [weak intelStart] plan in
                guard let c = intelStart, let s = c.session else { return }
                c.changePlan(MeetingStartPlan(keepNotes: s.plan.keepNotes, captions: plan.captions,
                                              translate: plan.translate, targetLanguage: s.plan.targetLanguage))
            }
        ))
```

| Action | Calls | Rule |
|---|---|---|
| recordNotes | `MeetingAssistant.startDetectedCall()` when the trigger's call is the detector's `activeCall` (titled after the call, opens the notepad, stops with the call); else `start(title: call.title, calendarEventID: call.calendarEventID)` + `openNotesWindow()`, stopped by the put-back when the call ends | consent: a tap only; `.microphone` checked by the engine through PermissionCenter |
| suggested answers | `MeetingAssistant.suggestAnswers = true` before any recording this moment starts, and whenever a recording runs during a detected call while the moment is on (MeetingIntel's too); back to `false` when that recording ends, unless the user changed it meanwhile | |
| liveCaptions | MeetingIntel on: live session → `changePlan` with `captions` (its caption band); no session → `start(.captionsOnly)`. Otherwise `LiveTranslationController` `showsOriginal`, `showsCaptionWindow`, `isEnabled` = true after starting the recording (`start(title:)`) if needed | consent: a tap only; `.microphone` + `.speech` |
| translateCaptions | MeetingIntel on: `changePlan` / `start(.translated)` (target language from Live Translation's settings; MeetingIntel restores it when the session ends). Otherwise `LiveTranslationController.isEnabled` + `showsCaptionWindow` | consent: a tap only; off by default |
| captions put back | the three Live Translation values as they were, or the plan as it was; a recording started only for captions is stopped | when the call ends, Undo, quit |
| pauseMusic / resumeMusic | `MediaEngine.send(.togglePlayPause)` only while `isPlaying` and the source is `.app` / `.player` (never `.needsPermission` / `.denied`, so no Automation prompt); resume only if still paused on the same `trackKey`. Playing again by hand → `engine.userChanged(.resumeMusic)` | chip hidden when nothing controllable plays |
| doNotDisturbOn / Off | `FocusController.doNotDisturb.refresh` + `turnOn` with the pair `ModeDoNotDisturbNames.resolve(preferred: settings.dndOn/OffShortcut, library:)` (the Focus / Modes shortcut path); Off runs that pair's off shortcut | skipped while a Focus session (`active.didEnableDoNotDisturb`) or an active ModeEngine mode with `.doNotDisturb(true)` holds DND; chip hidden when the shortcuts are missing |
| hide / showNotificationPreviews | `NotificationMonitor.isEnabled` false / true | shown again only if still hidden and no Focus session runs; shown by hand → `userChanged` |
| mirrorOff | `CameraController.stop()` when `isRunning || isStarting` | not turned back on (no camera light after a call) |

Never hides, quits or closes an app; asks for no permission itself. Tests:
`/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/moments/MeetingStarted/run.sh`
(`SWIFT_VERSION=5` for Swift 5): the real engine and moment file
(`-D SMARTMOMENTS_FAKES`, which leaves out the controller adapters) against
fake controllers (86 checks).

## Moment: ScreenSharing

File: `moment-ScreenSharing.swift`. `ScreenSharingMoment.install(on:deps:)`
wraps the shared hooks for `hideNotificationPreviews`/`showNotificationPreviews`,
`hideClipboardBand`/`showClipboardBand` and `pauseMusic`/`resumeMusic`. A
screen-sharing trigger (`screenSharingStarted`/`Ended`, also the quit and
Undo put-backs) is handled here, and every other moment's trigger goes on to
the earlier hook. `doNotDisturbOn` (off by default) stays on the shared hook.
The trigger itself is unchanged: `SmartMomentsLiveSources` reports
`screenSharingStarted`/`screenSharingEnded` (and sends the end when it stops).

Wiring line (already applied in `SmartMomentsWiring.installMoments()`, §6; it runs right after `installHooks()`).
Put it after the other `…Moment.install` lines (MeetingStarted, MeetingEnded,
Presentation) so the share's hold also covers their put-backs:

```swift
        ScreenSharingMoment.install(on: engine, deps: .live(
            media: app.media, notifications: app.notifications, clipboard: app.clipboard,
            activities: app.activities, sharing: sources.$isScreenSharing.eraseToAnyPublisher()
        ))
```

| Action | Calls | Put back (share ends, Undo, quit) |
|---|---|---|
| hideNotificationPreviews | `NotificationMonitor.isEnabled = false` (also dismisses a preview on screen) | `isEnabled = true`, only if we turned it off and it is still off |
| hideClipboardBand | `ClipboardController.setShowsBannerForEveryCopy(false)` and `ActivityCenter.dismiss(id: ClipboardController.activityID)`; history keeps recording; chip only while `ClipboardController.isEnabled` | `setShowsBannerForEveryCopy(true)`, only if we turned it off and it is still off |
| pauseMusic | `MediaEngine.send(.togglePlayPause)` when `isPlaying` | the same toggle, only if nothing plays and the same `sourceBundleID` owns Now Playing |

Rules:
- While a share is in effect, another moment's put-back of a state the share
  protects (Meeting ended's Show previews / Resume music, an Undo) is held and
  runs when the share ends. Moments that set the state directly (Presentation's
  quiet set) can call
  `ScreenSharingMomentSession.session(for: engine)?.holdUntilShareEnds(.previews, context:) { … }`
  (returns false when nothing is held: put it back now).
- The user turning previews or the band back on, or playing music, during the
  share wins: it is forgotten and `engine.userChanged(_:)` is called.
- Both settings are persisted by their controllers, so what the share changed
  is noted under `SmartMoments.screenSharing.changed.v1` until put back; after a
  crash mid-share the next launch turns them back on (music is never resumed
  at launch).
- If the live source stops the share and the engine's end never arrives, the
  rest is put back silently after `settleDelay` (3 s).
- Never hides or quits an app, records anything, or asks for a permission.
  Limit: a "Copied" band from a copy-back inside SparkV's own UI still shows
  (ClipboardController posts it regardless of the setting).

Tests:
`/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/moments/ScreenSharing/run.sh`
(`SWIFT_VERSION=5` for Swift 5): the real engine with API-shaped stub
controllers and the shared hooks.

## Moment: MeetingSoon

File: `moment-MeetingSoon.swift` (picked up by §1's `cp Sources/Labs/SmartMoments/*.swift`).
It replaces the wiring's generic meeting-soon hooks for `.meetingSoon`
triggers (other triggers keep the earlier hooks) and adds the put-backs.

| Action | Calls | Rule / put back (Undo) |
|---|---|---|
| joinMeeting | `MeetingsController.join(_:)` | tap only (the hook refuses `userInitiated == false` too); nothing to put back |
| openMirror | `ScreenDistanceController.yieldCamera()`, `CameraController.start()`, drawer on `.nook` | tap only; Undo = `CameraController.stop()`, only if this offer turned it on and it is still on |
| checkDevices | `PermissionCenter.isGranted` mic/camera, CoreAudio default input/output name, `AVCaptureDevice` discovery (never opened; "in use by another app"), `SystemProfilerBluetooth.connectedDevices()` (PowerMonitor's reader) for AirPods L/R/case | read only, may run in auto mode; strip `smartMoments.meetingSoon.devices` (updates in place when the batteries arrive; under 20 % warns "charge them"); Undo closes the strip |
| showAgendaBrief | `meetingIntelBrief` (MeetingIntel `MeetingBriefBuilder` lines) else the event notes' agenda lines (EventKit, only when `PermissionCenter` says Calendars is granted; never requested) | tap only (engine `chipOnlyInAuto`); card `smartMoments.meetingSoon.brief` opens `.today`; Undo closes it |

### Wiring

Applied in `SmartMomentsWiring.installMoments()` (§6), after the shared hooks:

```swift
        MeetingSoonMoment.install(on: engine, deps: .live(
            meetings: app.meetings, camera: app.camera, screenDistance: app.screenDistance,
            activities: app.activities, openTab: app.openTab, meetingIntelBrief: intel?.meetingBrief
        ))
```

With MeetingIntel built, §4b sets `meetingIntelExtras.meetingBrief`. For reference,
the stand-alone forms (NotchWindowController, after `smartMoments?.start()`)
are below; don't use them together with §6, or the moment is installed twice.

```swift
        if let smartMoments {
            MeetingSoonMoment.install(on: smartMoments.engine, deps: .live(
                meetings: meetings, camera: camera, screenDistance: screenDistance, activities: activities,
                openTab: { [weak self] tab in
                    self?.state.select(tab)
                    self?.setExpanded(true)
                }
            ))
        }
```

When Sources/Labs/MeetingIntel is built (its §6 applied), use this instead, so the
Agenda brief chip shows MeetingIntel's brief (agenda, what you owe, last time,
Spaces) and falls back to the invite notes:

```swift
        if let smartMoments {
            MeetingSoonMoment.install(on: smartMoments.engine, deps: .live(
                meetings: meetings, camera: camera, screenDistance: screenDistance, activities: activities,
                openTab: { [weak self] tab in
                    self?.state.select(tab)
                    self?.setExpanded(true)
                },
                meetingIntelBrief: { [weak meetingAssistant] meeting in
                    guard MeetingIntelPreferences.shared.showBrief, let assistant = meetingAssistant else { return nil }
                    let brief = await MeetingBriefBuilder.build(
                        title: meeting.title, calendarEventID: meeting.eventID, event: meeting,
                        library: assistant.library, spaces: SpaceStore.shared,
                        calendarGranted: PermissionCenter.shared.isGranted(.calendars), now: Date()
                    )
                    let lines = brief.bandLines(max: MeetingSoonMoment.briefLineLimit).map(\.text)
                    return lines.isEmpty ? nil : lines
                }
            ))
        }
```

Tests: `/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/moments/MeetingSoon/run.sh`
(`SWIFT_VERSION=5 run.sh` for Swift 5): engine + this moment against fakes,
trigger -> offer -> each action -> Undo -> auto mode -> settings off -> no offer.

## Moment: Presentation

`moment-Presentation.swift` (`PresentationMoment`) owns the
`presentationMode` and `talkTimer` hooks and put-backs. It replaces the
wiring's own `presentationMode` hook and put-back, so install it after
`installHooks()`.

Wiring line (already applied in `SmartMomentsWiring.installMoments()`, §6; it runs right after `installHooks()`)
(after the other `…Moment.install` lines when those are there; it reads the
engine's current hooks at run time, so their wrappers apply either way):

```swift
        PresentationMoment.install(on: engine, deps: .live(
            settings: settings, media: app.media, focus: app.focus,
            notifications: app.notifications, timer: app.timer
        ))
```

| Action | Calls | Rule |
|---|---|---|
| presentationMode | `ModeEngine.shared.activate(_:)` with the Settings pick (`tunables.presentationModeID`), else ModeEngine's built-in Presentation mode (`ModePresets.presentationID`), only if the mode has no `.hideApps` / `.quitApps` and no other mode is on. Otherwise (the shipped preset hides every other app, so this is the default) the quiet set: Do Not Disturb (`.doNotDisturbOn` hook, else `FocusController.doNotDisturb.turnOn(settings.dndOnShortcut)`), previews off (`.hideNotificationPreviews` hook, else `NotificationMonitor.isEnabled = false`), pause music (`.pauseMusic` hook, else `MediaEngine.send(.togglePlayPause)` while `isPlaying`) | auto for Keynote/PowerPoint play mode, ask for generic fullscreen (engine). On a new display it runs only from a tap. DND is skipped when a Focus session, the active mode or another moment's ledger entry (a call) already holds it. |
| put back (presentation ended, Undo, quit) | mode: `ModeEngine.shared.deactivate()` only if our mode is still the active one. Quiet set, reverse order, only the steps we changed: resume (`.resumeMusic` hook / toggle) only if nothing plays and a player is there; previews (`.showNotificationPreviews` hook / `isEnabled = true`) only if still hidden; DND off (`.doNotDisturbOff` hook / `turnOff(dndOffShortcut)`) | each step is left alone when the user changed it, a Focus session or the active mode holds it, or the engine ledger shows another moment (a call) owns it now, so that moment puts it back. Through the hooks, a screen share keeps previews hidden until it ends. |
| talkTimer | `TimerController.startTimer(minutes: 20)` (`talkMinutes`) | only when the timer is on and idle (never overwrites the user's timer); offered only for `presentationStarted`. Put back: `TimerController.reset()` only if that same countdown still runs. |
| quietNotchActivities | none: `ActivityCenter` has no suppress/restore API | no hook, so no chip (still "Not available yet" in Settings) |

Nothing here hides, quits or closes an app, records, or asks for a
permission. Tests:
`/private/tmp/claude-501/-Users-koushikgoudshaganti-Desktop-Agency-Apple-Face-id/9db1267f-9388-4278-81ac-295b0f0bcf44/scratchpad/moments/presentation/run.sh`
(`SWIFT_VERSION=5` for Swift 5): the real engine and moment file against fake
controllers (89 checks).
