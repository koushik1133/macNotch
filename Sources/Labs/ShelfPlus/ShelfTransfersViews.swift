import AppKit
import SwiftUI

// Copy / send progress: the band under the closed notch, the finished
// band, and the card in the Downloads drawer (with Pause, Cancel, Reveal).

/// "Copying Holiday.mov to Backup · 42% · 2 min left" (several: "+2").
struct ShelfTransfersBand: View {
    @ObservedObject var monitor: ShelfTransfersMonitor

    var body: some View {
        let active = monitor.activeTransfers
        let lead = active.first
        let summary = Self.summary(active)
        HStack(spacing: 8) {
            ShelfTransferRing(fraction: summary.fraction,
                              tint: lead?.phase == .paused ? SparkVTheme.warning : ShelfTransferStyle.tint(lead?.kind),
                              symbol: lead?.kind == .localSend ? "arrow.up" : "plus")
                .frame(width: 16, height: 16)
            HStack(spacing: 4) {
                Text(lead.map { "\($0.kind.verb) \($0.name)" } ?? "Copying")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if active.count > 1 {
                    Text("+\(active.count - 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(SparkVTheme.surfaceHover))
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            DownloadsBar(fraction: summary.fraction, tint: ShelfTransferStyle.tint(lead?.kind))
                .frame(width: 56)
            Text(summary.detail)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lead?.title ?? "Copying"), \(summary.detail)")
    }

    struct Summary: Equatable {
        let fraction: Double?
        let detail: String
    }

    static func summary(_ active: [ShelfTransfer]) -> Summary {
        guard let first = active.first else { return Summary(fraction: nil, detail: "") }
        guard active.count > 1 else {
            return Summary(fraction: first.fraction, detail: first.message.map { first.completed == 0 ? $0 : first.progressLine } ?? first.progressLine)
        }
        let totals = active.map(\.total)
        let done = active.reduce(Int64(0)) { $0 + $1.completed }
        let speed = active.reduce(0) { $0 + $1.bytesPerSecond }
        guard totals.allSatisfy({ $0 > 0 }) else { return Summary(fraction: nil, detail: DownloadFormat.bytes(done)) }
        let total = totals.reduce(0, +)
        let fraction = min(1, Double(done) / Double(total))
        var parts = [DownloadFormat.percent(fraction)]
        if speed > 1 { parts.append(DownloadFormat.eta(Double(max(0, total - done)) / speed)) }
        return Summary(fraction: fraction, detail: parts.joined(separator: " · "))
    }
}

/// "✓ Copied to Backup  Holiday.mov".
struct ShelfTransferDoneBand: View {
    let transfer: ShelfTransfer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SparkVTheme.success)
            Text(transfer.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(transfer.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Small determinate ring with a glyph for what's happening (copy: +,
/// send: ↑); unknown totals spin a quarter arc.
struct ShelfTransferRing: View {
    @ObservedObject private var energy = SparkVEnergy.shared
    let fraction: Double?
    var lineWidth: CGFloat = 2.5
    let tint: Color
    let symbol: String

    var body: some View {
        ZStack {
            Circle().stroke(DownloadsPalette.track, lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                TimelineView(.animation(minimumInterval: energy.frameInterval(1.0 / 20), paused: SparkVMotion.reduceMotion || energy.pausesDecoration)) { context in
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees((context.date.timeIntervalSinceReferenceDate * 300).truncatingRemainder(dividingBy: 360)))
                }
            }
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(SparkVTheme.text)
        }
        .accessibilityHidden(true)
    }
}

enum ShelfTransferStyle {
    /// Apple: Finder blue for copies, LocalSend teal for sends. SparkV Red: the accent.
    static func tint(_ kind: ShelfTransfer.Kind?) -> Color {
        guard SparkVTheme.isApple else { return SparkVTheme.red }
        return kind == .localSend ? NearbyStyle.tint : SparkVTheme.accent
    }
}

/// A transfer in the Downloads drawer (same size as a download card).
struct ShelfTransferCard: View {
    @ObservedObject var monitor: ShelfTransfersMonitor
    let transfer: ShelfTransfer

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(ShelfTransferStyle.tint(transfer.kind).opacity(SparkVTheme.isApple ? 0.22 : 0.16))
                    Image(systemName: transfer.kind.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ShelfTransferStyle.tint(transfer.kind))
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transfer.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(transfer.title)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(transfer.phase == .failed ? SparkVTheme.warning : SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if transfer.isActive {
                VStack(alignment: .leading, spacing: 3) {
                    DownloadsBar(fraction: transfer.fraction, tint: transfer.phase == .paused ? SparkVTheme.warning : ShelfTransferStyle.tint(transfer.kind))
                    Text(transfer.message.map { transfer.completed == 0 ? $0 : transfer.progressLine } ?? transfer.progressLine)
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
            } else {
                Text(finishedLine)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(SparkVTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                if transfer.isActive {
                    if transfer.canPause {
                        DownloadsIconButton(symbol: transfer.phase == .paused ? "play.fill" : "pause.fill",
                                            help: transfer.phase == .paused ? "Resume" : "Pause", enabled: true) {
                            monitor.togglePause(transfer.id)
                        }
                    }
                    DownloadsIconButton(symbol: "xmark", help: "Cancel", enabled: transfer.canCancel) {
                        monitor.cancel(transfer.id)
                    }
                } else {
                    if transfer.url != nil {
                        DownloadsIconButton(symbol: "magnifyingglass", help: "Show in Finder", enabled: true) {
                            monitor.reveal(transfer.id)
                        }
                    }
                    DownloadsIconButton(symbol: "xmark.circle", help: "Remove from List", enabled: true) {
                        monitor.forget(transfer.id)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(7)
        .background(shape.fill(SparkVTheme.surface))
        .overlay(shape.strokeBorder(transfer.isActive ? ShelfTransferStyle.tint(transfer.kind).opacity(0.45) : SparkVTheme.stroke, lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(transfer.title), \(transfer.name)")
    }

    private var finishedLine: String {
        var parts: [String] = []
        if transfer.total > 0 { parts.append(DownloadFormat.bytes(transfer.total)) }
        if let finished = transfer.finishedAt {
            parts.append(finished.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}
