import Foundation

// Test harness for CloudSync. Never touches iCloud Drive: every test works
// in a fresh scratch folder given on the command line. Run with
// Tests/run-tests.sh (see there). With -D CLOUDSYNC_FULL it is compiled with
// the whole app (minus its @main) and also tests rendering and full runs.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  FAIL \(message) (line \(line))")
    }
}

func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<missing>" }

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// Every regular file under `root` (relative paths), skipping SparkV's temp.
func allFiles(_ root: URL) -> [String] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var out: [String] = []
    let base = root.standardizedFileURL.resolvingSymlinksInPath().path
    for case let url as URL in e {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        out.append(String(path.dropFirst(base.count + 1)))
    }
    return out.sorted()
}

func md(_ path: String, _ key: String, _ text: String) -> CloudSyncFile { .markdown(path, key: key, text) }

func setOld(_ url: URL, seconds: TimeInterval = 60) {
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-seconds)], ofItemAtPath: url.path)
}

struct Scratch {
    let base: URL
    var n = 0
    mutating func folder(_ name: String) -> URL {
        n += 1
        let url = base.appendingPathComponent("\(n)-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - Engine

func testEngine(_ scratch: inout Scratch) {
    print("engine")
    let root = scratch.folder("engine")
    let engine = CloudSyncEngine(root: root)
    var manifest = CloudSyncManifest()
    let scopes = ["meetings:", "flowNotes:"]

    var files = [
        md("Meetings/2026-10/Standup.md", "meetings:1", "# Standup\n"),
        md("Notes/Plan.md", "flowNotes:a", "plan v1"),
        md("Notes/Ideas.md", "flowNotes:b", "ideas"),
    ]
    var r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.written == 3 && r.errors.isEmpty, "first run writes 3 (got \(r.written), \(r.errors))")
    check(read(root.appendingPathComponent("Notes/Plan.md")) == "plan v1", "content written")
    check(manifest.entries.count == 3, "manifest has 3 entries")

    let planURL = root.appendingPathComponent("Notes/Plan.md")
    let before = CloudSyncEngine.stat(planURL)
    r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.written == 0 && r.unchanged == 3, "second run is a no-op (written \(r.written))")
    check(CloudSyncEngine.stat(planURL)?.modified == before?.modified, "unchanged file not rewritten")

    files[1] = md("Notes/Plan.md", "flowNotes:a", "plan v2")
    r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.written == 1 && r.preserved == 0, "changed content rewrites one file")
    check(read(planURL) == "plan v2", "new content")

