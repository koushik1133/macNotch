import Foundation

/// One run of a Mode, recorded by `CloudSyncModeLog`.
struct CloudSyncModeSession: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var modeID: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date
}

/// Everything one sync needs, copied off the stores on the main actor so
/// rendering and file work can run in the background. A nil field means
/// "not available this run" (category off, or its store isn't connected):
/// files already in iCloud Drive for it are left as they are.
struct CloudSyncInput: Sendable {
    struct SpacesSnapshot: Sendable {
        var personaID: UUID
        var personaName: String
        /// Adds a persona folder level when there is more than one persona.
        var hasSeveralPersonas: Bool
        var spaces: [Space]
        var items: [SpaceItem]
        /// Item id -> stored attachment on disk.
        var attachments: [UUID: URL]
    }

    struct HabitsSnapshot: Sendable {
        var habits: [Habit]
        var done: [UUID: Set<String>]
    }

    var settings: CloudSyncSettings
    var meetings: [MeetingRecord]?
    var flowNotes: [FlowNote]?
    var dictations: [FlowEntry]?
    var spaces: SpacesSnapshot?
    var tray: [TrayItem]?
    var clipboardPinned: [ClipboardItem]?
    var focusSessions: [FocusSessionRecord]?
    var modeSessions: [CloudSyncModeSession]?
    var habits: HabitsSnapshot?
    var now = Date()
}

struct CloudSyncRendering: Sendable {
    var files: [CloudSyncFile] = []
    /// sourceKey prefixes the files cover (see `CloudSyncEngine.mirror`).
    var scopes: [String] = []
    var skipped: [String] = []
}

/// Turns SparkV data into Markdown files and copies. Pure apart from
/// checking that files to copy still exist.
enum CloudSyncRenderer {
    static let maxCopyBytes: Int64 = 100 * 1024 * 1024
    static let maxItemTextCharacters = 400_000

    /// A file (or a Markdown file plus its attachment) before its final name
    /// is known; names are made unique per folder, oldest item first, so an
    /// existing file keeps its name when a newer one with the same title appears.
    private struct Draft {
        struct Part {
            /// Name for the given stem ("Plan" -> "Plan.md").
            var name: (String) -> String
            var keySuffix: String
            /// Content for the final stem (a Markdown file links its attachment by name).
            var payload: (String) -> CloudSyncFile.Payload
        }

        var directory: String
        var stem: String
        var sourceKey: String
        var order: Date
        var parts: [Part]
    }

