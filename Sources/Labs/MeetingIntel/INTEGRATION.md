# Meeting Intelligence: integration

Nothing here is applied yet. Files outside `Sources/Labs/MeetingIntel/` belong to
other agents. Whoever integrates applies these edits, in this order, to the files
named. Each "find" line is copied from the current source and occurs exactly
once. Each block is the code to paste.

Validated on 2026-10-22: every edit below (steps 1–12, including the Reminders
steps 3–5) was applied to a snapshot copy of the tree. The whole app then
type-checked with 0 errors and 0 warnings in Swift 6 and in Swift 5. The same
holds for the lab alone (no edits applied) and for the set without steps 2–5 (steps
1 and 6–10, step 6 without the step-2 hooks). A full-app harness with steps 2 and 6 applied
checks the hooks: with MeetingIntel on, the assistant posts no prompt of its own;
with it off, the assistant's prompt shows; `skipNotesFor` follows the plan.

Parts: A = `StartCoordinator.swift`, `start-Brief.swift`, `start-Views.swift`.
B = `LiveAssist.swift`. C = `WrapUp.swift`, `wrapup-AppAdapters.swift`. Shared
types are in `MeetingIntelModels.swift`, and the design is in `DESIGN.md`.

The minimum to ship is steps 1, 6 and 7. Everything else adds features.

## 1. build.sh: compile the lab

After `cp Sources/Labs/CloudSync/*.swift "$WORK/src/"` add:

```sh
cp Sources/Labs/MeetingIntel/*.swift "$WORK/src/"
```

## 2. MeetingAssistant.swift: hooks for the call offer and for skipping minutes

Recommended. Without this step, A hides the assistant's own "Take notes?"
prompt one main-actor turn after it appears, and Captions / Translate calls
still get written minutes.

Find `    @Published private(set) var promptedCall: DetectedCall?` and add after it:

```swift
    /// Return true to take over the offer for this call (MeetingIntel shows
    /// its own prompt). Renames, calendar marks and auto-stop still run here.
    var callOfferOverride: ((DetectedCall) -> Bool)?
    /// Recordings whose minutes shouldn't be written (captions-only calls).
    var skipNotesFor: Set<UUID> = []
```

In `handleCallEvent`, case `.started`, find
`            if autoStartDetectedCalls, Self.canRecordWithoutPrompt {` and put this line
directly above it:

```swift
            if !autoStartDetectedCalls, callOfferOverride?(call) == true { return }
```

Make the detector-aware start reachable. Change
`    private func startRecording(for call: DetectedCall) {` to:

```swift
    func startRecording(for call: DetectedCall) {
```

In `stop()`, find this block:

```swift
            await store.saveAndWait(record)

            guard !record.segments.isEmpty else {
```

and insert between its two lines:

```swift
            if skipNotesFor.remove(record.id) != nil {
                finishSession()
                return
            }
```

In `delete(meetingID:)`, after `        store.delete(id: meetingID)` add:

```swift
        Task { await MeetingIntelSidecarStore.shared.remove(meetingID) }
```

## 3. Info.plist: Reminders usage string (part C, optional)

After the `NSCalendarsFullAccessUsageDescription` string add:

```xml
	<key>NSRemindersFullAccessUsageDescription</key>
	<string>SparkV adds the meeting tasks you tick to Reminders. Nothing is added unless you click Add.</string>
```

The existing `com.apple.security.personal-information.calendars` entitlement
covers EventKit under the Hardened Runtime, including reminders. If SparkV never
appears under Privacy › Reminders after a grant, check this entitlement first.

## 4. PermissionCenter.swift: add `.reminders` (with step 3)

| Find | Add after it |
|---|---|
| `        case calendars` (enum `Permission`) | `        case reminders` |
| `            case .calendars: "calendars"` | `            case .reminders: "reminders"` |
| `            case .calendars: anchor = "Privacy_Calendars"` | `            case .reminders: anchor = "Privacy_Reminders"` |
| `        case .calendars: return Self.calendar(EKEventStore.authorizationStatus(for: .event))` | `        case .reminders: return Self.calendar(EKEventStore.authorizationStatus(for: .reminder))` |