    // Edited on the iPhone, then SparkV changes it too.
    try! "edited on iPhone".write(to: planURL, atomically: true, encoding: .utf8)
    files[1] = md("Notes/Plan.md", "flowNotes:a", "plan v3")
    r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.preserved == 1 && r.written == 1, "external edit preserved (preserved \(r.preserved))")
    check(read(planURL) == "plan v3", "SparkV version written after preserving")
    let conflicts = allFiles(root).filter { $0.hasPrefix("Conflicts/Notes/Plan (edited ") }
    check(conflicts.count == 1, "edited copy in Conflicts/Notes (\(allFiles(root)))")
    if let c = conflicts.first { check(read(root.appendingPathComponent(c)) == "edited on iPhone", "edited copy keeps the edit") }

    // Edited externally while SparkV's content is unchanged: still kept.
    try! "edited again".write(to: planURL, atomically: true, encoding: .utf8)
    r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.preserved == 1 && read(planURL) == "plan v3", "edit with unchanged source preserved and restored")

    // User deleted a mirrored file: it comes back.
    try! FileManager.default.removeItem(at: root.appendingPathComponent("Notes/Ideas.md"))
    r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.written == 1 && exists(root.appendingPathComponent("Notes/Ideas.md")), "deleted mirror file recreated")

    // Rename: same source, new path. Moves, doesn't trash.
    files[0] = md("Meetings/2026-10/Weekly standup.md", "meetings:1", "# Standup\n")
    r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.renamed == 1 && r.trashed == 0 && r.written == 0, "rename moves the file (renamed \(r.renamed) trashed \(r.trashed) written \(r.written))")
    check(!exists(root.appendingPathComponent("Meetings/2026-10/Standup.md")), "old name gone")
    check(read(root.appendingPathComponent("Meetings/2026-10/Weekly standup.md")) == "# Standup\n", "new name has content")

    // Source removed: to .trash/<day>/, empty folder removed.
    files.remove(at: 0)
    r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.trashed == 1, "removed source trashed")
    let day = CloudSyncPaths.day(Date())
    check(exists(root.appendingPathComponent(".trash/\(day)/Meetings/2026-10/Weekly standup.md")), "file is in .trash/<day>/Meetings")
    check(!exists(root.appendingPathComponent("Meetings")), "empty Meetings folder removed")

    // Removed source whose file the user edited: Conflicts, not trash.
    try! "my changes".write(to: root.appendingPathComponent("Notes/Ideas.md"), atomically: true, encoding: .utf8)
    files.remove(at: 1)
    r = engine.mirror(files, scopes: scopes, manifest: &manifest)
    check(r.preserved == 1 && r.trashed == 0, "edited file of removed source kept in Conflicts")

    // Out-of-scope entries are untouched.
    var m2 = CloudSyncManifest()
    let root2 = scratch.folder("scopes")
    let e2 = CloudSyncEngine(root: root2)
    _ = e2.mirror([md("Spaces/A.md", "spaces:p1:a", "a"), md("Notes/B.md", "flowNotes:b", "b")],
                  scopes: ["spaces:p1:", "flowNotes:"], manifest: &m2)
    r = e2.mirror([md("Notes/B.md", "flowNotes:b", "b")], scopes: ["flowNotes:"], manifest: &m2)
    check(r.trashed == 0 && exists(root2.appendingPathComponent("Spaces/A.md")), "frozen scope not trashed")
    check(m2.entries.count == 2, "frozen entry kept in manifest")

    // Mass removal is held until confirmed.
    let root3 = scratch.folder("mass")
    var m3 = CloudSyncManifest()
    let e3 = CloudSyncEngine(root: root3)
    let many = (0..<30).map { md("Notes/N\($0).md", "flowNotes:\($0)", "n\($0)") }
    _ = e3.mirror(many, scopes: ["flowNotes:"], manifest: &m3)
    r = e3.mirror([], scopes: ["flowNotes:"], manifest: &m3)
    check(r.heldRemovals == 30 && r.trashed == 0, "mass removal held (\(r.heldRemovals))")
    check(allFiles(root3).filter { $0.hasPrefix("Notes/") }.count == 30, "nothing moved while held")
    r = e3.mirror([], scopes: ["flowNotes:"], manifest: &m3, allowMassRemoval: true)
    check(r.trashed == 30, "confirmed removal trashes all 30")
    check(allFiles(root3).filter { $0.hasPrefix(".trash/") }.count == 30, "all 30 in trash, none deleted")

    // A file SparkV never wrote: same content adopted, different preserved.
    let root4 = scratch.folder("unknown")
    try! FileManager.default.createDirectory(at: root4.appendingPathComponent("Notes"), withIntermediateDirectories: true)
    try! "same".write(to: root4.appendingPathComponent("Notes/Same.md"), atomically: true, encoding: .utf8)
    try! "mine".write(to: root4.appendingPathComponent("Notes/Mine.md"), atomically: true, encoding: .utf8)
    var m4 = CloudSyncManifest()
    r = CloudSyncEngine(root: root4).mirror([md("Notes/Same.md", "flowNotes:s", "same"), md("Notes/Mine.md", "flowNotes:m", "sparkv")],
                                             scopes: ["flowNotes:"], manifest: &m4)
    check(r.unchanged == 1 && r.preserved == 1 && r.written == 1, "unknown files: adopt same, preserve different")
    check(allFiles(root4).contains { $0.hasPrefix("Conflicts/Notes/Mine (edited ") }, "user's Mine.md preserved")

    // Case-insensitive duplicates and unsafe paths.
    let root5 = scratch.folder("names")
    var m5 = CloudSyncManifest()
    r = CloudSyncEngine(root: root5).mirror([
        md("Notes/A.md", "flowNotes:1", "1"), md("notes/a.md", "flowNotes:2", "2"),
        md("../escape.md", "flowNotes:3", "x"), md(".trash/x.md", "flowNotes:4", "x"),
        md("Inbox/x.md", "flowNotes:5", "x"), md("Notes/.hidden.md", "flowNotes:6", "x"),
    ], scopes: ["flowNotes:"], manifest: &m5)
    check(r.written == 2 && r.skipped.count == 4, "dupes renamed, unsafe skipped (written \(r.written), skipped \(r.skipped.count))")
    check(exists(root5.appendingPathComponent("Notes/a 2.md")) || exists(root5.appendingPathComponent("notes/a 2.md")), "case-insensitive duplicate numbered")
    check(!exists(root5.deletingLastPathComponent().appendingPathComponent("escape.md")), "no escape from root")

    // Path reused by a new source: old content trashed, not overwritten.
    let root6 = scratch.folder("reuse")
    var m6 = CloudSyncManifest()
    let e6 = CloudSyncEngine(root: root6)
    _ = e6.mirror([md("Notes/Plan.md", "flowNotes:old", "old plan")], scopes: ["flowNotes:"], manifest: &m6)
    r = e6.mirror([md("Notes/Plan.md", "flowNotes:new", "new plan")], scopes: ["flowNotes:"], manifest: &m6)
    check(r.trashed == 1 && read(root6.appendingPathComponent("Notes/Plan.md")) == "new plan", "reused path trashes old content")

    // Copies: written, updated when the source changes.
    let root7 = scratch.folder("copies")
    let src = scratch.folder("copy-src").appendingPathComponent("shot.png")
    try! Data(repeating: 7, count: 300_000).write(to: src)
    var m7 = CloudSyncManifest()
    let e7 = CloudSyncEngine(root: root7)
    r = e7.mirror([CloudSyncFile(path: "Tray/shot.png", sourceKey: "tray:1", payload: .copy(src))], scopes: ["tray:"], manifest: &m7)
    check(r.written == 1 && (try? Data(contentsOf: root7.appendingPathComponent("Tray/shot.png")))?.count == 300_000, "copy written")
    r = e7.mirror([CloudSyncFile(path: "Tray/shot.png", sourceKey: "tray:1", payload: .copy(src))], scopes: ["tray:"], manifest: &m7)
    check(r.unchanged == 1 && r.written == 0, "unchanged copy skipped")
    try! Data(repeating: 9, count: 1000).write(to: src)
    r = e7.mirror([CloudSyncFile(path: "Tray/shot.png", sourceKey: "tray:1", payload: .copy(src))], scopes: ["tray:"], manifest: &m7)
    check(r.written == 1 && (try? Data(contentsOf: root7.appendingPathComponent("Tray/shot.png")))?.count == 1000, "changed source recopied")
    try! FileManager.default.removeItem(at: src)
    r = e7.mirror([CloudSyncFile(path: "Tray/shot.png", sourceKey: "tray:1", payload: .copy(src))], scopes: ["tray:"], manifest: &m7)
    check(r.skipped.count == 1 && exists(root7.appendingPathComponent("Tray/shot.png")), "missing source skipped, file kept")
    check(!exists(root7.appendingPathComponent(CloudSyncPaths.temp)), "temp folder cleaned up")
}

