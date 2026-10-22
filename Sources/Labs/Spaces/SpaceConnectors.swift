import AppKit
import CoreServices
import CryptoKit
import Foundation
import UniformTypeIdentifiers

// Ingest connectors for Spaces: each one turns something the user already has
// (a meeting, a dictation, a tray item, a screenshot, a file, a web page, a
// mail message) into a `SpaceIngestInput` with a stable `sourceKey` and
// routing hints. `SpaceIngestCenter` decides when they run and hands the
// result to `SpaceStore.ingest`.
//
// Everything here is on-device. The only network access is
// `TrayAIWeb.fetch`, used when the user explicitly saves the current web
// page. Apple Events go through `SpaceAppleEvents` (one serial background
// queue, timeouts) and only from user-triggered actions.
//
// Hint keys (all optional, free-form strings):
//   app, appName            frontmost app bundle id / name (screenshots, dictation)
//   participants            comma-separated people (meetings)
//   calendarEventID         EventKit id (meetings)
//   sender, senderName, senderDomain, recipients, subject   (mail)
//   domain, browser, siteName                              (web)
//   path, folder, fileType                                 (files, tray files)
//   ocrLabels, barcodes                                    (images)

enum SpaceConnectors {
    /// Longest body handed to the store.
    static let maxTextCharacters = 60_000
    /// Transcript characters kept with a meeting (after the notes).
    static let transcriptExcerptCharacters = 6_000
    /// Files above this are referenced by URL only, not copied into the store.
    static let attachmentMaxBytes = 25 * 1024 * 1024
    /// Shorter dictations ("ok thanks") aren't worth filing.
    static let minimumDictationWords = 6

    // MARK: - Meetings

    /// Title, notes (summary, key points, decisions, tasks, questions, next
    /// steps) and a transcript excerpt. Nil when the meeting has neither notes
    /// nor a meaningful transcript yet.
    static func meetingInput(_ record: MeetingRecord, attendees: [String] = []) -> SpaceIngestInput? {
        let finals = record.segments.filter(\.isFinal).sorted { $0.start < $1.start }
        let transcript = transcriptExcerpt(finals, limit: transcriptExcerptCharacters)
        guard record.notes != nil || transcript.count >= 80 else { return nil }

        let trimmedTitle = clean(record.title)
        let title = trimmedTitle.isEmpty
            ? "Meeting \(record.startedAt.formatted(date: .abbreviated, time: .shortened))"
            : trimmedTitle

        var sections: [String] = []
        var header = [title, dateRange(record.startedAt, record.endedAt)]
        let owners = record.notes.map { ($0.myTasks + $0.othersTasks).map(\.owner) } ?? []
        let people = uniquePeople(attendees + owners)
        if !people.isEmpty { header.append("Participants: \(people.joined(separator: ", "))") }
        sections.append(header.joined(separator: "\n"))

        if let notes = record.notes {
            if !clean(notes.summary).isEmpty { sections.append("Summary\n\(clean(notes.summary))") }
            appendList("Key points", notes.keyPoints, to: &sections)
            appendList("Decisions", notes.decisions, to: &sections)
            let tasks = (notes.myTasks + notes.othersTasks).map(taskLine)
            appendList("Tasks", tasks, to: &sections)
            appendList("Open questions", notes.openQuestions, to: &sections)
            appendList("Next steps", notes.nextSteps, to: &sections)
        }
        if !record.answers.isEmpty {
            let answers = record.answers.prefix(10).map { "Q: \(clean($0.question))\nA: \(clean($0.answer))" }
            sections.append("Questions answered\n" + answers.joined(separator: "\n"))
        }
        if !transcript.isEmpty { sections.append("Transcript (excerpt)\n\(transcript)") }

        var hints: [String: String] = [:]
        if !people.isEmpty { hints["participants"] = people.joined(separator: ", ") }
        if let eventID = record.calendarEventID, !eventID.isEmpty { hints["calendarEventID"] = eventID }
        if let notes = record.notes { hints["generatedBy"] = notes.generatedBy }

        return SpaceIngestInput(
            kind: .meeting,
            source: .meetings,
            title: title,
            text: capped(sections.joined(separator: "\n\n")),
            url: URL(string: "sparkv://meeting/\(record.id.uuidString)"),
            attachment: nil,
            sourceKey: "meeting:\(record.id.uuidString)",
            createdAt: record.startedAt,
            hints: hints
        )
    }

