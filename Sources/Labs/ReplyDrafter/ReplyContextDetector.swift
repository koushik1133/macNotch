import CoreGraphics
import Foundation

// Pure, testable steps that turn the frontmost window into a conversation:
// 1. which app / web app it is (bundle id, page URL, window title),
// 2. where the message box and an email Subject field are,
// 3. the visible messages, who wrote them and which ones are the user's.
// The same line parser handles Accessibility text and OCR lines, so the
// screen-capture fallback produces the same structure.

enum ReplyContextDetector {
    /// Browsers whose page decides the kind (Gmail in Chrome, Slack in Safari…).
    static let browserBundlePrefixes = [
        "com.google.Chrome", "com.apple.Safari", "com.apple.SafariTechnologyPreview", "company.thebrowser.",
        "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.", "com.operasoftware.", "com.vivaldi.",
        "org.chromium.", "com.kagi.", "app.zen-browser.",
    ]

    /// Chromium and Electron apps only build their web Accessibility tree for
    /// assistive apps that set `AXManualAccessibility` (Electron docs,
    /// "Accessibility": third-party assistive technology on macOS).
    static let manualAccessibilityPrefixes = [
        "com.google.Chrome", "company.thebrowser.", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.",
        "com.vivaldi.", "org.chromium.", "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams",
        "desktop.WhatsApp", "com.linkedin.", "com.electron.", "com.todesktop.",
    ]

    static func isBrowser(_ bundleID: String) -> Bool {
        browserBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    static func needsManualAccessibility(_ bundleID: String) -> Bool {
        manualAccessibilityPrefixes.contains { bundleID.hasPrefix($0) }
    }

    static func detect(bundleID: String, windowTitle: String, url: String?) -> ReplyAppKind {
        switch bundleID {
        case "com.apple.mail": return .appleMail
        case "com.microsoft.Outlook": return .outlook
        case "com.tinyspeck.slackmacgap": return .slack
        case "net.whatsapp.WhatsApp", "desktop.WhatsApp", "WhatsApp": return .whatsapp
        case "com.apple.MobileSMS", "com.apple.iChat": return .messages
        case "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary": return .discord
        default: break
        }
        if bundleID.hasPrefix("com.microsoft.teams") { return .teams }
        if isBrowser(bundleID) {
            if let url, let kind = kind(forURL: url) { return kind }
            if let kind = kind(forTitle: windowTitle) { return kind }
            return .generic
        }
        // Wrapper apps (Fluid, Unite, Rambox…) still show the service's title.
        return kind(forTitle: windowTitle) ?? .generic
    }

    static func kind(forURL raw: String) -> ReplyAppKind? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)),
              let host = components.host?.lowercased() else { return nil }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "mail.google.com" || host == "inbox.google.com" { return .gmail }
        if on("outlook.live.com") || on("outlook.office.com") || on("outlook.office365.com")
            || on("outlook.cloud.microsoft") { return .outlook }
        if on("slack.com") { return .slack }
        if host == "web.whatsapp.com" { return .whatsapp }
        if on("teams.microsoft.com") || on("teams.live.com") || on("teams.cloud.microsoft") { return .teams }
        if on("linkedin.com") { return .linkedin }
        if on("discord.com") || on("discordapp.com") { return .discord }
        if host == "messages.google.com" { return .messages }
        return nil
    }

    static func kind(forTitle title: String) -> ReplyAppKind? {
        let t = title.lowercased()
        if t.hasSuffix("- gmail") || t.contains(" - gmail") || t.hasPrefix("gmail") { return .gmail }
        if t.contains("outlook") { return .outlook }
        if t.hasSuffix("slack") || t.contains(" - slack") || t.contains("| slack") { return .slack }
        if t.contains("whatsapp") { return .whatsapp }
        if t.contains("microsoft teams") { return .teams }
        if t.contains("linkedin") { return .linkedin }
        if t.contains("discord") { return .discord }
        return nil
    }

    /// "Re: Q3 budget - koushik@gmail.com - Gmail" → "Re: Q3 budget".
    static func cleanTitle(_ title: String, kind: ReplyAppKind) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [" - Gmail", " - Outlook", " | Outlook", " - Slack", " | Slack", " | Microsoft Teams",
                        " | LinkedIn", " - Discord", " | Discord", " - WhatsApp", " | WhatsApp"]
        for suffix in suffixes where text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        if kind == .gmail {
            // Drop the account part ("… - name@gmail.com").
            let parts = text.components(separatedBy: " - ")
            if parts.count >= 2, parts.last?.contains("@") == true { text = parts.dropLast().joined(separator: " - ") }
            if text.hasPrefix("Inbox") || text.hasPrefix("Sent") { return "" }
        }
        if kind == .slack {
            // "#design (Channel) - Acme" → "#design".
            if let paren = text.range(of: " (") { text = String(text[..<paren.lowerBound]) }
            if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        }
        if kind == .linkedin, text.hasPrefix("(") , let close = text.firstIndex(of: ")") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if ["messaging", "whatsapp", "slack", "discord", "messages", "mail"].contains(text.lowercased()) { return "" }
        return text
    }
}

// MARK: - Identity

/// Recognizes the user's own messages by name, first name, email or "me"/"You".
struct ReplyIdentity: Sendable, Equatable {
    var fullName: String
    var extraNames: [String] = []

    var firstName: String {
        fullName.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? fullName
    }

    func matches(_ author: String) -> Bool {
        let a = author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s*\(you\)$"#, with: "", options: .regularExpression)
        guard !a.isEmpty else { return false }
        if ["me", "you", "myself"].contains(a) { return true }
        let candidates = ([fullName, firstName] + extraNames)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        if candidates.contains(a) { return true }
        // "Koushik Goud Shaganti <k@x.com>" / "Koushik G."
        let name = a.replacingOccurrences(of: #"\s*<[^>]*>$"#, with: "", options: .regularExpression)
        if candidates.contains(name) { return true }
        if !fullName.isEmpty, name.hasPrefix(fullName.lowercased()) { return true }
        return false
    }
}

// MARK: - Conversation reader (Accessibility)

enum ReplyConversationReader {
    static let maxMessages = 14

