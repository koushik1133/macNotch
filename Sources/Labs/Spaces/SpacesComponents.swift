import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Shared building blocks for the Spaces drawer tab and the Spaces window:
// palette, icons and labels for kinds and sources, chips, the agent status
// dot, a flow layout, prompts, and the drop handler that files dragged
// files, links and text into a Space. Everything is prefixed `Spaces` so it
// can't clash with the core and ingest agents' helpers.

// MARK: - Palette

/// Follows the app's look (computed, so a look switch takes effect).
/// Apple: the previous version's graphite window (sidebar a step lighter),
/// system-blue accent and selection. SparkV Red: near-black ground, one red.
enum SpacesPalette {
    static var background: Color { SparkVTheme.background }
    static var sidebar: Color {
        SparkVTheme.isApple ? Color(red: 0.137, green: 0.137, blue: 0.145) : Color(red: 13 / 255, green: 13 / 255, blue: 14 / 255)
    }
    static var inspector: Color {
        SparkVTheme.isApple ? Color(red: 0.125, green: 0.125, blue: 0.133) : Color(red: 12 / 255, green: 12 / 255, blue: 13 / 255)
    }
    static var card: Color { SparkVTheme.surface }
    static var cardHover: Color { SparkVTheme.surfaceHover }
    static var stroke: Color { SparkVTheme.stroke }
    /// A hovered card's outline: a soft white lift in Apple, a red hairline in SparkV Red.
    static var hoverStroke: Color { SparkVTheme.isApple ? Color.white.opacity(0.18) : SparkVTheme.red.opacity(0.5) }
    static var selection: Color { SparkVTheme.accentSoft }
    static var primaryText: Color { SparkVTheme.text }
    static var secondaryText: Color { SparkVTheme.textSecondary }
    static var tertiaryText: Color { SparkVTheme.textTertiary }
    static var accent: Color { SparkVTheme.accent }
    static let inbox = Color(red: 0.62, green: 0.64, blue: 0.70)
    static var success: Color { SparkVTheme.success }
    static var warning: Color { SparkVTheme.warning }

    /// Colors offered for new Spaces (hex, as stored in `Space.color`).
    static let spaceColors = [
        "#4F8EF7", "#8B5CF6", "#EC4899", "#F43F5E", "#F97316",
        "#EAB308", "#22C55E", "#14B8A6", "#06B6D4", "#94A3B8",
    ]

    /// SF Symbols offered as Space icons.
    static let spaceIcons = [
        "building.2.fill", "briefcase.fill", "folder.fill", "person.2.fill", "star.fill",
        "bolt.fill", "hammer.fill", "graduationcap.fill", "heart.fill", "leaf.fill",
        "cart.fill", "airplane", "house.fill", "chart.bar.fill", "lightbulb.fill",
        "paintbrush.fill", "music.note", "gamecontroller.fill", "globe", "flag.fill",
    ]

    static let personaIcons = [
        "person.crop.circle.fill", "briefcase.circle.fill", "house.circle.fill",
        "graduationcap.circle.fill", "star.circle.fill", "heart.circle.fill",
    ]
}

// MARK: - Helpers