    /// Consecutive lines by the same speaker merged, "Me:" / "Others:".
    static func transcriptExcerpt(_ segments: [TranscriptSegment], limit: Int) -> String {
        var turns: [(MeetingSpeaker, String)] = []
        for segment in segments {
            let text = clean(segment.text)
            guard !text.isEmpty else { continue }
            if let last = turns.last, last.0 == segment.speaker {
                turns[turns.count - 1].1 = last.1 + " " + text
            } else {
                turns.append((segment.speaker, text))
            }
        }
        var output = ""
        for (speaker, text) in turns {
            let line = "\(speaker == .me ? "Me" : "Others"): \(text)\n"
            if output.count + line.count > limit {
                let room = limit - output.count
                if room > 40 { output += String(line.prefix(room)) }
                output += "…"
                break
            }
            output += line
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func taskLine(_ item: ActionItem) -> String {
        var line = "[\(item.isDone ? "x" : " ")] \(clean(item.task))"
        let owner = clean(item.owner)
        var meta: [String] = []
        if !owner.isEmpty { meta.append(owner) }
        if let due = item.due.map(clean), !due.isEmpty { meta.append("due \(due)") }
        if !meta.isEmpty { line += " (\(meta.joined(separator: ", ")))" }
        return line
    }

    private static func appendList(_ heading: String, _ lines: [String], to sections: inout [String]) {
        let items = lines.map(clean).filter { !$0.isEmpty }
        guard !items.isEmpty else { return }
        sections.append(heading + "\n" + items.map { "• \($0)" }.joined(separator: "\n"))
    }

    /// Drops placeholders like "Team", "Me", "Everyone"; keeps order.
    static func uniquePeople(_ names: [String]) -> [String] {
        let generic: Set<String> = ["me", "team", "everyone", "all", "us", "we", "others", "unknown", "tbd", "n/a", "someone"]
        var seen = Set<String>()
        var result: [String] = []
        for name in names.map(clean) where !name.isEmpty && !generic.contains(name.lowercased()) {
            if seen.insert(name.lowercased()).inserted { result.append(name) }
        }
        return result
    }

    private static func dateRange(_ start: Date, _ end: Date?) -> String {
        let begin = start.formatted(date: .abbreviated, time: .shortened)
        guard let end, end > start else { return begin }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return "\(begin) · \(minutes) min"
    }

    // MARK: - Flow (dictation, notes)

    static func flowInput(_ entry: FlowEntry) -> SpaceIngestInput? {
        let text = clean(entry.text.isEmpty ? entry.raw : entry.text)
        guard wordCount(text) >= minimumDictationWords else { return nil }
        var hints: [String: String] = [:]
        if let app = entry.appName, !app.isEmpty { hints["appName"] = app }
        return SpaceIngestInput(
            kind: .dictation, source: .flow, title: headline(text), text: capped(text),
            url: nil, attachment: nil, sourceKey: "flow:\(entry.id.uuidString)",
            createdAt: entry.date, hints: hints
        )
    }

    static func flowNoteInput(_ note: FlowNote) -> SpaceIngestInput? {
        let text = clean(note.text)
        guard wordCount(text) >= 3 else { return nil }
        return SpaceIngestInput(
            kind: .note, source: .flow, title: headline(text), text: capped(text),
            url: nil, attachment: nil, sourceKey: "flownote:\(note.id.uuidString)",
            createdAt: note.date, hints: [:]
        )
    }

    // MARK: - Tray

    static func trayInput(_ item: TrayItem) async -> SpaceIngestInput? {
        switch item.kind {
        case .text:
            let text = clean(item.text ?? "")
            guard !text.isEmpty else { return nil }
            if let link = singleWebURL(text) {
                var hints: [String: String] = [:]
                if let domain = domain(of: link) { hints["domain"] = domain }
                return SpaceIngestInput(
                    kind: .link, source: .tray, title: linkTitle(link), text: text,
                    url: link, attachment: nil, sourceKey: "web:\(normalizedWebKey(link))",
                    createdAt: item.addedAt, hints: hints
                )
            }
            return SpaceIngestInput(
                kind: .note, source: .tray, title: headline(text), text: capped(text),
                url: nil, attachment: nil, sourceKey: "tray:\(item.id.uuidString)",
                createdAt: item.addedAt, hints: [:]
            )
        case .image:
            guard let url = item.url else { return nil }
            return await imageInput(at: url, kind: .screenshot, source: .tray, createdAt: item.addedAt, hints: [:])
        case .file:
            guard let url = item.url else { return nil }
            return await fileInput(url, source: .tray)
        }
    }

    // MARK: - Images and screenshots

    /// OCR (Vision, on-device) plus labels and barcodes; the image itself is
    /// the attachment. The key is a content hash, so the same screenshot seen
    /// by the watcher and dropped on the Tray is filed once.
    static func imageInput(
        at url: URL, kind: SpaceItemKind, source: SpaceItemSource, createdAt: Date, hints extra: [String: String]
    ) async -> SpaceIngestInput? {
        let analysis = await TrayAIOCR.analyze(imageAt: url)
        let ocr = clean(analysis?.copyText ?? "")
        var hints = extra
        if let labels = analysis?.labels.prefix(4).map(\.name), !labels.isEmpty {
            hints["ocrLabels"] = labels.joined(separator: ", ")
        }
        if let codes = analysis?.barcodes.map(\.payload), !codes.isEmpty {
            hints["barcodes"] = codes.prefix(5).joined(separator: " ")
        }
        let baseName = url.deletingPathExtension().lastPathComponent
        let title: String
        if wordCount(ocr) >= 2 {
            title = headline(ocr)
        } else {
            title = baseName
        }
        var bodyLines: [String] = []
        if !ocr.isEmpty { bodyLines.append(ocr) }
        if let codes = hints["barcodes"] { bodyLines.append("Codes: \(codes)") }
        if bodyLines.isEmpty { bodyLines.append(baseName) }
        let size = fileSize(url)
        let key = contentHash(url).map { "image:\($0)" } ?? "file:\(url.standardizedFileURL.path)"
        return SpaceIngestInput(
            kind: kind, source: source, title: title, text: capped(bodyLines.joined(separator: "\n\n")),
            url: url, attachment: size <= attachmentMaxBytes ? url : nil, sourceKey: key,
            createdAt: createdAt, hints: hints
        )
    }

    // MARK: - Files

    /// Text from txt/md/rtf/docx/html/pdf (PDFKit, OCR for scanned PDFs) via
    /// `TrayAIFiles`; images go through OCR; .eml files are parsed as mail.
    /// Files up to `attachmentMaxBytes` are copied as the attachment, larger
    /// ones are referenced by `url` only. Directories are skipped.
    static func fileInput(_ rawURL: URL, source: SpaceItemSource) async -> SpaceIngestInput? {
        let url = rawURL.standardizedFileURL
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .creationDateKey, .contentTypeKey])
        if values?.isDirectory == true, values?.isPackage != true { return nil }
        let created = values?.creationDate ?? Date()
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        var hints: [String: String] = [
            "path": url.path,
            "folder": url.deletingLastPathComponent().lastPathComponent,
        ]
        if !url.pathExtension.isEmpty { hints["fileType"] = url.pathExtension.lowercased() }

        if url.pathExtension.lowercased() == "eml" || type.identifier == "com.apple.mail.email" {
            if let data = try? Data(contentsOf: url, options: .mappedIfSafe), let message = EML.parse(data) {
                return mailInput(message, source: source, attachment: url, fallbackKey: "file:\(url.path)")
            }
        }
        if type.conforms(to: .image) {
            let kind: SpaceItemKind = ScreenshotLocation.looksLikeScreenshot(url) ? .screenshot : .file
            return await imageInput(at: url, kind: kind, source: source, createdAt: created, hints: hints)
        }

        let content = await TrayAIFiles.read(url)
        let text = clean(content.text ?? "")
        let body = text.isEmpty ? content.metadata : text
        let size = fileSize(url)
        return SpaceIngestInput(
            kind: .file, source: source, title: url.deletingPathExtension().lastPathComponent,
            text: capped(body), url: url, attachment: size <= attachmentMaxBytes ? url : nil,
            sourceKey: "file:\(url.path)", createdAt: created, hints: hints
        )
    }