In `static let standard`, change
`            .calendars, .notifications, .bluetooth, .downloadsFolder,` to:

```swift
            .calendars, .reminders, .notifications, .bluetooth, .downloadsFolder,
```

In `SystemPermissionSystem.prompt(_:)`, after the
`_ = try? await EKEventStore().requestFullAccessToEvents()` line add:

```swift
        case .reminders:
            _ = try? await EKEventStore().requestFullAccessToReminders()
```

These are the only exhaustive switches over `PermissionCenter.Permission` in
the built sources. The Onboarding lab has its own enum and needs no change. If
Settings or Onboarding should list Reminders, use the label "Reminders", the
symbol `checklist` and the reason "Meeting tasks you approve".

## 5. The Reminders gate (with steps 3 and 4)

Paste at the end of `Sources/Labs/MeetingIntel/WrapUp.swift`. It isn't in
there yet because it won't compile until step 4 lands:

```swift
@MainActor
final class PermissionCenterRemindersGate: MeetingRemindersGate {
    private let center: PermissionCenter
    init(center: PermissionCenter? = nil) { self.center = center ?? .shared }

    func status() -> MeetingRemindersAccess {
        switch center.status(.reminders) {
        case .granted: .granted
        case .notDetermined, .unknown: .notDetermined
        case .denied, .restricted, .limited: .denied
        case .appNotRunning, .appNotInstalled: .unavailable
        }
    }

    func request(from feature: String) async -> Bool {
        await center.ensure(.reminders, from: feature)
    }
}
```

Then, in step 6, pass `PermissionCenterRemindersGate()` in place of
`MeetingRemindersUnavailableGate()`. Until then the wrap-up panel shows
"Reminders isn't connected yet" where the Add button would be.

## 6. NotchWindowController.swift: create, wire, start, stop

Properties. After `    private let liveTranslation: LiveTranslationController` add:

```swift
    private let meetingIntel: MeetingIntelCenter
    private let meetingLive: LiveMeetingAssist
    private let meetingWrapUp: MeetingWrapUpController
```

In `init()`, after `        liveTranslation = LiveTranslationController(activities: activities)` add:

```swift
        let intelStart = MeetingStartCoordinator(
            activities: activities,
            assistant: meetingAssistant,
            translation: liveTranslation,
            calendar: { MeetingsController.current?.meetings ?? [] },
            spaces: SpaceStore.shared
        )
        meetingLive = LiveMeetingAssist(activities: activities, assistant: meetingAssistant)
        meetingWrapUp = MeetingWrapUpController(
            activities: activities,
            assistant: meetingAssistant,
            spaces: SpaceStore.shared,
            reminders: MeetingRemindersUnavailableGate()   // PermissionCenterRemindersGate() after steps 3–5
        )
        meetingIntel = MeetingIntelCenter(start: intelStart, live: meetingLive, wrapUp: meetingWrapUp)
```

After `        liveTranslation.attach(to: meetingAssistant)` (this is after `super.init`) add:

```swift
        MeetingIntelCenter.current = meetingIntel
        LiveMeetingAssist.current = meetingLive
        MeetingWrapUpController.current = meetingWrapUp
```

With step 2 applied, add the following right after those three lines. Without
step 2, leave it out: A's defaults then use `startDetectedCall()` /
`start(title:calendarEventID:)`.

```swift
        meetingIntel.coordinator.startRecording = { [weak meetingAssistant] call, plan in
            guard let assistant = meetingAssistant else { return }
            if let call { assistant.startRecording(for: call) } else { assistant.start(title: nil, calendarEventID: nil) }
            if plan.keepNotes, assistant.phase == .recording { assistant.openNotesWindow() }
        }
        meetingIntel.coordinator.setWritesNotes = { [weak meetingAssistant] id, writes in
            if writes { meetingAssistant?.skipNotesFor.remove(id) } else { meetingAssistant?.skipNotesFor.insert(id) }
        }
        meetingAssistant.callOfferOverride = { [weak meetingIntel] call in
            meetingIntel?.coordinator.wantsOffer(for: call) ?? false
        }
```

