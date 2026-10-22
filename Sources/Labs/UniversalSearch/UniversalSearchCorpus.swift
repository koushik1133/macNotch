import Foundation

/// Turns each store's records into `UniversalSearchDocument`s. Pure
/// functions over the stores' value types, so tests feed fixtures.
enum UniversalSearchCorpus {
    struct Input: Sendable {
        var flowHistory: [FlowEntry] = []
        var flowNotes: [FlowNote] = []
        var meetings: [MeetingRecord] = []
        var clipboard: [ClipboardItem] = []
        var tray: [TrayItem] = []
        var spaceItems: [SpaceItem] = []
        var spaces: [Space] = []
        /// Bundle id -> app name for clipboard rows.
        var appNames: [String: String] = [:]
    }

    static func build(_ input: Input, enabled: Set<UniversalSearchSource> = Set(UniversalSearchSource.allCases)) -> [UniversalSearchDocument] {
        var docs: [UniversalSearchDocument] = []
        if enabled.contains(.spaces) { docs += spaces(input.spaceItems, spaces: input.spaces) }
        if enabled.contains(.meetings) { docs += meetings(input.meetings) }
        if enabled.contains(.flow) { docs += flow(input.flowHistory, notes: input.flowNotes) }
        if enabled.contains(.clipboard) { docs += clipboard(input.clipboard, appNames: input.appNames) }
        if enabled.contains(.tray) { docs += tray(input.tray) }
        return docs
    }

    // MARK: Flow