    // MARK: - Web

    struct BrowserTab: Sendable, Equatable {
        var url: URL
        var title: String
        var browser: String
    }

    enum BrowserScriptResult: Sendable, Equatable {
        case tab(BrowserTab)
        /// The front window is private / incognito: never saved.
        case privateWindow
        case nothing
    }

    struct Browser: Sendable, Equatable {
        enum Flavor: Sendable { case safari, chromium }
        var name: String
        var bundleID: String
        var flavor: Flavor

        static let all: [Browser] = [
            Browser(name: "Safari", bundleID: "com.apple.Safari", flavor: .safari),
            Browser(name: "Safari Technology Preview", bundleID: "com.apple.SafariTechnologyPreview", flavor: .safari),
            Browser(name: "Google Chrome", bundleID: "com.google.Chrome", flavor: .chromium),
            Browser(name: "Arc", bundleID: "company.thebrowser.Browser", flavor: .chromium),
            Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", flavor: .chromium),
            Browser(name: "Brave", bundleID: "com.brave.Browser", flavor: .chromium),
        ]

        /// The frontmost app when it's a supported browser, else the first
        /// supported browser that's running (never launches one).
        static func target(frontmostBundleID: String?, runningBundleIDs: [String]) -> Browser? {
            if let front = frontmostBundleID, let browser = all.first(where: { $0.bundleID == front }) { return browser }
            let running = Set(runningBundleIDs)
            return all.first { running.contains($0.bundleID) }
        }

        /// URL on the first line, title after it. Runs only when the app is
        /// already running (checked first); 5 s Apple Event timeout.
        var tabScript: String {
            switch flavor {
            case .safari:
                return """
                with timeout of 5 seconds
                    tell application id "\(bundleID)"
                        if (count of documents) is 0 then return ""
                        set d to front document
                        return (URL of d as text) & linefeed & (name of d as text)
                    end tell
                end timeout
                """
            case .chromium:
                return """
                with timeout of 5 seconds
                    tell application id "\(bundleID)"
                        if (count of windows) is 0 then return ""
                        set w to front window
                        try
                            if (mode of w as text) is "incognito" then return "\(Browser.privateMarker)"
                        end try
                        set t to active tab of w
                        return (URL of t as text) & linefeed & (title of t as text)
                    end tell
                end timeout
                """
            }
        }

        static let privateMarker = "<<private-window>>"
    }

    /// Parses `Browser.tabScript` output.
    static func parseBrowserOutput(_ output: String, browser: String) -> BrowserScriptResult {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == Browser.privateMarker { return .privateWindow }
        guard !trimmed.isEmpty else { return .nothing }
        var lines = trimmed.components(separatedBy: .newlines)
        let rawURL = lines.removeFirst().trimmingCharacters(in: .whitespaces)
        guard rawURL != "missing value", let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else { return .nothing }
        var title = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if title == "missing value" { title = "" }
        return .tab(BrowserTab(url: url, title: title, browser: browser))
    }

    static func webInput(tab: BrowserTab, page: TrayAIWebPage?) -> SpaceIngestInput {
        let pageTitle = page?.title.map(clean) ?? ""
        let title = !pageTitle.isEmpty ? pageTitle : (!tab.title.isEmpty ? tab.title : linkTitle(tab.url))
        var body = [title, tab.url.absoluteString]
        if let summary = page?.summary.map(clean), !summary.isEmpty { body.append(summary) }
        if let text = page?.text, !clean(text).isEmpty { body.append(text) }
        var hints: [String: String] = ["browser": tab.browser]
        if let domain = domain(of: tab.url) { hints["domain"] = domain }
        if let site = page?.siteName, !site.isEmpty { hints["siteName"] = site }
        return SpaceIngestInput(
            kind: .webPage, source: .web, title: title, text: capped(body.joined(separator: "\n\n")),
            url: tab.url, attachment: nil, sourceKey: "web:\(normalizedWebKey(tab.url))",
            createdAt: Date(), hints: hints
        )
    }

