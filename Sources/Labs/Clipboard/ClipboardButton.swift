import AppKit
import SwiftUI

// MARK: - Live activity band

/// "Copied" confirmation in the band under the notch (~368×30 pt, dark).
struct ClipboardActivityView: View {
    let symbol: String
    let title: String
    let detail: String
    let thumbnail: NSImage?
    var tint: Color = .green

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .frame(width: 20, height: 18)
                Image(systemName: tint == .green ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(displayTint)
                    .background(Circle().fill(Color.black).padding(-1))
                    .offset(x: 3, y: 2)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// Callers pass SwiftUI's .green / .orange; show the brand's status colors.
    private var displayTint: Color {
        if tint == .green { return SparkVTheme.success }
        if tint == .orange { return SparkVTheme.warning }
        return tint
    }
}

// MARK: - "C" capsule

/// Small capsule for the drawer header (or the Nook grid): a "C" badge and
/// a preview of the current clipboard item. Click pastes it into the
/// frontmost app (⌥-click only copies); click-and-hold or right-click opens
/// the recent-items menu.
struct ClipboardButton: View {
    @EnvironmentObject private var clipboard: ClipboardController
    var maxWidth: CGFloat = 116
    var height: CGFloat = 20

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = Capsule(style: .continuous)
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(badgeColor)
                Text("C")
                    .font(.system(size: height * 0.46, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black)
            }
            .frame(width: height - 6, height: height - 6)
            preview
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .frame(height: height)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(shape.fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
        .overlay(shape.strokeBorder(clipboard.flashedItemID != nil ? SparkVTheme.success.opacity(0.7) : SparkVTheme.stroke, lineWidth: 0.5))
        .contentShape(shape)
        .overlay(
            ClipboardPressArea(
                toolTip: toolTip,
                onClick: { option in clipboard.useCurrent(pasting: !option) },
                makeMenu: { ClipboardMenu.make(for: clipboard) },
                onHoverChange: { hover.isOn = $0 }
            )
        )
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clipboard: \(previewText)")
        .accessibilityHint("Click to paste, hold for history")
    }

    private var badgeColor: Color {
        if clipboard.flashedItemID != nil { return SparkVTheme.success }
        switch clipboard.status {
        case .running: return SparkVTheme.text
        case .paused, .off: return SparkVTheme.textTertiary
        case .needsPermission, .denied: return SparkVTheme.warning
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let symbol = stateSymbol {
            HStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
                Text(previewText).font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(SparkVTheme.textSecondary)
            .lineLimit(1)
        } else if let item = clipboard.current {
            switch item.kind {
            case .image:
                if let image = clipboard.thumbnails[item.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: height * 1.3, height: height - 6)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                } else {
                    Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(SparkVTheme.textSecondary)
                }
            case .file:
                HStack(spacing: 3) {
                    if let url = item.fileURLs?.first {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: height - 6, height: height - 6)
                    }
                    snippet(item.displayTitle)
                }
            case .url:
                HStack(spacing: 3) {
                    Image(systemName: "link").font(.system(size: 8, weight: .bold)).foregroundStyle(SparkVTheme.link)
                    snippet(item.linkHost ?? item.displayTitle)
                }
            case .text, .richText:
                snippet(item.displayTitle)
            }
        } else {
            snippet("Empty")
        }
    }

    private func snippet(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(SparkVTheme.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: maxWidth - height - 14, alignment: .leading)
    }

    /// A status glyph that replaces the preview, if any.
    /// A status glyph that replaces the preview, if any. The preview never
    /// shows an older item as current when the clipboard holds a newer copy
    /// the history didn't record.
    private var stateSymbol: String? {
        switch clipboard.status {
        case .off: return "power"
        case .needsPermission, .denied: return "exclamationmark.triangle.fill"
        case .paused: return clipboard.current == nil || clipboard.hasUnrecordedCopy ? "pause.fill" : nil
        case .running:
            if clipboard.hiddenReason != nil { return "lock.fill" }
            return clipboard.hasUnrecordedCopy ? "doc.on.clipboard" : nil
        }
    }

    private var previewText: String {
        switch clipboard.status {
        case .off: return "Off"
        case .needsPermission: return "Allow"
        case .denied: return "No access"
        case .paused where clipboard.current == nil || clipboard.hasUnrecordedCopy: return "Paused"
        default:
            if clipboard.hiddenReason != nil { return "Hidden" }
            if clipboard.hasUnrecordedCopy { return "Not saved" }
            return clipboard.current?.displayTitle ?? "Empty"
        }
    }

