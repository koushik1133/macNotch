import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Floating, non-activating panel for Nearby Share (LocalSend). It takes
/// clicks and keys without activating SparkV, so the app the user is in
/// stays frontmost; Esc closes it.
final class LocalSendPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        title = "Nearby Share"
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

enum LocalSendPanelMetrics {
    static let size = CGSize(width: 400, height: 392)
    static let corner: CGFloat = 20
}

@MainActor
final class LocalSendPanelController: NSObject {
    static let shared = LocalSendPanelController()

    private var panel: LocalSendPanel?
    /// Bumped by every open / close, so a close's fade never hides a panel
    /// that was opened again meanwhile.
    private var generation = 0
    var isOpen: Bool { panel?.isVisible ?? false }

    /// Opens the panel with these files (keeps the list when called with
    /// none) and, when Nearby Share is on, starts looking for devices.
    func open(files: [URL] = []) {
        let controller = LocalSendController.shared
        if !files.isEmpty { controller.setFiles(files) }
        let panel = panel ?? makePanel()
        self.panel = panel
        generation += 1
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5
        if !wasVisible {
            panel.setFrame(initialFrame(), display: false)
            panel.alphaValue = 0
        }
        panel.makeKeyAndOrderFront(nil)
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = SparkVMotion.reduceMotion ? 0.12 : 0.18
                context.timingFunction = .sparkVEaseOut
                panel.animator().alphaValue = 1
            }
        }
        if controller.isEnabled, !controller.isBusy { controller.search() }
        AppLog.log("LocalSend: panel open with \(controller.files.count) file(s)")
    }

    func close() {
        LocalSendController.shared.panelClosed()
        guard let panel, panel.isVisible else { return }
        generation += 1
        let closing = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = SparkVMotion.reduceMotion ? 0.1 : 0.14
            context.timingFunction = .sparkVEaseOut
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, self.generation == closing else { return }
                panel?.orderOut(nil)
                panel?.alphaValue = 1
            }
        })
    }

    private func makePanel() -> LocalSendPanel {
        let size = LocalSendPanelMetrics.size
        let panel = LocalSendPanel(contentRect: NSRect(origin: .zero, size: size))
        let root = LocalSendPanelView(controller: .shared, onClose: { [weak self] in self?.close() }).followsAppearance()
        let hosting = NotchHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.onCancel = { [weak self] in self?.close() }
        return panel
    }

    /// Top centre of the screen under the pointer, below the open drawer.
    private func initialFrame() -> NSRect {
        let size = LocalSendPanelMetrics.size
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let visible = screen.visibleFrame
        let clearance: CGFloat = screen.safeAreaInsets.top > 0 ? 150 : 12
        let x = (screen.frame.midX - size.width / 2).rounded()
        let y = max(visible.minY, visible.maxY - size.height - clearance)
        return NSRect(x: max(visible.minX, min(x, visible.maxX - size.width)), y: y, width: size.width, height: size.height)
    }
}

// MARK: - Views

/// Look-dependent pieces of the Nearby panel.
enum NearbyStyle {
    /// Apple: LocalSend's teal on a dark tile; SparkV Red: the accent.
    static var tint: Color { SparkVTheme.isApple ? Color(red: 0.16, green: 0.75, blue: 0.72) : SparkVTheme.red }
    static var rowSelected: Color { SparkVTheme.isApple ? SparkVTheme.accent.opacity(0.22) : SparkVTheme.redSoft }
    static var rowSelectedStroke: Color { SparkVTheme.isApple ? SparkVTheme.accent.opacity(0.75) : SparkVTheme.red.opacity(0.7) }
}

struct LocalSendPanelView: View {
    @ObservedObject var controller: LocalSendController
    @ObservedObject var settings: ShelfSettings
    let onClose: () -> Void