// MARK: - Engine safety (validator additions)

func testEngineSafety(_ scratch: inout Scratch) {
    print("engine safety")
    let fm = FileManager.default

    // Mass removal is judged per category: 30 meetings vanishing is held
    // even though 200 Spaces files are still there; other removals proceed.
    let root = scratch.folder("mass-per-category")
    var m = CloudSyncManifest()
    let e = CloudSyncEngine(root: root)
    let meetings = (0..<30).map { md("Meetings/M\($0).md", "meetings:\($0)", "m\($0)") }
    let spaces = (0..<200).map { md("Spaces/S\($0).md", "spaces:p:\($0)", "s\($0)") }
    _ = e.mirror(meetings + spaces, scopes: ["meetings:", "spaces:p:"], manifest: &m)
    var r = e.mirror(Array(spaces.dropLast()), scopes: ["meetings:", "spaces:p:"], manifest: &m)
    check(r.heldRemovals == 30 && r.trashed == 1, "per-category hold: meetings held, one Space file trashed (held \(r.heldRemovals), trashed \(r.trashed))")
    check(allFiles(root).filter { $0.hasPrefix("Meetings/") }.count == 30, "held meetings untouched")
    r = e.mirror(Array(spaces.dropLast()), scopes: ["meetings:", "spaces:p:"], manifest: &m, allowMassRemoval: true)
    check(r.trashed == 30 && r.heldRemovals == 0, "confirmed: meetings go to .trash")
    check(allFiles(root).filter { $0.hasPrefix(".trash/") }.count == 31, "nothing deleted outright")

    // A folder inside the mirror that is a symlink to somewhere else never
    // receives writes or moves.
    let symRoot = scratch.folder("symlink").appendingPathComponent("SparkV")
    let outside = scratch.folder("symlink-outside")
    try! fm.createDirectory(at: symRoot, withIntermediateDirectories: true)
    try! fm.createSymbolicLink(at: symRoot.appendingPathComponent("Notes"), withDestinationURL: outside)
    var ms = CloudSyncManifest()
    r = CloudSyncEngine(root: symRoot).mirror([md("Notes/A.md", "flowNotes:a", "a"), md("Habits.md", "habits:all", "h")],
                                              scopes: ["flowNotes:", "habits:"], manifest: &ms)
    check(r.written == 1 && r.errors.count == 1 && !r.permissionDenied, "write through a symlinked folder refused (\(r.errors))")
    check((try? fm.contentsOfDirectory(atPath: outside.path))?.isEmpty == true, "nothing written outside the root")
    check(exists(symRoot.appendingPathComponent("Habits.md")), "other files still written")

    // A root that is itself reached through a symlink (e.g. /tmp) still works.
    let realRoot = scratch.folder("real-root")
    let linkParent = scratch.folder("link-parent")
    let linkedRoot = linkParent.appendingPathComponent("linked")
    try! fm.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
    var ml = CloudSyncManifest()
    r = CloudSyncEngine(root: linkedRoot).mirror([md("Notes/B.md", "flowNotes:b", "b")], scopes: ["flowNotes:"], manifest: &ml)
    check(r.written == 1 && r.errors.isEmpty, "symlinked root itself is fine (\(r.errors))")
    r = CloudSyncEngine(root: linkedRoot).mirror([], scopes: ["flowNotes:"], manifest: &ml)
    check(r.trashed == 1 && r.errors.isEmpty, "trash works under a symlinked root")

    // Owner file: not yet downloaded means wait, never claim another Mac's folder.
    let ownerBase = scratch.folder("owner-wait").appendingPathComponent("SparkV")
    try! fm.createDirectory(at: ownerBase, withIntermediateDirectories: true)
    try! Data().write(to: CloudSyncPaths.placeholder(for: ownerBase.appendingPathComponent(CloudSyncPaths.ownerFile)))
    var waited = false
    do { _ = try CloudSyncOwner.destination(base: ownerBase, deviceID: UUID(), deviceName: "New Mac") } catch is CloudSyncOwner.NotDownloaded {
        waited = true
    } catch {}
    check(waited && !exists(ownerBase.appendingPathComponent(CloudSyncPaths.ownerFile)), "evicted owner file: wait, don't claim")

    // Damaged owner file counts as someone else's.
    let damaged = scratch.folder("owner-damaged").appendingPathComponent("SparkV")
    try! fm.createDirectory(at: damaged, withIntermediateDirectories: true)
    try! "garbage".write(to: damaged.appendingPathComponent(CloudSyncPaths.ownerFile), atomically: true, encoding: .utf8)
    let d = try? CloudSyncOwner.destination(base: damaged, deviceID: UUID(), deviceName: "Air")
    check(d?.lastPathComponent == "Air" && read(damaged.appendingPathComponent(CloudSyncPaths.ownerFile)) == "garbage",
          "damaged owner file left alone, subfolder used")

    // Three Macs, two with the same name; one named like a SparkV folder.
    let shared = scratch.folder("owner-names").appendingPathComponent("SparkV")
    let first = try! CloudSyncOwner.destination(base: shared, deviceID: UUID(), deviceName: "MacBook Pro")
    let idB = UUID(), idC = UUID()
    let b = try! CloudSyncOwner.destination(base: shared, deviceID: idB, deviceName: "MacBook Pro")
    let c = try! CloudSyncOwner.destination(base: shared, deviceID: idC, deviceName: "MacBook Pro")
    let bAgain = try! CloudSyncOwner.destination(base: shared, deviceID: idB, deviceName: "MacBook Pro")
    check(first == shared && b.lastPathComponent == "MacBook Pro" && c.lastPathComponent == "MacBook Pro 2" && bAgain == b,
          "same-name Macs get separate folders (\(b.lastPathComponent), \(c.lastPathComponent))")
    let notes = try! CloudSyncOwner.destination(base: shared, deviceID: UUID(), deviceName: "Notes")
    check(notes.lastPathComponent == "Notes (Mac)", "a Mac named Notes doesn't write into Notes/")

    // Big .txt from the iPhone: arrives as a file instead of waiting forever.
    let inboxRoot = scratch.folder("inbox-big")
    var mi = CloudSyncManifest()
    try! CloudSyncInbox.prepare(root: inboxRoot)
    let big = CloudSyncInbox.inboxURL(in: inboxRoot).appendingPathComponent("Export.txt")
    try! String(repeating: "line of text\n", count: 200_000).write(to: big, atomically: true, encoding: .utf8)
    setOld(big)
    let received = scratch.folder("inbox-big-received")
    _ = CloudSyncInbox.collect(root: inboxRoot, receivedDirectory: received, manifest: &mi)
    let ri = CloudSyncInbox.collect(root: inboxRoot, receivedDirectory: received, manifest: &mi, now: Date().addingTimeInterval(5))
    check(ri.arrivals.count == 1 && ri.arrivals[0].kind == .file && ri.arrivals[0].localCopy.map(exists) == true,
          "over-2-MB text imported as a file")
    let badLink = CloudSyncInbox.inboxURL(in: inboxRoot).appendingPathComponent("Broken.webloc")
    try! "not a plist".write(to: badLink, atomically: true, encoding: .utf8)
    setOld(badLink)
    _ = CloudSyncInbox.collect(root: inboxRoot, receivedDirectory: received, manifest: &mi)
    let rl = CloudSyncInbox.collect(root: inboxRoot, receivedDirectory: received, manifest: &mi, now: Date().addingTimeInterval(5))
    check(rl.arrivals.count == 1 && rl.arrivals[0].kind == .file && !exists(badLink), "link file without an address arrives as a file")
}

