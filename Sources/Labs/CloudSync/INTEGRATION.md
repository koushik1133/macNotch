# Sync to iPhone (iCloud Drive): wiring steps for the lead

Everything lives in `Sources/Labs/CloudSync/`. I didn't edit any existing file. The feature is opt-in and off by default: nothing reads or writes iCloud Drive until the user turns it on.

It mirrors SparkV content into **iCloud Drive › SparkV** (`~/Library/Mobile Documents/com~apple~CloudDocs/SparkV/`). That's a plain iCloud Drive folder, so it needs no iCloud entitlement, provisioning profile or Developer account. The iPhone and iPad **Files** app shows it under Browse › iCloud Drive › SparkV. Files saved into `SparkV/Inbox` from the iPhone (share sheet › Save to Files) come back into Spaces and the Tray.

## What it contains

| File | What it is |
| --- | --- |
| `CloudSyncModels.swift` | `CloudSyncCategory` (meetings, flowNotes, dictations, spaces, tray, clipboard, focus, modes, habits), `CloudSyncSettings` (JSON, tolerant decode), `CloudSyncFile`, `CloudSyncManifest`, `CloudSyncReport`, `CloudSyncStatus`. |
| `CloudSyncPaths.swift` | File-name rules that are safe for APFS, iCloud and iOS. Also holds `CloudSyncLocation` (iCloud Drive on or off, custom folder present or missing) and `CloudSyncOwner`: a second Mac on the same Apple Account writes to `SparkV/<Mac name>/` instead of fighting the first one. |
| `CloudSyncEngine.swift` | The incremental mirror: hashes per file, renames, conflict copies, trash, scopes and the mass-removal guard. All writes and moves go through `NSFileCoordinator`. |
| `CloudSyncInbox.swift` | The two-way part: imports settled files from `SparkV/Inbox`, then archives each original to `Inbox/Imported/<day>/`. |
| `CloudSyncSecrets.swift` | A second filter for pinned clipboard text: keys, tokens, card numbers and password-like strings never get written. |
| `CloudSyncRenderer.swift` | Turns SparkV data into Markdown and copies (`CloudSyncInput` → files). It reuses `MeetingFormat.markdown`. |
| `CloudSyncController.swift` | `CloudSyncController.shared`: settings, the debounced scheduler, the Inbox watcher, the background `CloudSyncJob`, import delivery, and `CloudSyncModeLog`, which records Mode runs because `ModeEngine` keeps only the active one. |
| `CloudSyncViews.swift` | `CloudSyncSettingsView` (SparkVTheme), `CloudSyncStatusRow` (one line for the drawer or Settings), `CloudSyncWindowController.shared.show()`, and `CloudSyncController.importActivity(_:)` (a notch band). |
| `Tests/` | `CloudSyncTests.swift` and `run-tests.sh`. They're in a subfolder, so the `*.swift` glob in build.sh skips them. |

## 1. build.sh: compile the folder

Next to the other `Labs` lines:

```zsh
cp Sources/Labs/CloudSync/*.swift "$WORK/src/"
```

No new frameworks or linker flags. CryptoKit, Combine, SystemConfiguration and UniformTypeIdentifiers are autolinked. It needs no new entitlement: SparkV isn't sandboxed, and `~/Library/Mobile Documents` is an ordinary folder for it.

## 2. NotchWindowController.swift: connect and start

The Tray, clipboard, Focus and meeting stores aren't singletons, so hand them over. Do this in `init` after `meetingAssistant.start()` (next to `spacesIngest.start()`):

```swift
        let cloudSync = CloudSyncController.shared
        cloudSync.connect(meetings: meetingAssistant, tray: tray, clipboard: clipboard, focus: focus)
        cloudSync.onImport = { [weak self] message in
            self?.activities.post(CloudSyncController.importActivity(message))
        }
        // Does nothing unless the user turned sync on; then the first sync runs 8 s after launch.
        cloudSync.start()
```

In `tearDown()`:

```swift
        CloudSyncController.shared.stop()
```

FlowStore, SpaceStore, HabitStore and ModeEngine are read through their `shared` instances. Nothing else has to be injected.

## 3. An entry point (pick one or both)

**Agents hub tile.** `AgentHubMetrics` says 22 of 24 slots are used. In `AgentsHubView.cells`, for example after `.agent(... "Setup" ...)`:

```swift
            .agent(Agent(tab: nil, title: "iPhone", systemImage: "iphone.and.arrow.forward", tint: SparkVTheme.red,
                         help: "Sync to iPhone: keeps iCloud Drive › SparkV up to date for the Files app",
                         open: { CloudSyncWindowController.shared.show() })),
```

**Settings or a drawer row.** `CloudSyncStatusRow(controller: .shared)` is one line: status dot, "Up to date · 14:32", and an Open / Set Up button. It fits any settings list or the 508 pt drawer.

## 4. Info.plist (recommended)

Some macOS versions ask before an app reads files that a File Provider manages, and iCloud Drive is one of those. Add this key so the prompt explains itself:

```xml
	<key>NSFileProviderDomainUsageDescription</key>
	<string>SparkV keeps a SparkV folder in iCloud Drive up to date so you can read your meetings and notes on your iPhone.</string>
```

The prompt, if any, appears only once, when the user turns sync on, because nothing touches iCloud Drive before that. If macOS refuses, sync stops completely: no retry loop and no repeated prompts. The page then shows "Open Privacy Settings" and "Retry".

## How it behaves

