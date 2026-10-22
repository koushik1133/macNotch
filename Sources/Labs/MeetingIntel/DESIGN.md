# Meeting Intelligence (SparkV Labs) — design

Status: design + shared types (`MeetingIntelModels.swift`, done, typechecks in
Swift 6 and 5). Three builders work in parallel on `StartCoordinator.swift` (A),
`LiveAssist.swift` (B) and `WrapUp.swift` (C). All four files live in
`Sources/Labs/MeetingIntel/`. Nothing outside that folder is edited; app wiring
is written as exact code in `INTEGRATION.md`.

---

## 1. What the best tools do (research, Oct 2026)

| Tool | Features worth learning from | What SparkV takes |
|---|---|---|
| **Granola** | No bot: captures device audio. You type rough notes and the AI rewrites them around the transcript. Templates/"recipes", chat over meetings, team folders. | Already have the notepad (`MeetingRecord.userNotes`). Take: **the call is detected, not scheduled**. Take: **past meetings as context**. |
| **Otter** | Live transcript, live action items and highlights during the call, AI chat, auto-shared summary after the call. | Take: **live action-item flagging**. Leave out: sharing automatically (SparkV never sends). |
| **Fathom** | Bookmark/highlight a moment during the call with one click, then share a clip. Instant summary when the call ends. | Take: **bookmark this moment** (no video, a timestamp + note). |
| **tl;dv** | Timestamps tied to notes, multi-language, free recordings. | Take: **every flag jumps to its timestamp** in the transcript. |
| **Fireflies** | Talk-time tracking, topic tracking, sentiment, follow-up summaries, CRM push. | Take: **talk-time stats** after the call. Leave out: sentiment, CRM push. |
| **Read AI** | Speaker coach: talking too fast, interruptions, filler words, baselines over past meetings. | Take: **one gentle live nudge** (long monologue), not a scorecard. |
| **Jamie** | Bot-free, audio dropped once the transcript exists, decisions and speakers found, Ask AI. | Take: **decisions as their own flag**; privacy wording ("on this Mac"). |
| **Krisp** | Noise cancelling plus notes; an optional bot. | Confirms that bot-free, local capture is what people expect on a Mac. |
| **Google Meet (Gemini)** | "Take notes for me" with **suggested next steps** you can edit and assign; translated captions. | Take: **next steps reviewed before they become tasks** (Reminders only on approval). |
| **Apple (macOS 26)** | Live Translation captions in FaceTime; Phone/FaceTime audio call recording with an Apple Intelligence summary in Notes; recording tells the other side. | Take: **consent built in** (a reminder every time recording starts) and on-device translation (already in the LiveTranslation lab). |

Common thread across the best ones: (1) notice the call on its own, (2) one tap to
start, (3) very few, clear live signals, (4) a follow-up that is ready but only a
draft, (5) context from last time.

Where SparkV should be different (original, not a copy of any product UI):
- It lives in the **notch**: the prompt, the live signals and the wrap-up are
  island bands and wings, never a sidebar or floating bot tile.
- **Three choices in one band** (notes, captions, translated captions), because
  SparkV already has the caption and translation engines.
- **Nothing leaves the Mac without a click.** No auto email, no auto share, no
  auto task creation. Mail opens a *draft*; Reminders get only the ticked items.
- **On-device by default** (FoundationModels via `MeetingAIBackend`). Groq only
  when `MeetingAssistant.allowGroqForMeetings` is on, the same switch as today.

## 2. Look and feel (all parts)

- Tokens only from `SparkVTheme` (both looks: Apple and SparkV Red). Island ground
  is `SparkVTheme.islandBackground`; cards use `surface`/`stroke`; primary action
  `SparkVPrimaryButtonStyle`; Record uses `SparkVPrimaryButtonStyle(tint: SparkVTheme.recording)`.