    /// Lowercased scheme/host without "www.", no fragment, no tracking
    /// parameters, no trailing slash.
    static func normalizedWebKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        if let host = components.host?.lowercased() {
            components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let tracking: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "ref_src", "_hsenc", "_hsmi", "si"]
        if let items = components.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !tracking.contains(name)
            }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string ?? url.absoluteString
    }

    static func domain(of url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func linkTitle(_ url: URL) -> String {
        let host = domain(of: url) ?? url.absoluteString
        let path = url.path == "/" ? "" : url.path
        return String((host + path).prefix(80))
    }

    /// The text when it is exactly one http(s) URL.
    static func singleWebURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    // MARK: - Mail

    struct MailMessage: Sendable, Equatable {
        var messageID: String?
        var subject: String
        var senderName: String?
        var senderEmail: String?
        var recipients: [String]
        var date: Date?
        var body: String
    }

    static let mailBundleID = "com.apple.mail"
    static let mailRecordSeparator = "\u{1E}"
    static let mailFieldSeparator = "\u{1F}"

    /// Up to 10 selected messages: id, subject, sender, ISO date, recipients,
    /// content (fields separated by U+001F, records by U+001E).
    static let mailSelectionScript = """
    with timeout of 10 seconds
        tell application id "com.apple.mail"
            set sel to selection
            if (count of sel) is 0 then return ""
            set RS to character id 30
            set US to character id 31
            set out to ""
            set n to 0
            repeat with m in sel
                set n to n + 1
                if n > 10 then exit repeat
                set mid to ""
                set subj to ""
                set snd to ""
                set d to ""
                set rcpts to ""
                set bodyText to ""
                try
                    set mid to (message id of m) as text
                end try
                try
                    set subj to (subject of m) as text
                end try
                try
                    set snd to (sender of m) as text
                end try
                try
                    set d to ((date received of m) as «class isot» as string)
                end try
                try
                    repeat with r in (to recipients of m)
                        set rcpts to rcpts & ((address of r) as text) & ","
                    end repeat
                end try
                try
                    set bodyText to (content of m) as text
                end try
                set out to out & mid & US & subj & US & snd & US & d & US & rcpts & US & bodyText & RS
            end repeat
            return out
        end tell
    end timeout
    """

    /// Parses `mailSelectionScript` output.
    static func parseMailScriptOutput(_ output: String) -> [MailMessage] {
        output.components(separatedBy: mailRecordSeparator).compactMap { record -> MailMessage? in
            let fields = record.components(separatedBy: mailFieldSeparator)
            guard fields.count >= 6 else { return nil }
            let (name, email) = EML.parseAddress(fields[2])
            let recipients = fields[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            // The body is the last field and may itself contain U+001F.
            let body = fields[5...].joined(separator: mailFieldSeparator)
            let message = MailMessage(
                messageID: id.isEmpty ? nil : EML.stripAngles(id),
                subject: fields[1].trimmingCharacters(in: .whitespacesAndNewlines),
                senderName: name, senderEmail: email, recipients: recipients,
                date: parseAppleScriptISODate(fields[3]),
                body: body.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard message.messageID != nil || !message.subject.isEmpty || !message.body.isEmpty else { return nil }
            return message
        }
    }

    /// `«class isot» as string` is local time without a zone: "2026-10-20T09:30:00".
    static func parseAppleScriptISODate(_ raw: String, timeZone: TimeZone = .current) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    static func mailInput(_ message: MailMessage, source: SpaceItemSource, attachment: URL?, fallbackKey: String? = nil) -> SpaceIngestInput {
        let subject = message.subject.isEmpty ? "(no subject)" : message.subject
        var header: [String] = []
        let from = [message.senderName, message.senderEmail.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
        if !from.isEmpty { header.append("From: \(from)") }
        if !message.recipients.isEmpty { header.append("To: \(message.recipients.joined(separator: ", "))") }
        if let date = message.date { header.append("Date: \(date.formatted(date: .abbreviated, time: .shortened))") }
        header.append("Subject: \(subject)")

        var hints: [String: String] = ["subject": subject]
        if let email = message.senderEmail {
            hints["sender"] = email
            if let at = email.lastIndex(of: "@") { hints["senderDomain"] = String(email[email.index(after: at)...]).lowercased() }
        }
        if let name = message.senderName { hints["senderName"] = name }
        if !message.recipients.isEmpty { hints["recipients"] = message.recipients.joined(separator: ", ") }

        let key: String
        if let id = message.messageID {
            key = "mail:\(id)"
        } else if let fallbackKey {
            key = fallbackKey
        } else {
            let basis = "\(subject)|\(message.senderEmail ?? "")|\(message.date?.timeIntervalSince1970 ?? 0)"
            key = "mail:sha-\(sha256Hex(Data(basis.utf8)).prefix(24))"
        }
        return SpaceIngestInput(
            kind: .email, source: source, title: subject,
            text: capped(header.joined(separator: "\n") + "\n\n" + message.body),
            url: message.messageID.flatMap(mailURL), attachment: attachment, sourceKey: key,
            createdAt: message.date ?? Date(), hints: hints
        )
    }

    /// message://%3C<id>%3E opens the message in Mail.
    static func mailURL(_ messageID: String) -> URL? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "<>%/?#")
        guard let encoded = messageID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "message://%3C\(encoded)%3E")
    }

    // MARK: - Clipboard (source off by default)

    static func clipboardInput(_ text: String, appBundleID: String?, appName: String?) -> SpaceIngestInput? {
        let body = clean(text)
        guard wordCount(body) >= 4 || singleWebURL(body) != nil else { return nil }
        var hints: [String: String] = [:]
        if let appBundleID { hints["app"] = appBundleID }
        if let appName { hints["appName"] = appName }
        let link = singleWebURL(body)
        return SpaceIngestInput(
            kind: link == nil ? .clipboard : .link, source: .clipboard, title: headline(body), text: capped(body),
            url: link, attachment: nil,
            sourceKey: link.map { "web:\(normalizedWebKey($0))" } ?? "clip:\(sha256Hex(Data(body.utf8)).prefix(24))",
            createdAt: Date(), hints: hints
        )
    }

    // MARK: - Text helpers

    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capped(_ text: String) -> String {
        text.count > maxTextCharacters ? String(text.prefix(maxTextCharacters)) + "…" : text
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// First non-empty line, cut at a word boundary.
    static func headline(_ text: String, limit: Int = 72) -> String {
        let line = text.components(separatedBy: .newlines).map(clean).first { !$0.isEmpty } ?? ""
        guard line.count > limit else { return line }
        let cut = String(line.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]) + "…"
        }
        return cut + "…"
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// SHA-256 of the file (first 32 hex chars); nil when unreadable.
    static func contentHash(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(sha256Hex(data).prefix(32))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Screenshot location

    enum ScreenshotLocation {
        static let defaultsDomain = "com.apple.screencapture"
        /// Localized default names ("Screenshot 2026-10-20 at 09.30.00.png").
        static let defaultPrefixes = [
            "Screenshot", "Screen Shot", "Bildschirmfoto", "Capture d’écran", "Capture d'écran",
            "Captura de pantalla", "Istantanea schermo", "Schermafbeelding", "スクリーンショット", "截屏", "螢幕截圖", "스크린샷",
        ]

        /// `defaults read com.apple.screencapture location` → folder.
        /// Handles nil/empty (→ ~/Desktop), "~/…", file:// URLs and trailing slashes.
        static func directory(defaultsValue: String?, home: URL) -> URL {
            let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
            guard var value = defaultsValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return desktop
            }
            if value.lowercased().hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
                value = url.path
            }
            if value == "~" {
                value = home.path
            } else if value.hasPrefix("~/") {
                value = home.path + "/" + value.dropFirst(2)
            }
            guard value.hasPrefix("/") else {
                // Relative values are resolved against home, like Finder does.
                return home.appendingPathComponent(value, isDirectory: true).standardizedFileURL
            }
            while value.count > 1, value.hasSuffix("/") { value.removeLast() }
            return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        }

        /// Reads the current screencapture prefs (location, name, type).
        static func current(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> (folder: URL, prefix: String?, fileExtension: String) {
            let domain = defaultsDomain as CFString
            CFPreferencesAppSynchronize(domain)
            let location = CFPreferencesCopyAppValue("location" as CFString, domain) as? String
            let name = CFPreferencesCopyAppValue("name" as CFString, domain) as? String
            let type = CFPreferencesCopyAppValue("type" as CFString, domain) as? String
            var folder = directory(defaultsValue: location, home: home)
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                folder = home.appendingPathComponent("Desktop", isDirectory: true)
            }
            return (folder, name.flatMap { $0.isEmpty ? nil : $0 }, normalizedType(type))
        }

        static func normalizedType(_ raw: String?) -> String {
            let value = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "": return "png"
            case "jpeg": return "jpg"
            case "tif": return "tiff"
            default: return value
            }
        }

        /// Visible file named like a screenshot with an image extension.
        static func isScreenshotName(_ name: String, customPrefix: String?, fileExtension: String) -> Bool {
            guard !name.hasPrefix("."), !name.hasPrefix("~$") else { return false }
            let ext = (name as NSString).pathExtension.lowercased()
            let allowed: Set<String> = [fileExtension.lowercased(), "png", "jpg", "jpeg", "heic", "tiff"]
            guard allowed.contains(ext) else { return false }
            var prefixes = defaultPrefixes
            if let customPrefix, !customPrefix.isEmpty { prefixes.insert(customPrefix, at: 0) }
            return prefixes.contains { name.hasPrefix($0 + " ") || name.hasPrefix($0 + "_") || name.hasPrefix($0 + "-") }
        }

        /// The xattr macOS puts on every screenshot, whatever its name.
        static func hasScreenCaptureAttribute(_ url: URL) -> Bool {
            url.withUnsafeFileSystemRepresentation { path -> Bool in
                guard let path else { return false }
                return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
            }
        }

        static func looksLikeScreenshot(_ url: URL) -> Bool {
            isScreenshotName(url.lastPathComponent, customPrefix: nil, fileExtension: "png") || hasScreenCaptureAttribute(url)
        }

        /// Folders behind the Files & Folders privacy prompt. Watching one
        /// needs the user's go-ahead first so nothing prompts at launch.
        static func isPrivacyProtected(_ folder: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
            let path = folder.standardizedFileURL.path
            let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { home.appendingPathComponent($0).path }
            return path.hasPrefix("/Volumes/") || protected.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }

    // MARK: - .eml parsing

    enum EML {
        struct Part {
            var headers: [String: String]
            /// Raw body, one Character per byte (ISO Latin-1).
            var body: String
        }

        static func parse(_ data: Data) -> MailMessage? {
            guard let raw = String(data: data, encoding: .isoLatin1) else { return nil }
            let part = parsePart(raw.replacingOccurrences(of: "\r\n", with: "\n"))
            let headers = part.headers
            guard headers["from"] != nil || headers["subject"] != nil || headers["message-id"] != nil else { return nil }
            let (name, email) = parseAddress(header("from", in: headers))
            let recipients = (splitAddresses(header("to", in: headers)) + splitAddresses(header("cc", in: headers)))
                .compactMap { parseAddress($0).email }
            let id = header("message-id", in: headers)
            return MailMessage(
                messageID: id.isEmpty ? nil : stripAngles(id),
                subject: header("subject", in: headers),
                senderName: name, senderEmail: email, recipients: recipients,
                date: parseRFC2822Date(header("date", in: headers)),
                body: (bestBody(part, depth: 0) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        /// Header value: raw 8-bit bytes read as UTF-8 when valid, then
        /// RFC 2047 encoded words decoded.
        static func header(_ name: String, in headers: [String: String]) -> String {
            guard let value = headers[name] else { return "" }
            let utf8 = value.data(using: .isoLatin1).flatMap { String(data: $0, encoding: .utf8) } ?? value
            return decodeEncodedWords(utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static func parsePart(_ text: String) -> Part {
            let headerText: Substring
            let body: String
            if text.hasPrefix("\n") {
                headerText = ""
                body = String(text.dropFirst())
            } else if let range = text.range(of: "\n\n") {
                headerText = text[..<range.lowerBound]
                body = String(text[range.upperBound...])
            } else {
                headerText = Substring(text)
                body = ""
            }
            var headers: [String: String] = [:]
            var currentName: String?
            var currentValue = ""
            func commit() {
                if let name = currentName, headers[name] == nil { headers[name] = currentValue }
            }
            for line in headerText.split(separator: "\n", omittingEmptySubsequences: false) {
                if let first = line.first, first == " " || first == "\t" {
                    currentValue += " " + line.trimmingCharacters(in: .whitespaces)
                } else if let colon = line.firstIndex(of: ":") {
                    commit()
                    currentName = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    currentValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
            }
            commit()
            return Part(headers: headers, body: body)
        }

        /// text/plain preferred; text/html reduced to readable text; nested
        /// multiparts searched; attachments skipped.
        static func bestBody(_ part: Part, depth: Int) -> String? {
            let (type, params) = contentType(part.headers["content-type"])
            if type.hasPrefix("multipart/"), let boundary = params["boundary"], depth < 8 {
                var html: String?
                var nested: String?
                for child in splitMultipart(part.body, boundary: boundary) {
                    let disposition = (child.headers["content-disposition"] ?? "").lowercased()
                    if disposition.hasPrefix("attachment") { continue }
                    let (childType, _) = contentType(child.headers["content-type"])
                    if childType == "text/plain", let text = decodeBody(child), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return text
                    }
                    if childType == "text/html", html == nil {
                        html = decodeBody(child)
                    } else if childType.hasPrefix("multipart/"), nested == nil {
                        nested = bestBody(child, depth: depth + 1)
                    }
                }
                return nested ?? html.map { TrayAIHTML.readableText($0).text }
            }
            if type == "text/html" { return decodeBody(part).map { TrayAIHTML.readableText($0).text } }
            if type.hasPrefix("text/") { return decodeBody(part) }
            return nil
        }

        /// Lowercased type ("text/plain" when missing) and parameters.
        static func contentType(_ value: String?) -> (String, [String: String]) {
            guard let value, !value.isEmpty else { return ("text/plain", [:]) }
            var pieces = splitOutsideQuotes(value, separator: ";")
            let type = pieces.removeFirst().trimmingCharacters(in: .whitespaces).lowercased()
            var params: [String: String] = [:]
            for piece in pieces {
                guard let equals = piece.firstIndex(of: "=") else { continue }
                let key = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                var raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 { raw = String(raw.dropFirst().dropLast()) }
                params[key] = raw
            }
            return (type.isEmpty ? "text/plain" : type, params)
        }

        static func splitMultipart(_ body: String, boundary: String) -> [Part] {
            let delimiter = "--" + boundary
            var parts: [Part] = []
            var current: [Substring]?
            for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == delimiter + "--" {
                    if let lines = current { parts.append(parsePart(lines.joined(separator: "\n"))) }
                    current = nil
                    break
                }
                if trimmed == delimiter {
                    if let lines = current { parts.append(parsePart(lines.joined(separator: "\n"))) }
                    current = []
                    continue
                }
                current?.append(line)
            }
            if let lines = current, !lines.isEmpty { parts.append(parsePart(lines.joined(separator: "\n"))) }
            return parts
        }

        static func decodeBody(_ part: Part) -> String? {
            let encoding = (part.headers["content-transfer-encoding"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let bytes: Data?
            switch encoding {
            case "base64":
                let compact = part.body.filter { !$0.isWhitespace }
                bytes = Data(base64Encoded: compact, options: .ignoreUnknownCharacters)
            case "quoted-printable":
                bytes = part.body.data(using: .isoLatin1).map { quotedPrintableDecode($0, isHeader: false) }
            default:
                bytes = part.body.data(using: .isoLatin1)
            }
            guard let bytes else { return nil }
            let charset = contentType(part.headers["content-type"]).1["charset"]
            return decode(bytes, charset: charset)
        }

        static func decode(_ data: Data, charset: String?) -> String {
            if let charset, !charset.isEmpty {
                let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                if cf != kCFStringEncodingInvalidId,
                   let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) {
                    return text
                }
            }
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        }

        static func quotedPrintableDecode(_ data: Data, isHeader: Bool) -> Data {
            let bytes = [UInt8](data)
            var output = [UInt8]()
            output.reserveCapacity(bytes.count)
            var index = 0
            func hex(_ byte: UInt8) -> UInt8? {
                switch byte {
                case 48...57: byte - 48
                case 65...70: byte - 55
                case 97...102: byte - 87
                default: nil
                }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "=") {
                    if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "\n") {
                        index += 2
                        continue
                    }
                    if index + 2 < bytes.count, bytes[index + 1] == UInt8(ascii: "\r"), bytes[index + 2] == UInt8(ascii: "\n") {
                        index += 3
                        continue
                    }
                    if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                        output.append(high << 4 | low)
                        index += 3
                        continue
                    }
                }
                if isHeader, byte == UInt8(ascii: "_") {
                    output.append(UInt8(ascii: " "))
                } else {
                    output.append(byte)
                }
                index += 1
            }
            return Data(output)
        }

        /// RFC 2047: =?charset?B|Q?text?=, whitespace between adjacent words dropped.
        static func decodeEncodedWords(_ value: String) -> String {
            guard value.contains("=?"),
                  let regex = try? NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?]*)\?="#) else { return value }
            let ns = value as NSString
            let matches = regex.matches(in: value, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return value }
            var output = ""
            var cursor = 0
            var previousWasEncoded = false
            for match in matches {
                let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !(previousWasEncoded && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    output += gap
                }
                var charset = ns.substring(with: match.range(at: 1))
                if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // RFC 2231 language
                let mode = ns.substring(with: match.range(at: 2)).uppercased()
                let payload = ns.substring(with: match.range(at: 3))
                let data: Data? = mode == "B"
                    ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
                    : payload.data(using: .isoLatin1).map { quotedPrintableDecode($0, isHeader: true) }
                if let data {
                    output += decode(data, charset: charset)
                } else {
                    output += ns.substring(with: match.range)
                }
                cursor = match.range.location + match.range.length
                previousWasEncoded = true
            }
            output += ns.substring(from: cursor)
            return output
        }

        /// "Jane Doe <jane@x.com>", "\"Doe, Jane\" <jane@x.com>", "jane@x.com (Jane)", "jane@x.com".
        static func parseAddress(_ raw: String) -> (name: String?, email: String?) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return (nil, nil) }
            if let open = value.lastIndex(of: "<"), let close = value[open...].firstIndex(of: ">") {
                let email = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                var name = value[..<open].trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
                name = name.replacingOccurrences(of: "\\\"", with: "\"").trimmingCharacters(in: .whitespaces)
                return (name.isEmpty ? nil : name, email.contains("@") ? email.lowercased() : nil)
            }
            if let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")"), open < close {
                let email = value[..<open].trimmingCharacters(in: .whitespaces)
                let name = value[value.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                return (name.isEmpty ? nil : name, email.contains("@") ? email.lowercased() : nil)
            }
            return value.contains("@") ? (nil, value.lowercased()) : (value, nil)
        }

        /// Splits an address list on commas outside quotes and angle brackets.
        static func splitAddresses(_ value: String) -> [String] {
            var result: [String] = []
            var current = ""
            var inQuotes = false
            var angleDepth = 0
            var previous: Character = " "
            for character in value {
                switch character {
                case "\"" where previous != "\\": inQuotes.toggle()
                case "<" where !inQuotes: angleDepth += 1
                case ">" where !inQuotes: angleDepth = max(0, angleDepth - 1)
                default: break
                }
                if character == ",", !inQuotes, angleDepth == 0 {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { result.append(trimmed) }
                    current = ""
                } else {
                    current.append(character)
                }
                previous = character
            }
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(trimmed) }
            return result
        }

        static func splitOutsideQuotes(_ value: String, separator: Character) -> [String] {
            var result: [String] = []
            var current = ""
            var inQuotes = false
            for character in value {
                if character == "\"" { inQuotes.toggle() }
                if character == separator, !inQuotes {
                    result.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            result.append(current)
            return result
        }

        static func stripAngles(_ id: String) -> String {
            var value = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("<") { value.removeFirst() }
            if value.hasSuffix(">") { value.removeLast() }
            return value
        }

        static func parseRFC2822Date(_ raw: String) -> Date? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            // Drop trailing comments such as "(UTC)" or "(PDT)".
            if let paren = value.firstIndex(of: "(") { value = value[..<paren].trimmingCharacters(in: .whitespaces) }
            value = value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            let formats = [
                "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
                "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz",
                "EEE, d MMM yy HH:mm:ss Z",
            ]
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
            return nil
        }
    }
}

