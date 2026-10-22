# Download watcher: design note

## How production tools do it

| Topic | What working tools do | Source |
|---|---|---|
| Live progress across apps | Browsers publish an `NSProgress` per download with `kind = file`, `NSProgressFileOperationKindKey = downloading`, `NSProgressFileURLKey` set to the file, and the source in `NSProgressFileDownloadingSourceURLKey`. They call `publish`, then `unpublish` when the download leaves the in-progress state. This is what Finder and the Dock's Downloads stack draw. Any process can listen with `+[NSProgress addSubscriberForFileURL:withPublishingHandler:]`, which fires for the URL itself or anything it directly contains, on the main thread. | Chromium `chrome/browser/download/download_status_updater_mac.mm`; `NSProgress.h` in the macOS SDK |
| The `com.apple.progress.fractionCompleted` xattr | A third-party report says writing it draws nothing; only a published NSProgress does. We don't rely on it. | go-macos/fileprogress README |
| Safari in-flight files | A `name.ext.download` package holding `Info.plist` (`DownloadEntryURL`, `DownloadEntryProgressTotalToLoad`, `DownloadEntryProgressBytesSoFar`, the same keys as Safari's Downloads.plist history) and the partial data file. | Safari 1.2 notes (mjtsai.com, 2004); plaso `safari_downloads` parser |
| Chromium / Firefox in-flight files | Chromium: `name.crdownload` (older builds: `Unconfirmed N.crdownload`), renamed in place. Opera: `.opdownload`. Firefox: `name.part` plus a zero-byte placeholder `name`, and the `.part` is renamed over it. | Browser behavior; SpaceIngestCenter already skips these suffixes |
| Where a file came from | `com.apple.metadata:kMDItemWhereFroms` is a binary plist array of [file URL, referring page]. Hazel's "Source URL/Address" condition reads it. Safari and Firefox set it, and so do Chromium builds. `com.apple.quarantine` = `flags;hex time;agent;UUID` names the downloading app. | Hazel forums, `mdls -name kMDItemWhereFroms`, macOS quarantine format |
| Sorting rules | Hazel: per-folder rules with all/any conditions (Kind, Extension, Name, Source URL, Size…). Rules run top to bottom, and a rule that moves the file ends processing. The classic recipe sorts Downloads into subfolders by Kind. | noodlesoft.com "About Folders & Rules", Hazel rule examples |
| Low-overhead watching | FSEvents with file-level events and kernel coalescing (latency), handled on a private queue. | Apple File System Events guide |
| Notch products | boring.notch shows a browser download indicator (`components/Live activities/DownloadView.swift`). It's GPL-3.0, so we reuse the idea only, not the code. NotchNook and Dropzone show the active download in the bar with a progress ring. | github.com/TheBoredTeam/boring.notch |

No permissively licensed library did this end to end. The FSEvents wrapper (~60 lines) and the NSProgress subscription are thin uses of system APIs, so nothing was vendored.

## Decisions for SparkV

1. **Opt-in.** `~/Downloads` is TCC-protected, so the controller doesn't touch it at launch. The first folder listing happens when the user presses Turn On, which triggers the system prompt. A permission error (`NSFileReadNoPermissionError`, `EPERM`/`EACCES`) shows a "blocked" state with Open Settings and Try Again instead of failing silently.
2. **Three signals, cheapest first.**
   - FSEvents (`FileEvents | NoDefer`, 0.3 s latency) reports changed paths. Only top-level entries, and the direct contents of `.download` packages, are `lstat`ed. Deeper paths, such as unzipping into Downloads, are dropped by a string check.
   - The NSProgress subscription gives exact total/received bytes and the source URL when the browser publishes them. Updates are throttled to 4 per second.
   - A 1 s sampler runs only while something is in flight. It measures size growth, smoothed speed (exponential moving average, α = 0.3, as in Chromium), ETA and the paused state (no bytes for 12 s).
3. **Completion by inode.** Rename-in-place (Chromium), rename-over-placeholder (Firefox) and Safari's move-out-of-package all keep the inode of the growing file. A new top-level file with the same device+inode finishes that download. If a browser copies instead of moving, a file with the expected final name that appeared since the start counts. A partial that vanishes with no result is "cancelled" after 4 s.
4. **Generic growing files** (curl, other apps) count only if they grow while watched, or arrive with download provenance (where-froms or quarantine). Files the user copies or saves into Downloads, and edits to existing files, are ignored, and so is anything SparkV itself moves (Undo, sorting into a subfolder). The "recent" list shown at enable is filtered the same way.
5. **Sorting never surprises.**
   - A file moves only when the user clicks Sort (or picks a folder), or when they ticked "Sort automatically" on a rule. No default rule sorts automatically.
   - Moves never overwrite: a taken name gets " 2", like Finder. Undo moves the file back without overwriting anything that took its old name, and moves survive relaunch in `history.json`. Nothing is ever deleted.
6. **Suggestions: rules first, model second.**
   - The first enabled rule that matches gives the suggestion.
   - The on-device model (FoundationModels, guided generation with an `anyOf` string schema, so it can only answer with one of the listed folder names or "None") picks among rule folders, Downloads subfolders and standard folders.
   - The model's pick replaces a rule's only when that rule is a generic kind-only rule and the pick is a more specific folder (for example "Invoices" over "Documents"). Otherwise it's offered in the Sort menu marked with ✦.
   - The model sees only the file name, kind, size and source domain. It is never sent file contents and there is no cloud fallback, so no Groq toggle exists.
7. **Notch bands** (through `ActivityCenter`):
   - Progress (priority 45, persistent while anything is in flight; the view observes the controller, so it updates without re-posting).
   - Finished, with the suggested folder (priority 66, 6 s).
   - Auto-sorted (priority 66, 5 s).
   - Hovering a band opens the Downloads tab.
8. **Spaces / Tray / AirDrop** reuse `SpaceIngestCenter.file` (its agents auto-route to a Space), `TrayStore.addFile` (wired by the lead) and `AirDrop.share(urls:)`.

## Testing

`scratchpad/features2/downloads/harness/run.sh [5|6]` builds a headless test binary. It runs real FSEvents on fixture folders under the scratch directory (never the real Downloads), a separate publisher process that does what Chromium's updater does, real xattrs, a chmod-000 folder for the denied path, and the real on-device model. It renders every view offscreen into `out/run/renders/`. It reports 111 passing checks in both Swift 5 and Swift 6 mode, including xattrs written after the rename (Chromium annotates right after it), history pruning that never looks inside Downloads while the watcher is off, and FSEvents start/stop churn.