@MainActor
enum SpacesUI {
    static func color(hex: String, fallback: Color = SpacesPalette.accent) -> Color {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        guard string.count == 6, let value = UInt32(string, radix: 16) else { return fallback }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func isSymbol(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    static func symbol(for kind: SpaceItemKind) -> String {
        switch kind {
        case .meeting: return "person.2.wave.2.fill"
        case .note: return "note.text"
        case .dictation: return "waveform"
        case .screenshot: return "camera.viewfinder"
        case .file: return "doc.fill"
        case .webPage: return "safari.fill"
        case .email: return "envelope.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .job: return "briefcase.fill"
        case .contact: return "person.crop.circle.fill"
        case .link: return "link"
        case .manual: return "square.and.pencil"
        }
    }

    static func label(for kind: SpaceItemKind) -> String {
        switch kind {
        case .meeting: return "Meeting"
        case .note: return "Note"
        case .dictation: return "Dictation"
        case .screenshot: return "Screenshot"
        case .file: return "File"
        case .webPage: return "Web Page"
        case .email: return "Email"
        case .clipboard: return "Clipboard"
        case .job: return "Job"
        case .contact: return "Contact"
        case .link: return "Link"
        case .manual: return "Manual"
        }
    }

    /// Apple: each kind keeps the previous version's color. SparkV Red tells
    /// kinds apart by glyph only: icons stay monochrome, red is for what's active.
    static func tint(for kind: SpaceItemKind) -> Color {
        guard SparkVTheme.usesTileTints else { return Color.white.opacity(0.78) }
        switch kind {
        case .meeting: return Color(red: 0.55, green: 0.45, blue: 1.0)
        case .note, .manual: return Color(red: 1.0, green: 0.80, blue: 0.30)
        case .dictation: return Color(red: 0.95, green: 0.45, blue: 0.65)
        case .screenshot: return Color(red: 0.30, green: 0.78, blue: 0.85)
        case .file: return Color(red: 0.55, green: 0.65, blue: 0.80)
        case .webPage, .link: return SpacesPalette.accent
        case .email: return Color(red: 0.35, green: 0.70, blue: 1.0)
        case .clipboard: return Color(red: 0.65, green: 0.70, blue: 0.75)
        case .job: return Color(red: 0.95, green: 0.60, blue: 0.30)
        case .contact: return SpacesPalette.success
        }
    }

    /// `SpaceItemSource` isn't `CaseIterable`, so the filter menu lists them here.
    static let allSources: [SpaceItemSource] = [
        .meetings, .flow, .tray, .screenshots, .files, .web, .mail, .clipboard, .jobs, .manual,
    ]

    static func label(for source: SpaceItemSource) -> String {
        switch source {
        case .meetings: return "Meetings"
        case .flow: return "Flow"
        case .tray: return "Tray"
        case .screenshots: return "Screenshots"
        case .files: return "Files"
        case .web: return "Web"
        case .mail: return "Mail"
        case .clipboard: return "Clipboard"
        case .jobs: return "Jobs"
        case .manual: return "Manual"
        }
    }

    static func symbol(for source: SpaceItemSource) -> String {
        switch source {
        case .meetings: return "person.2.wave.2"
        case .flow: return "waveform"
        case .tray: return "tray"
        case .screenshots: return "camera.viewfinder"
        case .files: return "doc"
        case .web: return "safari"
        case .mail: return "envelope"
        case .clipboard: return "doc.on.clipboard"
        case .jobs: return "briefcase"
        case .manual: return "hand.point.up.left"
        }
    }

    static let emptyRules = SpaceAgentRules(
        keywords: [], people: [], domains: [], apps: [], about: "", autoFileThreshold: 0.8
    )

    static func hasRules(_ rules: SpaceAgentRules) -> Bool {
        !rules.keywords.isEmpty || !rules.people.isEmpty || !rules.domains.isEmpty || !rules.apps.isEmpty
            || !rules.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func relativeDate(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Item counts per Space including nested folders, computed in one pass.
    static func recursiveCounts(spaces: [Space], items: [SpaceItem]) -> [UUID: Int] {
        var direct: [UUID: Int] = [:]
        for item in items { if let id = item.spaceID { direct[id, default: 0] += 1 } }
        var children: [UUID: [UUID]] = [:]
        for space in spaces { if let parent = space.parentID { children[parent, default: []].append(space.id) } }
        var memo: [UUID: Int] = [:]
        func total(_ id: UUID, depth: Int) -> Int {
            if let cached = memo[id] { return cached }
            guard depth < 64 else { return 0 }
            let sum = (direct[id] ?? 0) + (children[id] ?? []).reduce(0) { $0 + total($1, depth: depth + 1) }
            memo[id] = sum
            return sum
        }
        for space in spaces { _ = total(space.id, depth: 0) }
        return memo
    }

    /// "Acme › Projects › Launch" for a Space.
    static func path(of spaceID: UUID?, in spaces: [Space]) -> String {
        guard let spaceID else { return "Inbox" }
        var names: [String] = []
        var cursor: UUID? = spaceID
        var guardCount = 0
        while let id = cursor, let space = spaces.first(where: { $0.id == id }), guardCount < 32 {
            names.insert(space.name, at: 0)
            cursor = space.parentID
            guardCount += 1
        }
        return names.isEmpty ? "Inbox" : names.joined(separator: " › ")
    }

    /// True when `candidate` is `spaceID` or nested anywhere inside it.
    static func isDescendant(_ candidate: UUID, of spaceID: UUID, in spaces: [Space]) -> Bool {
        var cursor: UUID? = candidate
        var guardCount = 0
        while let id = cursor, guardCount < 64 {
            if id == spaceID { return true }
            cursor = spaces.first(where: { $0.id == id })?.parentID
            guardCount += 1
        }
        return false
    }

    /// The meeting a "sparkv://meeting/<id>" item URL points to (older items
    /// use the "notchisland" scheme). These open in Meeting Notes, not a browser.
    nonisolated static func meetingID(from url: URL?) -> UUID? {
        guard let url, let scheme = url.scheme?.lowercased(), ["sparkv", "notchisland"].contains(scheme),
              url.host?.lowercased() == "meeting" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }

    /// Host shown next to an item ("helm.events"); nil for app-internal links.
    static func displayHost(of url: URL?) -> String? {
        guard let url, meetingID(from: url) == nil, !url.isFileURL else { return nil }
        return url.host
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Asks for one line of text, as a sheet on `window` when there is one.
    static func prompt(
        title: String,
        message: String = "",
        defaultValue: String = "",
        confirm: String = "OK",
        window: NSWindow?
    ) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        field.placeholderString = title
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Shows a confirmation with up to three buttons; returns the index tapped.
    static func confirm(
        title: String,
        message: String,
        buttons: [String],
        destructiveIndex: Int? = 0,
        window: NSWindow?
    ) async -> Int? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        for button in buttons { alert.addButton(withTitle: button) }
        if let destructiveIndex, alert.buttons.indices.contains(destructiveIndex) {
            alert.buttons[destructiveIndex].hasDestructiveAction = true
        }
        let response: NSApplication.ModalResponse
        if let window {
            response = await alert.beginSheetModal(for: window)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            response = alert.runModal()
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return buttons.indices.contains(index) ? index : nil
    }

    /// Display name and icon for an app bundle identifier (Launch Services
    /// lookup only; no file access).
    static func appInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
}

// MARK: - Icons

/// A Space's icon (SF Symbol or emoji) on a tinted rounded square.
struct SpacesIconTile: View {
    let icon: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(color.opacity(0.22))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
            SpacesGlyph(icon: icon, size: size * 0.52)
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

/// SF Symbol when `icon` names one, otherwise the text itself (emoji).
struct SpacesGlyph: View {
    let icon: String
    let size: CGFloat

    var body: some View {
        if SpacesUI.isSymbol(icon) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
        } else {
            Text(icon.isEmpty ? "•" : String(icon.prefix(2)))
                .font(.system(size: size * 1.1))
        }
    }
}

struct SpacesPersonaAvatar: View {
    let persona: Persona?
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(SpacesPalette.accent.opacity(0.25))
            if let persona, SpacesUI.isSymbol(persona.icon) {
                Image(systemName: persona.icon)
                    .font(.system(size: size * 0.62, weight: .semibold))
                    .foregroundStyle(SpacesPalette.accent)
            } else if let persona, !persona.icon.isEmpty {
                Text(String(persona.icon.prefix(2))).font(.system(size: size * 0.6))
            } else {
                Text(String((persona?.name ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(SpacesPalette.accent)
            }
        }
        .frame(width: size, height: size)
    }
}

struct SpacesKindIcon: View {
    let kind: SpaceItemKind
    var size: CGFloat = 26

    var body: some View {
        let tint = SpacesUI.tint(for: kind)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(tint.opacity(0.16))
            Image(systemName: SpacesUI.symbol(for: kind))
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Agent status

enum SpacesAgentStatus {
    /// The store is indexing / routing right now.
    case working
    /// Suggestions are waiting for this Space.
    case needsReview
    /// The agent has rules to file by.
    case active
    /// No rules yet: the agent only learns from what's filed by hand.
    case idle

    @MainActor
    static func of(_ space: Space, store: SpaceStore) -> SpacesAgentStatus {
        if store.isIndexing { return .working }
        let pending = store.suggestions.contains { suggestion in
            if case .file(_, let spaceID, _, _) = suggestion.action { return spaceID == space.id }
            return false
        }
        if pending { return .needsReview }
        return SpacesUI.hasRules(space.rules) ? .active : .idle
    }

    var color: Color {
        switch self {
        case .working: return SpacesPalette.warning
        case .needsReview: return SpacesPalette.accent
        case .active: return SpacesPalette.success
        case .idle: return SparkVTheme.textTertiary.opacity(0.7)
        }
    }

    var help: String {
        switch self {
        case .working: return "Agent is filing new items"
        case .needsReview: return "Agent has suggestions for you to review"
        case .active: return "Agent is auto-filing with its rules"
        case .idle: return "Agent has no rules yet; add keywords, people or domains"
        }
    }
}

struct SpacesStatusDot: View {
    let status: SpacesAgentStatus
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .shadow(color: status == .idle ? .clear : status.color.opacity(0.6), radius: 2)
            .help(status.help)
    }
}

// MARK: - Chips

struct SpacesChip: View {
    let text: String
    var symbol: String?
    var tint: Color = SparkVTheme.textSecondary
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            }
            Text(text).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(SparkVPressStyle())
                .foregroundStyle(tint.opacity(0.7))
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 0.5))
    }
}

struct SpacesBadge: View {
    let count: Int
    var tint: Color = SpacesPalette.accent

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(Color.white)
            .padding(.horizontal, 4.5)
            .padding(.vertical, 1)
            .background(Capsule().fill(tint))
    }
}

struct SpacesConfidenceBadge: View {
    let confidence: Double?

    var body: some View {
        if let confidence {
            let tint = confidence >= 0.8 ? SpacesPalette.success : (confidence >= 0.5 ? SpacesPalette.warning : SpacesPalette.secondaryText)
            Text("\(Int((confidence * 100).rounded()))%")
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 0.75))
                .help("Filed by the agent, \(Int((confidence * 100).rounded()))% confident")
        }
    }
}