// MARK: - Apple Events

/// Runs AppleScript against other apps from one serial background queue, so
/// a slow app or the Automation consent prompt never blocks the main thread.
/// Each NSAppleScript is created and executed on that queue only.
final class SpaceAppleEvents: @unchecked Sendable {
    static let shared = SpaceAppleEvents()

    enum Failure: Error, Sendable, Equatable {
        case notRunning
        case notPermitted
        case timedOut
        case script(code: Int, message: String)
    }

    private let queue = DispatchQueue(label: "NotchIsland.Spaces.AppleEvents", qos: .userInitiated)

    /// Automation permission for `bundleID`. With `askUser` (only from a
    /// user action) the ask goes through PermissionCenter: the consent prompt
    /// if it was never answered, one system prompt at a time and at most once
    /// per session; Settings › Automation when it was denied. Not
    /// time-limited: the user may take a while to answer.
    func permission(bundleID: String, askUser: Bool, from feature: String = "Spaces") async -> OSStatus {
        if askUser {
            let status = await Self.ask(bundleID: bundleID, feature: feature)
            if let code = Self.code(for: status) { return code }
        }
        return await check(bundleID: bundleID)
    }

    @MainActor
    private static func ask(bundleID: String, feature: String) async -> PermissionCenter.Status {
        await PermissionCenter.shared.request(.automation(bundleID: bundleID), from: feature)
    }

