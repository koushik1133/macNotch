import AppKit
import Combine
import SwiftUI

// The clipboard stack (⌘⇧V): a floating, non-activating panel at the text
// caret (or the pointer) listing the history newest first with number
// badges 1–9, like Paste's stack and Maccy's popup. It takes keystrokes
// without activating SparkV, so the app you were typing in stays frontmost
// and ↩ pastes straight back into it.

enum ClipboardStackMetrics {
    static let listWidth: CGFloat = 384
    static let previewWidth: CGFloat = 316
    static let headerHeight: CGFloat = 38
    static let footerHeight: CGFloat = 30
    static let rowHeight: CGFloat = 46
    static let maxVisibleRows = 8
    static let emptyHeight: CGFloat = 96
    static let corner: CGFloat = 16
    /// Transparent margin around the card for its shadow.
    static let margin: CGFloat = 20

    static func listHeight(rows: Int) -> CGFloat {
        rows == 0 ? emptyHeight : CGFloat(min(rows, maxVisibleRows)) * rowHeight + 8
    }

    /// The card's size for `rows` items; the preview adds a column.
    static func cardSize(rows: Int, previewing: Bool) -> CGSize {
        let width = listWidth + (previewing ? previewWidth : 0)
        // The preview needs some height even for one item.
        let list = max(listHeight(rows: rows), previewing ? 200 : 0)
        return CGSize(width: width, height: headerHeight + list + footerHeight + 2)
    }
}