    init(controller: LocalSendController, settings: ShelfSettings? = nil, onClose: @escaping () -> Void) {
        self.controller = controller
        self.settings = settings ?? controller.settings
        self.onClose = onClose
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LocalSendPanelMetrics.corner, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider().overlay(SparkVTheme.stroke)
            Group {
                if settings.localSendEnabled {
                    sendingBody
                } else {
                    LocalSendConsentView(onTurnOn: { controller.turnOnAndSearch() }, onNotNow: onClose)
                }
            }
            .transition(.sparkVCrossfade)
        }
        .frame(width: LocalSendPanelMetrics.size.width, height: LocalSendPanelMetrics.size.height, alignment: .top)
        .background(shape.fill(SparkVTheme.background))
        .overlay(shape.strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .clipShape(shape)
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: settings.localSendEnabled)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(NearbyStyle.tint)
                Image(systemName: "wave.3.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nearby Share")
                    .font(SparkVTheme.headline(13.5))
                    .foregroundStyle(SparkVTheme.text)
                Text("LocalSend · Android, Windows, Linux")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            LocalSendIconButton(symbol: "xmark", help: "Close (Esc)", action: onClose)
        }
    }

    // MARK: Turned on

    private var sendingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            LocalSendFilesRow(controller: controller)
            HStack(spacing: 6) {
                Text("DEVICES")
                    .font(SparkVTheme.eyebrow(9))
                    .tracking(1)
                    .foregroundStyle(SparkVTheme.textTertiary)
                if controller.isSearching {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                        .accessibilityLabel("Searching")
                }
                Spacer(minLength: 4)
                Button {
                    controller.search()
                } label: {
                    Label(controller.isSearching ? "Searching…" : "Search Again", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(controller.isSearching ? SparkVTheme.textTertiary : SparkVTheme.text)
                }
                .buttonStyle(SparkVPressStyle())
                .disabled(controller.isSearching || controller.isBusy)
                .opacity(controller.isBusy ? 0.4 : 1)
                .help("Look for LocalSend devices for a few seconds")
            }
            LocalSendDeviceList(controller: controller)
                .frame(maxHeight: .infinity, alignment: .top)
            LocalSendFooter(controller: controller)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }
}

/// First run: what turning it on means, then one clearly labelled button.
private struct LocalSendConsentView: View {
    let onTurnOn: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send shelf files to Android phones, Windows PCs and Linux machines that have the free LocalSend app, over your own network.")
                .font(.system(size: 12))
                .foregroundStyle(SparkVTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                bullet("antenna.radiowaves.left.and.right", "SparkV looks for devices only while this panel is open, for a few seconds.")
                bullet("hand.tap", "Nothing is sent until you pick a device and click Send. That device asks its owner to accept.")
                bullet("lock.shield", "Files go straight to the other device on your network, never through the internet, encrypted unless that device turned encryption off.")
                bullet("network", "macOS asks once to let SparkV find devices on your local network.")
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer()
                Button("Not Now", action: onNotNow)
                    .buttonStyle(SparkVSecondaryButtonStyle())
                Button("Turn On and Search", action: onTurnOn)
                    .buttonStyle(SparkVPrimaryButtonStyle())
                    .help("Turns on Nearby Share (LocalSend) and looks for devices")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(NearbyStyle.tint)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(SparkVTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What will be sent: a few thumbnails, the count and size, Add / Clear.
private struct LocalSendFilesRow: View {
    @ObservedObject var controller: LocalSendController

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                ForEach(Array(controller.files.prefix(3).enumerated()).reversed(), id: \.element) { index, url in
                    LocalSendThumbnail(url: url)
                        .frame(width: 34, height: 34)
                        .rotationEffect(.degrees(Double(index) * 7 - 7))
                        .offset(x: CGFloat(index) * 5)
                }
                if controller.files.isEmpty {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(SparkVTheme.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .frame(width: 34, height: 34)
                        .overlay(Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(SparkVTheme.textTertiary))
                }
            }
            .frame(width: 48, height: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(controller.skippedFolders > 0 ? SparkVTheme.warning : SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Add…") { controller.chooseFiles() }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .controlSize(.small)
                .disabled(controller.isBusy)
                .opacity(controller.isBusy ? 0.4 : 1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch controller.files.count {
        case 0: "No files yet"
        case 1: controller.files[0].lastPathComponent
        default: "\(controller.files.count) files"
        }
    }

    private var detail: String {
        if controller.files.isEmpty { return "Add files, or use Share › LocalSend on Tray items" }
        var text = DownloadFormat.bytes(controller.totalFileBytes)
        if controller.skippedFolders > 0 { text += " · \(controller.skippedFolders) folder\(controller.skippedFolders == 1 ? "" : "s") skipped (zip first)" }
        return text
    }
}

/// Quick Look thumbnail of a file (Finder icon until it arrives).
private struct LocalSendThumbnail: View {
    let url: URL
    @StateObject private var loader = LocalSendThumbnailLoader()

    var body: some View {
        Image(nsImage: loader.image ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .onAppear { loader.load(url) }
    }
}

@MainActor
private final class LocalSendThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    private var requested: URL?

    func load(_ url: URL) {
        guard requested != url else { return }
        requested = url
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 68, height: 68), scale: scale,
                                                   representationTypes: [.icon, .thumbnail])
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let cgImage = representation?.cgImage else { return }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale))
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.image = image } }
        }
    }
}

private struct LocalSendDeviceList: View {
    @ObservedObject var controller: LocalSendController