    /// Reads the conversation and the fields to write into from a window snapshot.
    static func read(_ snapshot: ReplyWindowSnapshot, kind: ReplyAppKind, me: ReplyIdentity) -> ReplyConversation {
        var conversation = ReplyConversation(kind: kind)
        conversation.title = ReplyContextDetector.cleanTitle(snapshot.windowTitle, kind: kind)
        let compose = findCompose(in: snapshot.nodes, kind: kind, focusedIndex: snapshot.focusedIndex)
        conversation.composeIndex = compose
        if kind.isEmail, let subject = findSubject(in: snapshot.nodes, near: compose) {
            conversation.subjectIndex = subject
            conversation.subjectFieldValue = snapshot.nodes[subject].value
        }
        if kind.isEmail { conversation.recipients = recipients(in: snapshot.nodes, near: compose) }
        if let compose {
            let node = snapshot.nodes[compose]
            var notes = ReplyInsertionPlanner.userNotes(in: node.value, placeholder: node.placeholder)
            if kind.isEmail, let signature = trailingSignature(in: notes, me: me) {
                conversation.signature = signature
                let ns = notes as NSString
                notes = ns.substring(to: ns.range(of: signature, options: .backwards).location).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            conversation.existingDraft = notes
        }
        var lines = lines(from: snapshot, kind: kind, compose: compose)
        let pane = paneFrame(snapshot: snapshot, compose: compose, kind: kind)
        if let header = chatHeaderName(&lines, kind: kind, windowHeight: snapshot.windowFrame.height), conversation.title.isEmpty {
            conversation.title = header
        }
        conversation.messages = parse(lines: lines, kind: kind, me: me, pane: pane)
        // Apple Mail / Outlook reply windows show no thread, only the quoted
        // message inside the message box: that is the conversation.
        if kind.isEmail, conversation.messages.isEmpty, let compose {
            conversation.messages = quotedMessages(in: snapshot.nodes[compose].value, me: me)
        }
        if kind.isEmail {
            conversation.subject = lines.first { $0.role == .subject }?.text
                ?? (conversation.title.isEmpty ? nil : conversation.title)
            if let subject = conversation.subject, conversation.title.isEmpty { conversation.title = subject }
        }
        nameOneToOneChat(&conversation)
        conversation.participants = participants(conversation.messages)
        conversation.source = conversation.messages.isEmpty ? .none : .accessibility
        return conversation
    }

    // MARK: Fields

    private static let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    private static func fieldText(_ node: ReplyAXNode) -> String {
        [node.label, node.placeholder, node.title, node.identifier].joined(separator: " ").lowercased()
    }

    /// Fields that are never the message box.
    static func isExcludedField(_ node: ReplyAXNode) -> Bool {
        if node.subrole == "AXSearchField" || node.subrole == "AXSecureTextField" { return true }
        let text = fieldText(node)
        let patterns = [#"\bsearch\b"#, #"^\s*(to|cc|bcc)\b"#, #"\b(to|cc|bcc) recipients\b"#, #"\bsubject\b"#,
                        #"\bfind\b"#, #"\bjump to\b"#, #"\burl\b"#, #"address and search"#, #"\bfilter\b"#]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private static let composePatterns = [
        #"message body"#, #"type a message"#, #"type a new message"#, #"^message\b"#, #"message to "#,
        #"write a message"#, #"\bimessage\b"#, #"text message"#, #"\breply\b"#, #"send a message"#, #"compose"#,
        #"start a new conversation"#, #"\bmessage #"#, #"\bmessage @"#, #"^body$"#,
    ]

    static func findCompose(in nodes: [ReplyAXNode], kind: ReplyAppKind, focusedIndex: Int?) -> Int? {
        let editable = nodes.indices.filter { nodes[$0].isEditable && textRoles.contains(nodes[$0].role) && !isExcludedField(nodes[$0]) }
        if let focusedIndex, editable.contains(focusedIndex) { return focusedIndex }
        let labelled = editable.filter { index in
            let text = fieldText(nodes[index])
            return composePatterns.contains { text.range(of: $0, options: .regularExpression) != nil }
        }
        if let best = labelled.max(by: { nodes[$0].frame.minY < nodes[$1].frame.minY }) { return best }
        // Otherwise the lowest multi-line field (chat boxes sit at the bottom).
        let areas = editable.filter { nodes[$0].role == "AXTextArea" }
        return areas.max { nodes[$0].frame.minY < nodes[$1].frame.minY }
    }

    static func findSubject(in nodes: [ReplyAXNode], near compose: Int?) -> Int? {
        let candidates = nodes.indices.filter { index in
            let node = nodes[index]
            guard node.isEditable, node.role == "AXTextField" || node.role == "AXComboBox" else { return false }
            let text = fieldText(node)
            return text.range(of: #"(^|\s)subject|add a subject"#, options: .regularExpression) != nil
        }
        guard let compose else { return candidates.first }
        // The Subject of the same compose window: nearest one above the body.
        let body = nodes[compose].frame
        return candidates.min { lhs, rhs in
            distance(nodes[lhs].frame, body) < distance(nodes[rhs].frame, body)
        }
    }

    /// Addresses or names in the To field of the compose window.
    static func recipients(in nodes: [ReplyAXNode], near compose: Int?) -> [String] {
        let fields = nodes.indices.filter { index in
            let node = nodes[index]
            guard ["AXTextField", "AXComboBox", "AXTextArea"].contains(node.role) else { return false }
            return fieldText(node).range(of: #"^\s*to\b|\bto recipients\b|^\s*to:"#, options: .regularExpression) != nil
        }
        var chosen = fields.first
        if let compose {
            chosen = fields.min { distance(nodes[$0].frame, nodes[compose].frame) < distance(nodes[$1].frame, nodes[compose].frame) }
        }
        guard let index = chosen else { return [] }
        return nodes[index].value.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(5).map { String($0) }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.maxY - b.minY)
    }

    /// The user's own signature at the end of what is in the message box,
    /// when it has no "-- " marker: a last block of 1–6 short lines that
    /// starts with the user's name, or with a sign-off and then the name.
    static func trailingSignature(in notes: String, me: ReplyIdentity) -> String? {
        let blocks = notes.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = blocks.last else { return nil }
        let lines = last.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...6).contains(lines.count), lines.allSatisfy({ $0.count <= 60 }) else { return nil }
        if me.matches(lines[0]) { return last }
        let bare = lines[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!- "))
        if lines.count >= 2, ReplyToneLearner.signOffs.contains(bare), me.matches(lines[1]) { return last }
        return nil
    }

    /// The quoted message(s) inside a reply's message box, newest first in
    /// the field, returned oldest first. "On …, Sarah Lee <s@x.com> wrote:"
    /// and Outlook's "From: Sarah Lee / Sent: …" headers name the author.
    static func quotedMessages(in value: String, me: ReplyIdentity) -> [ReplyMessage] {
        guard let start = ReplyInsertionPlanner.quoteStart(in: value) else { return [] }
        let quoted = (value as NSString).substring(from: start)
        var messages: [ReplyMessage] = []
        var author: String?
        var time: String?
        var body: [String] = []
        var inHeader = false
        func flush() {
            let text = joinBody(body.filter { !isNoise($0) })
            if !text.isEmpty, messages.count < 4 {
                let name = author.map(cleanAuthor) ?? ""
                let fromMe = me.matches(name)
                messages.append(ReplyMessage(author: fromMe ? "Me" : (name.isEmpty ? "Them" : name), text: text, isFromMe: fromMe, time: time))
            }
            body = []
        }
        for raw in quoted.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            if let intro = quoteIntroAuthor(line) {
                flush()
                author = intro.author
                time = intro.time
                inHeader = false
                continue
            }
            if line.range(of: #"^-{2,}\s*(original message|forwarded message)"#, options: [.regularExpression, .caseInsensitive]) != nil
                || line.hasPrefix("Begin forwarded message") || line.range(of: #"^_{10,}$"#, options: .regularExpression) != nil {
                flush()
                author = nil
                time = nil
                inHeader = true
                continue
            }
            if let range = line.range(of: #"^From:\s*"#, options: [.regularExpression, .caseInsensitive]) {
                flush()
                author = String(line[range.upperBound...])
                time = nil
                inHeader = true
                continue
            }
            if inHeader {
                if line.isEmpty { inHeader = false; continue }
                if let range = line.range(of: #"^(Sent|Date):\s*"#, options: [.regularExpression, .caseInsensitive]) {
                    time = String(line[range.upperBound...])
                }
                continue // To:, Cc:, Subject:
            }
            if !line.isEmpty { body.append(line) }
        }
        flush()
        return Array(messages.reversed())
    }

    /// "On Oct 19, 2026, at 9:14 AM, Sarah Lee <s@x.com> wrote:" → (Sarah Lee, the date).
    static func quoteIntroAuthor(_ line: String) -> (author: String, time: String?)? {
        guard line.range(of: #"^On .{6,240}wrote:$"#, options: .regularExpression) != nil else { return nil }
        var inner = String(line.dropFirst(3).dropLast("wrote:".count)).trimmingCharacters(in: .whitespaces)
        inner = inner.replacingOccurrences(of: #"\s*<[^>]*>$"#, with: "", options: .regularExpression)
        // The name follows the time ("… 9:14 AM, Sarah Lee" / "… 11:02 AM Koushik …").
        let pattern = #"^(.*\d{1,2}[:.]\d{2}(?:\s?[AaPp]\.?[Mm]\.?)?)[,\s]+(.+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: inner, range: NSRange(inner.startIndex..., in: inner)),
           let date = Range(match.range(at: 1), in: inner), let name = Range(match.range(at: 2), in: inner) {
            return (String(inner[name]).trimmingCharacters(in: CharacterSet(charactersIn: " ,")), String(inner[date]))
        }
        // No time: "On Monday, Sarah Lee wrote:" → the part after the last comma.
        let parts = inner.components(separatedBy: ",")
        guard parts.count >= 2, let name = parts.last?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return (name, parts.dropLast().joined(separator: ","))
    }

    // MARK: Lines

    /// The column the conversation is in, window-relative: the message box's
    /// horizontal span (so sidebars and chat lists are ignored).
    static func paneFrame(snapshot: ReplyWindowSnapshot, compose: Int?, kind: ReplyAppKind) -> CGRect {
        let window = CGRect(origin: .zero, size: snapshot.windowFrame.size)
        guard let compose else {
            let fraction = sidebarFraction(kind)
            return CGRect(x: window.width * fraction, y: 0, width: window.width * (1 - fraction), height: window.height)
        }
        let field = snapshot.nodes[compose].frame.offsetBy(dx: -snapshot.windowFrame.minX, dy: -snapshot.windowFrame.minY)
        let minX = max(0, field.minX - 60)
        let maxX = min(window.width, field.maxX + 60)
        return CGRect(x: minX, y: 0, width: max(1, maxX - minX), height: window.height)
    }

    /// Share of the window's width taken by the app's sidebar / chat list.
    static func sidebarFraction(_ kind: ReplyAppKind) -> CGFloat {
        switch kind {
        case .whatsapp, .messages, .outlook, .teams: 0.32
        case .slack, .discord: 0.24
        case .gmail: 0.17
        case .linkedin: 0.3
        case .appleMail: 0.3
        case .generic: 0
        }
    }

    /// Readable lines of the conversation pane, top to bottom, window-relative.
    static func lines(from snapshot: ReplyWindowSnapshot, kind: ReplyAppKind, compose: Int?) -> [ReplyTextLine] {
        let nodes = snapshot.nodes
        let origin = snapshot.windowFrame.origin
        let pane = paneFrame(snapshot: snapshot, compose: compose, kind: kind)
        var composeTop: CGFloat?
        var scope: Set<Int>?
        if let compose {
            composeTop = nodes[compose].frame.minY - origin.y
            // A compose dialog (Gmail's pop-up) only shows its own fields.
            if let dialog = ancestor(of: compose, in: nodes, where: { $0.subrole == "AXApplicationDialog" || $0.subrole == "AXDialog" || $0.role == "AXSheet" }) {
                scope = subtree(of: dialog, in: nodes)
            }
        }
        var result: [ReplyTextLine] = []
        for (index, node) in nodes.enumerated() {
            if let scope, !scope.contains(index) { continue }
            if node.isEditable { continue }
            if let compose, isInside(index, compose, nodes) { continue }
            var text = node.readableText
            if node.role == "AXGroup", text.isEmpty, kind == .messages, !node.label.isEmpty { text = node.label }
            text = clean(text)
            guard !text.isEmpty else { continue }
            let roles = classify(index, nodes: nodes, kind: kind)
            // Buttons and links are only kept when they are an author or time.
            if (node.role == "AXButton" || node.role == "AXLink"), roles.role != .author, roles.role != .time { continue }
            if node.role == "AXHeading", roles.role != .subject, !kind.isEmail { continue }
            let frame = node.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            if frame.width > 0 {
                guard frame.maxX > pane.minX, frame.minX < pane.maxX else { continue }
                guard frame.maxY > 0, frame.minY < snapshot.windowFrame.height else { continue }
                if let composeTop, frame.minY >= composeTop - 1 { continue }
            }
            if isNoise(text) && roles.role != .author { continue }
            // Chromium repeats a heading's text in its static-text child.
            if let last = result.last, last.text == text, last.frame.intersects(frame) || frame == .zero { continue }
            var line = ReplyTextLine(text: text, frame: frame, role: roles.role, outgoing: roles.outgoing, group: roles.group)
            if node.role == "AXHeading", kind.isEmail, roles.role == .text { line.role = .subject }
            result.append(line)
        }
        return result
    }

    private struct LineRoles {
        var role: ReplyTextLine.Role = .text
        var outgoing: Bool?
        var group: Int?
    }

    /// Per-app class names of the web clients (stable, human-written class
    /// names of each service's DOM, read through AXDOMClassList).
    private static func classify(_ index: Int, nodes: [ReplyAXNode], kind: ReplyAppKind) -> LineRoles {
        var roles = LineRoles()
        let node = nodes[index]
        // "Your iMessage, …" (Messages), "You said …".
        let label = node.label.lowercased()
        if label.hasPrefix("your ") || label.hasPrefix("you:") || label.hasPrefix("you said") { roles.outgoing = true }
        var current: Int? = index
        var hops = 0
        while let i = current, hops < 14 {
            let n = nodes[i]
            switch kind {
            case .gmail:
                if n.hasClass("gD") { roles.role = .author }
                if n.hasClass("g3") { roles.role = .time }
                if n.hasClass("hP") { roles.role = .subject }
                if n.hasClass("gmail_quote") || n.hasClass("gmail_attr") || n.hasClass("im") { roles.role = .quoted }
                if n.hasClass("go") { roles.role = .quoted } // the sender's address next to the name
                if roles.group == nil, n.hasClass("adn") || n.hasClass("h7") { roles.group = i }
            case .slack:
                if n.hasClass(prefix: "c-message__sender") || n.hasClass(prefix: "c-message_kit__sender") { roles.role = .author }
                if n.hasClass(prefix: "c-timestamp") { roles.role = .time }
                if roles.group == nil, n.hasClass("c-message_kit__background") || n.hasClass("c-virtual_list__item") { roles.group = i }
            case .whatsapp:
                if n.hasClass("message-out") { roles.outgoing = roles.outgoing ?? true; roles.group = roles.group ?? i }
                if n.hasClass("message-in") { roles.outgoing = roles.outgoing ?? false; roles.group = roles.group ?? i }
                if n.hasClass(prefix: "quoted-mention") { roles.role = .quoted }
            case .linkedin:
                if n.hasClass(prefix: "msg-s-message-group__name") || n.hasClass(prefix: "msg-s-message-group__profile-link") { roles.role = .author }
                if n.hasClass(prefix: "msg-s-message-group__timestamp") { roles.role = .time }
                if roles.group == nil, n.hasClass(prefix: "msg-s-message-list__event") { roles.group = i }
            case .discord:
                if n.hasClass(prefix: "username") { roles.role = .author }
                if n.hasClass(prefix: "timestamp") { roles.role = .time }
                if n.hasClass(prefix: "repliedTextPreview") || n.hasClass(prefix: "repliedMessage") { roles.role = .quoted }
                if roles.group == nil, n.hasClass(prefix: "messageListItem") { roles.group = i }
            case .teams:
                if n.hasClass(prefix: "fui-ChatMessage__author") || n.hasClass(prefix: "fui-ChatMyMessage__author") { roles.role = .author }
                if n.hasClass(prefix: "fui-ChatMessage__timestamp") || n.hasClass(prefix: "fui-ChatMyMessage__timestamp") { roles.role = .time }
                if n.hasClass("fui-ChatMyMessage") { roles.outgoing = roles.outgoing ?? true; roles.group = roles.group ?? i }
                if n.hasClass("fui-ChatMessage") { roles.outgoing = roles.outgoing ?? false; roles.group = roles.group ?? i }
            case .outlook, .appleMail, .messages, .generic:
                break
            }
            if n.role == "AXWebArea" || n.role == "AXWindow" { break }
            current = n.parent
            hops += 1
        }
        return roles
    }

    /// Bubble apps show the chat's name above the messages: take it as the
    /// title instead of a message.
    static func chatHeaderName(_ lines: inout [ReplyTextLine], kind: ReplyAppKind, windowHeight: CGFloat) -> String? {
        guard kind.usesBubbles, let first = lines.first, first.group == nil, first.outgoing == nil,
              first.frame.minY < windowHeight * 0.15, looksLikeName(first.text) else { return nil }
        lines.removeFirst()
        return first.text
    }

    // MARK: Parsing

    /// Lines → messages, for every app family.
    static func parse(lines input: [ReplyTextLine], kind: ReplyAppKind, me: ReplyIdentity, pane: CGRect) -> [ReplyMessage] {
        let lines = input.filter { $0.role != .subject && $0.role != .quoted }
        var messages: [ReplyMessage]
        if lines.contains(where: { $0.group != nil }) {
            messages = parseGrouped(lines, me: me, kind: kind)
        } else if kind.usesBubbles {
            messages = parseBubbles(lines, me: me, pane: pane)
        } else if kind.isEmail {
            messages = parseEmail(lines, me: me)
        } else {
            messages = parseChat(lines, me: me)
        }
        messages = messages.compactMap { message in
            var m = message
            m.text = stripQuoted(m.text, isEmail: kind.isEmail)
            return m.text.isEmpty ? nil : m
        }
        return Array(messages.suffix(maxMessages))
    }

    private static func parseGrouped(_ lines: [ReplyTextLine], me: ReplyIdentity, kind: ReplyAppKind) -> [ReplyMessage] {
        var order: [Int] = []
        var buckets: [Int: [ReplyTextLine]] = [:]
        var pendingHeader: [ReplyTextLine] = []
        for line in lines {
            guard let group = line.group else {
                // Author/time just before a group belong to it.
                if line.role == .author || line.role == .time { pendingHeader.append(line) }
                continue
            }
            if buckets[group] == nil {
                order.append(group)
                buckets[group] = pendingHeader
            }
            pendingHeader = []
            buckets[group, default: []].append(line)
        }
        var messages: [ReplyMessage] = []
        var lastAuthor = ""
        var lastFromMe = false
        for group in order {
            let groupLines = buckets[group] ?? []
            var author = groupLines.first { $0.role == .author }?.text ?? ""
            let time = groupLines.first { $0.role == .time }?.text ?? groupLines.lazy.compactMap { timeOnly($0.text) }.first
            let outgoing = groupLines.lazy.compactMap(\.outgoing).first
            var bodyLines = groupLines.filter { $0.role == .text || $0.role == .body }
                .map(\.text)
                .filter { timeOnly($0) == nil }
            bodyLines = bodyLines.map { stripTrailingTime($0) }.filter { !$0.isEmpty && !isNoise($0) }
            // Slack/Gmail repeat the author at the start of the body text.
            if !author.isEmpty, bodyLines.first == author { bodyLines.removeFirst() }
            let text = joinBody(bodyLines)
            guard !text.isEmpty else { continue }
            let fromMe: Bool
            if let outgoing {
                fromMe = outgoing
                if author.isEmpty { author = outgoing ? "Me" : (lastFromMe ? "" : lastAuthor) }
            } else if author.isEmpty {
                author = lastAuthor
                fromMe = lastFromMe
            } else {
                fromMe = me.matches(author)
            }
            lastAuthor = author
            lastFromMe = fromMe
            messages.append(ReplyMessage(author: fromMe ? "Me" : (author.isEmpty ? "Them" : cleanAuthor(author)), text: text, isFromMe: fromMe, time: time))
        }
        return merged(messages)
    }

    /// Slack / Teams / Discord / LinkedIn without class hints: "Name  10:42 AM" headers.
    private static func parseChat(_ lines: [ReplyTextLine], me: ReplyIdentity) -> [ReplyMessage] {
        var messages: [ReplyMessage] = []
        var author = ""
        var time: String?
        var body: [String] = []
        func flush() {
            let text = joinBody(body)
            if !text.isEmpty {
                let fromMe = me.matches(author)
                messages.append(ReplyMessage(author: fromMe ? "Me" : (author.isEmpty ? "Them" : cleanAuthor(author)), text: text, isFromMe: fromMe, time: time))
            }
            body = []
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let header = chatHeader(line.text) {
                flush()
                author = header.author
                time = header.time
            } else if line.role == .author || (looksLikeName(line.text) && index + 1 < lines.count && timeOnly(lines[index + 1].text) != nil) {
                flush()
                author = line.text
                if line.role != .author, index + 1 < lines.count {
                    time = timeOnly(lines[index + 1].text)
                    index += 1
                }
            } else if timeOnly(line.text) != nil || line.role == .time {
                // A bare time between messages of the same author.
            } else if !isNoise(line.text) {
                body.append(line.text)
            }
            index += 1
        }
        flush()
        return merged(messages)
    }

    /// Email threads: "Name <email>" / "From: Name" headers, dates, bodies.
    private static func parseEmail(_ lines: [ReplyTextLine], me: ReplyIdentity) -> [ReplyMessage] {
        var messages: [ReplyMessage] = []
        var author = ""
        var time: String?
        var body: [String] = []
        var inQuote = false
        func flush() {
            let text = joinBody(body)
            if !text.isEmpty {
                let fromMe = me.matches(author)
                messages.append(ReplyMessage(author: fromMe ? "Me" : (author.isEmpty ? "Them" : cleanAuthor(author)), text: text, isFromMe: fromMe, time: time))
            }
            body = []
            inQuote = false
        }
        for line in lines {
            let text = line.text
            if isQuoteIntro(text) { inQuote = true; continue }
            if line.role == .author || emailHeaderAuthor(text) != nil {
                flush()
                author = line.role == .author ? text : (emailHeaderAuthor(text) ?? text)
                time = nil
                continue
            }
            if line.role == .time || emailDate(text) {
                if time == nil { time = text }
                continue
            }
            let lower = text.lowercased()
            if lower == "to me" || lower.hasPrefix("to me,") || lower.hasPrefix("to: ") || lower.hasPrefix("cc: ") || lower == "to" { continue }
            if inQuote || text.hasPrefix(">") { continue }
            if !isNoise(text) { body.append(text) }
        }
        flush()
        return messages
    }

    /// WhatsApp / Messages: bubbles on the right are the user's.
    private static func parseBubbles(_ lines: [ReplyTextLine], me: ReplyIdentity, pane: CGRect) -> [ReplyMessage] {
        struct Bubble { var outgoing: Bool; var lines: [String]; var time: String?; var bottom: CGFloat; var author: String? }
        var bubbles: [Bubble] = []
        for line in lines {
            if isDateSeparator(line.text) { continue }
            let outgoing = line.outgoing ?? isRightAligned(line.frame, pane: pane)
            if let time = timeOnly(line.text) {
                if var last = bubbles.last, last.time == nil {
                    last.time = time
                    bubbles[bubbles.count - 1] = last
                }
                continue
            }
            let (text, trailingTime) = splitTrailingTime(line.text)
            guard !text.isEmpty, !isNoise(text) else { continue }
            let height = max(line.frame.height, 12)
            if var last = bubbles.last, last.outgoing == outgoing, last.time == nil,
               line.frame.minY - last.bottom < height * 0.9 || line.frame == .zero {
                last.lines.append(text)
                last.bottom = max(last.bottom, line.frame.maxY)
                last.time = trailingTime
                bubbles[bubbles.count - 1] = last
            } else {
                bubbles.append(Bubble(outgoing: outgoing, lines: [text], time: trailingTime, bottom: line.frame.maxY, author: nil))
            }
        }
        return merged(bubbles.compactMap { bubble in
            var lines = bubble.lines
            var author = bubble.outgoing ? "Me" : "Them"
            // Group chats print the sender's name on the first line of a bubble.
            if !bubble.outgoing, lines.count >= 2, let first = lines.first, looksLikeName(first.replacingOccurrences(of: "~", with: "")) {
                author = cleanAuthor(first.replacingOccurrences(of: "~", with: ""))
                lines.removeFirst()
            }
            let text = joinBody(lines)
            guard !text.isEmpty else { return nil }
            if !bubble.outgoing, me.matches(author) { return ReplyMessage(author: "Me", text: text, isFromMe: true, time: bubble.time) }
            return ReplyMessage(author: author, text: text, isFromMe: bubble.outgoing, time: bubble.time)
        })
    }

    static func isRightAligned(_ frame: CGRect, pane: CGRect) -> Bool {
        guard frame.width > 0, pane.width > 0 else { return false }
        let leftGap = frame.minX - pane.minX
        let rightGap = pane.maxX - frame.maxX
        return leftGap > rightGap + pane.width * 0.08 && leftGap > pane.width * 0.25
    }

    /// Consecutive messages of the same author become one.
    private static func merged(_ messages: [ReplyMessage]) -> [ReplyMessage] {
        var result: [ReplyMessage] = []
        for message in messages {
            if var last = result.last, last.author == message.author, last.isFromMe == message.isFromMe {
                last.text += "\n" + message.text
                last.time = message.time ?? last.time
                result[result.count - 1] = last
            } else {
                result.append(message)
            }
        }
        return result
    }

    /// In a one-to-one bubble chat the other person is the chat's title.
    static func nameOneToOneChat(_ conversation: inout ReplyConversation) {
        guard conversation.kind.usesBubbles, !conversation.title.isEmpty, looksLikeName(conversation.title),
              !conversation.messages.contains(where: { !$0.isFromMe && $0.author != "Them" }) else { return }
        for index in conversation.messages.indices where !conversation.messages[index].isFromMe {
            conversation.messages[index].author = conversation.title
        }
    }

    private static func participants(_ messages: [ReplyMessage]) -> [String] {
        var seen: [String] = []
        for message in messages where !message.isFromMe && message.author != "Them" && !seen.contains(message.author) {
            seen.append(message.author)
        }
        return seen
    }

    // MARK: Text helpers

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lines of one message; a line starting in lowercase continues the
    /// previous one (a soft wrap in a bubble or an OCR line break).
    static func joinBody(_ lines: [String]) -> String {
        var result = ""
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if result.isEmpty {
                result = line
            } else if let first = line.first, first.isLowercase, let last = result.last, !".!?:".contains(last) {
                result += " " + line
            } else {
                result += "\n" + line
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanAuthor(_ author: String) -> String {
        var a = author.trimmingCharacters(in: .whitespacesAndNewlines)
        a = a.replacingOccurrences(of: #"\s*<[^>]*>$"#, with: "", options: .regularExpression)
        a = a.replacingOccurrences(of: #"^From:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        return a.trimmingCharacters(in: CharacterSet(charactersIn: " :~"))
    }

    private static let timePattern = #"\d{1,2}[:.]\d{2}(\s?[AaPp]\.?[Mm]\.?)?"#

    /// "10:42 AM" / "Yesterday at 9:14 PM" / "Today 10:42" → the time, else nil.
    static func timeOnly(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let pattern = #"^((today|yesterday|mon|tue|wed|thu|fri|sat|sun)[a-z]*,?\s*(at\s*)?)?"# + timePattern + #"(\s*[✓✔︎]+)?$"#
        guard t.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return t.replacingOccurrences(of: #"\s*[✓✔︎]+$"#, with: "", options: .regularExpression)
    }

    /// "Thanks! 10:42 ✓✓" → ("Thanks!", "10:42").
    static func splitTrailingTime(_ text: String) -> (String, String?) {
        let pattern = #"\s+("# + timePattern + #")(\s*[✓✔︎]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text), let time = Range(match.range(at: 1), in: text) else { return (text, nil) }
        let body = String(text[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces)
        return (body, String(text[time]))
    }

    private static func stripTrailingTime(_ text: String) -> String {
        let (body, time) = splitTrailingTime(text)
        return time == nil ? text : body
    }

    /// "Alice Chen  10:42 AM" → (Alice Chen, 10:42 AM).
    static func chatHeader(_ text: String) -> (author: String, time: String)? {
        let pattern = #"^([\p{L}][\p{L}\p{M}.'’\- ]{1,40}?)\s{1,4}(?:\(you\)\s*)?("# + timePattern + #")$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text), let t = Range(match.range(at: 2), in: text) else { return nil }
        let author = String(text[a]).trimmingCharacters(in: .whitespaces)
        guard looksLikeName(author) else { return nil }
        return (author, String(text[t]))
    }

    /// One to four capitalized words, or a phone number (WhatsApp group senders).
    static func looksLikeName(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard (2...40).contains(t.count) else { return false }
        if t.range(of: #"^\+?[\d\s()\-]{7,}$"#, options: .regularExpression) != nil { return true }
        if t.last.map({ ".?!,:;".contains($0) }) == true { return false }
        let words = t.split(separator: " ")
        guard (1...4).contains(words.count) else { return false }
        return words.allSatisfy { word in
            guard let first = word.first else { return false }
            return first.isUppercase || first.isNumber == false && word.count <= 3 && word.lowercased() == word && ["de", "van", "von", "da", "bin", "al"].contains(String(word))
        }
    }

    /// "Sarah Lee <sarah@acme.com>" / "From: Sarah Lee" → "Sarah Lee".
    static func emailHeaderAuthor(_ text: String) -> String? {
        if text.hasSuffix("wrote:") || isQuoteIntro(text) { return nil }
        if let range = text.range(of: #"^From:\s*(.+)$"#, options: [.regularExpression, .caseInsensitive]) {
            return cleanAuthor(String(text[range]))
        }
        let pattern = #"^([^<>@]{2,60}?)\s*<[^<>\s]+@[^<>\s]+>(\s.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let a = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[a]).trimmingCharacters(in: .whitespaces)
    }

    /// "Oct 19, 2026, 9:14 AM (1 day ago)", "Mon, Oct 19, 9:14 AM", "19 October 2026 at 09:14".
    static func emailDate(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count <= 60 else { return false }
        let month = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"#
        let a = #"^([a-z]{3,9},?\s+)?"# + month + #"\s+\d{1,2}(,\s*\d{4})?,?\s*(at\s*)?"# + timePattern
        let b = #"^([a-z]{3,9},?\s+)?\d{1,2}\s+"# + month + #"(\s+\d{4})?,?\s*(at\s*)?"# + timePattern
        let c = #"^\d{1,2}/\d{1,2}/\d{2,4},?\s*"# + timePattern
        // "9:40 AM (15 minutes ago)"
        let d = "^" + timePattern + #"\s*\(.+\)$"#
        return [a, b, c, d].contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    static func isQuoteIntro(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^On .{6,120} wrote:$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^-{2,}\s*(Original Message|Forwarded message)\s*-{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        return false
    }

    /// Drops quoted history from a message body.
    static func stripQuoted(_ text: String, isEmail: Bool) -> String {
        guard isEmail else { return text }
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            if isQuoteIntro(line) { break }
            if line.hasPrefix(">") { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDateSeparator(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if ["today", "yesterday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"].contains(t) { return true }
        if t.range(of: #"^\d{1,2}/\d{1,2}/\d{2,4}$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^(today|yesterday)\s"#, options: .regularExpression) != nil, timeOnly(t) == nil { return true }
        return t.hasPrefix("messages and calls are end-to-end encrypted") || t.hasPrefix("imessage")
    }

    private static let noiseLines: Set<String> = [
        "reply", "reply all", "forward", "show quoted text", "show trimmed content", "to me", "edited", "(edited)",
        "seen", "delivered", "read", "sent", "type a message", "message", "more", "react", "add reaction",
        "reply in thread", "share", "new", "new messages", "unread", "jump to present", "load more", "...",
        "…", "print all", "in new window", "summarize this email", "translate message", "view thread",
        "new message", "minimize", "pop-out", "full screen", "save & close", "discard draft", "draft saved",
    ]

    static func isNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty || noiseLines.contains(t) { return true }
        // A bare address ("<sarah@acme.com>") next to a sender name.
        if t.range(of: #"^<?[^\s@<>]+@[^\s@<>]+>?$"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^\d+\s+(replies|reply|new messages?|unread)"#, options: .regularExpression) != nil { return true }
        if t.range(of: #"^(read|delivered|seen)\s"#, options: .regularExpression) != nil, t.count < 30 { return true }
        if t.range(of: #"^[\p{So}\p{Sk}\s\d]{1,6}$"#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: Tree helpers

    static func ancestor(of index: Int, in nodes: [ReplyAXNode], where predicate: (ReplyAXNode) -> Bool) -> Int? {
        var current = nodes[index].parent
        var hops = 0
        while let i = current, hops < 40 {
            if predicate(nodes[i]) { return i }
            current = nodes[i].parent
            hops += 1
        }
        return nil
    }

    static func subtree(of root: Int, in nodes: [ReplyAXNode]) -> Set<Int> {
        var result: Set<Int> = [root]
        for index in nodes.indices where index > root {
            if let parent = nodes[index].parent, result.contains(parent) { result.insert(index) }
        }
        return result
    }

    private static func isInside(_ index: Int, _ container: Int, _ nodes: [ReplyAXNode]) -> Bool {
        var current: Int? = index
        var hops = 0
        while let i = current, hops < 40 {
            if i == container { return true }
            current = nodes[i].parent
            hops += 1
        }
        return false
    }
}

// MARK: - OCR

/// The screen-capture fallback: Vision OCR lines of the window → lines →
/// the same parser.
enum ReplyOCRReader {
    /// One OCR observation in image pixels, top-left origin.
    struct Observation: Sendable, Equatable {
        var text: String
        var rect: CGRect
    }

    /// `scale` = image pixels per window point.
    static func lines(from observations: [Observation], scale: CGFloat, windowSize: CGSize, kind: ReplyAppKind, composeFrame: CGRect?) -> [ReplyTextLine] {
        let s = max(scale, 0.01)
        var lines = observations.map { observation in
            ReplyTextLine(
                text: ReplyConversationReader.clean(observation.text),
                frame: CGRect(x: observation.rect.minX / s, y: observation.rect.minY / s,
                              width: observation.rect.width / s, height: observation.rect.height / s)
            )
        }
        let pane = pane(windowSize: windowSize, kind: kind, composeFrame: composeFrame)
        let toolbar = windowSize.height * (kind.isEmail ? 0.06 : 0.07)
        let composeTop = composeFrame?.minY ?? bottomBarTop(lines, windowSize: windowSize)
        lines = lines.filter { line in
            guard !line.text.isEmpty else { return false }
            guard line.frame.midX > pane.minX, line.frame.midX < pane.maxX else { return false }
            guard line.frame.minY > toolbar, line.frame.maxY < composeTop else { return false }
            return !ReplyConversationReader.isNoise(line.text)
        }
        lines.sort { abs($0.frame.minY - $1.frame.minY) < 4 ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }
        return mergeRows(lines, bubbles: kind.usesBubbles)
    }

    static func pane(windowSize: CGSize, kind: ReplyAppKind, composeFrame: CGRect?) -> CGRect {
        if let composeFrame, composeFrame.width > 40 {
            let minX = max(0, composeFrame.minX - 60)
            let maxX = min(windowSize.width, composeFrame.maxX + 60)
            return CGRect(x: minX, y: 0, width: maxX - minX, height: windowSize.height)
        }
        let fraction = ReplyConversationReader.sidebarFraction(kind)
        return CGRect(x: windowSize.width * fraction, y: 0, width: windowSize.width * (1 - fraction), height: windowSize.height)
    }

    /// Without Accessibility the message box is found by its placeholder.
    private static func bottomBarTop(_ lines: [ReplyTextLine], windowSize: CGSize) -> CGFloat {
        let placeholders = [#"^type a message"#, #"^message\s"#, #"^imessage"#, #"^text message"#, #"^write a message"#,
                            #"^reply"#, #"^type a new message"#, #"^send a message"#]
        let hits = lines.filter { line in
            line.frame.minY > windowSize.height * 0.6 &&
                placeholders.contains { line.text.lowercased().range(of: $0, options: .regularExpression) != nil }
        }
        return hits.map(\.frame.minY).min().map { $0 - 2 } ?? windowSize.height
    }

    /// Fragments on the same row (OCR splits "Alice Chen" and "10:42 AM").
    static func mergeRows(_ lines: [ReplyTextLine], bubbles: Bool) -> [ReplyTextLine] {
        var result: [ReplyTextLine] = []
        for line in lines {
            if var last = result.last {
                let height = min(last.frame.height, line.frame.height)
                let sameRow = abs(last.frame.midY - line.frame.midY) < max(4, height * 0.5)
                let gap = line.frame.minX - last.frame.maxX
                if sameRow, gap > -2, gap < (bubbles ? 40 : 120) {
                    last.text += gap > 12 ? "  " + line.text : " " + line.text
                    last.frame = last.frame.union(line.frame)
                    result[result.count - 1] = last
                    continue
                }
            }
            result.append(line)
        }
        return result
    }

    static func read(observations: [Observation], scale: CGFloat, windowSize: CGSize, kind: ReplyAppKind, composeFrame: CGRect?, me: ReplyIdentity, title: String) -> ReplyConversation {
        var conversation = ReplyConversation(kind: kind)
        conversation.title = ReplyContextDetector.cleanTitle(title, kind: kind)
        let lines = lines(from: observations, scale: scale, windowSize: windowSize, kind: kind, composeFrame: composeFrame)
        let pane = pane(windowSize: windowSize, kind: kind, composeFrame: composeFrame)
        var bodyLines = lines
        if let header = ReplyConversationReader.chatHeaderName(&bodyLines, kind: kind, windowHeight: windowSize.height), conversation.title.isEmpty {
            conversation.title = header
        }
        if kind.isEmail, let first = lines.first, ReplyConversationReader.emailHeaderAuthor(first.text) == nil, !ReplyConversationReader.emailDate(first.text) {
            // The first line of a mail view is its subject.
            conversation.subject = first.text
            if conversation.title.isEmpty { conversation.title = first.text }
            bodyLines.removeFirst()
        }
        conversation.messages = ReplyConversationReader.parse(lines: bodyLines, kind: kind, me: me, pane: pane)
        ReplyConversationReader.nameOneToOneChat(&conversation)
        var seen: [String] = []
        for m in conversation.messages where !m.isFromMe && m.author != "Them" && !seen.contains(m.author) { seen.append(m.author) }
        conversation.participants = seen
        conversation.source = conversation.messages.isEmpty ? .none : .screen
        return conversation
    }
}