    /// The AEDeterminePermissionToAutomateTarget code callers already handle.
    private static func code(for status: PermissionCenter.Status) -> OSStatus? {
        switch status {
        case .granted: noErr
        case .denied, .restricted: OSStatus(errAEEventNotPermitted)
        case .notDetermined, .limited: OSStatus(errAEEventWouldRequireUserConsent)
        case .appNotRunning, .appNotInstalled: OSStatus(procNotFound)
        case .unknown: nil
        }
    }

    /// Never prompts.
    private func check(bundleID: String) async -> OSStatus {
        let askUser = false
        return await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                guard let address = target.aeDesc else {
                    continuation.resume(returning: OSStatus(paramErr))
                    return
                }
                continuation.resume(returning: AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, askUser))
            }
        }
    }

    /// Executes `source` and returns its string result. Gives up after
    /// `timeout` seconds (the script also carries its own `with timeout`).
    func run(_ source: String, timeout: TimeInterval) async -> Result<String, Failure> {
        let gate = SpaceResumeGate<Result<String, Failure>>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            queue.async {
                gate.resume(Self.execute(source))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.resume(.failure(.timedOut))
            }
        }
    }

    private static func execute(_ source: String) -> Result<String, Failure> {
        guard let script = NSAppleScript(source: source) else { return .failure(.script(code: 0, message: "Couldn't compile script")) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? ""
            switch code {
            case Int(errAEEventNotPermitted), Int(errAEEventWouldRequireUserConsent): return .failure(.notPermitted)
            case Int(procNotFound), Int(connectionInvalid): return .failure(.notRunning)
            case Int(errAETimeout): return .failure(.timedOut)
            default: return .failure(.script(code: code, message: message))
            }
        }
        return .success(result.stringValue ?? "")
    }
}