    private var toolTip: String {
        switch clipboard.status {
        case .off: return "Clipboard history is off · click to set it up, hold for options"
        case .needsPermission: return "Allow SparkV in Privacy & Security › Paste from Other Apps · click pastes the clipboard"
        case .denied: return "macOS denies SparkV clipboard access · click pastes the clipboard"
        default:
            if clipboard.hiddenReason != nil {
                return "The clipboard holds a password or private copy (not recorded) · click pastes it"
            }
            if clipboard.hasUnrecordedCopy { return "The latest copy wasn't saved to history · click pastes it" }
            return "Click to paste · ⌥-click to copy · hold or right-click for history"
        }
    }
}

// MARK: - Mouse handling

/// Transparent AppKit view that owns the mouse over the capsule: click,
/// click-and-hold (0.35 s) and right/control-click. AppKit, not SwiftUI
/// gestures, so it works in the non-activating notch panel.
final class ClipboardPressView: NSView {
    var onClick: ((_ option: Bool) -> Void)?
    var makeMenu: (() -> NSMenu?)?
    var onHoverChange: ((Bool) -> Void)?

    static let holdDelay: Duration = .milliseconds(350)

    private var holdTask: Task<Void, Never>?
    private var menuShownForPress = false
    private var hoverArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            holdTask?.cancel()
            onHoverChange?(false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        menuShownForPress = false
        if event.modifierFlags.contains(.control) {
            showMenu()
            menuShownForPress = true
            return
        }
        holdTask?.cancel()
        holdTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ClipboardPressView.holdDelay)
            guard !Task.isCancelled, let self else { return }
            self.menuShownForPress = true
            self.showMenu()
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTask?.cancel()
        holdTask = nil
        guard !menuShownForPress, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(event.modifierFlags.contains(.option))
    }

    override func rightMouseDown(with event: NSEvent) {
        holdTask?.cancel()
        showMenu()
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    private func showMenu() {
        guard let menu = makeMenu?() else { return }
        // Below the capsule, left-aligned (flipped coordinates).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }
}

struct ClipboardPressArea: NSViewRepresentable {
    var toolTip: String?
    var onClick: (Bool) -> Void
    var makeMenu: () -> NSMenu?
    var onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> ClipboardPressView {
        let view = ClipboardPressView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ClipboardPressView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ClipboardPressView) {
        view.onClick = onClick
        view.makeMenu = makeMenu
        view.onHoverChange = onHoverChange
        if view.toolTip != toolTip { view.toolTip = toolTip }
    }
}

// MARK: - Menu

/// Recent-items menu shared by the C button and the tab's header.
@MainActor
enum ClipboardMenu {
    static let recentCount = 12

    static func make(for clipboard: ClipboardController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        switch clipboard.status {
        case .off:
            menu.addItem(TrayMenuItem("Turn On Clipboard History", systemImage: "power") { clipboard.setEnabled(true) })
            let note = NSMenuItem(title: "Keeps your last 30 copies on this Mac; passwords are skipped", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            return menu
        case .needsPermission, .denied:
            let title = clipboard.status == .denied
                ? "macOS denies SparkV clipboard access"
                : "macOS asks before every clipboard read"
            let note = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(TrayMenuItem("Open Privacy & Security…", systemImage: "hand.raised") {
                clipboard.openPrivacySettings()
            })
            menu.addItem(.separator())
        case .running, .paused:
            break
        }

        // The latest copy's smart actions (Open, Call via FaceTime, Copy as RGB…).
        if let current = clipboard.current, clipboard.clipboardMatchesCurrent {
            let actions = clipboard.smartActions(for: current)
            if !actions.isEmpty {
                menu.addItem(header("Latest copy · \(clipboard.smartContent(for: current)?.label ?? "")"))
                actions.forEach { menu.addItem($0.menuItem(for: current, clipboard: clipboard)) }
                menu.addItem(.separator())
            }
        }

        let pinned = clipboard.pinned
        let recent = clipboard.items.filter { !$0.isPinned }.prefix(recentCount)
        // Numbers are stack positions (1 = newest), the same N as ⌘+N+V.
        let stack = clipboard.items
        func number(_ item: ClipboardItem) -> Int? {
            guard let index = stack.firstIndex(where: { $0.id == item.id }), index < 9 else { return nil }
            return index + 1
        }
        if !pinned.isEmpty {
            menu.addItem(header("Pinned"))
            for item in pinned { addEntry(item, to: menu, clipboard: clipboard, number: number(item)) }
            menu.addItem(.separator())
        }
        if recent.isEmpty, pinned.isEmpty {
            let empty = NSMenuItem(title: clipboard.isPaused ? "History is paused" : "Nothing copied yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else if !recent.isEmpty {
            menu.addItem(header("Recent  ·  ⌥ to paste"))
            // ⌘1…⌘9 pick the newest nine while the menu is open (⌥⌘ pastes).
            for item in recent {
                addEntry(item, to: menu, clipboard: clipboard, number: number(item))
            }
        }

        menu.addItem(.separator())
        if clipboard.isEnabled {
            let stackItem = TrayMenuItem("Open Clipboard Stack", systemImage: "square.stack.3d.up") {
                // After the menu has closed, so the panel can take key focus.
                Task { @MainActor in clipboard.showStackPanel() }
            }
            if clipboard.stackPanelShortcutEnabled {
                stackItem.keyEquivalent = "v"
                stackItem.keyEquivalentModifierMask = [.command, .shift]
            }
            stackItem.toolTip = "Pick from your copies at the text cursor: ↑↓ to choose, ↩ to paste, ⌘1–9, type to search"
            menu.addItem(stackItem)
            if clipboard.stackShortcutsNeedAccessibility {
                // Otherwise ⌘+Number+V and ⌘⇧V silently do nothing.
                let allow = TrayMenuItem("Allow Accessibility for ⌘+Number+V…", systemImage: "exclamationmark.triangle") {
                    clipboard.openAccessibilitySettings()
                }
                allow.toolTip = "The clipboard shortcuts need Accessibility. If SparkV is already listed, remove it and add it again (each rebuild needs a fresh grant). They start by themselves a few seconds later."
                menu.addItem(allow)
            }
        }
        if let open = clipboard.onOpenTab {
            menu.addItem(TrayMenuItem("Show All…", systemImage: "rectangle.stack") { open() })
        }
        menu.addItem(TrayMenuItem(clipboard.isPaused ? "Resume History" : "Pause History",
                                  systemImage: clipboard.isPaused ? "play.fill" : "pause.fill") {
            clipboard.setPaused(!clipboard.isPaused)
        })
        let ignore = TrayMenuItem("Ignore Next Copy", systemImage: "eye.slash") { clipboard.ignoreNextCopy() }
        ignore.state = clipboard.isIgnoringNextCopy ? .on : .off
        menu.addItem(ignore)
        menu.addItem(settingsItem(for: clipboard))
        menu.addItem(.separator())
        // Deferred so the alert opens after the menu has closed.
        let clear = TrayMenuItem("Clear History…", systemImage: "trash") {
            Task { @MainActor in clipboard.confirmAndClear() }
        }
        clear.isEnabled = !clipboard.items.filter { !$0.isPinned }.isEmpty
        menu.addItem(clear)
        let clearAll = TrayMenuItem("Clear History Including Pinned…", systemImage: "trash.fill") {
            Task { @MainActor in clipboard.confirmAndClear(includingPinned: true) }
        }
        clearAll.isEnabled = !clipboard.items.isEmpty
        clearAll.isAlternate = true
        clearAll.keyEquivalentModifierMask = .option
        menu.addItem(clearAll)
        return menu
    }

    private static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// One history entry: "copy", with an ⌥ alternate that pastes.
    private static func addEntry(_ item: ClipboardItem, to menu: NSMenu, clipboard: ClipboardController, number: Int?) {
        let title = menuTitle(for: item)
        let image = menuImage(for: item, clipboard: clipboard)
        let key = number.map(String.init) ?? ""
        let copy = TrayMenuItem(title) { clipboard.copy(item) }
        copy.keyEquivalent = key
        copy.keyEquivalentModifierMask = .command
        copy.image = image
        copy.toolTip = item.kind == .image ? item.displayTitle : String((item.plainText ?? "").prefix(400))
        menu.addItem(copy)
        let paste = TrayMenuItem("Paste “\(title)”") { clipboard.paste(item) }
        paste.image = image
        paste.isAlternate = true
        paste.keyEquivalent = key
        paste.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(paste)
    }

    private static func settingsItem(for clipboard: ClipboardController) -> NSMenuItem {
        let parent = NSMenuItem(title: "Clipboard Settings", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false
        let persist = TrayMenuItem("Keep History After Restart") { clipboard.setPersistsHistory(!clipboard.persistsHistory) }
        persist.state = clipboard.persistsHistory ? .on : .off
        sub.addItem(persist)
        let banner = TrayMenuItem("Show Banner for Every Copy") {
            clipboard.setShowsBannerForEveryCopy(!clipboard.showsBannerForEveryCopy)
        }
        banner.state = clipboard.showsBannerForEveryCopy ? .on : .off
        sub.addItem(banner)
        let universal = TrayMenuItem("Ignore Copies From Other Devices") {
            clipboard.setIgnoresUniversalClipboard(!clipboard.ignoresUniversalClipboard)
        }
        universal.state = clipboard.ignoresUniversalClipboard ? .on : .off
        sub.addItem(universal)

        sub.addItem(.separator())
        let chord = TrayMenuItem("⌘ + Number + V Pastes From History") {
            clipboard.setStackChordEnabled(!clipboard.stackChordEnabled)
        }
        chord.state = clipboard.stackChordEnabled ? .on : .off
        chord.toolTip = "Hold ⌘, press 1–9, then V to paste that copy (1 = newest). ⌘1–9 alone still works as usual. Needs Accessibility."
        sub.addItem(chord)
        let panelShortcut = TrayMenuItem("⌘⇧V Opens the Clipboard Stack") {
            clipboard.setStackPanelShortcutEnabled(!clipboard.stackPanelShortcutEnabled)
        }
        panelShortcut.state = clipboard.stackPanelShortcutEnabled ? .on : .off
        panelShortcut.toolTip = "Turn off to keep ⌘⇧V as “Paste and Match Style” in apps that use it."
        sub.addItem(panelShortcut)

        sub.addItem(.separator())
        let excludedHeader = NSMenuItem(title: "Also never recorded from:", action: nil, keyEquivalent: "")
        excludedHeader.isEnabled = false
        sub.addItem(excludedHeader)
        let extra = clipboard.userExcludedBundleIDs
        if extra.isEmpty {
            let none = NSMenuItem(title: "No apps (password managers are built in)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        for bundleID in extra {
            let entry = TrayMenuItem(clipboard.appName(for: bundleID) ?? bundleID) { clipboard.include(bundleID: bundleID) }
            entry.state = .on
            entry.toolTip = "Click to record copies from this app again"
            if let icon = clipboard.appIcon(for: bundleID) { entry.image = resized(icon, side: 16) }
            sub.addItem(entry)
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           front != Bundle.main.bundleIdentifier, !clipboard.excludedBundleIDs.contains(front) {
            let name = clipboard.appName(for: front) ?? front
            sub.addItem(TrayMenuItem("Exclude \(name)", systemImage: "plus") { clipboard.exclude(bundleID: front) })
        }
        sub.addItem(.separator())
        sub.addItem(TrayMenuItem("Turn Off Clipboard History", systemImage: "power") { clipboard.setEnabled(false) })
        parent.submenu = sub
        return parent
    }

    static func menuTitle(for item: ClipboardItem) -> String {
        let base: String
        switch item.kind {
        case .text, .richText:
            base = (item.text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        case .url: base = item.text ?? item.displayTitle
        case .image, .file: base = item.displayTitle
        }
        return base.count > 48 ? String(base.prefix(47)) + "…" : (base.isEmpty ? "Text" : base)
    }

    private static func menuImage(for item: ClipboardItem, clipboard: ClipboardController) -> NSImage? {
        switch item.kind {
        case .image:
            if let thumb = clipboard.thumbnails[item.id] { return resized(thumb, side: 18) }
        case .file:
            if let url = item.fileURLs?.first { return resized(NSWorkspace.shared.icon(forFile: url.path), side: 16) }
        case .text, .richText, .url:
            break
        }
        return NSImage(systemSymbolName: ClipboardController.symbol(for: item.kind), accessibilityDescription: nil)
    }

    static func resized(_ image: NSImage, side: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = side / max(size.width, size.height)
        let target = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        return TrayDragImage.render(size: target) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}

// MARK: - Drag images

@MainActor
enum ClipboardDragImage {
    static func make(for item: ClipboardItem, thumbnail: NSImage?, controller: ClipboardController) -> NSImage {
        let size = TrayStore.dragImageSize
        if item.kind == .file, let url = item.fileURLs?.first { return fileIcon(url) }
        return TrayDragImage.render(size: size) { rect in
            let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            if item.kind == .image, let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 {
                NSGraphicsContext.saveGraphicsState()
                card.addClip()
                let scale = max(rect.width / thumbnail.size.width, rect.height / thumbnail.size.height)
                let drawn = CGSize(width: thumbnail.size.width * scale, height: thumbnail.size.height * scale)
                thumbnail.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2,
                                          width: drawn.width, height: drawn.height),
                               from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                NSColor(white: 0.18, alpha: 0.95).setFill()
                card.fill()
                if item.kind == .image {
                    TrayDragImage.drawSymbol("photo", in: rect)
                } else {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 7),
                        .foregroundColor: NSColor(white: 1, alpha: 0.9),
                    ]
                    (String((item.plainText ?? "").prefix(200)) as NSString).draw(
                        with: rect.insetBy(dx: 4, dy: 4),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                        attributes: attributes
                    )
                }
            }
            NSColor(white: 1, alpha: 0.3).setStroke()
            card.lineWidth = 1
            card.stroke()
        }
    }

    static func fileIcon(_ url: URL) -> NSImage {
        let size = TrayStore.dragImageSize
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return TrayDragImage.render(size: size) { rect in
            let side = min(rect.width, rect.height) - 2
            icon.draw(in: NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}