- **Folder layout:**
  - `Meetings/<yyyy-MM>/<date time title>.md` (tasks, minutes, decisions, my notes, transcript if on)
  - `Notes/<first line>.md`
  - `Dictation/<yyyy-MM>/<day>.md`
  - `Spaces/[<Persona>/]<Space path>/<item>.md` with its attachment copied next to it; unfiled items go in `Spaces/Unfiled/`
  - `Tray/` (copies of images and files, plus `Tray text.md`)
  - `Clipboard/Pinned.md`
  - `Focus/<yyyy-MM>.md` and `Modes/<yyyy-MM>.md`
  - `Habits.md`
  - `README.md`
  - `Inbox/` (with `Inbox/Imported/`)
  - `Conflicts/`
  - `.trash/` (hidden)
- **Incremental:** a run writes a file only when its SHA-256 changed. Unchanged files are recognized by size and modification date, so a quiet run reads nothing from iCloud Drive and never downloads evicted files. The manifest stays on this Mac in `~/Library/Application Support/SparkV/CloudSync/manifest-<id>.json` and is saved only when it changes.
- **Debounced:** a change is synced after 3 s of quiet and waits at most 45 s. Runs never overlap. All file work runs in a utility-priority detached task. The Inbox is watched with a vnode source and polled every 60 s; a full re-check runs every 15 min, which also picks up the new day for Habits.
- **Never deletes:**
  - A file whose source is gone moves to `.trash/<day>/<same path>`.
  - A file edited outside SparkV (on the iPhone, in Finder, by another Mac) moves to `Conflicts/<path> (edited <time>).md` before SparkV writes its own version.
  - An unknown file already sitting at a target path is adopted if its content is identical and preserved if it differs.
  - Only folders the mirror itself emptied are removed (allowing a lone `.DS_Store`).
- **Renames:** a renamed meeting, an edited first line of a note or a renamed Space moves the file. It doesn't trash and rewrite it.
- **Safety valves:**
  - A category that is off, or whose store isn't connected, is frozen: its files stay as they are.
  - For 2 minutes after launch, an empty store with files already in iCloud Drive counts as "still loading".
  - A run that would remove more than 20 files and over half of a category is held, judged per category (30 meetings vanishing is held even when 200 Spaces files are fine; other categories still sync). The page then offers "Move N Files to Trash".
  - A folder inside the mirror that is a symlink leading outside it never receives writes or moves (the run reports an error for that file only).
  - A second Mac claims `SparkV/<Mac name>/` (then `<Mac name> 2`… when Macs share a name; a Mac named like a SparkV folder, e.g. "Notes", gets "Notes (Mac)"). If the folder's owner file is still an iCloud placeholder or can't be downloaded, the run waits and retries in 30 s instead of claiming another Mac's folder. A damaged owner file counts as another Mac's.
  - If the whole SparkV folder is deleted (say, from the iPhone), sync pauses and offers "Create the Folder Again". It doesn't silently rebuild.
  - iCloud Drive turned off, or a custom folder whose drive is unplugged: a clear message, and the parent folder is never created.
  - A damaged manifest is moved aside and sync starts over safely (files are recognized by content).
  - Disk full or permission errors stop the run.
- **Inbox:**
  - A file is imported once its size and date have held for 2 s; uploads still in progress wait.
  - `.icloud` placeholders get a download request and wait. Folders are skipped with a note, and so are empty files and files over 200 MB. Text over 2 MB or binary data renamed `.txt`, and a `.webloc` without a web address, arrive as files on the Tray (so they are not re-hashed on every scan).
  - `.md`, `.txt` and `.rtf` become Spaces Inbox notes, titled from the first heading. `.webloc` and `.url` become Spaces links.
  - Images and other files go on the Tray, which hands them to Spaces if its Tray source is on, or straight to Spaces when no Tray is connected.
  - Duplicate content (same SHA-256 as an earlier import) is archived, not imported twice.
  - SparkV keeps its own copy in `Application Support/SparkV/CloudSync/Received/`, so Tray references survive iCloud eviction. Copies are pruned after 30 days unless the Tray still points at them.
- **Clipboard and other copied text:** pinned clipboard is off by default. Only pinned text and URLs go out. The history never records concealed or transient copies or password managers in the first place; pins copied in a password manager app are left out anyway, and `CloudSyncSecrets` also leaves out anything that looks like a key, token, card number or password, including inside a sentence ("wifi password …", "PIN 4821", "verification code 482913", a card number with an expiry). The same filter applies to Tray text and to Spaces items that came from the clipboard. Each file (or the run's skipped notes) says how many items were left out. It errs toward leaving things out.
- **Settings** live in `Application Support/SparkV/CloudSync/settings.json`, not in UserDefaults. Mode runs are logged in `mode-sessions.json` there, but only while Modes sync is on.

## Tests

```zsh
# Engine, Inbox, names, owner, secrets, settings (seconds, Foundation only):
Sources/Labs/CloudSync/Tests/run-tests.sh quick
# Plus rendering of real SparkV types, full jobs and the controller (compiles the app minus @main):
GLANCE_DIR=<dir with modules/GlanceKit.swiftmodule and lib/libGlanceKit.a> Sources/Labs/CloudSync/Tests/run-tests.sh full
```

Both modes run entirely in a scratch folder, never iCloud Drive. Current result (after independent validation): quick 116/116, full 161/161. The full mode's controller test syncs Habits only, so it leaves the real Spaces database alone. Its log lines go to `~/Library/Logs/SparkV.log` unless you compile a copy with `AppLog.log` stubbed (the validator did).

## Known limits (today, without a Developer account)

- This is a one-way mirror plus an Inbox. Editing a mirrored file on the iPhone does not change SparkV (the edit is kept in Conflicts). True two-way sync of Spaces, notes and tasks needs CloudKit and an iOS app: see `docs/iPhone-Companion-Plan.md`.
- How fast the iPhone sees changes depends on iCloud Drive, usually seconds to a minute on Wi-Fi.
