import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Bands under the closed notch (about 380×30 pt on black): download progress,
// a finished download with its suggested folder, and an auto-sort notice.

/// Follows the look. Apple: system-blue progress (as in Safari and Finder),
/// purple for AI picks. SparkV Red: red progress and accents. Green only for "done".
enum DownloadsPalette {
    static var accent: Color { SparkVTheme.accent }
    static var done: Color { SparkVTheme.success }
    static var ai: Color { SparkVTheme.isApple ? Color.purple : SparkVTheme.red }
    static var secondary: Color { SparkVTheme.textSecondary }
    static let track = Color.white.opacity(0.14)
}

/// Finder's icon for a file, or for its type while it's still downloading.
@MainActor
enum DownloadsIcons {
    private static var byType: [String: NSImage] = [:]

    static func icon(for item: DownloadItem) -> NSImage {
        if !item.isActive, FileManager.default.fileExists(atPath: item.url.path) {
            return NSWorkspace.shared.icon(forFile: item.url.path)
        }
        let ext = item.fileExtension
        if let cached = byType[ext] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        byType[ext] = icon
        return icon
    }
}

/// Small determinate ring (indeterminate: a rotating quarter arc).
struct DownloadsRing: View {
    @ObservedObject private var energy = SparkVEnergy.shared
    let fraction: Double?
    var lineWidth: CGFloat = 2.5
    var tint: Color = DownloadsPalette.accent

    var body: some View {
        ZStack {
            Circle().stroke(DownloadsPalette.track, lineWidth: lineWidth)
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                // Unknown total: a spinning quarter arc, so it doesn't read as 25%.
                // Reduce Motion: a still quarter arc (paused at rest).
                TimelineView(.animation(minimumInterval: energy.frameInterval(1.0 / 20), paused: energy.pausesDecoration || SparkVMotion.reduceMotion)) { context in
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees((context.date.timeIntervalSinceReferenceDate * 300).truncatingRemainder(dividingBy: 360)))
                }
            }
            Image(systemName: "arrow.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(SparkVTheme.text)
        }
    }
}

/// Thin capsule progress bar; nil fraction draws a faint full track with a stripe.
struct DownloadsBar: View {
    let fraction: Double?
    var height: CGFloat = 4
    var tint: Color = DownloadsPalette.accent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(DownloadsPalette.track)
                if let fraction {
                    Capsule().fill(tint).frame(width: max(height, proxy.size.width * fraction))
                } else {
                    Capsule().fill(tint.opacity(0.55)).frame(width: proxy.size.width * 0.3)
                }
            }
        }
        .frame(height: height)
    }
}

/// In-flight downloads: the newest one's name, a bar and "42% · 3 MB/s · 12 s left".
/// Several at once show combined progress and "+2".
struct DownloadsProgressBand: View {
    @ObservedObject var controller: DownloadsController

    var body: some View {
        let active = controller.activeItems
        let summary = Self.summary(active)
        HStack(spacing: 8) {
            DownloadsRing(fraction: summary.fraction)
                .frame(width: 16, height: 16)
            HStack(spacing: 4) {
                Text(summary.title)
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
            DownloadsBar(fraction: summary.fraction, tint: summary.paused ? SparkVTheme.warning : DownloadsPalette.accent)
                .frame(width: 64)
            Text(summary.detail)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(DownloadsPalette.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Downloading \(summary.title), \(summary.detail)")
    }

    struct Summary: Equatable {
        let title: String
        let fraction: Double?
        let detail: String
        let paused: Bool
    }

    static func summary(_ active: [DownloadItem]) -> Summary {
        guard let newest = active.max(by: { $0.startedAt < $1.startedAt }) else {
            return Summary(title: "Downloads", fraction: nil, detail: "", paused: false)
        }
        guard active.count > 1 else {
            return Summary(title: newest.name, fraction: newest.fraction, detail: DownloadFormat.progressLine(newest),
                           paused: newest.phase == .paused)
        }
        let received = active.reduce(Int64(0)) { $0 + $1.bytesReceived }
        let speed = active.reduce(0) { $0 + $1.bytesPerSecond }
        let totals = active.compactMap(\.totalBytes)
        var parts: [String] = []
        var fraction: Double?
        if totals.count == active.count, case let total = totals.reduce(0, +), total > 0 {
            fraction = min(1, Double(received) / Double(total))
            parts.append(DownloadFormat.percent(fraction!))
            // Several at once: percent and time left only, so the name keeps its room.
            if speed > 1 { parts.append(DownloadFormat.eta(Double(max(0, total - received)) / speed)) }
        } else {
            parts.append(DownloadFormat.bytes(received))
            if speed > 1 { parts.append(DownloadFormat.speed(speed)) }
        }
        return Summary(title: newest.name, fraction: fraction, detail: parts.joined(separator: " · "),
                       paused: active.allSatisfy { $0.phase == .paused })
    }
}

/// "✓ report.pdf  → Documents": hover opens the drawer, where the buttons are.
struct DownloadsDoneBand: View {
    @ObservedObject var controller: DownloadsController
    let itemID: UUID

    var body: some View {
        let item = controller.item(itemID)
        let suggestion = controller.suggestions[itemID]
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DownloadsPalette.done)
            Text(item?.name ?? "Download finished")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 6)
            if let item, item.move != nil {
                Label("Sorted", systemImage: "folder.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DownloadsPalette.secondary)
            } else if let suggestion {
                HStack(spacing: 3) {
                    Image(systemName: suggestion.isAI ? "sparkles" : "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(suggestion.destination.displayName)
                        .lineLimit(1)
                }
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(suggestion.isAI ? DownloadsPalette.ai : SparkVTheme.text)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(SparkVTheme.surfaceHover))
            } else if let item {
                Text(DownloadFormat.detailLine(item))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DownloadsPalette.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// An auto-sort rule moved a file.
struct DownloadsMovedBand: View {
    let name: String
    let folder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DownloadsPalette.accent)
            Text(name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text("Moved to \(folder) · Undo in drawer")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DownloadsPalette.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
