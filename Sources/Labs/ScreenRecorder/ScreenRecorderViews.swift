import AppKit
import AVFoundation
import SwiftUI

// MARK: - Band under the notch

/// "● REC 0:42  Full screen ……… ■ Stop ⌃⌥⇧R". The collapsed notch ignores
/// clicks, so the band says how to stop; hovering it opens the Screen tab,
/// whose Record tile has become a Stop button.
struct ScreenRecorderBandView: View {
    let since: Date
    let label: String
    let shortcut: String

    var body: some View {
        TimelineView(.periodic(from: since, by: 0.5)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(since))
            HStack(spacing: 8) {
                Circle()
                    .fill(SparkVTheme.recording)
                    .frame(width: 8, height: 8)
                    .opacity(Int(elapsed * 2) % 2 == 0 ? 1 : 0.35)
                    .shadow(color: SparkVTheme.isApple ? Color.clear : SparkVTheme.recording.opacity(0.8), radius: 3)
                Text(ScreenRecording.durationText(elapsed))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill").font(.system(size: 7, weight: .bold))
                    Text("Stop  \(shortcut)").font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(SparkVTheme.recording))
            }
        }
        .foregroundStyle(SparkVTheme.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Screen tab tile

/// The recorder's tile on the Screen tab (`ScreenRegionController.drawerAccessory`).
struct ScreenRecorderDrawerTile: View {
    @ObservedObject var recorder: ScreenRecorderController
    @ObservedObject var settings: ScreenRecorderSettings

    init(recorder: ScreenRecorderController) {
        self.recorder = recorder
        self.settings = recorder.settings
    }

    var body: some View {
        switch recorder.phase {
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                ScreenToolTile(
                    systemImage: "stop.fill", title: "Stop recording", shortTitle: "Stop",
                    detail: "\(ScreenRecording.durationText(context.date.timeIntervalSince(since)))  ·  \(settings.shortcut.displayString)",
                    tint: SparkVTheme.recording, isActive: true, help: "Stop and save to the Desktop",
                    action: { recorder.stop() }
                )
            }
        case .starting, .stopping:
            ScreenToolTile(
                systemImage: "record.circle", title: recorder.phase == .starting ? "Starting…" : "Saving…",
                detail: settings.shortcut.displayString, tint: SparkVTheme.recording, action: {}
            )
            .opacity(0.7)
        case .idle, .selecting:
            ScreenToolTile(
                systemImage: "record.circle", title: "Record screen", shortTitle: "Record",
                detail: settings.shortcut.displayString, tint: SparkVTheme.recording,
                help: "Drag an area, click a window, or press Return for the whole screen (\(settings.shortcut.displayString))",
                action: { recorder.beginSelection() }
            ) {
                HStack(spacing: 2) {
                    if let recording = recorder.lastRecording {
                        ScreenRecorderDragThumbnail(recording: recording, image: recorder.lastThumbnail, size: CGSize(width: 30, height: 20))
                            .help("\(recording.name): drag into any app")
                    }
                    ScreenToolTileMenu { ScreenRecorderMenuItems(recorder: recorder) }
                }
            }
        }
    }
}

/// A recording's thumbnail that can be dragged out into Finder, Mail, Slack…
struct ScreenRecorderDragThumbnail: View {
    let recording: ScreenRecording
    let image: NSImage?
    let size: CGSize

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SparkVTheme.surfaceHover)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").font(.system(size: size.height * 0.45)).foregroundStyle(SparkVTheme.textSecondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(SparkVTheme.stroke))
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(contentsOf: recording.url) ?? NSItemProvider()
        }
    }
}

// MARK: - Menu items

/// For the notch's "…" menu and the tile's chevron.
struct ScreenRecorderMenuItems: View {
    @ObservedObject var recorder: ScreenRecorderController
    @ObservedObject var settings: ScreenRecorderSettings

    init(recorder: ScreenRecorderController) {
        self.recorder = recorder
        self.settings = recorder.settings
    }