    var body: some View {
        Group {
            if controller.isBlocked {
                LocalSendNote(symbol: "hand.raised.fill", tone: SparkVTheme.warning,
                              title: "macOS blocked local network access",
                              detail: "Turn on SparkV in Privacy & Security › Local Network, then search again.",
                              button: ("Open Settings", { controller.openLocalNetworkSettings() }))
            } else if controller.devices.isEmpty {
                LocalSendNote(symbol: controller.isSearching ? "dot.radiowaves.left.and.right" : "questionmark.circle",
                              tone: SparkVTheme.textSecondary,
                              title: controller.isSearching ? "Looking for devices…" : "No devices found",
                              detail: "Open LocalSend on the other device and keep both on the same Wi-Fi.",
                              button: nil)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(controller.devices) { device in
                            LocalSendDeviceRow(device: device, isSelected: controller.selectedDeviceID == device.id) {
                                if !controller.isBusy { controller.selectedDeviceID = device.id }
                            }
                            .transition(.sparkVEnter)
                        }
                    }
                    .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: controller.devices.map(\.id))
                }
            }
        }
    }
}

private struct LocalSendDeviceRow: View {
    let device: LocalSendDevice
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: device.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isSelected ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.alias)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                    Text(device.subtitle)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !device.usesTLS {
                    Label("Unencrypted", systemImage: "lock.open.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.warning)
                        .help("This device has encryption turned off in LocalSend: files cross your network unencrypted")
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? NearbyStyle.rowSelectedStroke : SparkVTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(shape.fill(isSelected ? NearbyStyle.rowSelected : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(shape.strokeBorder(isSelected ? NearbyStyle.rowSelectedStroke : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .animation(SparkVMotion.hover(), value: isSelected)
        .accessibilityLabel("\(device.alias), \(device.deviceModel ?? device.deviceType)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct LocalSendNote: View {
    let symbol: String
    let tone: Color
    let title: String
    let detail: String
    let button: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tone)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let button {
                    Button(button.0, action: button.1)
                        .buttonStyle(SparkVSecondaryButtonStyle())
                        .controlSize(.small)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
    }
}

/// Status, progress and the Send / Cancel buttons.
private struct LocalSendFooter: View {
    @ObservedObject var controller: LocalSendController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.isBusy || isFinished {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        statusIcon
                        Text(statusText)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SparkVTheme.text)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if case .sending = controller.phase, let fraction = controller.fraction {
                            Text(DownloadFormat.percent(fraction))
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                .foregroundStyle(SparkVTheme.textSecondary)
                        }
                    }
                    if case .sending = controller.phase {
                        DownloadsBar(fraction: controller.fraction, tint: NearbyStyle.tint)
                    }
                }
                .transition(.sparkVEnter)
            }
            HStack(spacing: 8) {
                if controller.isBusy {
                    Button("Cancel") { controller.cancel() }
                        .buttonStyle(SparkVSecondaryButtonStyle())
                }
                Spacer()
                let canSend = controller.selectedDevice != nil && !controller.files.isEmpty && !controller.isBusy
                Button {
                    controller.send()
                } label: {
                    Label(controller.isBusy ? "Sending…" : sendTitle, systemImage: "paperplane.fill")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .buttonStyle(SparkVPrimaryButtonStyle(tint: SparkVTheme.isApple ? nil : SparkVTheme.red))
                .disabled(!canSend)
                // The filled style doesn't dim by itself.
                .opacity(canSend ? 1 : 0.45)
                .help(controller.selectedDevice == nil ? "Pick a device first" : "Send to \(controller.selectedDevice?.alias ?? "")")
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: controller.phase)
    }

    private var isFinished: Bool {
        switch controller.phase {
        case .sent, .failed: true
        default: false
        }
    }

    private var sendTitle: String {
        guard let device = controller.selectedDevice else { return "Send" }
        return "Send to \(device.alias)"
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch controller.phase {
        case .sent:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(SparkVTheme.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SparkVTheme.warning)
        default:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .waiting(let name): "Waiting for \(name) to accept…"
        case .sending(let name): "Sending to \(name)… \(DownloadFormat.bytes(controller.sentBytes)) of \(DownloadFormat.bytes(controller.totalBytes))"
        case .sent(let name, let count): count == 0 ? "\(name) already had these files" : "Sent \(count == 1 ? "1 file" : "\(count) files") to \(name)"
        case .failed(let message): message
        default: ""
        }
    }
}

private struct LocalSendIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .frame(width: 24, height: 24)
                .sparkVHoverFill(hover.isOn, cornerRadius: 12)
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
