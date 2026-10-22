# SparkV on iPhone: the Apple-style plan

_Status, October 2026: Phase 0 is built. Everything after it needs Xcode and a paid Apple Developer account._

## What works today: iCloud Drive and the Files app

SparkV can already put your content on your iPhone. Turn on **Sync to iPhone** (Agents hub › iPhone, or `CloudSyncWindowController`) and SparkV keeps **iCloud Drive › SparkV** up to date:

| On the iPhone (Files › iCloud Drive › SparkV) | What it is |
| --- | --- |
| `Meetings/2026-10/2026-10-22 1430 Design review.md` | Your tasks, minutes, key points, decisions, open questions, your own notes and (optionally) the transcript |
| `Notes/…`, `Dictation/2026-10/2026-10-22.md` | Flow notes and dictation history |
| `Spaces/<Space>/<item>.md` (+ attachment) | Everything filed in Spaces, one folder per Space |
| `Tray/`, `Clipboard/Pinned.md`, `Focus/2026-10.md`, `Modes/2026-10.md`, `Habits.md` | Shelf copies, pinned text (no passwords), session summaries, streaks |
| `Inbox/` | **Send to Mac:** anything saved here from the share sheet ("Save to Files") shows up in SparkV within about a minute. Text and links go to the Spaces Inbox; photos and files go on the Tray. |

It needs no entitlement, no Developer account and no iOS app: it is an ordinary iCloud Drive folder. SparkV writes only what changed, never deletes (old files go to `.trash`, edited ones to `Conflicts`), and pauses rather than rebuild a folder you deleted. Details are in `Sources/Labs/CloudSync/INTEGRATION.md`.

**Limits of the folder approach:**

- It is one-way plus an Inbox: editing a note on the iPhone does not change SparkV.
- Markdown in Files is readable, but you can't tick a task done from there.
- There are no widgets, Live Activities or notifications on the phone.
- Anything in the folder is in your iCloud, readable by any device signed in to that Apple Account. Pinned clipboard is off by default, and anything that looks like a password, key, code or card number is left out of the clipboard file, the Tray text and copied Spaces items. Files that SparkV moves to `.trash` and `Conflicts` stay in iCloud Drive until you delete them in Files; turning a category off leaves its files where they are.
- A second Mac on the same Apple Account writes to `SparkV/<Mac name>/` rather than merging with the first.

Macs already give you two "Apple-like" pieces for free:

- **Universal Clipboard.** Copy on the iPhone, paste on the Mac, and the other way round. It works with SparkV's clipboard history today. SparkV marks those copies as remote (`com.apple.is-remote-clipboard`), and there is an option to ignore them.
- **AirDrop** between the two devices. SparkV's Tray already sends to the iPhone with AirDrop, and files AirDropped to the Mac can be dropped on the Tray.

## The full version: a SparkV iPhone app with CloudKit

### What the user gets

1. **Everything, live, both ways:** Spaces and their items, Flow notes, meeting minutes, tasks (tick one on the iPhone and it ticks on the Mac), pinned clipboard and habits. All of it lives in the user's own iCloud (CloudKit **private database**). SparkV runs no server and never sees the data.
2. **Capture from anywhere on the iPhone:** a share extension ("Save to SparkV" files into the Spaces Inbox or a chosen Space), a home-screen quick note, and dictation.
3. **Glanceable:**
   - Home and Lock Screen **widgets**: next meeting, my open tasks, today's focus time, habits.
   - A **Live Activity** and Dynamic Island while a meeting is recorded on the Mac (elapsed time, "3 tasks so far") or a Focus session runs (time left).
   - An Apple Watch complication later.
4. **Handoff:** the meeting or note you have open on the Mac appears in the iPhone app switcher, and the other way round.
5. **Shortcuts and Siri** through App Intents on both platforms:
   - "Add to SparkV Inbox"
   - "What are my tasks from today's meetings?"
   - "Start a 25-minute Focus"
   - "Latest meeting notes"
   - "Log habit Read"

   They also show up in Spotlight and the Action button.
6. **Later:** shared Spaces with friends or teammates via `CKShare`, the Apple-native version of today's `.sparkvspace` export.

### Architecture

```
SparkV (macOS, AppKit/SwiftUI)          SparkV (iOS, SwiftUI)          Widgets / Live Activity / Intents
        |                                        |                                  |
   SparkVKit (shared Swift package): models, local SQLite store, CKSyncEngine sync, App Intents
        |                                        |
        +------------ CloudKit private database (user's iCloud, zone "SparkV") ------------+
                                   (+ CKAssets for transcripts, screenshots, files)
```

- **SparkVKit**, a Swift package shared by both apps:
  - Today's model types (`Space`, `SpaceItem`, `MeetingRecord`, `ActionItem`, `FlowNote`, `Habit`, `FocusSessionRecord`), each with sync metadata: `modifiedAt`, `deletedAt` tombstones, and the CloudKit system fields blob.
  - The local store. Spaces already uses SQLite, so the others move there too.
  - **`CKSyncEngine`** (iOS 17 and macOS 14 or later), which handles batching, retries, push-driven fetches, account changes and zone resets.
- **Record types (custom zone `SparkV`):**

  | Record type | Notes |
  | --- | --- |
  | `Persona` | |
  | `Space` | Parent reference |
  | `SpaceItem` | Large text and attachments as `CKAsset` |
  | `Meeting` | Notes as fields, transcript as `CKAsset` |
  | `Task` | Separate records, so ticking one never conflicts with an edit to the minutes |
  | `Note` | |
  | `ClipboardPin` | Text in `encryptedValues` |
  | `Habit` and `HabitDay` | |
  | `FocusSession` | |
  | `ModeSession` | |