- Status colors only for status: flag kinds use `MeetingFlagKind.tint`.
- The visual signature of this lab: a thin **"thread" line** (1.5 pt, `stroke`)
  running left of stacked items, with small glyph nodes for each flag/agenda line,
  and eyebrows via `MeetingIntelEyebrow` ("— BRIEF", "— LIVE", "— WRAP-UP").
  Builders should reuse this so all three parts read as one feature.
- The red recording dot (`MeetingIntelLiveBadge`) appears on every MeetingIntel
  surface shown while capturing. The existing REC wings (priority 65) are never
  covered: every MeetingIntel activity uses a lower priority except the short
  flag toast (66, transient ≤ 3 s).
- Band sizes: 360 pt wide content, heights 30 (one line), 48 (two lines), up to
  ~120 for the prompt with brief (`presentation: .expanded`).
- No SwiftUI `@State`, `#Preview`, `@Entry` (Command Line Tools). Local view
  state: `@StateObject` of a tiny `ObservableObject`, or `ViewFlag` if present in
  the app. Typecheck with Swift 6 and 5.
- Each builder renders its views offscreen (NSHostingView -> PNG) in its scratch
  folder in both looks (`UserDefaults "AppearanceStyle"`), and looks at them.

## 3. Shared types (already written: `MeetingIntelModels.swift`)

```swift
enum MeetingIntelActivity          // activity ids + priorities (startPrompt, brief, captions, flag, nudge, wrapUp)
struct MeetingKindKey              // init(call: DetectedCall); service + optional calendar series; .serviceOnly
struct MeetingStartPlan            // keepNotes, captions, translate, targetLanguage; .notes / .captionsOnly / .translated; needsRecording
enum MeetingStartRule              // .ask | .auto(MeetingStartPlan) | .never
@MainActor final class MeetingIntelPreferences   // .shared; isEnabled, showBrief, flagging, talkMeter,
                                   // monologueNudge, monologueSeconds (120), autoCountdown (5)
                                   // rule(for:), setRule(_:for:), forgetAllRules()
struct MeetingAttendee             // name, email, isMe, firstName
struct MeetingBriefPastMeeting, MeetingBriefSpaceHit, MeetingBrief (.empty(title:), isEmpty)
struct MeetingIntelSession         // id (== MeetingRecord.id), callKey, kind, serviceName, title,
                                   // calendarEventID, plan, brief, startedAt
enum MeetingFlagKind               // actionItem, decision, question, bookmark (+ symbol, label, tint)
enum MeetingFlagOrigin             // rule, model, user, assistant
struct MeetingFlag                 // id, kind, text, owner, due, isMine, at, segmentID, speaker, origin, isDismissed, note
struct MeetingTalkStats            // meSeconds, othersSeconds, longestMonologue, currentMonologue, monologueCount, turns, myShare
enum MeetingTalkTime               // compute(_ segments:, monologueThreshold:) -> MeetingTalkStats (pure)
struct MeetingFollowUpDraft        // to, subject, body; mailtoURL (nil if too long), plainText
struct MeetingReminderProposal     // id, actionItemID, title, dueDate, dueText, isSelected, reminderID
struct MeetingWrapUpState          // draftOpenedAt, draftCopiedAt, remindedTaskIDs, filedSpaceID, filedItemID, dismissedAt
struct MeetingIntelSidecar         // per-meeting JSON: flags, talk, plan, kind, wrapUp
actor MeetingIntelSidecarStore     // .shared; load(_:), save(_:), update(_:_:), remove(_:)
                                   // ~/Library/Application Support/SparkV/MeetingIntel/<id>.json
@MainActor protocol MeetingLiveAssisting   // begin(_:), update(plan:), bookmarkNow(note:), end() async -> MeetingIntelSidecar?
@MainActor protocol MeetingWrappingUp      // present(meetingID:session:sidecar:), openWindow(meetingID:)
enum MeetingRemindersAccess; @MainActor protocol MeetingRemindersGate  // status(), request(from:) async -> Bool
views: MeetingIntelLiveBadge, MeetingIntelEyebrow, MeetingTalkShareBar; MeetingIntelConsent strings
```

