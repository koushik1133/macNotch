import AppKit
import SwiftUI

/// Borderless, non-activating panel for the drop shelf under the closed
/// notch. It exists only while a file drag is near the notch, so it never
/// blocks clicks on the menu bar; while hidden it ignores the mouse.
@MainActor
final class FileDropZonePanel: NSPanel {
    init(controller: FileDropController) {
        super.init(contentRect: NSRect(origin: .zero, size: FileDropLayout.zoneSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // One above the notch panel (.statusBar), so drags reach the shelf
        // even where the collapsed notch window overlaps it.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        let host = FileDropZoneHostingView(rootView: FileDropTargetView(controller: controller).followsAppearance())
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: FileDropLayout.zoneSize)
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func present(at frame: NSRect) {
        setFrame(frame, display: true)
        ignoresMouseEvents = false
        if !isVisible { alphaValue = 0 }
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = .sparkVEaseOut
            animator().alphaValue = 1
        }
    }

    func dismiss(animated: Bool) {
        ignoresMouseEvents = true
        guard animated, isVisible else {
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = .sparkVEaseOut
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new drag may have brought it back meanwhile.
                guard let self, self.ignoresMouseEvents else { return }
                self.orderOut(nil)
            }
        })
    }
}

private final class FileDropZoneHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Shelf view

/// The drop target that appears under the collapsed notch while a file
/// drag nears it: Dropover-style instant-action buckets. "Actions" keeps the
/// files and opens the strip; the others run right away.
struct FileDropTargetView: View {
    @ObservedObject var controller: FileDropController

    var body: some View {
        HStack(spacing: 6) {
            FileDropBucket(instant: .actions, controller: controller, wide: true)
            FileDropBucket(instant: .compress, controller: controller)
            FileDropBucket(instant: .space, controller: controller)
            FileDropBucket(instant: .airDrop, controller: controller)
        }
        .padding(8)
        .frame(width: FileDropLayout.zoneSize.width, height: FileDropLayout.zoneSize.height)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(SparkVTheme.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(SparkVTheme.stroke, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SparkV file drop")
    }
}

private struct FileDropBucket: View {
    let instant: FileDropInstant
    @ObservedObject var controller: FileDropController
    var wide = false
    @StateObject private var targeted = ViewFlag()

    var body: some View {
        let active = targeted.isOn
        Group {
            if wide {
                HStack(spacing: 8) {
                    icon(active: active)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Actions")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(SparkVTheme.text)
                        Text("Rename, convert…")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(SparkVTheme.textTertiary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            } else {
                VStack(spacing: 4) {
                    icon(active: active)
                    Text(instant.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                }
            }
        }
        .frame(minWidth: wide ? 130 : 62, maxWidth: wide ? .infinity : 62)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(active ? (SparkVTheme.isApple ? instant.tint.opacity(0.20) : SparkVTheme.redSoft) : SparkVTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(active ? (SparkVTheme.isApple ? instant.tint.opacity(0.85) : SparkVTheme.red) : SparkVTheme.stroke,
                              style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active && !SparkVTheme.isApple ? [4, 3] : []))
        )
        .scaleEffect(active && !SparkVMotion.reduceMotion ? 1.04 : 1)
        .animation(SparkVMotion.snappy, value: active)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .onDrop(of: FileDropController.acceptedTypes, isTargeted: $targeted.isOn) { providers in
            controller.hideZone(after: .milliseconds(120))
            controller.noteShelfDrop(instant)
            return controller.accept(providers, then: instant)
        }
        .onReceive(targeted.$isOn.removeDuplicates()) { on in
            if on { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(instant == .actions ? "Drop for actions" : instant.title)
    }

    /// Apple: every bucket in its own color, white glyph (like the share
    /// sheet). SparkV Red: monochrome glyphs; red for the primary bucket
    /// (Actions) and for the one under the drag.
    private func icon(active: Bool) -> some View {
        let lit = SparkVTheme.isApple || active || instant == .actions
        return ZStack {
            Circle()
                .fill(lit ? (SparkVTheme.isApple ? instant.tint : SparkVTheme.red) : SparkVTheme.surfaceHover)
                .frame(width: 26, height: 26)
            Circle()
                .strokeBorder(lit ? Color.clear : SparkVTheme.stroke, lineWidth: 1)
                .frame(width: 26, height: 26)
            Image(systemName: instant.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(lit ? Color.white : SparkVTheme.text)
        }
    }
}

/// Band under the notch after an instant action finishes.
struct FileDropActivityView: View {
    let icon: String
    let color: Color
    let headline: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                } else {
                    Text(icon).font(.system(size: 12))
                }
            }
            .frame(width: 16)
            Text(headline)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Optional "Actions" drop tile for the open drawer's Tray (beside the
/// AirDrop tile), for drags that already opened the drawer: dropping on it
/// keeps the files for the action strip, which the controller then opens.
struct FileDropTile: View {
    @ObservedObject var controller: FileDropController
    @StateObject private var targeted = ViewFlag()
    @StateObject private var hovered = ViewFlag()

    var body: some View {
        let active = targeted.isOn
        Button {
            controller.onOpenStrip?()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(SparkVTheme.red)
                        .frame(width: 30, height: 30)
                        .shadow(color: SparkVTheme.red.opacity(active && !SparkVTheme.isApple ? 0.6 : 0), radius: 8)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                }
                Text("Actions")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
            }
            .frame(minWidth: 64, minHeight: 64)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(active ? SparkVTheme.accentSoft : (hovered.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(active ? SparkVTheme.accent : SparkVTheme.stroke,
                                  style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active && !SparkVTheme.isApple ? [4, 3] : []))
            )
            .scaleEffect(active && !SparkVMotion.reduceMotion ? 1.05 : 1)
            .animation(SparkVMotion.snappy, value: active)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hovered.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hovered.isOn)
        .onDrop(of: FileDropController.acceptedTypes, isTargeted: $targeted.isOn) { providers in
            controller.accept(providers, then: .actions)
        }
        .help("Drop files here for Rename, Compress, Convert, Space, AirDrop…")
        .accessibilityLabel("File actions")
    }
}

extension FileDropInstant {
    /// Bucket color in the Apple look (share-sheet style tinted circles).
    var tint: Color {
        switch self {
        case .actions: SparkVTheme.accent
        case .compress: Color.orange
        case .space: Color(red: 0.55, green: 0.45, blue: 1.0)
        case .airDrop: Color(red: 0.0, green: 0.60, blue: 1.0)
        }
    }
}
