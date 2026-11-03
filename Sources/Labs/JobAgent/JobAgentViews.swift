import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared bits

enum JobAgentStyle {
    // Apple: the per-score and per-status colors the Job Agent had before
    // the sparkv.si restyle. SparkV Red: white, red and status green only.

    static func fitColor(_ value: Int) -> Color {
        let apple = SparkVTheme.isApple
        switch value {
        case 80...: return apple ? Color(red: 0.30, green: 0.85, blue: 0.50) : SparkVTheme.success
        case 65..<80: return apple ? Color(red: 0.55, green: 0.80, blue: 0.35) : SparkVTheme.text
        case 50..<65: return apple ? Color(red: 0.98, green: 0.75, blue: 0.25) : SparkVTheme.warning
        default: return apple ? coral : SparkVTheme.brandRed
        }
    }

    static func statusColor(_ status: JobStatus) -> Color {
        let apple = SparkVTheme.isApple
        switch status {
        case .considering: return SparkVTheme.textSecondary
        case .applied: return apple ? blue : SparkVTheme.text
        case .interview: return apple ? purple : SparkVTheme.brandRed
        case .offer: return SparkVTheme.success
        case .rejected: return apple ? coral : SparkVTheme.textTertiary
        case .ghosted: return Color.white.opacity(apple ? 0.4 : 0.3)
        }
    }

    /// The fit ring / fit bar fill: the score color in Apple, red in SparkV Red.
    static func fitFill(_ value: Int) -> Color {
        SparkVTheme.isApple ? fitColor(value) : SparkVTheme.brandRed
    }

    /// Chip wash for a missing skill.
    static var missingChip: Color { SparkVTheme.choose(apple: coral.opacity(0.22), sparkv: SparkVTheme.accentSoft) }

    static let blue = Color(red: 0.40, green: 0.65, blue: 1.0)
    static let purple = Color(red: 0.75, green: 0.55, blue: 1.0)
    static let coral = Color(red: 0.98, green: 0.45, blue: 0.40)
}

/// Circular fit gauge.
struct JobFitRing: View {
    let value: Int
    var size: CGFloat = 34
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(SparkVTheme.stroke, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, value))) / 100)
                .stroke(JobAgentStyle.fitFill(value), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(value)")
                .font(.system(size: size * 0.34, weight: .bold).monospacedDigit())
                .foregroundStyle(SparkVTheme.text)
        }
        .frame(width: size, height: size)
    }
}

struct JobChip: View {
    let text: String
    var color: Color = SparkVTheme.surfaceHover
    var textColor: Color = SparkVTheme.text

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
            .foregroundStyle(textColor)
    }
}

// MARK: - Band under the notch

/// "Fit 78% · Senior iOS Engineer @ Acme" over "missing: SwiftData, GraphQL".
struct JobAgentBandView: View {
    enum Style { case working, success, failure }

    let title: String
    let subtitle: String?
    let fit: Int?
    let style: Style

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style == .failure ? LabsTint.errorText : SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var leading: some View {
        switch style {
        case .working:
            ProgressView().controlSize(.small).tint(LabsTint.progress)
        case .success:
            if let fit {
                JobFitRing(value: fit, size: 24, lineWidth: 3)
            } else {
                Image(systemName: "briefcase.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(SparkVTheme.text)
            }
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(LabsTint.errorText)
        }
    }
}

// MARK: - Drawer tab (≈508×69 at the default drawer height, dark)

/// Drawer content: the latest captured job (fit ring, missing skills,
/// status, deadline), the agent's current state, and quick actions.
/// Files dropped here go to the Job Agent (resume or screenshots).
struct JobAgentDrawerView: View {
    let controller: JobAgentController
    @StateObject private var dropTarget = ViewFlag()

    var body: some View {
        JobAgentDrawerContent(controller: controller)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(SparkVTheme.accent.opacity(dropTarget.isOn ? 0.8 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget.isOn) { providers in
                JobAgentDrop.load(providers) { urls in route(urls) }
                return true
            }
    }

    private func route(_ urls: [URL]) {
        if let resume = urls.first(where: { JobAgentDrop.resumeExtensions.contains($0.pathExtension.lowercased()) }) {
            controller.importResume(resume)
        } else {
            controller.importScreenshots(urls)
        }
    }
}

/// The drawer's visible part, laid out to fit 508×69 pt.
struct JobAgentDrawerContent: View {
    @ObservedObject var controller: JobAgentController
    @ObservedObject var store: JobStore