Rules for builders: do not change these types' existing members (others rely on
them). If you need something more, add it in *your own* file (extensions are
fine), and note it at the top of your file.

Existing app types you build on (read, don't edit):
`MeetingAssistant` (`phase`, `current`, `library`, `liveAnswer`, `start(title:calendarEventID:)`,
`stop()`, `record(id:)`, `isLive(_:)`, `openNotesWindow(meetingID:)`, `setTask(_:done:meetingID:)`,
`allowGroqForMeetings`, `static userName`, `callDetector` (`$activeCall`), `detectCalls`,
`autoStartDetectedCalls`, `promptedCall`, `startDetectedCall()`, `dismissDetectedCall()`, `ActivityID.recording`, `recordingPriority` 65),
`MeetingRecord`/`TranscriptSegment`/`ActionItem`/`MeetingNotes`/`SuggestedAnswer` (MeetingModels),
`MeetingCallDetector`/`DetectedCall`/`MeetingCallEvent` (Sources/MeetingDetector.swift),
`MeetingsController` (`meetings: [CalendarMeeting]`), `CalendarMeeting` (no attendees: read the
EKEvent by `eventID` only when `PermissionCenter.shared.status(.calendars) == .granted`),
`LiveTranslationController` (`isEnabled`, `targetLanguage`, `status`, `captions`; it starts
translating when MeetingAssistant records), `ActivityCenter.post/dismiss`, `LiveActivity`,
`SpaceStore.shared` (`search(_:in:)`, `items`, `spaces`, `move(itemID:to:)`, `ingest(_:)`),
`SpaceConnectors.meetingInput(_:attendees:)`, `SpaceIngestCenter.meeting(_:)` (meetings already
reach the Spaces Inbox automatically), `MeetingAIBackend.onDevice(...)`, `PermissionCenter.shared`.

---

## 4. Part A — `StartCoordinator.swift` (builder A)

**Job:** when a call is detected (or started from the menu), show one prompt band;
start what the user picks; remember per meeting kind; show a pre-meeting brief. Also
holds the root object `MeetingIntelCenter` that wires A, B and C together.

### Detection source (important: MeetingAssistant already reacts to calls)
`MeetingAssistant` now owns `callDetector: MeetingCallDetector` and its
`onEvent` (it marks calendar events joined, renames generic titles, shows its own
simple prompt `ActivityID.callPrompt`, and **stops a detector-started recording when
the call ends**). MeetingIntel must not take over `onEvent`. Instead:
- A derives events from `assistant.callDetector.$activeCall` (nil→call = started,
  same key + new title = updated, call→nil = ended) via `MeetingCallEventDiffer`
  (pure), and `MeetingStartCoordinator.handle(_:)` stays the testable entry point.
- Until the INTEGRATION.md hook lands, A hides the assistant's plain prompt by
  calling `assistant.dismissDetectedCall()` when `assistant.promptedCall?.key ==
  call.key`, right before posting its own band (that only suppresses the offer;
  `startDetectedCall()` still records `callDetector.activeCall`).
- If `assistant.autoStartDetectedCalls` is on, the assistant starts on its own: A
  posts no prompt, just builds the session (stage `.live`) and the brief peek.

### Flow
1. Call started → if `!prefs.isEnabled`, `!assistant.detectCalls`, or the assistant is
   already recording/summarizing → ignore. Else `rule = prefs.rule(for: MeetingKindKey(call: call))`:
   - `.never` → nothing (and suppress the assistant prompt as above).
   - `.ask` → post the **prompt band** (id `MeetingIntelActivity.startPrompt`,
     priority 64, `presentation: .expanded`, `duration: nil` while the call lasts,
     `opensTab: .today`). Brief loads in the background and fills in.
   - `.auto(plan)` → post the **countdown band**: "Starting notes in 5 · Cancel"
     plus the consent line; after `prefs.autoCountdown` seconds start the plan. Never
     silent.
2. Choosing a plan (`choose(_:remember:)`): if `plan.needsRecording` → the injected
   `startRecording(call, plan)` seam. Default: `plan.keepNotes` →
   `assistant.startDetectedCall()` (records the active call, opens the notepad, and
   auto-stops when the call ends); otherwise `assistant.start(title:calendarEventID:)`
   and A itself calls `assistant.stop()` when that call ends. If `plan.translate` →
   `translation.isEnabled = true` (+ `targetLanguage` if set). `remember` →
   `prefs.setRule(.auto(plan), for: kind)`. Post a 3 s consent toast
   (`MeetingIntelConsent.reminder` + `.detail`). When `assistant.phase == .recording`,
   build `MeetingIntelSession` with `id = assistant.current!.id` and fire
   `onSessionStarted` (the Center calls `live.begin(session)`).
3. "Not now" dismisses for this call; "Never for <service>" → `.never` for `kind.serviceOnly`.
4. Updated → refresh title in the band/brief. Ended → dismiss the prompt/countdown.
5. Recording ends (assistant `phase` leaves `.recording`) by any route → fire
   `onSessionEnded` (the Center does `let sidecar = await live.end()` then
   `wrapUp.present(meetingID:session:sidecar:)`).
6. Translation turned on only by this session is turned back off at the end
   (remember whether it was on before).
7. A recording started by hand (not from a call) still gets a session: A watches
   `assistant.$phase` and, on `.recording` without a session, builds one with
   `plan = .notes` so B and C work for every meeting.

### Prompt band layout (original)
```
[provider icon]  Google Meet · Design sync              ● 2 people you met Tue
 ┃ ◦ Agenda: pricing v2, launch date        (thread line + nodes, max 2 lines)
 ┃ ◦ You owe: send deck to Priya
[ Record notes ]  [ Captions ]  [ Translate ▾ ES ]      ☐ Always for Meet   ✕
 Let everyone know you're taking notes. Audio stays on this Mac.
```
Record notes is `SparkVPrimaryButtonStyle(tint: SparkVTheme.recording)`; others
secondary. "Always for …" checkbox maps to `remember`. Brief lines collapse when empty.

### Brief sources (all local, read-only)
- **Calendar:** only if `.calendars` is granted (`status`, never `request` from here).
  `EKEventStore().event(withIdentifier:)` → `notes` → agenda lines (bullets, numbered,
  "Agenda:" blocks; strip meeting-link boilerplate: Zoom/Meet/Teams dial-in text) and
  `attendees` → `MeetingAttendee`.
- **Meetings library:** `assistant.library`, scored by attendee overlap (names found in
  title/notes/transcript when attendees are known) else same normalized title/series;
  newest 3; their not-done `myTasks` → `openTasks`.
- **Spaces:** `SpaceStore.shared.search(title + attendee names, in: nil)` top 3.

### Contract
```swift
@MainActor
final class MeetingStartCoordinator: ObservableObject {
    enum Stage: Equatable {
        case idle
        case prompting(DetectedCall)
        case countingDown(DetectedCall, MeetingStartPlan, secondsLeft: Int)
        case live(MeetingIntelSession)
    }
    @Published private(set) var stage: Stage
    @Published private(set) var brief: MeetingBrief?

    /// Fired after recording really started for a session.
    var onSessionStarted: ((MeetingIntelSession) -> Void)?
    /// Fired when that session's recording ended (any route).
    var onSessionEnded: ((MeetingIntelSession) -> Void)?

    /// Recording seam (see Flow 2). INTEGRATION.md swaps in the exact
    /// detector-aware start once MeetingAssistant exposes it.
    var startRecording: (DetectedCall?, MeetingStartPlan) -> Void

    init(activities: ActivityCenter,
         assistant: MeetingAssistant,
         translation: LiveTranslationController?,
         calendar: @escaping () -> [CalendarMeeting],
         spaces: SpaceStore?,
         prefs: MeetingIntelPreferences = .shared,
         permissions: PermissionCenter = .shared)

    /// Subscribes to assistant.callDetector.$activeCall and assistant.$phase.
    func attach()
    func detach()

    func handle(_ event: MeetingCallEvent)
    /// For MeetingAssistant.callOfferOverride (INTEGRATION.md §5): true when
    /// MeetingIntel shows (or deliberately suppresses, rule .never) the offer.
    func wantsOffer(for call: DetectedCall) -> Bool
    func choose(_ plan: MeetingStartPlan, remember: Bool)
    func notNow()
    func never()                       // .never for kind.serviceOnly
    func cancelCountdown()
    /// Menu / Today tab: start without a detected call.
    func startManually(title: String?, calendarEventID: String?, plan: MeetingStartPlan)
}

enum MeetingBriefBuilder {
    static func build(title: String, calendarEventID: String?, event: CalendarMeeting?,
                      library: [MeetingRecord], spaces: SpaceStore?,
                      calendarGranted: Bool, now: Date) async -> MeetingBrief
    static func agendaLines(from notes: String) -> [String]          // pure, testable
    static func attendees(eventID: String) -> [MeetingAttendee]       // EventKit read, granted only
    static func related(_ library: [MeetingRecord], attendees: [MeetingAttendee],
                        title: String, limit: Int) -> [MeetingBriefPastMeeting]  // pure
}

/// Turns successive `activeCall` values into events (pure, testable).
struct MeetingCallEventDiffer {
    mutating func next(_ call: DetectedCall?) -> MeetingCallEvent?
}

struct MeetingStartPromptBand: View  { /* coordinator: MeetingStartCoordinator, call: DetectedCall */ }
struct MeetingCountdownBand: View    { /* plan, secondsLeft, onCancel */ }
struct MeetingBriefCard: View        { let brief: MeetingBrief }   // also used by Today tab

/// Root: owns A and talks to B and C through the protocols.
@MainActor
final class MeetingIntelCenter: ObservableObject {
    static weak var current: MeetingIntelCenter?
    let start: MeetingStartCoordinator
    init(start: MeetingStartCoordinator, live: any MeetingLiveAssisting, wrapUp: any MeetingWrappingUp)
    func start()                                 // start.attach(); wires onSessionStarted/Ended to live/wrapUp
    func stop()                                  // at quit
    func handle(_ event: MeetingCallEvent)       // forwards to start (tests)
    func bookmarkNow()                           // live.bookmarkNow(note: nil)
}
```

## 5. Part B — `LiveAssist.swift` (builder B)

**Job:** while a session records: flag action items and decisions from the live
transcript, surface questions (existing detection), meter talk time and nudge on
long monologues, bookmark moments, and show a caption band.

### Inputs
- `assistant.$current` → `segments` (volatile replaced in place by id; act only on
  `isFinal` for flags; volatile OK for the meter/captions).
- `assistant.$liveAnswer` → a `.question` flag (`origin: .assistant`) — the answer card
  itself stays MeetingAssistant's; B only records it on the timeline.

### Flagging (on device)
1. **Rules first** (instant, `MeetingFlagDetector.flags(in:userName:)`): commitment
   phrases ("I'll", "I will", "we'll", "let me", "can you", "<Name> will", "action
   item", "by Friday/EOD/next week", "follow up") → `.actionItem` with owner
   (`isMine` when speaker `.me` and first person, or the user's first name is the
   subject); decision phrases ("we decided", "let's go with", "agreed", "final answer",
   "we're going with", "ship it") → `.decision`. Due phrases extracted to `due`.
2. **Model second** (optional, coalesced every ~20 s, only if candidates exist):
   `MeetingAIBackend.onDevice(...)` with a small schema to confirm/clean the candidate
   text and owner, `origin: .model`. Never Groq here.
3. De-dupe by normalized text within 90 s. Max one toast every 20 s.
4. Toast: transient (≤ 3 s) band `MeetingIntelActivity.flag`, priority 66, one line:
   `[glyph] Action · You: send the deck by Fri   Undo`. Undo → `dismiss(flagID:)`.

### Talk time and nudge
- `MeetingTalkTime.compute(segments, monologueThreshold: prefs.monologueSeconds)` on
  each change, throttled to 1 Hz.
- Meter: the caption band's trailing edge shows `MeetingTalkShareBar` + "You 38%".
  B does not replace the REC wings (owned by MeetingAssistant).
- Nudge: when `currentMonologue ≥ monologueSeconds` and `prefs.monologueNudge`: one
  two-line band (`nudge`, priority 63, 6 s): "You've had the floor for 2 min · maybe
  check in with the room". At most once per 5 min; never while others are speaking.

### Bookmark
`bookmarkNow(note:)` → `.bookmark` flag at the current recording time (from the
newest segment `end`, else `Date() - session.startedAt`), `origin: .user`, toast
"Moment saved · 12:41". Entry points: a button on the caption band, the menu, and the
recording band button described in INTEGRATION.md.

### Caption band
- Shown when `plan.captions && !plan.translate` (translation draws its own band and
  window through LiveTranslationController; B never duplicates it).
- `MeetingIntelActivity.captions`, priority 62, `duration: nil`, height 48: two lines,
  newest at the bottom, speaker shown as a small leading tick (me = `accent`, others =
  `textSecondary`), volatile text in `textTertiary`. Trailing: talk meter + bookmark
  button + close. Compact form: none (REC wings stay).

### Persistence
Every flag change → `MeetingIntelSidecarStore.shared.update(id) { $0.flags = … }`
(coalesced 2 s); `end()` writes final `talk` stats and returns the sidecar.

### Contract
```swift
struct MeetingCaptionLine: Identifiable, Equatable, Sendable {
    let id: UUID              // segment id
    var speaker: MeetingSpeaker
    var text: String
    var isFinal: Bool
    var at: TimeInterval
}

@MainActor
final class LiveMeetingAssist: ObservableObject, MeetingLiveAssisting {
    @Published private(set) var session: MeetingIntelSession?
    @Published private(set) var flags: [MeetingFlag]
    @Published private(set) var talk: MeetingTalkStats
    @Published private(set) var captionLines: [MeetingCaptionLine]   // last ~6
    @Published var captionsVisible: Bool

    init(activities: ActivityCenter,
         assistant: MeetingAssistant,
         prefs: MeetingIntelPreferences = .shared,
         store: MeetingIntelSidecarStore = .shared,
         userName: String = MeetingAssistant.userName)

    // MeetingLiveAssisting
    func begin(_ session: MeetingIntelSession)
    func update(plan: MeetingStartPlan)
    func bookmarkNow(note: String?)
    func end() async -> MeetingIntelSidecar?

    func dismiss(flagID: UUID)
    func flag(segmentID: UUID, as kind: MeetingFlagKind)
    func setNote(_ note: String, flagID: UUID)
    /// Test seam: feed a transcript snapshot without MeetingAssistant.
    func ingest(_ segments: [TranscriptSegment], at now: Date)
}

enum MeetingFlagDetector {
    static func flags(in segment: TranscriptSegment, userName: String) -> [MeetingFlag]   // pure
    static func dueText(in text: String) -> String?                                       // pure
    static func normalizedKey(_ text: String) -> String                                    // pure, for de-dupe
    static func refine(_ candidates: [MeetingFlag], context: [TranscriptSegment],
                       userName: String) async -> [MeetingFlag]                            // on-device model; returns input on failure
}

struct MeetingCaptionBand: View   { @ObservedObject var assist: LiveMeetingAssist }
struct MeetingFlagToast: View     { let flag: MeetingFlag; let onUndo: () -> Void }
struct MeetingNudgeBand: View     { let stats: MeetingTalkStats }
struct MeetingFlagTimeline: View  { let flags: [MeetingFlag]; var onSelect: (MeetingFlag) -> Void }  // reused by C
```

## 6. Part C — `WrapUp.swift` (builder C)

**Job:** after the call: summary card, follow-up email draft (Mail draft or copy;
never sends), add tasks to Reminders on approval, file into a Space, talk-time stats.

### Flow
1. `present(meetingID:session:sidecar:)`: if `plan.keepNotes`, wait for
   `assistant.record(id:)?.notes` (observe `assistant.$library` / `$phase` until the
   minutes exist; give up after 3 min with what there is); else present right away.
2. Post a **wrap-up peek** (`wrapUp`, priority 61, 12 s, `.expanded`, 48 pt):
   `● Design sync · 32 min · 3 tasks for you · 2 decisions   [Review]`. Review opens
   the wrap-up window. Clicking nothing does nothing else.
3. **Wrap-up window** (NSPanel, `MeetingWrapUpWindowController`), sections down a
   thread line:
   - Summary (`notes.summary`, decisions, key points) + "Open full notes"
     (`assistant.openNotesWindow(meetingID:)`).
   - Moments: `MeetingFlagTimeline` from the sidecar (bookmarks, flagged decisions).
   - Talk time: `MeetingTalkShareBar`, "You 41% · longest stretch 2:10 · 14 turns".
   - Tasks → Reminders: every `myTasks` (+ action-item flags not already in notes),
     checkbox each (all unticked by default), parsed due dates editable;
     **Add N to Reminders** → `reminders.request(from: "Meeting wrap-up")` only now,
     then create `EKReminder`s in the default reminders list with title, due date,
     notes "From <meeting> · <date>", url `sparkv://meeting/<id>` if the scheme exists
     else none. Store ids in `remindedTaskIDs`; ticked tasks show "In Reminders".
   - Follow-up: editable To / Subject / Body. To = attendee emails (from
     `session.brief.attendees` minus me) — empty if unknown. Buttons: **Open draft in
     Mail** (`NSWorkspace.shared.open(mailtoURL)`; if nil, copy and say so) and
     **Copy**. Body written by a template; "Polish" button runs the on-device model
     (Groq only if `allowGroqForMeetings`). Never sends.
   - File into Space: picker of `SpaceStore.shared.spaces` (current persona), suggested
     one preselected from the Spaces routing (the existing item for sourceKey
     `"meeting:<id>"`'s `spaceID`, else best `search` hit's space). **File** → find the
     item by sourceKey in `SpaceStore.shared.items`; if missing,
     `SpaceConnectors.meetingInput(record, attendees:)` → `ingest`; then
     `move(itemID:to:)`. Record `filedSpaceID`.
4. Every action updates `MeetingWrapUpState` in the sidecar so nothing is offered twice.

### Follow-up template
```
Subject: Recap: <title> (<Mon 21 Oct>)
Hi <first names or "all">,
Thanks for the time today. Quick recap:
Decisions
- …
Next steps
- <owner>: <task> (<due>)
Open questions
- …
<user first name>
```

### Contract
```swift
struct MeetingWrapUpModel: Equatable {
    var meetingID: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var notes: MeetingNotes?
    var flags: [MeetingFlag]
    var talk: MeetingTalkStats?
    var proposals: [MeetingReminderProposal]
    var draft: MeetingFollowUpDraft
    var suggestedSpaceID: UUID?
    var state: MeetingWrapUpState
}

@MainActor
final class MeetingWrapUpController: ObservableObject, MeetingWrappingUp {
    @Published private(set) var model: MeetingWrapUpModel?
    @Published private(set) var busy: Set<String>       // "reminders", "polish", "file"
    @Published private(set) var message: String?        // last result line

    init(activities: ActivityCenter,
         assistant: MeetingAssistant,
         spaces: SpaceStore?,
         reminders: any MeetingRemindersGate,
         store: MeetingIntelSidecarStore = .shared)

    // MeetingWrappingUp
    func present(meetingID: UUID, session: MeetingIntelSession?, sidecar: MeetingIntelSidecar?)
    func openWindow(meetingID: UUID)

    func toggleProposal(_ id: UUID)
    func setDue(_ date: Date?, proposal id: UUID)
    func addSelectedToReminders() async -> Int          // asks permission here, only on click
    func updateDraft(_ draft: MeetingFollowUpDraft)
    func polishDraft() async
    func openDraftInMail() -> Bool                       // false -> copied instead
    func copyDraft()
    func file(into spaceID: UUID) async -> Bool
    func dismiss()
}

enum MeetingFollowUpWriter {
    static func draft(record: MeetingRecord, attendees: [MeetingAttendee], userName: String) -> MeetingFollowUpDraft // pure
}
enum MeetingDueDateParser {
    static func date(from spoken: String, relativeTo now: Date, calendar: Calendar) -> Date?  // pure: "Friday", "tomorrow", "EOD", "next week", "Oct 30"
}
enum MeetingReminderWriter {
    /// Creates reminders in the default list. Caller already has access.
    static func add(_ proposals: [MeetingReminderProposal], meetingTitle: String, date: Date,
                    store: EKEventStore) throws -> [UUID: String]
}

struct MeetingWrapUpPeek: View      { let model: MeetingWrapUpModel; let onReview: () -> Void }
struct MeetingWrapUpView: View      { @ObservedObject var controller: MeetingWrapUpController }
final class MeetingWrapUpWindowController { init(controller: MeetingWrapUpController); func show(); func close() }
```

Reminders permission: PermissionCenter has no `.reminders` case today. C uses the
`MeetingRemindersGate` protocol; INTEGRATION.md has the exact PermissionCenter patch
and the adapter `PermissionCenterRemindersGate`. Until that lands, C's own file may
ship a `MeetingRemindersUnavailableGate` returning `.unavailable` (button hidden with
"Reminders isn't connected yet").

---

## 7. Privacy checklist (all builders)

- [ ] No network call except through `MeetingAIBackend` with Groq gated by
      `allowGroqForMeetings`.
- [ ] Recording never starts without either a click or a visible countdown with Cancel,
      and the consent line is shown at every start.
- [ ] REC wings never covered (priorities above).
- [ ] Mail: only `mailto:` drafts or the clipboard. No AppleScript `send`.
- [ ] Reminders: created only from ticked items after a click; permission asked only
      then, through PermissionCenter.
- [ ] Spaces: move/ingest only on File click (the existing auto-ingest is unchanged).
- [ ] Calendar: read only when already granted; MeetingIntel never prompts for it.
- [ ] Sidecar lives in Application Support/SparkV/MeetingIntel; delete with the meeting.

## 8. Tests each builder should leave (pure functions)

- A: `agendaLines(from:)` with Zoom/Meet/Teams boilerplate; `related(...)` ordering;
  `MeetingKindKey(call:)` with generic vs calendar titles; rule fallback series→service.
- B: `MeetingFlagDetector.flags` on 20 phrases (mine vs others, decisions, negatives
  like "I will not be there" must not flag); `MeetingTalkTime.compute` with
  backchannels and gaps.
- C: `MeetingDueDateParser` across weekdays/EOD/month names; `MeetingFollowUpWriter`
  output; `MeetingFollowUpDraft.mailtoURL` length fallback.