final class ClipboardStackPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    /// True when the scroll moved the selection (and is consumed); false
    /// lets it scroll the view under the pointer (the preview).
    var onScroll: ((NSEvent) -> Bool)?
    var onPointerMoved: (() -> Void)?
    var onResignKey: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        title = "SparkV Clipboard Stack"
        appearance = NSAppearance(named: .darkAqua)
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if onKey?(event) == true { return }
        case .scrollWheel:
            if onScroll?(event) == true { return }
        case .mouseMoved:
            onPointerMoved?()
        default:
            break
        }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class ClipboardStackPanelController {
    let model: ClipboardStackModel
    private unowned let clipboard: ClipboardController
    private var panel: ClipboardStackPanel?
    private var hosting: NSHostingView<AnyView>?
    /// The app the panel opened over; pastes go back to it.
    private var targetApp: NSRunningApplication?
    /// Caret (or pointer) rect the panel hangs from, Cocoa coordinates.
    private var anchor: CGRect = .zero
    private var screenVisible: CGRect = .zero
    private var observers: Set<AnyCancellable> = []
    private var closing = false
    private var opening = false
    /// Called with true / false as the panel opens and closes.
    var onOpenChange: ((Bool) -> Void)?

    var isOpen: Bool { panel?.isVisible ?? false }

    init(clipboard: ClipboardController) {
        self.clipboard = clipboard
        model = ClipboardStackModel(items: { [unowned clipboard] in clipboard.items })
        clipboard.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.model.clampSelection()
                    self?.relayout()
                }
            }
            .store(in: &observers)
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.relayout() } }
            .store(in: &observers)
    }

    func toggle() {
        isOpen ? hide() : show()
    }

    func show() {
        guard !isOpen, !opening else { return }
        opening = true
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            targetApp = front
        }
        model.reset()
        let mouse = NSEvent.mouseLocation
        Task { @MainActor [weak self] in
            // Accessibility can block on a busy app; ask off the main thread.
            let caret = await Task.detached(priority: .userInitiated) { ClipboardCaretLocator.caretRectAX() }.value
            guard let self else { return }
            self.opening = false
            self.present(caretAX: caret, mouse: mouse)
        }
    }

    private func present(caretAX: CGRect?, mouse: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        if let caretAX {
            anchor = ClipboardStackPlacement.cocoaRect(fromAX: caretAX, primaryScreenHeight: primaryHeight)
        } else {
            anchor = CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        }
        let point = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        screenVisible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let panel = panel ?? makePanel()
        self.panel = panel
        relayout(force: true)
        // ⌘⇧V opens it instantly (keyboard-triggered: no fade), and it
        // already closes instantly.
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        onOpenChange?(true)
        AppLog.log("Clipboard: stack opened (\(clipboard.items.count) item(s), \(caretAX == nil ? "at pointer" : "at caret"))")
    }

    func hide() {
        guard let panel, panel.isVisible, !closing else { return }
        closing = true
        panel.orderOut(nil)
        closing = false
        model.isPreviewing = false
        onOpenChange?(false)
    }

    /// Sizes the panel for the current rows and preview, hanging from the anchor.
    private func relayout(force: Bool = false) {
        guard let panel, force || panel.isVisible else { return }
        let card = ClipboardStackMetrics.cardSize(rows: model.visibleItems.count, previewing: model.isPreviewing)
        let m = ClipboardStackMetrics.margin
        let frame = ClipboardStackPlacement.frame(size: card, anchor: anchor, visible: screenVisible)
        let outer = frame.insetBy(dx: -m, dy: -m)
        if panel.frame != outer { panel.setFrame(outer, display: true) }
    }

    private func makePanel() -> ClipboardStackPanel {
        let panel = ClipboardStackPanel()
        let root = ClipboardStackView(model: model, onCommand: { [weak self] in self?.run($0) })
            .environmentObject(clipboard)
            .padding(ClipboardStackMetrics.margin)
            .followsAppearance()
        let hosting = NSHostingView(rootView: AnyView(root))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.hosting = hosting
        panel.onKey = { [weak self] event in
            let key = ClipboardStackKey(event)
            return MainActor.assumeIsolated { self?.handle(key) ?? false }
        }
        panel.onScroll = { [weak self] event in
            let delta = event.scrollingDeltaY
            let precise = event.hasPreciseScrollingDeltas
            let x = event.locationInWindow.x
            return MainActor.assumeIsolated {
                guard let self else { return false }
                // Over the preview column the wheel scrolls the preview (long
                // text or code); everywhere else it moves the selection.
                if ClipboardStackPanelController.scrollsPreview(pointerX: x, previewing: self.model.isPreviewing) {
                    return false
                }
                self.model.scroll(deltaY: delta, precise: precise)
                return true
            }
        }
        panel.onPointerMoved = { [weak self] in
            MainActor.assumeIsolated { self?.model.pointerMoved = true }
        }
        panel.onResignKey = { [weak self] in
            // Clicking elsewhere closes it, like a menu.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, panel.isVisible, !panel.isKeyWindow else { return }
                    self.hide()
                }
            }
        }
        return panel
    }

    /// The pointer (window x) is over the preview column.
    nonisolated static func scrollsPreview(pointerX: CGFloat, previewing: Bool) -> Bool {
        previewing && pointerX > ClipboardStackMetrics.margin + ClipboardStackMetrics.listWidth
    }

    private func handle(_ key: ClipboardStackKey) -> Bool {
        let result = model.handle(key)
        if let command = result.command { run(command) }
        return result.handled
    }

    func run(_ command: ClipboardStackModel.Command) {
        switch command {
        case .paste(let item, let plain):
            let target = targetApp
            hide()
            clipboard.paste(item, plainText: plain, target: target)
        case .copy(let item):
            hide()
            clipboard.copy(item)
        case .delete(let item):
            clipboard.delete(item)
        case .togglePin(let item):
            clipboard.togglePin(item)
        case .smartAction(let item):
            guard let action = clipboard.smartActions(for: item).first else { return }
            hide()
            clipboard.perform(action, for: item)
        case .close:
            hide()
        }
    }
}

// MARK: - Views

struct ClipboardStackView: View {
    @EnvironmentObject private var clipboard: ClipboardController
    @ObservedObject var model: ClipboardStackModel
    let onCommand: (ClipboardStackModel.Command) -> Void

