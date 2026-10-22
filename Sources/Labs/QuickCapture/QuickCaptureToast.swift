import AppKit
import SwiftUI

/// What the action strip shows. Observable so the strip updates in place
/// when the capture moves to another Space.
@MainActor
final class QuickCaptureToastModel: ObservableObject {
    @Published var record: QuickCaptureRecord?
    @Published var spaceName = "Inbox"
    @Published var spaceIcon = "tray.and.arrow.down.fill"
    @Published var spaceColor: Color = .white
    @Published var isHovered = false
}

/// The small strip under the notch band with Change Space, Open and Undo.
/// The notch panel ignores clicks while collapsed, so the actions live in
/// their own non-activating panel (one level below the notch, so the open
/// drawer covers it) that never takes focus from the front app.
@MainActor
final class QuickCaptureToastController {
    static let size = CGSize(width: 300, height: 30)

    private weak var controller: QuickCaptureController?
    private let model = QuickCaptureToastModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var deadline = Date.distantPast

    init(controller: QuickCaptureController) {
        self.controller = controller
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ record: QuickCaptureRecord) {
        guard let controller else { return }
        let space = record.spaceID.flatMap { controller.store.space($0) }
        model.record = record
        model.spaceName = space?.name ?? "Inbox"
        model.spaceIcon = space?.icon ?? "tray.and.arrow.down.fill"
        model.spaceColor = space.map { SpaceIngestCenter.color(hex: $0.color) } ?? .white
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
        deadline = Date().addingTimeInterval(QuickCaptureController.toastDuration)
        scheduleHide()
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        model.record = nil
        model.isHovered = false
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = self.deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    if self.model.isHovered {
                        // Hovering keeps it (and the band) up, like a macOS notification.
                        self.deadline = Date().addingTimeInterval(2)
                        self.controller?.extendBand()
                    } else {
                        self.panel?.orderOut(nil)
                        self.model.record = nil
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = QuickCaptureToastPanel(contentRect: NSRect(origin: .zero, size: Self.size))
        let view = QuickCaptureToastView(
            model: model,
            onChangeSpace: { [weak self] anchor in self?.showSpaceMenu(anchor: anchor) },
            onOpen: { [weak self] in self?.controller?.openLastCapture() },
            onUndo: { [weak self] in self?.controller?.undo() }
        )
        let host = NotchHostingView(rootView: view.followsAppearance())
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.screens.first else { return }
        let frame = screen.frame
        let notch = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : max(24, frame.maxY - screen.visibleFrame.maxY)
        let top = frame.maxY - notch - NotchMetrics.activityBandHeight - 6
        panel.setFrame(NSRect(x: frame.midX - Self.size.width / 2, y: top - Self.size.height,
                              width: Self.size.width, height: Self.size.height), display: true)
    }

    // MARK: - Change Space menu

    private func showSpaceMenu(anchor: NSView?) {
        guard let controller, let record = model.record else { return }
        let menu = NSMenu(title: "Change Space")
        let inbox = QuickCaptureMenuItem(title: "Inbox", spaceID: nil, controller: controller)
        inbox.image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)
        inbox.state = record.spaceID == nil ? .on : .off
        menu.addItem(inbox)
        let entries = controller.spaceMenuEntries()
        if !entries.isEmpty { menu.addItem(.separator()) }
        for entry in entries {
            let item = QuickCaptureMenuItem(title: entry.space.name, spaceID: entry.space.id, controller: controller)
            item.indentationLevel = entry.depth
            item.state = record.spaceID == entry.space.id ? .on : .off
            if let image = NSImage(systemSymbolName: entry.space.icon, accessibilityDescription: nil) {
                item.image = image
            }
            menu.addItem(item)
        }
        // Stay up while the menu is open (popUp tracks the menu synchronously).
        deadline = Date().addingTimeInterval(120)
        let view = anchor ?? panel?.contentView
        guard let view else { return }
        // Below the strip, aligned with the Space button.
        let below = NSPoint(x: 6, y: view.isFlipped ? view.bounds.height + 4 : -4)
        menu.popUp(positioning: nil, at: below, in: view)
        // popUp blocks until the menu closes; give the user a moment to see the result.
        deadline = Date().addingTimeInterval(3)
    }
}

/// Menu item that re-files the capture when chosen.
private final class QuickCaptureMenuItem: NSMenuItem {
    let spaceID: UUID?
    weak var controller: QuickCaptureController?

    init(title: String, spaceID: UUID?, controller: QuickCaptureController) {
        self.spaceID = spaceID
        self.controller = controller
        super.init(title: title, action: #selector(choose), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func choose() {
        MainActor.assumeIsolated { controller?.changeSpace(to: spaceID) }
    }
}

final class QuickCaptureToastPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Dark capsule: [Space ▾] · Open · Undo.
struct QuickCaptureToastView: View {
    @ObservedObject var model: QuickCaptureToastModel
    var onChangeSpace: (NSView?) -> Void
    var onOpen: () -> Void
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { onChangeSpace(nil) } label: {
                HStack(spacing: 5) {
                    spaceIcon.frame(width: 14, height: 14)
                    Text(model.spaceName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 22)
                .background(Capsule().fill(SparkVTheme.surfaceHover))
                .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Change Space")
            .accessibilityLabel("Change Space, now \(model.spaceName)")

            QuickCaptureStripButton(title: "Open", symbol: "arrow.up.right.square", action: onOpen)
                .help("Open in Spaces")
            QuickCaptureStripButton(title: "Undo", symbol: "arrow.uturn.backward", action: onUndo)
                .help("Remove this capture")
        }
        .foregroundStyle(SparkVTheme.text)
        .padding(.horizontal, 4)
        .frame(width: QuickCaptureToastController.size.width, height: QuickCaptureToastController.size.height)
        // Apple: a pure black pill that reads as part of the island above it.
        .background(Capsule().fill(SparkVTheme.isApple ? SparkVTheme.islandBackground : SparkVTheme.background))
        .overlay(Capsule().strokeBorder(SparkVTheme.stroke, lineWidth: 0.5))
        .onHover { model.isHovered = $0 }
    }

    @ViewBuilder
    private var spaceIcon: some View {
        if NSImage(systemSymbolName: model.spaceIcon, accessibilityDescription: nil) != nil {
            Image(systemName: model.spaceIcon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.spaceColor)
        } else {
            Text(model.spaceIcon).font(.system(size: 11))
        }
    }
}

private struct QuickCaptureStripButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hover.isOn ? (SparkVTheme.isApple ? SparkVTheme.text : SparkVTheme.red) : SparkVTheme.textSecondary)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .accessibilityLabel(title)
    }
}