// MARK: - Inbox

func testInbox(_ scratch: inout Scratch) {
    print("inbox")
    let root = scratch.folder("inbox")
    let received = scratch.folder("received")
    var manifest = CloudSyncManifest()
    try! CloudSyncInbox.prepare(root: root)
    let inbox = CloudSyncInbox.inboxURL(in: root)

    let note = inbox.appendingPathComponent("Groceries.md")
    try! "# Shopping list\n- milk".write(to: note, atomically: true, encoding: .utf8)
    setOld(note)
    let photo = inbox.appendingPathComponent("IMG_0001.jpg")
    try! Data(repeating: 1, count: 2048).write(to: photo)
    setOld(photo)

    var r = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest)
    check(r.arrivals.isEmpty && r.pending == 2, "first sighting waits (pending \(r.pending))")
    r = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest, now: Date().addingTimeInterval(5))
    check(r.arrivals.count == 2, "settled files imported (\(r.arrivals.count), \(r.errors) \(r.skipped))")
    let text = r.arrivals.first { $0.kind == .text }
    check(text?.title == "Shopping list" && text?.text?.contains("milk") == true, "text read with heading title")
    let image = r.arrivals.first { $0.kind == .image }
    check(image?.localCopy.map(exists) == true, "image copied locally")
    check(!exists(note) && !exists(photo), "originals left the Inbox")
    let day = CloudSyncPaths.day(Date().addingTimeInterval(5))
    check(exists(inbox.appendingPathComponent("Imported/\(day)/Groceries.md")), "original archived, not deleted")

    // Same content again: duplicate, archived but not re-imported.
    let again = inbox.appendingPathComponent("Groceries copy.md")
    try! "# Shopping list\n- milk".write(to: again, atomically: true, encoding: .utf8)
    setOld(again)
    _ = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest, now: Date())
    r = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest, now: Date().addingTimeInterval(5))
    check(r.arrivals.count == 1 && r.arrivals[0].isDuplicate, "duplicate detected")
    check(!exists(again), "duplicate archived")

    // A file still growing is not imported.
    let growing = inbox.appendingPathComponent("Video.mov")
    try! Data(repeating: 2, count: 100).write(to: growing)
    setOld(growing)
    _ = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest, now: Date())
    try! Data(repeating: 2, count: 500).write(to: growing)
    setOld(growing)
    r = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest, now: Date().addingTimeInterval(5))
    check(r.arrivals.isEmpty && exists(growing), "growing file waits")
    r = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest, now: Date().addingTimeInterval(10))
    check(r.arrivals.count == 1 && r.arrivals[0].kind == .file, "settled file imported as file")

    // Evicted placeholder, folder, empty file, binary text, link, UTF-16.
    try! Data().write(to: inbox.appendingPathComponent(".Remote.pdf.icloud"))
    try! FileManager.default.createDirectory(at: inbox.appendingPathComponent("Folder"), withIntermediateDirectories: true)
    let empty = inbox.appendingPathComponent("Empty.txt")
    try! Data().write(to: empty)
    setOld(empty)
    let binary = inbox.appendingPathComponent("Binary.txt")
    try! Data([0x41, 0x00, 0x42, 0x00, 0x43]).write(to: binary)
    setOld(binary)
    let link = inbox.appendingPathComponent("Apple.webloc")
    let plist = try! PropertyListSerialization.data(fromPropertyList: ["URL": "https://www.apple.com/iphone/"], format: .xml, options: 0)
    try! plist.write(to: link)
    setOld(link)
    let utf16 = inbox.appendingPathComponent("Wide.txt")
    try! "Café notes".write(to: utf16, atomically: true, encoding: .utf16)
    setOld(utf16)
    _ = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest, now: Date())
    r = CloudSyncInbox.collect(root: root, receivedDirectory: received, manifest: &manifest, now: Date().addingTimeInterval(5))
    check(r.arrivals.contains { $0.kind == .link && $0.link?.host == "www.apple.com" }, "webloc imported as link")
    check(r.arrivals.contains { $0.kind == .text && $0.text == "Café notes" }, "UTF-16 text decoded")
    check(r.arrivals.contains { $0.name == "Binary.txt" && $0.kind == .file && $0.text == nil } && !exists(binary),
          "binary .txt arrives as a file, not as a note (and leaves the Inbox)")
    check(!r.arrivals.contains { $0.name == "Empty.txt" } && exists(empty), "empty file waits")
    check(r.skipped.contains { $0.contains("folder") }, "folder skipped with a note")
    check(r.pending >= 1, "placeholder counted as pending")
    check(exists(inbox.appendingPathComponent(".Remote.pdf.icloud")), "placeholder untouched")
}