/// Section caption used across the window ("RULES", "MEMBERS"…).
struct SpacesSectionHeader: View {
    let title: String
    var trailing: AnyView?

    var body: some View {
        HStack {
            // SparkV Red: the sparkv.si eyebrow (red dash, mono caps).
            // Apple: a plain small-caps section title, as in Finder.
            if !SparkVTheme.isApple {
                Rectangle().fill(SparkVTheme.eyebrowDash).frame(width: 10, height: 1.5)
            }
            Text(title.uppercased())
                .font(SparkVTheme.eyebrow())
                .tracking(SparkVTheme.isApple ? 0.6 : 1.2)
                .foregroundStyle(SpacesPalette.tertiaryText)
            Spacer()
            if let trailing { trailing }
        }
    }
}

struct SpacesCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SpacesPalette.card))
            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SpacesPalette.stroke, lineWidth: 0.5))
    }
}

/// Small borderless icon button with a hover background.
struct SpacesIconButton: View {
    let systemImage: String
    let help: String
    var isActive = false
    var size: CGFloat = 24
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(isActive ? SpacesPalette.accent : SpacesPalette.secondaryText)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hover.isOn || isActive ? SpacesPalette.cardHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
    }
}

// MARK: - Flow layout

struct SpacesFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Dropping into a Space