/// Resumes a checked continuation exactly once (result or timeout).
final class SpaceResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var done = false

    func install(_ continuation: CheckedContinuation<T, Never>) {
        lock.lock()
        if let pending, !done {
            done = true
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: T) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        guard let continuation else {
            pending = pending ?? value
            lock.unlock()
            return
        }
        done = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

// MARK: - Watchers

/// Watches one folder (non-recursive) with a DispatchSource and reports
/// files that appear after `start()`; the existing contents are not reported.
final class SpaceDirectoryWatcher: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "NotchIsland.Spaces.DirectoryWatcher", qos: .utility)
    private let onNewFiles: @Sendable ([URL]) -> Void
    // Queue-confined.
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []

    init(url: URL, onNewFiles: @escaping @Sendable ([URL]) -> Void) {
        self.url = url
        self.onNewFiles = onNewFiles
    }

    func start() {
        queue.async { [self] in
            guard source == nil else { return }
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else {
                AppLog.log("Spaces: can't watch \(url.path) (errno \(errno))")
                return
            }
            known = listing()
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: queue)
            source.setEventHandler { [weak self] in self?.scan() }
            source.setCancelHandler { close(descriptor) }
            self.source = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
        }
    }

    deinit {
        source?.cancel()
    }

    private func listing() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
    }

    private func scan() {
        let names = listing()
        let added = names.subtracting(known)
        known = names
        guard !added.isEmpty else { return }
        onNewFiles(added.sorted().map { url.appendingPathComponent($0) })
    }
}

/// Recursive FSEvents stream over a set of folders; reports created,
/// renamed-in and modified regular files (file-level events, 1 s latency).
final class SpaceFolderWatcher: @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let handler: @Sendable ([String]) -> Void
        init(_ handler: @escaping @Sendable ([String]) -> Void) { self.handler = handler }
    }

    let paths: [String]
    private let box: Box
    private let queue = DispatchQueue(label: "NotchIsland.Spaces.FolderWatcher", qos: .utility)
    private var stream: FSEventStreamRef?

    init(paths: [String], onFiles: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths
        self.box = Box(onFiles)
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Box>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<Box>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            let interesting = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
                | FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            let isFile = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
            var files: [String] = []
            for index in 0..<count {
                let flags = rawFlags[index]
                guard flags & isFile != 0, flags & interesting != 0, let path = array[index] as? String else { continue }
                files.append(path)
            }
            if !files.isEmpty { box.handler(files) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
            | FSEventStreamCreateFlags(kFSEventStreamCreateFlagIgnoreSelf)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags
        ) else {
            AppLog.log("Spaces: couldn't create FSEvents stream")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