    var body: some View {
        let items = model.visibleItems
        let shape = RoundedRectangle(cornerRadius: ClipboardStackMetrics.corner, style: .continuous)
        let selected = items.indices.contains(model.selection) ? items[model.selection] : items.first
        VStack(spacing: 0) {
            header(count: items.count)
            Divider().overlay(SparkVTheme.stroke)
            HStack(spacing: 0) {
                list(items)
                    .frame(width: ClipboardStackMetrics.listWidth)
                if model.isPreviewing, let selected {
                    Divider().overlay(SparkVTheme.stroke)
                    ClipboardStackPreview(item: selected)
                        .frame(width: ClipboardStackMetrics.previewWidth)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            Divider().overlay(SparkVTheme.stroke)
            footer(selected: selected)
        }
        .background(shape.fill(SparkVTheme.background.opacity(0.97)))
        .background(shape.fill(Color.black).shadow(color: .black.opacity(0.5), radius: 16, y: 8))
        .overlay(shape.strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .clipShape(shape)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.isSearching ? SparkVTheme.red : SparkVTheme.textTertiary)
            if model.query.isEmpty {
                Text(model.isSearching ? "Search…" : "Type to search")
                    .font(.system(size: 12.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            } else {
                HStack(spacing: 1) {
                    Text(model.query)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Rectangle().fill(SparkVTheme.red).frame(width: 1.5, height: 14)
                }
            }
            Spacer(minLength: 6)
            Text(model.query.isEmpty ? "\(count) item\(count == 1 ? "" : "s")" : "\(count) match\(count == 1 ? "" : "es")")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(SparkVTheme.textTertiary)
            ClipboardKeyCap("⌘⇧V")
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardStackMetrics.headerHeight)
    }

    // MARK: List

    @ViewBuilder
    private func list(_ items: [ClipboardItem]) -> some View {
        if items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 20))
                    .foregroundStyle(SparkVTheme.textTertiary)
                Text(model.query.isEmpty ? emptyTitle : "No matches for “\(model.query)”")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ClipboardStackRow(
                                item: item,
                                number: index < ClipboardStackModel.maxNumbered ? index + 1 : nil,
                                isSelected: index == model.selection,
                                deleteArmed: model.armedDeleteID == item.id
                            )
                            .id(item.id)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside, model.pointerMoved { model.select(index) }
                            }
                            .gesture(
                                TapGesture(count: 2).onEnded { onCommand(.paste(item, plainText: false)) }
                                    .exclusively(before: TapGesture().onEnded { model.select(index) })
                            )
                        }
                    }
                    .padding(4)
                }
                .onChange(of: model.selection) { _, newValue in
                    guard items.indices.contains(newValue) else { return }
                    proxy.scrollTo(items[newValue].id)
                }
            }
        }
    }

    private var emptyTitle: String {
        switch clipboard.status {
        case .off: "Clipboard history is off"
        case .paused: "History is paused"
        default: "Nothing copied yet"
        }
    }

    // MARK: Footer

    private func footer(selected: ClipboardItem?) -> some View {
        let action = selected.flatMap { clipboard.smartActions(for: $0).first }
        // With an action chip the hints drop their labels, so both fit.
        let compact = action != nil || model.isSearching
        return HStack(spacing: 8) {
            if let selected, let action {
                ClipboardSmartChip(action: action, height: 19, shortcut: "⌘O") {
                    onCommand(.smartAction(selected))
                }
                .fixedSize()
            }
            Spacer(minLength: 4)
            hint("↩", "Paste")
            hint("⌘1–9", nil)
            if !model.isSearching {
                hint("␣", compact ? nil : "Preview")
                hint("P", compact ? nil : "Pin")
            }
            hint("⌫", nil)
            if !compact { hint("esc", nil) }
        }
        .padding(.horizontal, 10)
        .frame(height: ClipboardStackMetrics.footerHeight)
        .background(Color.white.opacity(0.03))
    }

    private func hint(_ key: String, _ label: String?) -> some View {
        HStack(spacing: 3) {
            ClipboardKeyCap(key)
            if let label {
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }
}

struct ClipboardKeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(SparkVTheme.textSecondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 15)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SparkVTheme.surface))
            .fixedSize()
    }
}

struct ClipboardStackRow: View {
    @EnvironmentObject private var clipboard: ClipboardController
    let item: ClipboardItem
    let number: Int?
    let isSelected: Bool
    var deleteArmed = false