/// Turns dragged files, images, links and text into Space items. A drop on a
/// Space files there (ingest, then move, so the agents still extract
/// entities); a drop on the Inbox (`spaceID == nil`) lets the agents route.
/// Drags of items/Spaces inside the Spaces window carry an internal marker
/// string and are handed to `internalHandler` instead.
@MainActor
enum SpacesDropIngestor {
    static let acceptedTypes: [UTType] = [.fileURL, .image, .url, .text]
    static let itemMarker = "notchspaces-item:"
    static let spaceMarker = "notchspaces-space:"

    enum Internal: Sendable {
        case item(UUID)
        case space(UUID)
    }

    static func dragProvider(itemID: UUID) -> NSItemProvider {
        NSItemProvider(object: (itemMarker + itemID.uuidString) as NSString)
    }

    static func dragProvider(spaceID: UUID) -> NSItemProvider {
        NSItemProvider(object: (spaceMarker + spaceID.uuidString) as NSString)
    }

    static func parseInternal(_ text: String) -> Internal? {
        if text.hasPrefix(itemMarker), let id = UUID(uuidString: String(text.dropFirst(itemMarker.count))) {
            return .item(id)
        }
        if text.hasPrefix(spaceMarker), let id = UUID(uuidString: String(text.dropFirst(spaceMarker.count))) {
            return .space(id)
        }
        return nil
    }

