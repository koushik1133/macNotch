import SwiftUI

/// Content of the band under the notch (~360×30 pt, dark).
struct BrowserRecorderBandView: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    /// 0…1 for a thin progress bar, nil for none.
    let progress: Double?
    /// Short trailing text that must stay visible, e.g. "3/10".
    var counter: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let counter {
                        Spacer(minLength: 0)
                        Text(counter)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .fixedSize()
                            .layoutPriority(2)
                    }
                }
                if let progress {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(SparkVTheme.stroke)
                            Capsule().fill(SparkVTheme.accent).frame(width: max(2, geo.size.width * progress))
                        }
                    }
                    .frame(height: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }
}

/// Drawer tab content, dark: record / stop, recent flows with a play button
/// each, and a button for the editor window. Fits the drawer's content area
/// at every height (about 508×69 pt at the default drawer, 508×114 at 160).
struct BrowserRecorderTabView: View {
    @ObservedObject var controller: BrowserRecorderController

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 96
            HStack(spacing: 12) {
                statusColumn(compact: compact)
                    .frame(width: 150, alignment: .leading)
                Rectangle()
                    .fill(SparkVTheme.stroke)
                    .frame(width: 1, height: max(20, min(70, geo.size.height - 8)))
                flowsColumn(compact: compact, height: geo.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Left: status and the main button

    private func statusColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(controller.phase == .idle ? SparkVTheme.textSecondary : (controller.phase == .recording ? SparkVTheme.recording : SparkVTheme.accent))
                Text("Browser Flows")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
            }
            Text(statusLine)
                .font(.system(size: 10))
                .foregroundStyle(statusColor)
                .lineLimit(compact ? 1 : 2)
                .truncationMode(.tail)
                .frame(height: compact ? 13 : 26, alignment: .topLeading)
                .help(statusLine)
            HStack(spacing: 6) {
                primaryButton
                BRCompactButton(symbol: "rectangle.and.pencil.and.ellipsis", title: nil, tint: SparkVTheme.surfaceHover) {
                    controller.openWindow()
                }
                .help("Open the flow editor")
            }
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch controller.phase {
        case .recording:
            BRCompactButton(symbol: "stop.fill", title: "Stop", tint: SparkVTheme.surfaceHover) { controller.stopRecording() }
        case .replaying:
            BRCompactButton(symbol: "stop.fill", title: "Stop", tint: SparkVTheme.surfaceHover) { controller.cancelReplay() }
        case .checking:
            BRCompactButton(symbol: "hourglass", title: "Checking", tint: SparkVTheme.surfaceHover) {}
                .disabled(true)
        case .idle:
            BRCompactButton(symbol: "record.circle", title: "Record", tint: SparkVTheme.recording) { controller.startRecording() }
                .disabled(!controller.runtimeAvailable)
        }
    }

    private var statusLine: String {
        if let error = controller.lastError { return error }
        switch controller.phase {
        case .recording:
            return "\(BRTemplate.stepCount(controller.liveSteps.count)) · \(controller.liveSteps.last?.displayTitle ?? "use the browser window")"
        case .replaying:
            guard let progress = controller.progress else { return "Replaying…" }
            return "Step \(progress.position ?? 0)/\(progress.totalSteps) · \(progress.currentTitle)"
        case .checking:
            return "Checking the browser runtime…"
        case .idle:
            if let notice = controller.lastNotice { return notice }
            return controller.runtimeAvailable ? "Record once, replay any time." : controller.runtimeStatus
        }
    }

    private var statusColor: Color {
        if controller.lastError != nil { return SparkVTheme.warning }
        return controller.phase == .recording ? SparkVTheme.recording : SparkVTheme.textTertiary
    }

    // MARK: Right: recent flows

    @ViewBuilder
    private func flowsColumn(compact: Bool, height: CGFloat) -> some View {
        if controller.phase == .replaying, let progress = controller.progress {
            BRReplayStrip(progress: progress, compact: compact)
        } else if controller.flows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No flows yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SparkVTheme.text)
                Text("Press Record, do the task in the browser window that opens, then Stop. Passwords are never recorded.")
                    .font(.system(size: 10))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(compact ? 3 : 4)
            }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(controller.flows.prefix(8)) { flow in
                        BRFlowChip(flow: flow, isBusy: controller.isBusy, compact: compact,
                                   height: max(44, min(76, height - 6))) {
                            controller.replay(flowID: flow.id)
                        } onOpen: {
                            controller.selectedFlowID = flow.id
                            controller.openWindow()
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

private struct BRReplayStrip: View {
    let progress: BRReplayProgress
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack {
                Text(progress.flowName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Spacer()
                Text("\(progress.position ?? 0)/\(progress.totalSteps)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(SparkVTheme.textSecondary)
                if progress.rows > 1 {
                    Text("Row \(progress.row + 1)/\(progress.rows)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                if progress.healedCount > 0 {
                    Label("\(progress.healedCount) healed", systemImage: "bandage")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SparkVTheme.warning)
                }
            }
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(SparkVTheme.accent)
            Text(progress.lastMessage ?? progress.currentTitle)
                .font(.system(size: 10))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(compact ? 1 : 2)
        }
    }
}

private struct BRFlowChip: View {
    let flow: BRFlow
    let isBusy: Bool
    var compact = false
    var height: CGFloat = 76
    let onPlay: () -> Void
    let onOpen: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(flow.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(compact ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text(BRTemplate.stepCount(flow.steps.count))
                    .font(.system(size: 9.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
                if !flow.variables.isEmpty {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 8.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                Spacer()
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(SparkVTheme.accent.opacity(isBusy ? 0.3 : 1)))
                }
                .buttonStyle(SparkVPressStyle())
                .disabled(isBusy)
                .help("Replay")
            }
        }
        .padding(compact ? 6 : 8)
        .frame(width: 118, height: height)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .fill(hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .strokeBorder(hover.isOn ? SparkVTheme.choose(apple: Color.white.opacity(0.18), sparkv: SparkVTheme.brandRed.opacity(0.45)) : SparkVTheme.stroke)
        )
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .contentShape(Rectangle())
        .onHover { hover.isOn = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("Replay", action: onPlay).disabled(isBusy)
            Button("Edit…", action: onOpen)
        }
    }
}

struct BRCompactButton: View {
    let symbol: String
    let title: String?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, title == nil ? 8 : 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(tint))
            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(tint == SparkVTheme.recording || tint == SparkVTheme.accent ? Color.clear : SparkVTheme.stroke))
        }
        .buttonStyle(SparkVPressStyle())

    }
}

/// Same tab, reading the controller from the environment
/// (`.environmentObject(browserRecorder)` on the notch root view).
struct BrowserRecorderTab: View {
    @EnvironmentObject private var controller: BrowserRecorderController

    var body: some View {
        BrowserRecorderTabView(controller: controller)
    }
}