// MARK: - Paths, owner, secrets, settings

func testPathsAndSecrets(_ scratch: inout Scratch) {
    print("paths, owner, secrets, settings")
    check(CloudSyncPaths.component("Q3: plan / review?") == "Q3 plan review", "unsafe characters removed (\(CloudSyncPaths.component("Q3: plan / review?")))")
    check(CloudSyncPaths.component("## Heading\nmore") == "Heading", "first line, no markdown marks")
    check(CloudSyncPaths.component("...") == "Untitled", "fallback for empty")
    check(CloudSyncPaths.component(String(repeating: "a", count: 300)).count == 80, "length limited")
    check(CloudSyncPaths.component("Trailing dots...  ") == "Trailing dots", "trailing dots trimmed")
    check(CloudSyncPaths.numbered("Notes/Plan.md", 2) == "Notes/Plan 2.md", "numbered before extension")
    check(CloudSyncPaths.key("Café.md") == CloudSyncPaths.key("CAFE\u{301}.md"), "keys ignore case and normalization")
    check(CloudSyncPaths.realName(ofPlaceholder: ".Report.pdf.icloud") == "Report.pdf", "placeholder name parsed")

    let base = scratch.folder("owner").appendingPathComponent("SparkV")
    let a = UUID(), b = UUID()
    let first = try! CloudSyncOwner.destination(base: base, deviceID: a, deviceName: "Studio")
    let again = try! CloudSyncOwner.destination(base: base, deviceID: a, deviceName: "Studio")
    let second = try! CloudSyncOwner.destination(base: base, deviceID: b, deviceName: "MacBook Pro: Work")
    check(first == base && again == base, "first Mac owns the folder")
    check(second.lastPathComponent == "MacBook Pro Work" && second.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path,
          "second Mac writes to its own subfolder (\(second.path))")

    let missingICloud = scratch.folder("no-icloud").appendingPathComponent("CloudDocs")
    check(CloudSyncLocation.resolve(CloudSyncSettings(), iCloudRoot: missingICloud) == .iCloudDriveOff, "iCloud Drive off detected")
    var custom = CloudSyncSettings()
    custom.customFolderPath = "/Volumes/NoSuchDrive/Sync"
    check(CloudSyncLocation.resolve(custom) == .folderMissing("/Volumes/NoSuchDrive/Sync"), "missing custom folder detected")

    let sensitive = ["sk-proj-abcdefghijklmnop1234567890", "Tr0ub4dor&3xyz", "4111 1111 1111 1111", "password: hunter2",
                     "-----BEGIN OPENSSH PRIVATE KEY-----", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
                     "token a8f5f167f44f4964e6c998dee827110c7d4a1b2c3d4e5f60 here"]
    let fine = ["Buy milk and eggs", "https://www.apple.com/iphone/", "Meeting at 3pm with Priya", "koushik@example.com",
                "The quick brown fox jumps over the lazy dog", "Call 555 1234"]
    for s in sensitive { check(CloudSyncSecrets.looksSensitive(s), "sensitive: \(s)") }
    for s in fine { check(!CloudSyncSecrets.looksSensitive(s), "not sensitive: \(s)") }
    // Secrets inside a sentence (validator additions).
    let embedded = ["wifi password Abc12345!", "My password is hunter2", "card 4111 1111 1111 1111 exp 12/27", "PIN 4821",
                    "recovery codes: 8f3k-29dk-1kd9", "user: koushik pass: S3cret!!", "Your verification code is 482913",
                    "seed phrase: abandon ability able about above absent absorb abstract absurd abuse access accident",
                    "AKIAIOSFODNN7EXAMPLE", "router admin Xk9#mPq2", "IBAN DE89 3704 0044 0532 0130 00"]
    let ordinary = ["Order #4411 shipped", "Spin 3 times", "Gate code is in the email", "Pick up dry cleaning at 5",
                    "Tracking 1Z999AA10123456784", "Lunch with the design team on Friday", "Spinach, pins and needles"]
    for s in embedded { check(CloudSyncSecrets.looksSensitive(s), "sensitive: \(s)") }
    for s in ordinary { check(!CloudSyncSecrets.looksSensitive(s), "not sensitive: \(s)") }
    check(CloudSyncSecrets.isPasswordManager("com.1password.1password") && CloudSyncSecrets.isPasswordManager("com.bitwarden.desktop")
          && CloudSyncSecrets.isPasswordManager("com.apple.Passwords") && !CloudSyncSecrets.isPasswordManager("com.apple.Notes")
          && !CloudSyncSecrets.isPasswordManager(nil), "password manager apps recognized")

    // Settings decode tolerates unknown and missing fields.
    let json = #"{"isEnabled":true,"categories":["meetings","fromTheFuture"],"newField":1}"#
    let decoded = try? JSONDecoder.cloudSync.decode(CloudSyncSettings.self, from: Data(json.utf8))
    check(decoded?.isEnabled == true && decoded?.categories == [.meetings] && decoded?.importsInbox == true, "settings decode is tolerant")
    check(!CloudSyncSettings().categories.contains(.clipboard), "clipboard off by default")
    check(CloudSyncSettings().isEnabled == false, "sync off by default")
}

