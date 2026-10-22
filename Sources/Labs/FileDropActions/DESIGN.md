# File Drop actions: design

Drop one or more files near the notch, pick an action, drag the result
anywhere.

## What we copied, and from whom

| Product | Proven idea we replicate | How it shows up here |
|---|---|---|
| **Dropover** | A temporary shelf; "Instant Actions" you drop straight onto so the task runs with no extra clicks; files are kept by reference, never copied or moved; results drag out with Finder's copy semantics; "drop to notch" on notched MacBooks. | The shelf's Compress / To Space / AirDrop buckets run on drop; the strip holds file URLs only; drags out are copies (`TrayDragSource`, `.copy` outside the app). |
| **Yoink** | The drop target exists only while you're dragging, then gets out of the way. | `FileDropDragWatcher` shows the shelf only during a file drag near the notch and hides it when the drag ends or moves away. |
| **NotchNook / NotchDrop** | The notch grows a drop zone as a drag approaches; a separate AirDrop target beside the shelf. | Black shelf directly under the notch with an AirDrop bucket; dragging on into the notch keeps SparkV's existing Tray behaviour. |
| **Finder › Compress** | `ditto -c -k --keepParent`, "Name.ext.zip" for one item, "Archive.zip" for several. | `FileDropOps.zip`. We add `--norsrc --noextattr --noqtn --noacl` (Keka/BetterZip's "exclude Mac resource forks") so zips have no `__MACOSX` folder. |
| **ImageOptim / Squoosh-style lossy re-encode** | Re-encode at ~0.7 quality, cap the long side, drop metadata, keep the copy only if it's smaller; keep PNG only when it has real transparency. | `FileDropOps.compressImage` (JPEG/HEIC same format, opaque PNG/TIFF/BMP/WebP → JPEG, transparent PNG stays PNG, 3072 px cap, GPS/EXIF dropped). |
| **AI renamers (Hazel rules + LLM, e.g. NameQuick/Renamer.ai)** | Read the content (OCR for images, the text layer for PDFs), ask a model for a 2–7 word name with the key facts first and ISO dates, preview it in an editable field, undo. | `FileDropNamer` + the rename row; on-device FoundationModels only. |

Drag detection is the standard notch-shelf technique (also used by
boring.notch and NotchDrop): remember `NSPasteboard(name: .drag).changeCount`
on mouse-down, and on mouse-dragged treat a changed count whose declared
types include file URLs, file promises or image data as a file drag. Only the
pasteboard's *types* are read, never its contents. Global monitors only, so a
drag that starts inside SparkV (out of the Tray or the strip) never opens the
shelf. Nothing was vendored: NotchDrop (MIT) was read for the approach; no code
was copied, so no third-party license is bundled.

## Pieces

- `FileDropController` (ObservableObject, MainActor): items, mode, undo,
  thumbnails (QuickLookThumbnailing, as Finder), Spaces list, settings, the shelf.
- `FileDropDragWatcher`: drag detection + geometry (pure, unit-tested).
- `FileDropZonePanel` + `FileDropTargetView`: the collapsed-notch drop shelf
  (372×76) with four buckets. `FileDropTile`: optional Tray tile.
- `FileDropActionStrip`: the drawer content (508×69): empty → actions →
  rename / space picker / working → result. `FileDropSettingsMenu` for the gear menu.
- `FileDropOps`: rename/undo, compress (images, PDFs via `ConverterEngine`), zip, trash.
- `FileDropNamer`: content reading with timeouts, on-device naming, heuristic fallback.
  Images: scene labels, then Vision's *fast* text recognizer (CPU, ~0.1 s); the
  accurate (Neural Engine) recognizer only for document-like images where fast
  found almost nothing. One in-flight read per file; Vision is prewarmed at start.

## Actions

- **Rename**: suggestions for every file are prepared one after another while
  the editor shows the first; the field is filled with the suggestion unless the
  user has typed (a late suggestion never overwrites typing). Enter or Rename
  applies, Skip/Cancel. Extension is kept, collisions get " 2", case-only renames
  work, Undo moves every file back (and refuses to overwrite something that took
  the old name since).
- **Compress**: images and PDFs → smaller copies next to the originals (or in
  `~/Library/Application Support/SparkV/FileDrop/` for staged drops); anything
  else, or "Zip" on the result, → one .zip. Originals are never modified. Undo
  moves the copies to the Trash. "Already as small as it gets" offers a zip.
- **Convert**: `ConverterController.add(urls)` and the drawer switches to the
  converter, whose formats then apply.
- **Space**: a row of Space chips plus **Auto** (the Spaces agents file it via
  `SpaceIngestCenter.submit`, Inbox when unsure). Explicit Spaces ingest and
  move like the Spaces drop targets do. Originals stay put.
- **AirDrop** (`AirDrop.share(urls:)`), **Tray** (`tray.addFile`), **Reveal**.

## Busy states and feedback (validator pass)

- A drop on an instant bucket while an action runs is queued and runs right
  after, on just those files; during an open rename it ends the rename (names
  already applied stay) and runs. Nothing dropped is silently ignored.
- With the drawer closed, every outcome of an instant drop shows in the band
  under the notch: results, "already as small as it gets", and warnings.
- A batch compress keeps going past an unreadable file; the copies already
  written are listed and undoable, and the failures are counted in the result.
  Animated GIF/PNG/WebP and vector images are left as they are.
- Model names get a post-pass that rewrites full dates (with a year) as
  YYYY-MM-DD, because the on-device model doesn't always follow that rule.
- `holdsDrawerOpen` keeps the drawer from closing under the pointer when a
  drop on the shelf's Actions bucket opened it while the shelf sat below the
  drawer (under a live-activity band).

## Dragging out (round 3)

Modelled on Dropover (drag the whole stack, Cmd-click to pick some, Shift
while dragging keeps the shelf open, click the stack to see each file) and
Yoink (stacks drag out together; files go out as Finder does).

- Every item leaves as a real `public.file-url` (NSURL), never a copy of its
  bytes and never a file promise: Finder, Mail, Messages, Slack and other
  Electron apps, browser upload fields and sandboxed apps all accept file
  URLs (Chromium ignores `NSFilePromiseProvider` drops into web pages), and
  the drag pasteboard extends sandboxed receivers read access. A promise is
  only worth it for content that doesn't exist on disk yet, and every shelf
  item does exist. Finder file-reference URLs are resolved to paths, missing
  files are skipped (a beep when nothing is left), duplicates collapsed.
- Tray links go out like a Safari link (`public.url` + `public.url-name` +
  string): a .webloc in Finder, the page in a browser, the address in text.
- Copy only outside the app, nothing inside it (no duplicate on drop back),
  modifiers ignored so Cmd/Option can't turn it into a failing move.
- Multi-item drags use `.pile` formation with the grabbed item as leader;
  AppKit draws the count badge.
- File Drop piles: drag = all files; click a pile of several = one tile per
  file (`FileDropFilesRow`), each dragged alone, plus "All"; right-click =
  Copy N Files / Open / Show in Finder / Show Each File.
- Tray: Cmd- (or Shift-) click picks cards; dragging any picked card drags
  the picked set; the header shows "N selected" (click to clear); a plain
  click copies and clears the pick.
- `TrayDragOut` tracks sessions so the drawer stays open during the drag and
  the slide-back of a cancelled one, and posts `didEndNotification`.

## Privacy and safety

On-device only: Vision OCR/labels, PDF text, FoundationModels with the
content-transformation guardrails. No network, no Groq, no keys. Content and
names are never logged (only failure kinds). No user file is ever deleted:
rename moves within the folder, compress and zip write new files, Undo of a
created file uses the Trash. Reading a file for a name is capped at 45 s and
the model at 25 s; on timeout the heuristic (title line, ISO date, image
labels) or the current name is used.