    var body: some View {
        let smart = clipboard.smartContent(for: item)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 9) {
            Text(number.map(String.init) ?? "")
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(isSelected ? Color.white : SparkVTheme.textSecondary)
                .frame(width: 17, height: 17)
                .background {
                    if number != nil {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSelected ? SparkVTheme.red : SparkVTheme.surfaceHover)
                    }
                }
            ClipboardStackThumb(item: item, smart: smart, side: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(smart))
                    .font(smart?.isMonospaced == true
                          ? .system(size: 11.5, weight: .medium, design: .monospaced)
                          : .system(size: 12, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(item.kind == .file || smart.map { if case .filePath = $0 { return true } else { return false } } == true ? .middle : .tail)
                HStack(spacing: 5) {
                    if let smart {
                        ClipboardSmartBadge(content: smart, size: 9)
                    } else {
                        Text(Self.kindLabel(item))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    if let name = clipboard.appName(for: item.sourceBundleID) {
                        Text("·").foregroundStyle(SparkVTheme.textTertiary)
                        Text(name).lineLimit(1)
                    }
                    Text("·").foregroundStyle(SparkVTheme.textTertiary)
                    Text(Self.age(item.copiedAt))
                }
                .font(.system(size: 9.5))
                .foregroundStyle(SparkVTheme.textTertiary)
            }
            Spacer(minLength: 4)
            if deleteArmed {
                Text("⌫ again to delete")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SparkVTheme.destructive)
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SparkVTheme.isApple ? Color.yellow : SparkVTheme.red)
                    .rotationEffect(.degrees(30))
            }
            if let icon = clipboard.appIcon(for: item.sourceBundleID) {
                Image(nsImage: icon).resizable().frame(width: 15, height: 15).opacity(0.9)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ClipboardStackMetrics.rowHeight)
        .background(shape.fill(isSelected ? SparkVTheme.redSoft : Color.clear))
        .overlay(shape.strokeBorder(isSelected ? SparkVTheme.red.opacity(0.45) : Color.clear, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number.map { "\($0), " } ?? "")\(item.displayTitle)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func title(_ smart: ClipboardSmartContent?) -> String {
        switch item.kind {
        case .text, .richText:
            let flat = (item.text ?? "").split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ⏎ ")
            return flat.isEmpty ? "Text" : String(flat.prefix(160))
        case .url:
            if let title = item.title, !title.isEmpty { return title }
            return item.text ?? item.displayTitle
        case .image:
            if let text = item.recognizedText?.split(whereSeparator: \.isNewline).first,
               text.filter(\.isLetter).count >= 3 {
                return "\(item.displayTitle) · “\(text.prefix(60))”"
            }
            return item.displayTitle
        case .file:
            return item.displayTitle
        }
    }

    static func kindLabel(_ item: ClipboardItem) -> String {
        switch item.kind {
        case .text: "Text"
        case .richText: "Formatted text"
        case .url: "Link"
        case .image: "Image"
        case .file: (item.fileURLs?.count ?? 0) > 1 ? "\(item.fileURLs?.count ?? 0) files" : "File"
        }
    }

    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }
}

/// Square icon for a row: image thumbnail, file icon, swatch or type glyph.
struct ClipboardStackThumb: View {
    @EnvironmentObject private var clipboard: ClipboardController
    let item: ClipboardItem
    let smart: ClipboardSmartContent?
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack {
            shape.fill(SparkVTheme.surface)
            switch item.kind {
            case .image:
                if let image = clipboard.thumbnails[item.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side).clipShape(shape)
                } else {
                    glyph("photo", .white)
                }
            case .file:
                if let url = item.fileURLs?.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                        .frame(width: side - 4, height: side - 4)
                } else {
                    glyph("doc", .white)
                }
            case .text, .richText, .url:
                if case .color(let color, _)? = smart {
                    ClipboardColorSwatch(color: color, size: side, corner: 7)
                } else if let smart {
                    glyph(smart.symbol, ClipboardSmartBadge.tint(for: smart))
                } else {
                    glyph(ClipboardController.symbol(for: item.kind), .white)
                }
            }
        }
        .frame(width: side, height: side)
    }

    private func glyph(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: side * 0.42, weight: .medium))
            .foregroundStyle(tint.opacity(0.85))
    }
}