    var body: some View {
        if recorder.phase.isRecording {
            Button("Stop Recording  \(settings.shortcut.displayString)") { recorder.stop() }
        } else {
            Button("Record Screen…  \(settings.shortcut.displayString)") { recorder.beginSelection() }
                .disabled(recorder.phase != .idle)
            Button("Record Full Screen") { recorder.recordFullScreen() }
                .disabled(recorder.phase != .idle)
            Button("Record a Window…") { recorder.beginSelection(mode: .window) }
                .disabled(recorder.phase != .idle)
        }
        Divider()
        Toggle("Record Microphone", isOn: Binding(
            get: { settings.recordsMicrophone },
            set: { recorder.setRecordsMicrophone($0) }
        ))
        Toggle("Record System Audio", isOn: $settings.recordsSystemAudio)
        Toggle("Show Cursor", isOn: $settings.showsCursor)
        Toggle("Highlight Clicks", isOn: $settings.highlightsClicks)
        Picker("Format", selection: $settings.format) {
            ForEach(ScreenRecorderFormat.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("Frame Rate", selection: $settings.framesPerSecond) {
            Text("60 fps").tag(60)
            Text("30 fps").tag(30)
        }
        if let recording = recorder.lastRecording {
            Divider()
            Button("Show Last Recording in Finder") { recorder.reveal(recording) }
        }
    }
}

// MARK: - Menu-bar stop button

/// A red "■ 0:42" in the menu bar while recording; one click stops, like the
/// system screenshot tool's stop button.
@MainActor
final class ScreenRecorderStatusItem {
    var onStop: (() -> Void)?
    private var item: NSStatusItem?
    private var timer: Timer?
    private var since = Date()
    private let target = ScreenRecorderStatusTarget()

    func show(since: Date) {
        self.since = since
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
                image?.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
                button.contentTintColor = NSColor(SparkVTheme.recording)
                button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                button.toolTip = "Stop recording (SparkV)"
                target.onClick = { [weak self] in self?.onStop?() }
                button.target = target
                button.action = #selector(ScreenRecorderStatusTarget.clicked)
            }
            self.item = item
        }
        update()
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func update() {
        item?.button?.title = " " + ScreenRecording.durationText(Date().timeIntervalSince(since))
    }
}

final class ScreenRecorderStatusTarget: NSObject {
    var onClick: (() -> Void)?
    @objc func clicked() { onClick?() }
}

// MARK: - Region frame

/// A dashed red frame just outside the recorded area (click-through, and
/// SparkV's windows are excluded from the recording).
@MainActor
final class ScreenRecorderFrameWindow {
    private var panel: NSPanel?
    static let outset: CGFloat = 4

    func show(around rect: CGRect) {
        hide()
        let frame = rect.insetBy(dx: -Self.outset, dy: -Self.outset)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = ScreenRecorderFrameView(frame: NSRect(origin: .zero, size: frame.size))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

final class ScreenRecorderFrameView: NSView {
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()
        let inset = ScreenRecorderFrameWindow.outset / 2
        let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
        path.lineWidth = 2
        path.setLineDash([7, 4], count: 2, phase: 0)
        NSColor(SparkVTheme.recording).withAlphaComponent(0.95).setStroke()
        path.stroke()
    }
}

// MARK: - Finished-recording panel

enum ScreenRecorderThumbnails {
    /// A frame half a second in (the first frame is often still the overlay fading).
    nonisolated static func make(for url: URL, maxSide: CGFloat = 480) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        guard let image = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

@MainActor
final class ScreenRecorderResultModel: ObservableObject {
    @Published var hovering = false
}

/// Floating card in the bottom-right corner after a recording, like the
/// macOS screenshot thumbnail and CleanShot's Quick Access Overlay.
@MainActor
final class ScreenRecorderResultPanel {
    static let size = CGSize(width: 356, height: 104)
    private var panel: NSPanel?
    private var closeTask: Task<Void, Never>?
    private let model = ScreenRecorderResultModel()

    var isOpen: Bool { panel != nil }

    func show(_ recording: ScreenRecording, controller: ScreenRecorderController) {
        close()
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let frame = CGRect(x: visible.maxX - Self.size.width - 16, y: visible.minY + 16, width: Self.size.width, height: Self.size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        model.hovering = false
        let view = ScreenRecorderResultView(controller: controller, recording: recording, model: model) { [weak self] in self?.close() }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        scheduleClose()
    }

    func close() {
        closeTask?.cancel()
        closeTask = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Closes after 12 s, but not while the pointer is over it.
    private func scheduleClose() {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            while !Task.isCancelled, self?.model.hovering == true {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }
}

struct ScreenRecorderResultView: View {
    @ObservedObject var controller: ScreenRecorderController
    let recording: ScreenRecording
    @ObservedObject var model: ScreenRecorderResultModel
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ScreenRecorderDragThumbnail(
                recording: recording,
                image: controller.lastRecording == recording ? controller.lastThumbnail : nil,
                size: CGSize(width: 128, height: 76)
            )
            .overlay(alignment: .bottomTrailing) {
                Text(recording.durationText)
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(4)
            }
            .help("Drag into any app")
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(recording.targetLabel) · \(recording.sizeText)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ScreenRecorderResultButton(title: "Reveal", systemImage: "folder") { controller.reveal(recording) }
                    ScreenRecorderResultButton(title: "Open", systemImage: "play.fill", isPrimary: true) { controller.open(recording) }
                    if controller.canAddToTray {
                        ScreenRecorderResultButton(title: "Tray", systemImage: "tray.and.arrow.down") {
                            controller.addToTray(recording)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(width: ScreenRecorderResultPanel.size.width, height: ScreenRecorderResultPanel.size.height)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous)
                .fill(SparkVTheme.background.opacity(0.97))
        )
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerLarge, style: .continuous).strokeBorder(SparkVTheme.stroke))
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(SparkVTheme.surfaceHover))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(7)
            .help("Close")
        }
        .foregroundStyle(SparkVTheme.text)
        .environment(\.colorScheme, .dark)
        .onHover { model.hovering = $0 }
    }
}

private struct ScreenRecorderResultButton: View {
    let title: String
    let systemImage: String
    var isPrimary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(isPrimary ? Color.white : SparkVTheme.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(isPrimary ? SparkVTheme.accent : SparkVTheme.surface))
            .overlay(Capsule().strokeBorder(isPrimary ? Color.clear : SparkVTheme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