    /// Accepts the providers of one drop. Returns false when none of them
    /// carry anything usable.
    @discardableResult
    static func accept(
        _ providers: [NSItemProvider],
        into spaceID: UUID?,
        store: SpaceStore? = nil,
        internalHandler: (@MainActor (Internal) -> Void)? = nil,
        onFiled: (@MainActor (SpaceItem) -> Void)? = nil
    ) -> Bool {
        let store = store ?? SpaceStore.shared
        var handled = false
        for provider in providers {
            let types = provider.registeredTypeIdentifiers
            let hasFileURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            let imageType = types.first { UTType($0)?.conforms(to: .image) ?? false }
            if hasFileURL {
                handled = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                    let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    Task { @MainActor in
                        guard let url else {
                            AppLog.log("Spaces: dropped file URL unreadable (\(error?.localizedDescription ?? "no data"))")
                            return
                        }
                        ingestFile(url, into: spaceID, store: store, onFiled: onFiled)
                    }
                }
            } else if let imageType {
                handled = true
                let suggested = provider.suggestedName ?? "Screenshot"
                let fileExtension = UTType(imageType)?.preferredFilenameExtension ?? "png"
                // The provided file only exists during the callback, so it's
                // copied to a temporary folder before hopping to the main actor.
                _ = provider.loadFileRepresentation(forTypeIdentifier: imageType) { url, error in
                    let copy = url.flatMap { copyToTemporary($0, suggestedName: suggested, fileExtension: fileExtension) }
                    Task { @MainActor in
                        guard let copy else {
                            AppLog.log("Spaces: dropped image unreadable (\(error?.localizedDescription ?? "no data"))")
                            return
                        }
                        ingestImage(copy, title: suggested, into: spaceID, store: store, onFiled: onFiled)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        let item = addLink(url, into: spaceID, store: store)
                        onFiled?(item)
                    }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text else { return }
                    Task { @MainActor in
                        if let marker = parseInternal(text) {
                            internalHandler?(marker)
                            return
                        }
                        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                           let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
                            onFiled?(addLink(url, into: spaceID, store: store))
                        } else {
                            onFiled?(addText(text, into: spaceID, store: store))
                        }
                    }
                }
            } else {
                AppLog.log("Spaces: nothing usable in drop \(types)")
            }
        }
        return handled
    }

    /// Reads the file like the folder watcher does (text from PDFs, docs and
    /// mail, OCR for images) so dropped files are searchable and askable.
    private static func ingestFile(_ url: URL, into spaceID: UUID?, store: SpaceStore, onFiled: (@MainActor (SpaceItem) -> Void)?) {
        let fallbackHints = hints(for: spaceID)
        Task { @MainActor in
            var input = await SpaceConnectors.fileInput(url, source: .files) ?? SpaceIngestInput(
                kind: (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false) ? .screenshot : .file,
                source: .files,
                title: url.deletingPathExtension().lastPathComponent,
                text: "",
                url: url,
                attachment: url,
                sourceKey: "file:\(url.standardizedFileURL.path)",
                createdAt: Date(),
                hints: [:]
            )
            input.hints.merge(fallbackHints) { current, _ in current }
            file(input, into: spaceID, store: store, onFiled: onFiled)
        }
    }

    /// Dropped image data (e.g. a screenshot thumbnail): OCR'd like a
    /// screenshot; the temporary copy is removed once the store has its own.
    private static func ingestImage(_ url: URL, title: String, into spaceID: UUID?, store: SpaceStore, onFiled: (@MainActor (SpaceItem) -> Void)?) {
        let extraHints = hints(for: spaceID)
        Task { @MainActor in
            let input = await SpaceConnectors.imageInput(at: url, kind: .screenshot, source: .manual, createdAt: Date(), hints: extraHints)
                ?? SpaceIngestInput(
                    kind: .screenshot, source: .manual, title: title, text: "", url: nil, attachment: url,
                    sourceKey: "drop:\(UUID().uuidString)", createdAt: Date(), hints: extraHints
                )
            var dropped = input
            // The temporary copy isn't a place the user can go back to.
            dropped.url = nil
            if dropped.title == url.deletingPathExtension().lastPathComponent { dropped.title = title }
            file(dropped, into: spaceID, store: store, onFiled: onFiled) {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
    }

    private static func file(
        _ input: SpaceIngestInput, into spaceID: UUID?, store: SpaceStore,
        onFiled: (@MainActor (SpaceItem) -> Void)?, cleanup: (@MainActor () -> Void)? = nil
    ) {
        Task { @MainActor in
            let result = await store.ingest(input)
            cleanup?()
            guard var item = result else {
                AppLog.log("Spaces: ingest returned nothing for \(input.sourceKey)")
                return
            }
            if let spaceID, item.spaceID != spaceID {
                store.move(itemID: item.id, to: spaceID)
                item.spaceID = spaceID
            }
            onFiled?(item)
        }
    }

    private static func addLink(_ url: URL, into spaceID: UUID?, store: SpaceStore) -> SpaceItem {
        let host = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
        let path = url.path == "/" ? "" : url.path
        return store.addManual(title: host + path, text: url.absoluteString, url: url, spaceID: spaceID, kind: .link)
    }

    private static func addText(_ text: String, into spaceID: UUID?, store: SpaceStore) -> SpaceItem {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let title = String(firstLine.trimmingCharacters(in: .whitespaces).prefix(60))
        return store.addManual(title: title.isEmpty ? "Note" : title, text: text, url: nil, spaceID: spaceID, kind: .note)
    }

    private static func hints(for spaceID: UUID?) -> [String: String] {
        var hints = ["origin": "drop"]
        if let spaceID { hints["spaceID"] = spaceID.uuidString }
        return hints
    }

    private nonisolated static func copyToTemporary(_ url: URL, suggestedName: String, fileExtension: String) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SparkV-Spaces", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        var name = (suggestedName as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Image" }
        let destination = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