#if CLOUDSYNC_FULL
// MARK: - Rendering and full runs (needs the app's types)

@MainActor
func testRendering(_ scratch: inout Scratch) {
    print("rendering and full runs")
    let start = Date(timeIntervalSince1970: 1_792_000_000) // Oct 2026
    let meetingID = UUID()
    var meeting = MeetingRecord(
        id: meetingID, title: "Design review: Q4", startedAt: start, endedAt: start.addingTimeInterval(1800), calendarEventID: nil,
        segments: [TranscriptSegment(id: UUID(), speaker: .others, text: "Let's ship Friday.", start: 4, end: 6, isFinal: true)],
        notes: MeetingNotes(summary: "We agreed to ship.", keyPoints: ["Scope is final"], decisions: ["Ship on Friday"],
                            myTasks: [ActionItem(id: UUID(), owner: "Me", task: "Write release notes", due: "Thursday", isMine: true, isDone: false)],
                            othersTasks: [], openQuestions: [], nextSteps: [], generatedBy: "On-device"),
        answers: [], userNotes: nil
    )
    let live = MeetingRecord(id: UUID(), title: "Live", startedAt: start, endedAt: nil, calendarEventID: nil,
                             segments: [], notes: nil, answers: [], userNotes: "typing")
    let note = FlowNote(text: "Trip ideas\nLisbon in May", date: start)
    let dictation = FlowEntry(date: start, raw: "hello", text: "Hello there.", appName: "Notes")
    let persona = UUID()
    let space = Space(id: UUID(), personaID: persona, parentID: nil, name: "Work/Clients", icon: "folder", color: "red",
                      rules: SpaceAgentRules(keywords: [], people: [], domains: [], apps: [], about: "", autoFileThreshold: 0.7),
                      members: [], createdAt: start, updatedAt: start)
    let attachmentDir = scratch.folder("attachments")
    let shot = attachmentDir.appendingPathComponent("shot.png")
    try! Data(repeating: 3, count: 4096).write(to: shot)
    func item(_ title: String, space: UUID?, attachment: Bool = false) -> SpaceItem {
        SpaceItem(id: UUID(), spaceID: space, personaID: persona, kind: attachment ? .screenshot : .note, source: .manual,
                  title: title, text: "Body of \(title)", url: nil, attachmentPath: attachment ? "Attachments/x/shot.png" : nil,
                  entities: [], tags: ["acme"], createdAt: start, sourceKey: "manual:\(title)", filingConfidence: nil)
    }
    let filed = item("Contract", space: space.id, attachment: true)
    var copiedSecret = item("wifi password Abc12345!", space: nil)
    copiedSecret.source = .clipboard
    copiedSecret.kind = .clipboard
    copiedSecret.text = "wifi password Abc12345! for the office"
    var copiedFine = item("Notes from the call", space: nil)
    copiedFine.source = .clipboard
    copiedFine.kind = .clipboard
    let inbox = item("Loose idea", space: nil)
    let twin = item("Loose idea", space: nil)
    let trayImage = TrayItem(id: UUID(), kind: .image, url: shot, text: nil, addedAt: start)
    let trayText = TrayItem(id: UUID(), kind: .text, url: nil, text: "Remember the milk", addedAt: start)
    func clip(_ text: String) -> ClipboardItem {
        ClipboardItem(id: UUID(), kind: .text, text: text, title: nil, fileURLs: nil, blobs: [:], thumbnailBlob: nil,
                      pixelWidth: nil, pixelHeight: nil, sourceBundleID: nil, copiedAt: start, firstCopiedAt: start,
                      copyCount: 1, isPinned: true, fingerprint: text, byteCount: text.utf8.count)
    }
    let habit = Habit(id: UUID(), name: "Read", symbol: "book", colorIndex: 0)

    var settings = CloudSyncSettings()
    settings.isEnabled = true
    settings.categories = Set(CloudSyncCategory.allCases)
    var input = CloudSyncInput(settings: settings)
    input.meetings = [meeting, live]
    input.flowNotes = [note, FlowNote(text: "   ", date: start)]
    input.dictations = [dictation]
    input.spaces = .init(personaID: persona, personaName: "Me", hasSeveralPersonas: false, spaces: [space],
                         items: [filed, inbox, twin, copiedSecret, copiedFine], attachments: [filed.id: shot])
    let traySecret = TrayItem(id: UUID(), kind: .text, url: nil, text: "PIN 4821", addedAt: start)
    input.tray = [trayImage, trayText, traySecret]
    var fromVault = clip("Ordinary words from a vault")
    fromVault.sourceBundleID = "com.1password.1password"
    input.clipboardPinned = [clip("Gate code is in the email"), clip("Tr0ub4dor&3xyz"), fromVault]
    input.modeSessions = [CloudSyncModeSession(id: UUID(), modeID: UUID(), name: "Deep Work", startedAt: start, endedAt: start.addingTimeInterval(3600))]
    input.habits = .init(habits: [habit], done: [habit.id: [HabitCalendar.key(for: Date())]])
    input.focusSessions = []

    let rendering = CloudSyncRenderer.render(input)
    let paths = Set(rendering.files.map(\.path))
    let month = CloudSyncPaths.month(start)
    let meetingPath = "Meetings/\(month)/\(CloudSyncPaths.day(start)) \(CloudSyncPaths.time(start)) Design review Q4.md"
    check(paths.contains(meetingPath), "meeting file named by date and title (\(paths.sorted()))")
    check(!rendering.files.contains { $0.sourceKey.contains(live.id.uuidString) }, "live meeting not synced yet")
    check(paths.contains("Notes/Trip ideas.md"), "flow note named by first line")
    check(rendering.files.filter { $0.path.hasPrefix("Notes/") }.count == 1, "empty note skipped")
    check(paths.contains("Dictation/\(month)/\(CloudSyncPaths.day(start)).md"), "dictation per day")
    check(paths.contains("Spaces/Work Clients/Contract.md") && paths.contains("Spaces/Work Clients/Contract.png"), "space item and attachment")
    check(paths.contains("Spaces/Unfiled/Loose idea.md") && paths.contains("Spaces/Unfiled/Loose idea 2.md"), "inbox items, unique names")
    check(paths.contains("Tray/shot.png") && paths.contains("Tray/Tray text.md"), "tray copies and text")
    check(paths.contains("Clipboard/Pinned.md") && paths.contains("Habits.md") && paths.contains("README.md"), "clipboard, habits, readme")
    check(paths.contains("Modes/\(month).md"), "modes monthly")
    func text(_ path: String) -> String {
        guard case .data(let d)? = rendering.files.first(where: { $0.path == path })?.payload else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    let meetingText = text(meetingPath)
    check(meetingText.contains("Write release notes") && meetingText.contains("Ship on Friday") && meetingText.contains("Let's ship Friday."),
          "meeting has tasks, decisions and transcript")
    check(text("Spaces/Work Clients/Contract.md").contains("![Contract.png](Contract.png)"), "space note links attachment")
    let pinned = text("Clipboard/Pinned.md")
    check(pinned.contains("Gate code") && !pinned.contains("Tr0ub4dor") && !pinned.contains("vault") && pinned.contains("2 pinned items were left out"),
          "password-like and password-manager pins left out")
    check(!rendering.files.contains { $0.sourceKey.hasSuffix(copiedSecret.id.uuidString) }
          && rendering.files.contains { $0.sourceKey.hasSuffix(copiedFine.id.uuidString) }, "copied Spaces item with a secret left out, others kept")
    let trayFile = text("Tray/Tray text.md")
    check(trayFile.contains("Remember the milk") && !trayFile.contains("4821"), "secret Tray text left out")
    check(rendering.skipped.contains { $0.hasPrefix("Spaces: 1 copied item") } && rendering.skipped.contains { $0.hasPrefix("Tray: 1 text item") },
          "left-out items reported")
    check(text("Habits.md").contains("| Read | 1 day |"), "habit streak")
    check(rendering.scopes.contains("spaces:\(persona.uuidString):"), "spaces scoped to persona")

    // Transcripts off.
    var noTranscript = input
    noTranscript.settings.includesTranscripts = false
    let r2 = CloudSyncRenderer.render(noTranscript)
    if case .data(let d)? = r2.files.first(where: { $0.path == meetingPath })?.payload {
        check(!String(decoding: d, as: UTF8.self).contains("Let's ship Friday."), "transcript left out when off")
    }

    // Full runs through the job, into a scratch "iCloud Drive".
    let base = scratch.folder("job").appendingPathComponent("SparkV")
    let support = scratch.folder("job-support")
    func job(_ input: CloudSyncInput?, grace: Set<CloudSyncCategory> = [], recreate: Bool = false) -> CloudSyncJob {
        CloudSyncJob(base: base, deviceID: settings.deviceID, deviceName: "Test Mac",
                     manifestURL: support.appendingPathComponent("manifest.json"),
                     receivedDirectory: support.appendingPathComponent("Received"), input: input, importsInbox: true,
                     allowMassRemoval: false, allowRecreate: recreate, graceCategories: grace)
    }
    guard case .done(let dest, let report, _, _, let tracked) = CloudSyncJob.perform(job(input)) else {
        check(false, "first job run succeeds"); return
    }
    check(dest == base && report.errors.isEmpty && report.written == tracked && tracked > 10, "job wrote \(report.written)/\(tracked) (\(report.errors))")
    check(exists(base.appendingPathComponent("Inbox/Imported")), "Inbox created")
    check(exists(base.appendingPathComponent(CloudSyncPaths.ownerFile)), "owner file written")
    guard case .done(_, let quiet, _, _, _) = CloudSyncJob.perform(job(input)) else { check(false, "second run"); return }
    check(quiet.written == 0 && quiet.changedCount == 0, "second job run changes nothing (\(quiet.written))")

    // Rename the meeting: file moves.
    meeting.title = "Design review: final"
    var renamed = input
    renamed.meetings = [meeting]
    guard case .done(_, let moved, _, _, _) = CloudSyncJob.perform(job(renamed)) else { check(false, "rename run"); return }
    check(moved.renamed == 1 && moved.trashed == 0, "renamed meeting moved (renamed \(moved.renamed), trashed \(moved.trashed))")

    // Right after launch an empty store does not empty iCloud Drive.
    var empty = renamed
    empty.flowNotes = []
    guard case .done(_, let graced, _, _, _) = CloudSyncJob.perform(job(empty, grace: [.flowNotes])) else { check(false, "grace run"); return }
    check(graced.trashed == 0 && exists(base.appendingPathComponent("Notes/Trip ideas.md")), "grace keeps notes")
    guard case .done(_, let after, _, _, _) = CloudSyncJob.perform(job(empty)) else { check(false, "post-grace run"); return }
    check(after.trashed == 1, "after grace, deleted note goes to trash")

    // An Inbox drop is imported by the next run.
    let drop = base.appendingPathComponent("Inbox/From iPhone.txt")
    try! "Pick up dry cleaning".write(to: drop, atomically: true, encoding: .utf8)
    setOld(drop)
    _ = CloudSyncJob.perform(job(nil))
    var later = job(nil)
    later.now = Date().addingTimeInterval(5)
    guard case .done(_, _, let arrivals, _, _) = CloudSyncJob.perform(later) else { check(false, "inbox run"); return }
    check(arrivals.count == 1 && arrivals[0].text == "Pick up dry cleaning", "inbox drop imported by a job")

    // Folder deleted from iCloud Drive: pause instead of rebuilding.
    try! FileManager.default.removeItem(at: base)
    if case .rootGone = CloudSyncJob.perform(job(empty)) { check(true, "") } else { check(false, "deleted root detected") }
    if case .done(_, let rebuilt, _, _, _) = CloudSyncJob.perform(job(empty, recreate: true)) {
        check(rebuilt.written > 5, "recreate writes the folder again")
    } else { check(false, "recreate run") }

    // Mode log records finished runs only.
    let log = CloudSyncModeLog(fileURL: scratch.folder("modes").appendingPathComponent("m.json"))
    let mode = UUID()
    let t0 = Date()
    log.observe(activeID: mode, name: "Deep Work", since: t0, now: t0)
    log.observe(activeID: mode, name: "Deep Work", since: t0, now: t0.addingTimeInterval(600))
    check(log.sessions.isEmpty, "running mode not logged yet")
    log.observe(activeID: nil, name: nil, since: nil, now: t0.addingTimeInterval(1200))
    check(log.sessions.count == 1 && log.sessions[0].name == "Deep Work", "finished mode logged")
    log.observe(activeID: mode, name: "Deep Work", since: t0.addingTimeInterval(1300), now: t0.addingTimeInterval(1300))
    log.observe(activeID: nil, name: nil, since: nil, now: t0.addingTimeInterval(1310))
    check(log.sessions.count == 1, "very short run not logged")
}

/// Spins the main run loop until `condition` holds (or `timeout`).
@MainActor
func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return condition()
}

