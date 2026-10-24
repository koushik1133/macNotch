import SwiftUI

/// The UI audit tab inside the expanded drawer (~508×114 pt, dark): URL,
/// mode, Start/Stop, progress or the last report's summary, and the report
/// and "P" (copy fix prompt) buttons. The full window has everything else.
/// Needs `.environmentObject(uiAuditController)`.
struct UIAuditTabView: View {
    @EnvironmentObject private var audit: UIAuditController

    var body: some View {
        // The 160 pt drawer has room for the summary; the default one doesn't.
        ViewThatFits(in: .vertical) {
            content(showSummary: true)
            content(showSummary: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 2)
    }

    private var showsSummaryRow: Bool { !audit.isRunning && !audit.summaryText.isEmpty }

    private func content(showSummary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(audit.isRunning ? LabsTint.feature : SparkVTheme.textSecondary)
                    .frame(width: 16)
                TextField("Your site, e.g. localhost:3000", text: $audit.urlText)
                    .textFieldStyle(.plain)
                    .font(SparkVTheme.body(11))
                    .foregroundStyle(SparkVTheme.text)
                    .onSubmit { if !audit.isRunning { audit.runAudit() } }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .labsFieldWell()
                    .disabled(audit.isRunning)
                Menu {
                    ForEach(UIAuditMode.allCases) { mode in
                        Button {
                            audit.mode = mode
                        } label: {
                            if audit.mode == mode { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
                        }
                    }
                } label: {
                    Text(audit.mode.shortLabel)
                        .font(SparkVTheme.caption())
                        .foregroundStyle(SparkVTheme.text)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .fixedSize()
                .disabled(audit.isRunning)
                .help(audit.mode.detail)
                startStop
                iconButton("macwindow", help: "Open the UI audit window") { audit.showWindow() }
            }

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(audit.progressText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(statusTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(audit.progressText)
                Spacer(minLength: 4)
                if audit.phase == .running {
                    textButton("Take over") { audit.pauseAudit() }
                        .help("Pause between actions so you can use the browser window")
                } else if audit.phase == .paused {
                    textButton("Resume") { audit.resumeAudit() }
                }
            }

            HStack(spacing: 6) {
                if audit.isRunning, !audit.currentStep.isEmpty {
                    Text(audit.currentStep)
                        .font(.system(size: 9.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    UIAuditCountChips(counts: counts, compact: true)
                    if showsSummaryRow, !showSummary, counts.isEmpty {
                        Text(audit.summaryText)
                            .font(.system(size: 9.5))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if audit.lastReport != nil {
                    textButton("Report") { audit.openReport() }
                        .help("Open report.html")
                }
                UIAuditPromptButton(controller: audit, size: 18)
            }

            if showSummary, showsSummaryRow {
                Text(audit.summaryText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(audit.summaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var startStop: some View {
        Button {
            audit.isRunning ? audit.stopAudit() : audit.runAudit()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: audit.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 9, weight: .bold))
                Text(audit.isRunning ? "Stop" : "Start")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(audit.isRunning ? SparkVTheme.text : Color.white)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(audit.isRunning ? SparkVTheme.surfaceHover : SparkVTheme.accent))
            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(audit.isRunning ? SparkVTheme.stroke : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .disabled(audit.phase == .stopping || (!audit.isRunning && audit.normalizedURL == nil))
        .help(audit.isRunning ? "Stop the audit (a partial report is written)" : "Audit this site in a visible browser window. \(audit.submissionPolicyText).")
    }

    private var counts: [UIAuditSeverity: Int] {
        var out: [UIAuditSeverity: Int] = [:]
        for f in audit.findings { out[f.severityLevel, default: 0] += 1 }
        return out
    }

    private var statusColor: Color {
        switch audit.phase {
        case .idle: return SparkVTheme.textTertiary
        case .starting, .running: return LabsTint.feature
        case .paused, .stopping: return SparkVTheme.warning
        case .finished: return SparkVTheme.success
        case .failed: return SparkVTheme.destructive
        }
    }

    /// Progress text: neutral while idle or running, coloured only for a result.
    private var statusTextColor: Color {
        switch audit.phase {
        case .idle, .starting, .running: return SparkVTheme.textSecondary
        case .paused, .stopping: return SparkVTheme.warning
        case .finished: return SparkVTheme.success
        case .failed: return LabsTint.errorText
        }
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .help(help)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(SparkVTheme.surface))
                .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
    }
}