    init(controller: JobAgentController) {
        _controller = ObservedObject(wrappedValue: controller)
        _store = ObservedObject(wrappedValue: controller.store)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            latest
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            Rectangle().fill(SparkVTheme.stroke).frame(width: 1, height: 52)
            actions.frame(width: 212, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var latest: some View {
        if let pending = controller.pendingConfirmation, let job = store.job(pending.jobID) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Confirmation found", systemImage: "checkmark.seal")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                Text("Mark \(job.title) @ \(job.company) as applied?")
                    .font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(1)
                HStack(spacing: 6) {
                    smallButton("Mark applied", "checkmark") { controller.confirmPending() }
                    smallButton("Not this job", "xmark") { controller.dismissPending() }
                }
            }
        } else if let job = controller.activeJob {
            HStack(alignment: .center, spacing: 10) {
                if let fit = job.fit {
                    JobFitRing(value: fit.overall, size: 40, lineWidth: 4)
                } else {
                    Image(systemName: "briefcase").font(.system(size: 20)).foregroundStyle(SparkVTheme.textSecondary).frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(SparkVTheme.text).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(job.company).font(.system(size: 11, weight: .medium)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(1)
                        Label(job.status.rawValue, systemImage: job.status.symbol)
                            .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            .foregroundStyle(JobAgentStyle.statusColor(job.status))
                            .layoutPriority(1)
                        if let days = job.daysUntilDeadline(), days <= 14 {
                            Label(days == 0 ? "today" : "\(days)d", systemImage: "calendar.badge.exclamationmark")
                                .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                .foregroundStyle(days <= 3 ? SparkVTheme.warning : SparkVTheme.textSecondary)
                                .help(days == 0 ? "Applications close today" : "Applications close in \(days) day\(days == 1 ? "" : "s")")
                                .layoutPriority(1)
                        }
                    }
                    if hasStatus {
                        statusLine
                    } else if let fit = job.fit, !fit.missingSkills.isEmpty {
                        HStack(spacing: 4) {
                            Text("missing").font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                            ForEach(fit.missingSkills.prefix(3), id: \.self) { skill in
                                JobChip(text: skill, color: JobAgentStyle.missingChip)
                            }
                        }
                    } else if job.fit == nil {
                        Text("Add your resume to see your fit").font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                    } else {
                        Text("No missing required skills").font(.system(size: 10)).foregroundStyle(SparkVTheme.textTertiary)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text("Job Agent").font(.system(size: 13, weight: .semibold)).foregroundStyle(SparkVTheme.text)
                if hasStatus {
                    statusLine
                } else {
                    Text(controller.hasResume
                         ? "Hold fn + ⌃ on a job posting, then release. Press again on the confirmation page after you apply."
                         : "Add your resume first, then hold fn + ⌃ on a job posting.")
                        .font(.system(size: 11)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(2)
                }
            }
        }
    }

    /// Something worth showing instead of the missing-skills row.
    private var hasStatus: Bool {
        switch controller.phase {
        case .working, .failed: true
        default: controller.browserNeedingAccess != nil
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch controller.phase {
        case .working(let text):
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(LabsTint.progress)
                Text(text).font(.system(size: 10)).foregroundStyle(SparkVTheme.textSecondary).lineLimit(1)
            }
        case .failed(let text):
            Text(text).font(.system(size: 10)).foregroundStyle(LabsTint.errorText).lineLimit(2)
        default:
            if let browser = controller.browserNeedingAccess {
                Button("Allow reading the URL from \(browser.name)") { controller.requestBrowserAccess() }
                    .buttonStyle(SparkVPressStyle()).font(.system(size: 10, weight: .semibold)).foregroundStyle(SparkVTheme.link)
                    .lineLimit(1)
            }
        }
    }

    private var actions: some View {
        let stats = store.analytics
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                stat("\(stats.weeks.last?.count ?? 0)", "this week")
                stat("\(store.jobs.filter { $0.status == .applied }.count)", "awaiting")
                stat(stats.totalApplied == 0 ? "–" : "\(Int((stats.responseRate * 100).rounded()))%", "replies")
            }
            HStack(spacing: 4) {
                smallButton("Tracker", "tablecells") { controller.showWindow(tab: .tracker) }
                smallButton("CV", controller.hasResume ? "doc.text" : "doc.badge.plus") { controller.showWindow(tab: .resume) }
                    .help(controller.hasResume ? "Your resume" : "Add your resume")
                smallButton("Capture", "viewfinder") { controller.captureNow() }
                    .disabled(controller.isBusy)
                    .help("Capture the front window (or hold fn + ⌃)")
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(SparkVTheme.text)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(SparkVTheme.textTertiary)
        }
    }

    private func smallButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Capsule().fill(SparkVTheme.surface))
                .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                .foregroundStyle(SparkVTheme.text)
        }
        .buttonStyle(SparkVPressStyle())
    }
}

// MARK: - Drops

enum JobAgentDrop {
    /// Dropped files with these extensions are treated as a resume.
    static let resumeExtensions: Set<String> = ["pdf", "docx", "doc", "txt", "rtf", "md"]
    /// Screenshots (posting, confirmation page or status email).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp", "bmp"]

    /// File URLs from drag providers, delivered on the main actor.
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let box = URLCollector(expected: providers.count, completion: completion)
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                box.add(url)
            }
        }
    }

    private final class URLCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        private var remaining: Int
        private let completion: @MainActor ([URL]) -> Void

        init(expected: Int, completion: @escaping @MainActor ([URL]) -> Void) {
            remaining = expected
            self.completion = completion
        }

        func add(_ url: URL?) {
            lock.lock()
            if let url { urls.append(url) }
            remaining -= 1
            let done = remaining == 0
            let result = urls
            lock.unlock()
            guard done else { return }
            let completion = self.completion
            Task { @MainActor in completion(result) }
        }
    }
}