/// Loads a full-size image for the preview, once.
@MainActor
final class ClipboardPreviewImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    private var loadedID: UUID?

    func load(_ item: ClipboardItem, url: URL?) {
        guard loadedID != item.id else { return }
        loadedID = item.id
        image = nil
        guard let url else { return }
        let id = item.id
        Task { @MainActor [weak self] in
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
            guard let self, self.loadedID == id, let data else { return }
            self.image = NSImage(data: data)
        }
    }
}

/// Space / → : a larger look at the selected item.
struct ClipboardStackPreview: View {
    @EnvironmentObject private var clipboard: ClipboardController
    let item: ClipboardItem
    @StateObject private var loader = ClipboardPreviewImageLoader()

    var body: some View {
        let smart = clipboard.smartContent(for: item)
        VStack(alignment: .leading, spacing: 8) {
            content(smart)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // Colours carry a Copy button on each format row instead.
            if case .color? = smart {} else {
                ClipboardSmartActionRow(item: item, limit: 2, height: 20)
            }
            Text(meta)
                .font(.system(size: 9.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(2)
        }
        .padding(12)
        .onAppear { loadIfImage() }
        .onChange(of: item.id) { _, _ in loadIfImage() }
    }

    private func loadIfImage() {
        if item.kind == .image { loader.load(item, url: clipboard.store.imageFileURL(for: item)) }
    }

    @ViewBuilder
    private func content(_ smart: ClipboardSmartContent?) -> some View {
        switch item.kind {
        case .image:
            if let image = loader.image ?? clipboard.thumbnails[item.id] {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(SparkVTheme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((item.fileURLs ?? []).prefix(6).enumerated()), id: \.offset) { _, url in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                            Text(url.deletingLastPathComponent().path).font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(SparkVTheme.textTertiary).truncationMode(.middle)
                        }
                        .lineLimit(1)
                    }
                }
                if (item.fileURLs?.count ?? 0) > 6 {
                    Text("+\((item.fileURLs?.count ?? 0) - 6) more").font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                }
            }
        case .text, .richText, .url:
            if case .color(let color, _)? = smart {
                VStack(alignment: .leading, spacing: 8) {
                    ClipboardColorSwatch(color: color, size: 70, corner: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(ClipboardColor.Format.allCases, id: \.self) { format in
                        ClipboardColorFormatRow(item: item, color: color, format: format)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if item.kind == .url, let title = item.title, !title.isEmpty {
                        Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(SparkVTheme.text).lineLimit(3)
                    }
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(String((item.text ?? "").prefix(6000)))
                            .font(smart?.isMonospaced == true
                                  ? .system(size: 10.5, design: .monospaced)
                                  : .system(size: 11.5))
                            .foregroundStyle(SparkVTheme.text)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let smart = clipboard.smartContent(for: item) { parts.append(smart.label) }
        else { parts.append(ClipboardStackRow.kindLabel(item)) }
        if let name = clipboard.appName(for: item.sourceBundleID) { parts.append("from \(name)") }
        parts.append(ClipboardStackRow.age(item.copiedAt) == "now" ? "just now" : "\(ClipboardStackRow.age(item.copiedAt)) ago")
        if item.copyCount > 1 { parts.append("copied \(item.copyCount)×") }
        if let w = item.pixelWidth, let h = item.pixelHeight { parts.append("\(w)×\(h)") }
        if item.kind == .text || item.kind == .richText { parts.append("\((item.text ?? "").count) chars") }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

/// One "HEX  #1E90FF  [Copy]" line of a colour's preview.
private struct ClipboardColorFormatRow: View {
    @EnvironmentObject private var clipboard: ClipboardController
    let item: ClipboardItem
    let color: ClipboardColor
    let format: ClipboardColor.Format

    var body: some View {
        let value: String = color.string(in: format)
        let action = ClipboardSmartAction(title: "Copy as \(format.label)", symbol: "doc.on.doc", kind: .copyText(value))
        let chip = ClipboardSmartAction(title: "Copy", symbol: "doc.on.doc", kind: .copyText(value))
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(format.label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SparkVTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            ClipboardSmartChip(action: chip, height: 17) {
                clipboard.perform(action, for: item)
            }
        }
    }
}
