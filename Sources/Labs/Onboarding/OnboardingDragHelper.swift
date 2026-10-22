import AppKit
import SwiftUI

/// A small floating card with SparkV's icon that can be dragged straight
/// into a System Settings privacy list (the approach PermissionFlow and
/// several menu-bar apps use), so nobody has to hunt for the .app in the
/// "+" file dialog.
@MainActor
final class OnboardingDragHelper: NSObject, NSWindowDelegate {
    static let shared = OnboardingDragHelper()
    private var panel: NSPanel?
    private var closeTask: Task<Void, Never>?

    func show(for permission: OnboardingPermission) {
        let panel = panel ?? makePanel()
        self.panel = panel
        self.permission = permission
        panel.contentView = OnboardingFirstMouseHostingView(rootView: OnboardingDragCard(permission: permission, appURL: Bundle.main.bundleURL) { [weak self] in
            self?.close()
        })
        position(panel)
        panel.orderFrontRegardless()
        closeTask?.cancel()
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    func close() {
        closeTask?.cancel()
        panel?.orderOut(nil)
    }

    /// The permission the visible card is for.
    var visiblePermission: OnboardingPermission? { panel?.isVisible == true ? permission : nil }
    private var permission: OnboardingPermission?

    private func makePanel() -> NSPanel {
        let panel = OnboardingDragPanel(
            contentRect: NSRect(origin: .zero, size: OnboardingDragCard.size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Bottom-right of the screen with the mouse, where System Settings'
    /// list usually isn't.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = OnboardingDragCard.size
        panel.setFrame(NSRect(x: visible.maxX - size.width - 24, y: visible.minY + 24, width: size.width, height: size.height), display: true)
    }
}

/// Borderless panels can't become key by default; this one may (without
/// activating SparkV) so the first click starts a drag.
private final class OnboardingDragPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Lets a drag start on the first click, even while SparkV is in the background.
final class OnboardingFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct OnboardingDragCard: View {
    static let size = CGSize(width: 340, height: 118)
    let permission: OnboardingPermission
    let appURL: URL
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .frame(width: 56, height: 56)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.accentSoft))
                .overlay(
                    RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .foregroundStyle(SparkVTheme.accent.opacity(0.7))
                )
                .onDrag { NSItemProvider(object: appURL as NSURL) }
                .help("Drag SparkV into the \(permission.title) list")
            VStack(alignment: .leading, spacing: 4) {
                Text("Drag SparkV into the list")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(SparkVTheme.text)
                Text("Drop this icon into the \(permission.title) list and turn it on. Remove an older SparkV there with − first.")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous)
                .fill(SparkVTheme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous)
                .strokeBorder(SparkVTheme.stroke)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(SparkVTheme.surface))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .environment(\.colorScheme, .dark)
    }
}