    static func flow(_ history: [FlowEntry], notes: [FlowNote]) -> [UniversalSearchDocument] {
        var docs: [UniversalSearchDocument] = []
        for e in history where !e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The raw transcript holds the same words as the formatted text
            // (only casing/punctuation differ), so it isn't indexed twice.
            let body = e.text
            docs.append(UniversalSearchDocument(
                id: "flow:\(e.id.uuidString)", source: .flow, target: .flowEntry(e.id),
                title: UniversalSearchText.firstLine(e.text),
                subtitle: ["Dictation", e.appName].compactMap { $0 }.joined(separator: " · "),
                keywords: e.appName ?? "",
                body: body, date: e.date, symbol: "waveform", copyText: e.text
            ))
        }
        for n in notes where !n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            docs.append(UniversalSearchDocument(
                id: "note:\(n.id.uuidString)", source: .flow, target: .flowNote(n.id),
                title: UniversalSearchText.firstLine(n.text), subtitle: "Scratchpad note",
                keywords: "note", body: n.text, date: n.date, symbol: "note.text", copyText: n.text
            ))
        }
        return docs
    }

    // MARK: Meetings

    static func meetings(_ records: [MeetingRecord]) -> [UniversalSearchDocument] {
        records.map { r in
            var parts: [String] = []
            var subtitle = "Meeting"
            if let notes = r.notes {
                parts.append(notes.summary)
                parts += notes.keyPoints
                parts += notes.decisions.map { "Decision: " + $0 }
                parts += (notes.myTasks + notes.othersTasks).map { t in
                    "Task (\(t.owner)): \(t.task)" + (t.due.map { " — due \($0)" } ?? "")
                }
                parts += notes.openQuestions.map { "Open question: " + $0 }
                parts += notes.nextSteps.map { "Next: " + $0 }
            } else {
                subtitle = r.endedAt == nil ? "Meeting · recording" : "Meeting · no notes yet"
            }
            if let user = r.userNotes, !user.isEmpty { parts.append(user) }
            parts += r.answers.map { "Q: \($0.question)\nA: \($0.answer)" }
            let transcript = r.segments.filter { !$0.text.isEmpty }.map { s in
                (s.speaker == .me ? "Me: " : "Them: ") + s.text
            }
            parts += transcript
            if let end = r.endedAt {
                let minutes = max(1, Int(end.timeIntervalSince(r.startedAt) / 60))
                subtitle += " · \(minutes) min"
            }
            let people = r.notes.map { Set(($0.myTasks + $0.othersTasks).map(\.owner)).sorted().joined(separator: " ") } ?? ""
            return UniversalSearchDocument(
                id: "meeting:\(r.id.uuidString)", source: .meetings, target: .meeting(r.id),
                title: r.title, subtitle: subtitle, keywords: "meeting " + people,
                body: parts.joined(separator: "\n"), date: r.startedAt,
                symbol: "person.2.wave.2.fill", copyText: nil
            )
        }
    }

    // MARK: Clipboard

    static func clipboard(_ items: [ClipboardItem], appNames: [String: String]) -> [UniversalSearchDocument] {
        items.map { item in
            var body: [String] = []
            if let text = item.text { body.append(String(text.prefix(40_000))) }
            // A link's page title is already its row title.
            if let title = item.title, title != item.displayTitle { body.append(title) }
            if let ocr = item.recognizedText { body.append(String(ocr.prefix(20_000))) }
            if let urls = item.fileURLs { body += urls.map(\.path) }
            let app = item.sourceBundleID.flatMap { appNames[$0] }
            let kindName: String = switch item.kind {
            case .text: "Text"
            case .richText: "Rich text"
            case .url: "Link"
            case .image: "Image"
            case .file: "File"
            }
            var subtitle = "Clipboard · " + kindName
            if let app { subtitle += " · " + app }
            if item.isPinned { subtitle += " · Pinned" }
            return UniversalSearchDocument(
                id: "clip:\(item.id.uuidString)", source: .clipboard, target: .clipboard(item.id),
                title: item.displayTitle, subtitle: subtitle,
                keywords: [app, item.linkHost, item.isPinned ? "pinned" : nil].compactMap { $0 }.joined(separator: " "),
                body: body.joined(separator: "\n"), date: item.copiedAt,
                symbol: symbol(for: item.kind), copyText: item.plainText
            )
        }
    }

    static func symbol(for kind: ClipboardItem.Kind) -> String {
        switch kind {
        case .text: "doc.plaintext"
        case .richText: "doc.richtext"
        case .url: "link"
        case .image: "photo"
        case .file: "doc"
        }
    }

    // MARK: Tray

    static func tray(_ items: [TrayItem]) -> [UniversalSearchDocument] {
        items.map { item in
            let (kindName, symbol): (String, String) = switch item.kind {
            case .file: ("File", "doc.fill")
            case .image: ("Image", "photo.fill")
            case .text: ("Text", "text.alignleft")
            }
            // The file name is the title; the body holds the folder it's in
            // (searchable, and the excerpt reads like Spotlight's path line).
            let folder = item.url.map { UniversalSearchText.abbreviatingHome($0.deletingLastPathComponent().path) }
            let body = [item.text, folder].compactMap { $0 }.joined(separator: "\n")
            return UniversalSearchDocument(
                id: "tray:\(item.id.uuidString)", source: .tray, target: .trayItem(item.id),
                title: item.kind == .text ? UniversalSearchText.firstLine(item.displayName) : item.displayName,
                subtitle: "Tray · " + kindName + (item.url.map { " · " + $0.deletingLastPathComponent().lastPathComponent } ?? ""),
                keywords: item.url?.pathExtension ?? "",
                body: body, date: item.addedAt, symbol: symbol,
                copyText: item.text ?? item.url?.path
            )
        }
    }

    // MARK: Spaces

    static func spaces(_ items: [SpaceItem], spaces: [Space]) -> [UniversalSearchDocument] {
        let byID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func path(_ id: UUID?) -> String {
            guard var current = id.flatMap({ byID[$0] }) else { return "Inbox" }
            var names = [current.name]
            var guardCount = 0
            while let parent = current.parentID.flatMap({ byID[$0] }), guardCount < 8 {
                names.insert(parent.name, at: 0)
                current = parent
                guardCount += 1
            }
            return names.joined(separator: " › ")
        }
        return items.map { item in
            let location = path(item.spaceID)
            let copy = item.url.map { item.title + "\n" + $0.absoluteString } ?? item.text
            return UniversalSearchDocument(
                id: "space:\(item.id.uuidString)", source: .spaces, target: .spaceItem(item.id),
                title: item.title, subtitle: location + " · " + kindName(item.kind),
                keywords: ([location] + item.tags + item.entities.prefix(12) + [item.url?.host ?? ""]).joined(separator: " "),
                body: item.text, date: item.createdAt, symbol: symbol(for: item.kind),
                copyText: copy
            )
        }
    }

    static func kindName(_ kind: SpaceItemKind) -> String {
        switch kind {
        case .meeting: "Meeting"
        case .note: "Note"
        case .dictation: "Dictation"
        case .screenshot: "Screenshot"
        case .file: "File"
        case .webPage: "Web page"
        case .email: "Email"
        case .clipboard: "Clipping"
        case .job: "Job"
        case .contact: "Contact"
        case .link: "Link"
        case .manual: "Note"
        }
    }

    static func symbol(for kind: SpaceItemKind) -> String {
        switch kind {
        case .meeting: "person.2.fill"
        case .note, .manual: "note.text"
        case .dictation: "waveform"
        case .screenshot: "camera.viewfinder"
        case .file: "doc.fill"
        case .webPage: "globe"
        case .email: "envelope.fill"
        case .clipboard: "doc.on.clipboard"
        case .job: "briefcase.fill"
        case .contact: "person.crop.circle"
        case .link: "link"
        }
    }
}