Environment for the notch views. After `            .environmentObject(liveTranslation)` add:

```swift
            .environmentObject(meetingLive)
```

Start. Change `        meetingAssistant.start()` (the line before
`spacesIngest.start()`) to:

```swift
        meetingAssistant.start()
        meetingIntel.start()
```

Stop, in `tearDown()`. Change `        meetingAssistant.shutdown()` to:

```swift
        meetingIntel.stop()
        meetingAssistant.shutdown()
```

## 7. NotchNookLayoutView.swift: gear menu (A and B)

In the struct that already declares
`    @EnvironmentObject private var liveTranslation: LiveTranslationController`, add
after that line:

```swift
    @EnvironmentObject private var meetingLive: LiveMeetingAssist
```

In `Menu("Meetings")`, after `                LiveTranslationMenu(controller: liveTranslation)`
(the last item, before the closing `}`) add:

```swift
                Divider()
                Button("Live Captions for This Meeting") {
                    MeetingIntelCenter.current?.coordinator.startManually(title: nil, calendarEventID: nil, plan: .captionsOnly)
                }
                .disabled(meetingAssistant.phase != .idle)
                MeetingStartMenuItems(prefs: MeetingIntelPreferences.shared)
                Divider()
                MeetingLiveAssistMenuItems(assist: meetingLive)
```

The items are:
- **A:** Live Captions for This Meeting; Offer Notes, Captions or Translation When a Call Starts; Show a Brief Before Calls; Forget Remembered Call Choices.
- **B:** Bookmark This Moment; Show Live Captions (only while a non-translated session is live); Flag Action Items & Decisions; Talk-Time Meter; Nudge After Long Monologues; Nudge After 1 / 1.5 / 2 / 3 min.

The Live Captions button is optional. Drop it to keep the menu shorter.

## 8. TodayView.swift: the offer in the Today tab (A)

Replace these two lines:

```swift
            MeetingsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
```

with:

```swift
            Group {
                if let intel = MeetingIntelCenter.current {
                    MeetingStartTodaySlot(coordinator: intel.coordinator) { MeetingsView() }
                } else {
                    MeetingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
```

The Today tab's left column is only about 280 × 69 pt: a 115 pt drawer, minus
the 38 pt header and 8 pt bottom padding, and minus the timer. While a call is
offered or counting down, the slot shows the provider line plus Notes /
Captions / Translate / ✕, with the consent line and "Always". Otherwise it shows
`MeetingsView()` unchanged. An earlier draft put `MeetingStartTodayRow` above
`MeetingsView()`, which overflowed the drawer. `MeetingStartTodayRow(coordinator:,
compact: false)`, with the full brief, is meant for roomy places such as a
window.

## 9. MeetingActivityViews.swift: bookmark on the recording band (B)

In `MeetingRecordingBand`, find the elapsed-time text that ends the `HStack`:

```swift
                Text(MeetingFormat.clock(elapsed))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
```

and add after it, inside the same `HStack`:

```swift

                if MeetingIntelCenter.current != nil {
                    Button {
                        MeetingIntelCenter.current?.bookmarkNow()
                    } label: {
                        Image(systemName: "bookmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Bookmark this moment")
                }
```

The band has no Stop button. Stop is in the header and in the gear menu.

## 10. MeetingNotesWindow.swift: wrap-up button and live flags (C, B; optional)

In `MeetingDetail.toolbar`, after
`            toolButton("square.and.arrow.up", "Export .md") { model.exportMarkdown(record) }` add:

```swift
            toolButton("text.badge.checkmark", "Wrap-up") {
                MeetingWrapUpController.current?.openWindow(meetingID: record.id)
            }
            .disabled(isLive || MeetingWrapUpController.current == nil)
```