    static func render(_ input: CloudSyncInput, calendar: Calendar = .current) -> CloudSyncRendering {
        var out = CloudSyncRendering()
        var drafts: [Draft] = []
        let on = input.settings.categories

        func markdown(_ dir: String, _ stem: String, key: String, order: Date, _ text: String) -> Draft {
            Draft(directory: dir, stem: stem, sourceKey: key, order: order,
                  parts: [.init(name: { "\($0).md" }, keySuffix: "", payload: { _ in .data(Data(text.utf8)) })])
        }

        drafts.append(markdown("", "README", key: "readme:root", order: .distantPast, readme))
        out.scopes.append("readme:")

        if on.contains(.meetings), let meetings = input.meetings {
            out.scopes.append("meetings:")
            for record in meetings where record.endedAt != nil {
                guard record.notes != nil || !record.segments.isEmpty
                        || !(record.userNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                var copy = record
                if !input.settings.includesTranscripts { copy.segments = [] }
                let title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let stem = "\(CloudSyncPaths.day(record.startedAt, calendar: calendar)) \(CloudSyncPaths.time(record.startedAt, calendar: calendar)) "
                    + CloudSyncPaths.component(title, fallback: "Meeting", maxLength: 70)
                drafts.append(markdown("Meetings/" + CloudSyncPaths.month(record.startedAt, calendar: calendar), stem,
                                       key: "meetings:\(record.id.uuidString)", order: record.startedAt,
                                       MeetingFormat.markdown(for: copy)))
            }
        }

        if on.contains(.flowNotes), let notes = input.flowNotes {
            out.scopes.append("flowNotes:")
            for note in notes {
                let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let title = CloudSyncInbox.title(of: text) ?? "Note"
                let body = "# \(title)\n\n_Edited \(note.date.formatted(date: .abbreviated, time: .shortened))_\n\n\(text)\n"
                // Named after the first line only: the date changes on every edit.
                drafts.append(markdown("Notes", CloudSyncPaths.component(title, fallback: "Note", maxLength: 60),
                                       key: "flowNotes:\(note.id.uuidString)", order: note.date, body))
            }
        }

        if on.contains(.dictations), let entries = input.dictations {
            out.scopes.append("dictations:")
            let byDay = Dictionary(grouping: entries) { CloudSyncPaths.day($0.date, calendar: calendar) }
            for (day, list) in byDay {
                let sorted = list.sorted { $0.date < $1.date }
                guard let first = sorted.first else { continue }
                var lines = ["# Dictation · \(first.date.formatted(date: .complete, time: .omitted))", ""]
                for entry in sorted {
                    let app = entry.appName.map { " · \($0)" } ?? ""
                    lines.append("### \(entry.date.formatted(date: .omitted, time: .shortened))\(app)")
                    lines.append("")
                    lines.append(entry.text)
                    lines.append("")
                }
                drafts.append(markdown("Dictation/" + CloudSyncPaths.month(first.date, calendar: calendar), day,
                                       key: "dictations:\(day)", order: first.date, lines.joined(separator: "\n")))
            }
        }

        if on.contains(.spaces), let snapshot = input.spaces {
            out.scopes.append("spaces:\(snapshot.personaID.uuidString):")
            let base = snapshot.hasSeveralPersonas
                ? "Spaces/" + CloudSyncPaths.component(snapshot.personaName, fallback: "Persona")
                : "Spaces"
            let byID = Dictionary(snapshot.spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func folder(of spaceID: UUID?) -> String {
                guard let spaceID, byID[spaceID] != nil else { return base + "/Unfiled" }
                var chain: [String] = []
                var cursor: UUID? = spaceID
                var seen = Set<UUID>()
                while let id = cursor, let space = byID[id], !seen.contains(id), chain.count < 12 {
                    seen.insert(id)
                    chain.insert(CloudSyncPaths.component(space.name, fallback: "Space", maxLength: 60), at: 0)
                    cursor = space.parentID
                }
                return base + "/" + chain.joined(separator: "/")
            }
            var secretItems = 0
            for item in snapshot.items {
                // Spaces can file copied text (its clipboard source): the same
                // secret filter as pinned clipboard applies before iCloud Drive.
                if item.source == .clipboard || item.kind == .clipboard,
                   CloudSyncSecrets.looksSensitive(item.text) || CloudSyncSecrets.looksSensitive(item.title) {
                    secretItems += 1
                    continue
                }
                let key = "spaces:\(snapshot.personaID.uuidString):\(item.id.uuidString)"
                var parts: [Draft.Part] = []
                var attachmentName: ((String) -> String)?
                if input.settings.includesSpaceAttachments, let file = snapshot.attachments[item.id],
                   let stat = CloudSyncEngine.stat(file) {
                    if stat.size <= maxCopyBytes {
                        let ext = file.pathExtension.isEmpty ? "file" : file.pathExtension
                        let name: (String) -> String = ext.lowercased() == "md"
                            ? { "\($0) (attachment).md" } : { "\($0).\(ext)" }
                        parts.append(.init(name: name, keySuffix: ":attachment", payload: { _ in .copy(file) }))
                        attachmentName = name
                    } else {
                        out.skipped.append("Spaces: attachment of “\(item.title)” is over 100 MB")
                    }
                }
                let stem = CloudSyncPaths.component(item.title, fallback: "Item", maxLength: 70)
                let linked = attachmentName
                parts.insert(.init(name: { "\($0).md" }, keySuffix: "", payload: { finalStem in
                    .data(Data(spaceItemMarkdown(item, attachmentName: linked?(finalStem)).utf8))
                }), at: 0)
                drafts.append(Draft(directory: folder(of: item.spaceID), stem: stem, sourceKey: key,
                                    order: item.createdAt, parts: parts))
            }
            if secretItems > 0 {
                out.skipped.append("Spaces: \(secretItems) copied item\(secretItems == 1 ? "" : "s") left out (looks like a password or key)")
            }
        }

        if on.contains(.tray), let tray = input.tray {
            out.scopes.append("tray:")
            var texts: [String] = []
            var secretTexts = 0
            for item in tray.sorted(by: { $0.addedAt < $1.addedAt }) {
                switch item.kind {
                case .text:
                    guard let t = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
                    if CloudSyncSecrets.looksSensitive(t) { secretTexts += 1 } else { texts.append(t) }
                case .image, .file:
                    guard let url = item.url else { continue }
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                    if isDir.boolValue {
                        out.skipped.append("Tray: “\(url.lastPathComponent)” is a folder (not copied)")
                        continue
                    }
                    guard let stat = CloudSyncEngine.stat(url) else {
                        out.skipped.append("Tray: “\(url.lastPathComponent)” is a link or can't be read (not copied)")
                        continue
                    }
                    guard stat.size <= maxCopyBytes else {
                        out.skipped.append("Tray: “\(url.lastPathComponent)” is over 100 MB (not copied)")
                        continue
                    }
                    let ext = url.pathExtension
                    let stem = CloudSyncPaths.component((url.lastPathComponent as NSString).deletingPathExtension, fallback: "File")
                    let safeExt = CloudSyncPaths.component(ext, fallback: "", maxLength: 12)
                    drafts.append(Draft(directory: "Tray", stem: stem, sourceKey: "tray:\(item.id.uuidString)", order: item.addedAt,
                                        parts: [.init(name: { safeExt.isEmpty ? $0 : "\($0).\(safeExt)" }, keySuffix: "", payload: { _ in .copy(url) })]))
                }
            }
            if secretTexts > 0 {
                out.skipped.append("Tray: \(secretTexts) text item\(secretTexts == 1 ? "" : "s") left out (looks like a password or key)")
            }
            if !texts.isEmpty {
                let body = "# Tray text\n\n" + texts.map { "---\n\n\($0)\n" }.joined(separator: "\n")
                drafts.append(markdown("Tray", "Tray text", key: "tray:text", order: .distantPast, body))
            }
        }

        if on.contains(.clipboard), let pinned = input.clipboardPinned {
            out.scopes.append("clipboard:")
            var blocks: [String] = []
            var leftOut = 0
            for item in pinned.sorted(by: { $0.firstCopiedAt < $1.firstCopiedAt }) {
                guard [.text, .richText, .url].contains(item.kind),
                      let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                if CloudSyncSecrets.isPasswordManager(item.sourceBundleID) || CloudSyncSecrets.looksSensitive(text) {
                    leftOut += 1
                    continue
                }
                let clipped = text.count > 20_000 ? String(text.prefix(20_000)) + "\n\n_(shortened)_" : text
                blocks.append("---\n\n\(clipped)\n")
            }
            var body = "# Pinned clipboard\n\n"
            body += blocks.isEmpty ? "_Nothing pinned._\n" : blocks.joined(separator: "\n")
            if leftOut > 0 {
                body += "\n_\(leftOut) pinned item\(leftOut == 1 ? " was" : "s were") left out because \(leftOut == 1 ? "it looks" : "they look") like a password or key._\n"
            }
            drafts.append(markdown("Clipboard", "Pinned", key: "clipboard:pinned", order: .distantPast, body))
        }

        if on.contains(.focus), let sessions = input.focusSessions {
            out.scopes.append("focus:")
            let byMonth = Dictionary(grouping: sessions) { CloudSyncPaths.month($0.startedAt, calendar: calendar) }
            for (month, list) in byMonth {
                let sorted = list.sorted { $0.startedAt > $1.startedAt }
                guard let first = sorted.last else { continue }
                drafts.append(markdown("Focus", month, key: "focus:\(month)", order: first.startedAt,
                                       focusMarkdown(sorted, monthStart: first.startedAt)))
            }
        }

        if on.contains(.modes), let sessions = input.modeSessions {
            out.scopes.append("modes:")
            let byMonth = Dictionary(grouping: sessions) { CloudSyncPaths.month($0.startedAt, calendar: calendar) }
            for (month, list) in byMonth {
                let sorted = list.sorted { $0.startedAt > $1.startedAt }
                guard let first = sorted.last else { continue }
                drafts.append(markdown("Modes", month, key: "modes:\(month)", order: first.startedAt,
                                       modesMarkdown(sorted, monthStart: first.startedAt)))
            }
        }

        if on.contains(.habits), let habits = input.habits {
            out.scopes.append("habits:")
            drafts.append(markdown("", "Habits", key: "habits:all", order: .distantPast,
                                   habitsMarkdown(habits, today: input.now, calendar: calendar)))
        }

        out.files = assignNames(drafts)
        return out
    }

    /// Unique names per folder (case-insensitive), oldest first.
    private static func assignNames(_ drafts: [Draft]) -> [CloudSyncFile] {
        var files: [CloudSyncFile] = []
        var used: [String: Set<String>] = [:]
        let ordered = drafts.sorted { a, b in
            a.order != b.order ? a.order < b.order : a.sourceKey < b.sourceKey
        }
        for draft in ordered {
            let dirKey = CloudSyncPaths.key(draft.directory)
            var taken = used[dirKey] ?? []
            var stem = draft.stem
            var n = 2
            while draft.parts.contains(where: { taken.contains(CloudSyncPaths.key($0.name(stem))) }) {
                stem = "\(draft.stem) \(n)"
                n += 1
            }
            for part in draft.parts {
                let name = part.name(stem)
                taken.insert(CloudSyncPaths.key(name))
                let path = draft.directory.isEmpty ? name : "\(draft.directory)/\(name)"
                files.append(CloudSyncFile(path: path, sourceKey: draft.sourceKey + part.keySuffix, payload: part.payload(stem)))
            }
            used[dirKey] = taken
        }
        return files
    }

    // MARK: - Markdown

    static let readme = """
    # SparkV

    This folder is kept up to date by SparkV on your Mac. Open it on your iPhone or iPad in the **Files** app: **Browse › iCloud Drive › SparkV**.

    - **Meetings**: minutes, decisions and tasks for every meeting.
    - **Notes** and **Dictation**: your Flow notes and dictation history.
    - **Spaces**: everything you filed, one folder per Space.
    - **Tray**, **Focus**, **Modes**, **Habits.md**: your shelf, sessions and streaks.

    ## Send something to your Mac

    Save a note, a photo, a link or a file into **Inbox** (in the share sheet: **Save to Files › iCloud Drive › SparkV › Inbox**). SparkV imports it within a minute: text becomes a note in the Spaces Inbox, images and files land on the Tray. The original moves to **Inbox/Imported**.

    ## Good to know

    - Files here are copies: editing them does not change SparkV. If you edit one anyway, SparkV keeps your version in **Conflicts** before it writes its own.
    - Nothing is deleted. Files SparkV no longer needs move to the hidden **.trash** folder (on the Mac, press Shift-Command-Period in Finder to see it).
    - To stop syncing, turn it off in SparkV. Turning off a category leaves its files here as they are; delete them (and **.trash**) here if you no longer want them in iCloud.

    """

    static func spaceItemMarkdown(_ item: SpaceItem, attachmentName: String?) -> String {
        var lines = ["# \(item.title)", ""]
        var meta = ["\(item.kind.rawValue.capitalized)", item.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if item.source != .manual { meta.insert("from \(item.source.rawValue)", at: 1) }
        lines.append("_" + meta.joined(separator: " · ") + "_")
        lines.append("")
        if let url = item.url, !url.isFileURL { lines.append("<\(url.absoluteString)>"); lines.append("") }
        if let name = attachmentName {
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            let isImage = item.kind == .screenshot || ["png", "jpg", "jpeg", "heic", "gif", "tiff", "webp"]
                .contains((name as NSString).pathExtension.lowercased())
            lines.append(isImage ? "![\(name)](\(encoded))" : "[\(name)](\(encoded))")
            lines.append("")
        }
        if !item.tags.isEmpty { lines.append("Tags: " + item.tags.map { "#\($0)" }.joined(separator: " ")); lines.append("") }
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append(text.count > maxItemTextCharacters ? String(text.prefix(maxItemTextCharacters)) + "\n\n_(shortened)_" : text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func focusMarkdown(_ sessions: [FocusSessionRecord], monthStart: Date) -> String {
        let total = sessions.reduce(0) { $0 + $1.focusedSeconds }
        var lines = [
            "# Focus · \(monthStart.formatted(.dateTime.month(.wide).year()))", "",
            "**\(duration(total))** focused over \(sessions.count) session\(sessions.count == 1 ? "" : "s").", "",
        ]
        for s in sessions {
            let span = "\(s.startedAt.formatted(date: .omitted, time: .shortened))–\(s.endedAt.formatted(date: .omitted, time: .shortened))"
            lines.append("## \(s.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(span) · \(duration(s.focusedSeconds))")
            var facts: [String] = []
            if s.roundsCompleted > 0 { facts.append("\(s.roundsCompleted) round\(s.roundsCompleted == 1 ? "" : "s")") }
            switch s.endReason {
            case .completed: facts.append("completed")
            case .stopped: facts.append("stopped early")
            case .expired: facts.append("ended")
            }
            if !s.interruptions.isEmpty { facts.append("\(s.interruptions.count) distraction\(s.interruptions.count == 1 ? "" : "s") caught") }
            lines.append("_" + facts.joined(separator: " · ") + "_")
            lines.append("")
            let summary = s.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty { lines.append(summary); lines.append("") }
            let apps = s.apps.sorted { $0.seconds > $1.seconds }.prefix(3)
            if !apps.isEmpty {
                lines.append("Top apps: " + apps.map { "\($0.name) (\(duration($0.seconds)))" }.joined(separator: ", "))
                lines.append("")
            }
            let made = FocusArtifact.Kind.allCases.compactMap { kind -> String? in
                let n = s.count(of: kind)
                return n > 0 ? kind.countLabel(n) : nil
            }
            if !made.isEmpty { lines.append("Made: " + made.joined(separator: ", ")); lines.append("") }
        }
        return lines.joined(separator: "\n")
    }

    static func modesMarkdown(_ sessions: [CloudSyncModeSession], monthStart: Date) -> String {
        var lines = ["# Modes · \(monthStart.formatted(.dateTime.month(.wide).year()))", ""]
        let totals = Dictionary(grouping: sessions, by: \.name).mapValues { $0.reduce(0) { $0 + $1.endedAt.timeIntervalSince($1.startedAt) } }
        for (name, seconds) in totals.sorted(by: { $0.value > $1.value }) {
            lines.append("- **\(name)**: \(duration(seconds))")
        }
        lines.append("")
        lines.append("## Sessions")
        for s in sessions {
            let day = s.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            let span = "\(s.startedAt.formatted(date: .omitted, time: .shortened))–\(s.endedAt.formatted(date: .omitted, time: .shortened))"
            lines.append("- \(day) · \(span) · **\(s.name)** (\(duration(s.endedAt.timeIntervalSince(s.startedAt))))")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func habitsMarkdown(_ snapshot: CloudSyncInput.HabitsSnapshot, today: Date, calendar: Calendar) -> String {
        let days = HabitCalendar.lastDays(14, endingAt: today, calendar: calendar)
        var lines = ["# Habits", ""]
        guard !snapshot.habits.isEmpty else { return (lines + ["_No habits yet._", ""]).joined(separator: "\n") }
        let header = days.map { "\(calendar.component(.day, from: $0))" }
        lines.append("| Habit | Streak | " + header.joined(separator: " | ") + " |")
        lines.append("| --- | --- | " + header.map { _ in ":-:" }.joined(separator: " | ") + " |")
        for habit in snapshot.habits {
            let done = snapshot.done[habit.id] ?? []
            let streak = HabitCalendar.streak(done: done, today: today, calendar: calendar)
            let cells = days.map { done.contains(HabitCalendar.key(for: $0, calendar: calendar)) ? "✓" : "·" }
            let name = habit.name.replacingOccurrences(of: "|", with: "/")
            lines.append("| \(name) | \(streak) day\(streak == 1 ? "" : "s") | " + cells.joined(separator: " | ") + " |")
        }
        lines.append("")
        lines.append("_Last 14 days, today on the right._")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