- **Privacy:** sensitive fields (clipboard pins, notes text, transcripts) go in CloudKit `encryptedValues`, so they are end-to-end encrypted with the user's iCloud keys. Data counts against the user's own iCloud storage.
- **Conflicts:**
  - Field-level last-writer-wins, using `modifiedAt`.
  - Task `isDone` uses the latest toggle.
  - When both sides edited a note's text, the loser is kept as "Note (conflict copy)", the same rule the iCloud Drive folder uses today.
- **Settings and small state** (which categories are on, the current persona) go through `NSUbiquitousKeyValueStore`.
- **Live Activities:**
  - The iPhone app can start a Live Activity itself only while it is in the foreground.
  - To start or update one from the Mac ("meeting started"), use ActivityKit **push-to-start and update pushes** (iOS 17.2 or later). These need APNs, and APNs needs a tiny relay: a Cloudflare Worker or similar holding the APNs auth key, which the Mac calls with the activity's push token.
  - Without the relay, the widgets still refresh from CloudKit pushes; only the live, second-by-second activity needs APNs.
- **Handoff:** `NSUserActivity` with shared activity types (`com.sparkv.meeting`, `com.sparkv.note`, `com.sparkv.space`). Both apps must be signed by the same Team ID.
- **Universal Clipboard** needs no work. It stays the system feature.

### What it needs

| Need | Why | Cost |
| --- | --- | --- |
| **Apple Developer Program** | iCloud/CloudKit container, push notifications, App Groups, Handoff (same team), TestFlight, App Store. A self-signed build cannot carry these entitlements: macOS kills an app that claims `com.apple.developer.icloud-*` without a matching provisioning profile. | $99 per year |
| **Xcode** (full, not only the Command Line Tools) | iOS builds and signing, simulators, widget and Live Activity extensions, App Intents metadata extraction, asset catalogs. It also lifts today's CLT limits (`@State`, `#Preview` and other macros). | Free |
| **iCloud container** `iCloud.com.sparkv.app` and the CloudKit schema, deployed from development to production in the CloudKit Console | The shared database | Free (uses the user's iCloud storage) |
| **Mac app re-signed with Developer ID, plus a provisioning profile and notarization** | CloudKit on macOS outside the App Store. The same change fixes Gatekeeper warnings when you share SparkV with friends. | Included |
| **APNs auth key and a small relay** | Only for Live Activities driven from the Mac | Free tier is enough |
| **App Store review** for the iOS app | Privacy nutrition labels (data stays in the user's iCloud, no tracking), usage strings, a demo of the Mac pairing in the review notes | 1 to 7 days per round |

### Phased plan and effort (one developer)

| Phase | Scope | Effort |
| --- | --- | --- |
| **0. Done** | iCloud Drive folder, Files app on iPhone, Inbox import (`Sources/Labs/CloudSync`) | Done |
| **1. Accounts and signing** | Enroll in the Developer Program; Xcode project for the Mac app (or keep build.sh and add `codesign` with a Developer ID and an embedded provisioning profile); notarization; bundle ids `com.sparkv.app` and `com.sparkv.app.ios`; iCloud container, App Group, push capability | 2 to 3 days |
| **2. SparkVKit and Mac sync** | Extract models into the package; add sync metadata and tombstones; SQLite stores for Flow, Meetings, Habits and Focus (Spaces already has one); `CKSyncEngine` with a custom zone, account-change handling and a first full upload; keep the iCloud Drive mirror as an export | 2 to 3 weeks |
| **3. iPhone app MVP** | SwiftUI tabs: Today (next meeting, my tasks), Meetings (minutes, tick tasks), Spaces (browse, search, add), Notes; share extension into the Spaces Inbox; onboarding ("sign in to the same iCloud as your Mac"); empty, offline and quota states | 3 to 4 weeks |
| **4. Glanceables and intents** | WidgetKit widgets (next meeting, tasks, focus, habits); Live Activity for meeting and Focus (with the APNs relay); App Intents and Shortcuts on both platforms; Handoff | 2 to 3 weeks |
| **5. Beta and release** | TestFlight with friends, CloudKit schema to production, App Store review, Mac update with Developer ID | 1 to 2 weeks |
| **6. Later** | Shared Spaces (`CKShare`), Apple Watch, iPad layout and multitasking | Open |

**Total: about 9 to 13 weeks** to a TestFlight-quality iPhone app with two-way sync, widgets and Live Activities. Phases 2 and 3 are the long pole. The models already exist and are `Codable`, so most of the work is adding sync metadata and building the iOS UI.

### Risks and how to handle them

- **CloudKit quotas and large transcripts:** store transcripts and attachments as `CKAsset`, fetch them on demand on the iPhone, and keep only minutes and tasks inline.
- **Schema changes after release** (CloudKit production schemas can only be added to): version the records and keep fields optional.
- **The user turns iCloud off or signs out:** `CKSyncEngine` reports account changes. Keep local data and pause sync, the same way the iCloud Drive mirror pauses today.
- **Two Macs and one iPhone:** CloudKit merges all devices into one dataset. This removes today's "one folder per Mac" workaround.

## Until then

Turn on **Sync to iPhone** in SparkV and open **Files › iCloud Drive › SparkV** on the iPhone. It already gives you your meetings, notes, Spaces and habits on the phone, and the **Inbox** folder sends things back to the Mac.