In `MeetingNotesTab.body`, find:

```swift
            VStack(alignment: .leading, spacing: 20) {
                if let notes = record.notes {
```

and insert between those two lines:

```swift
                if isLive, let live = LiveMeetingAssist.current {
                    MeetingLiveFlagsSection(assist: live, meetingID: record.id)
                }
```

`MeetingLiveFlagsSection` renders nothing until something is flagged in the
meeting being recorded.

## 11. What is already wired inside the lab (do not paste)

- `MeetingIntelCenter.start()` sets A's `onSessionStarted` (→ `LiveMeetingAssist.begin`),
  `onPlanChanged` (→ `update(plan:)`) and `onSessionEnded`. `onSessionEnded` calls
  `live.end()`, fills `kind` / `plan` / `serviceName` into the sidecar, then
  calls `wrapUp.present(meetingID:session:sidecar:)`.
- Part A is reached as `MeetingIntelCenter.coordinator`. The design called it
  `start`, but Swift doesn't allow a `start` property next to `func start()`.

## 12. Behaviour the integrator should know

**Priorities** (REC wings = `MeetingAssistant.recordingPriority`, 65):

| Band | Priority | Duration |
|---|---|---|
| start prompt / countdown | 64 | prompt peeks 10 s, then rests in the wings as "Notes?" until the call ends or you answer; the countdown is `.expanded` |
| consent toast | 63 | 3 s, at every session start, including manual and assistant auto-starts |
| monologue nudge | 63 | 6 s, at most once every 5 min |
| captions (B) | 62 | stays; only for `captions && !translate` |
| wrap-up peek (C) | 61 | 12 s |
| flag toast (B) | 66 | 3 s, at most one every 20 s; the only band above REC |

**Offer rules:**
- `.ask` shows the band.
- `.auto(plan)` shows a countdown with Cancel and the consent line.
- `.never` (per service) suppresses the offer.
- With `autoStartDetectedCalls` on, A shows no offer; the session is built when recording starts.
- `wantsOffer(for:)` is `MeetingIntelPreferences.shared.isEnabled && meetingAssistant.detectCalls`. With MeetingIntel off, the assistant's simple prompt shows as before.

**Who stops a recording:**
- With step 2 applied, every detected-call start goes through `startRecording(for:)`, so the assistant stops it when the call ends.
- Without step 2, Captions / Translate recordings are stopped by A when their call ends, and A clears the assistant's "Still recording" band.
- Turning call detection off mid-call never stops a recording. This is the same rule MeetingAssistant follows.

**Captions / Translate plans:** A calls `setWritesNotes(id, false)` for every
such session, however it started. With step 2 applied, no minutes are written.
`changePlan(_:)` back to notes calls `setWritesNotes(id, true)`.

**Translation:** A turns `LiveTranslationController.isEnabled` on, with the chosen
target, only for a translate plan. When the phase is back to `.idle`, it puts
back the previous on/off state and target, but only if translation is still on.

**Privacy:**
- Recording never starts without a click or a visible countdown.
- The red dot (`SparkVTheme.recording`) is on every live band.
- Calendars is read only when it is already granted. Nothing in the lab asks for Calendars access.
- Flag refinement uses only the on-device model, never Groq.
- Wrap-up Polish tries the on-device model first. It falls back to Groq only when "Allow Meeting Notes to Use My Groq Key" is on, and its status line says which one ran.
- Mail only opens a draft (mailto), or copies the text.
- Reminders are added only for ticked tasks, after "Add N to Reminders". Permission is asked only then.
- A Space is filed only on "File".
- Sidecars live in `~/Library/Application Support/SparkV/MeetingIntel/<id>.json`.

**Links in Reminders:** reminders get a `sparkv://meeting/<id>` link only if
Info.plist registers the `sparkv` URL scheme (`CFBundleURLTypes`). It doesn't
today, so reminders carry no link.