/// The controller end to end, with a scratch "iCloud Drive" and support
/// folder. Only Habits is synced (the other stores are the app's real ones).
@MainActor
func testController(_ scratch: inout Scratch) {
    print("controller")
    let icloud = scratch.folder("icloud-drive")
    let support = scratch.folder("controller-support")
    let controller = CloudSyncController(supportDirectory: support, iCloudRoot: icloud, deviceName: "Test Mac")
    check(controller.status == .off && !controller.settings.isEnabled, "off until turned on")
    controller.start()
    check(!exists(icloud.appendingPathComponent("SparkV")), "nothing written while off")
    for category in CloudSyncCategory.allCases where category != .habits { controller.setCategory(category, false) }
    controller.setImportsInbox(false)
    controller.setEnabled(true)
    let habits = icloud.appendingPathComponent("SparkV/Habits.md")
    check(waitUntil(10) { exists(habits) && controller.status == .idle }, "first sync writes Habits.md (status \(controller.status))")
    check(exists(support.appendingPathComponent("settings.json")), "settings saved in the support folder")
    check(controller.destination?.standardizedFileURL.path == icloud.appendingPathComponent("SparkV").standardizedFileURL.path, "destination reported")

    // Bursts of changes coalesce into one run.
    let written = controller.lastReport?.written ?? -1
    let firstSync = controller.lastSync ?? .distantPast
    for _ in 0..<10 { controller.noteChange() }
    check(waitUntil(8) { (controller.lastSync ?? .distantPast) > firstSync }, "debounced run happens")
    let secondSync = controller.lastSync ?? .distantPast
    _ = waitUntil(4.5) { (controller.lastSync ?? .distantPast) > secondSync }
    check(controller.lastSync == secondSync, "ten changes made one run")
    check(controller.lastReport?.written == 0 && written > 0, "nothing rewritten when nothing changed (before \(written), now \(String(describing: controller.lastReport)))")

    // Pause and resume.
    controller.setPaused(true)
    if case .paused = controller.status { check(true, "") } else { check(false, "paused status") }
    controller.setPaused(false)
    check(waitUntil(8) { controller.status == .idle }, "resumed")

    // iCloud Drive turned off on the Mac: a clear message, no folder created.
    try! FileManager.default.moveItem(at: icloud, to: icloud.deletingLastPathComponent().appendingPathComponent("moved-aside"))
    controller.syncNow()
    check(waitUntil(8) { if case .attention = controller.status { return true } else { return false } }, "iCloud Drive off reported (\(controller.status))")
    check(!exists(icloud), "iCloud Drive folder not created by SparkV")
    controller.setEnabled(false)
    check(controller.status == .off, "turned off")
    controller.stop()
}
#endif

@MainActor
func runAll(scratchPath: String) {
    var scratch = Scratch(base: URL(fileURLWithPath: scratchPath, isDirectory: true))
    testEngine(&scratch)
    testEngineSafety(&scratch)
    testInbox(&scratch)
    testPathsAndSecrets(&scratch)
    #if CLOUDSYNC_FULL
    testRendering(&scratch)
    testController(&scratch)
    #endif
    print(failures == 0 ? "OK: \(checks) checks passed" : "FAILED: \(failures) of \(checks) checks")
    exit(failures == 0 ? 0 : 1)
}

@main
enum CloudSyncTestMain {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else { print("usage: cloudsync-tests <scratch folder>"); exit(2) }
        runAll(scratchPath: args[1])
    }
}
