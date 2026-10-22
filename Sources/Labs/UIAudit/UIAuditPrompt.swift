import Foundation

/// Builds the "P" prompt: a self-contained brief a coding agent (Claude Code,
/// Cursor, Codex) can act on without seeing the app. Deterministic: findings
/// are grouped by page, ordered by severity, and each carries the selector,
/// a Playwright locator, repro steps, expected vs actual, the fix and
/// checkable acceptance criteria.
enum UIAuditPromptBuilder {
    /// Findings included in full; the rest are counted and pointed to.
    static let maxFindings = 60
    private static let fieldLimit = 400

    static func build(report: UIAuditReport) -> String {
        let file = report.file
        let meta = file.meta
        let issues = file.findings.filter(\.isIssue).sorted(by: order)
        let included = Array(issues.prefix(maxFindings))
        let omitted = issues.count - included.count

        var out: [String] = []
        out.append("# Fix the frontend issues found by an automated UI audit")
        out.append("")
        out.append("You are working in the codebase that serves \(meta.startURL). An automated audit (Playwright + axe-core, mode \"\(meta.modeLabel ?? meta.mode ?? "full")\", \(file.pages.count) page\(file.pages.count == 1 ? "" : "s")\(meta.startedAt.map { ", \($0)" } ?? "")) found the \(issues.count) issue\(issues.count == 1 ? "" : "s") below. Fix them in the source (components, templates, styles, validation and API code). Do not special-case the audit or the test data.")
        out.append("")
        out.append("## Ground rules")
        out.append("- Locate each element with its CSS selector or Playwright locator, then fix the component that renders it (generated selectors such as `div:nth-of-type(2) > a` describe position, not source names).")
        out.append("- Make the smallest change that satisfies every acceptance criterion; keep the visual design and copy unless the finding is about them.")
        out.append("- Validation fixes must exist client-side (visible, programmatically associated error) and server-side.")
        out.append("- Do not delete features to make a finding disappear (a dead button gets wired up or removed only if it is genuinely unused).")
        out.append("- When the project has tests, add a regression test per fixed issue (the Playwright locators below can be pasted into tests).")
        out.append("")
        out.append("## Context")
        let viewports = (meta.viewports ?? []).map { "\($0.width)×\($0.height)" }.joined(separator: ", ")
        out.append("- Viewports: \(viewports.isEmpty ? "1440×900 desktop, 390×844 mobile" : viewports)")
        if let origins = meta.allowedOrigins, !origins.isEmpty { out.append("- Origins audited: \(origins.joined(separator: ", "))") }
        if let policy = meta.submitPolicy { out.append("- Form submission during the audit: \(policy)") }
        out.append("- Test data was synthetic (test+…@example.com, fictional phone numbers, generated passwords).")
        if meta.stopped == true { out.append("- The run stopped early (\(meta.stopReason ?? "stopped")), so other pages may have more issues.") }
        out.append("- Pages: " + file.pages.map { page in
            let status = page.status.map { " [\($0)]" } ?? ""
            return UIAuditURL.shortPath(page.url) + status
        }.joined(separator: ", "))
        out.append("")
        out.append("## Issues (\(included.count)\(omitted > 0 ? " of \(issues.count)" : ""), grouped by page, most severe first)")

        var number = 0
        for (page, group) in groupedByPage(included) {
            out.append("")
            out.append("### Page \(UIAuditURL.shortPath(page)) — \(page)")
            for f in group {
                number += 1
                out.append("")
                out.append("#### \(number). [\(f.severity.uppercased())] \(clean(f.title)) — `\(f.ruleLabel)` (\(f.id))")
                if let selector = nonEmpty(f.selector) {
                    var line = "- Element: `\(clean(selector))`"
                    if let locator = nonEmpty(f.locator) { line += " · `\(clean(locator))`" }
                    out.append(line)
                }
                if let viewport = nonEmpty(f.viewport) { out.append("- Viewport: \(viewport)") }
                if let also = f.alsoOn, !also.isEmpty {
                    out.append("- Also on: " + also.prefix(8).map(UIAuditURL.shortPath).joined(separator: ", ") + (also.count > 8 ? " (+\(also.count - 8) more)" : ""))
                }
                if let steps = f.steps, !steps.isEmpty {
                    out.append("- Steps to reproduce:")
                    for (i, step) in steps.enumerated() { out.append("  \(i + 1). \(clean(step))") }
                }
                if let expected = nonEmpty(f.expected) { out.append("- Expected: \(clean(expected))") }
                if let actual = nonEmpty(f.actual) { out.append("- Actual: \(clean(actual))") }
                if let evidence = nonEmpty(f.evidence) { out.append("- Evidence: \(clean(evidence))") }
                if let fix = nonEmpty(f.fix) { out.append("- Suggested fix: \(clean(fix))") }
                if let help = nonEmpty(f.helpUrl) { out.append("- Reference: \(help)") }
                let criteria = (f.acceptance ?? []).filter { !$0.isEmpty }
                out.append("- Acceptance criteria:")
                if criteria.isEmpty {
                    out.append("  - [ ] \(clean(f.expected ?? "The issue no longer reproduces with the steps above."))")
                } else {
                    for c in criteria { out.append("  - [ ] \(clean(c))") }
                }
                out.append("  - [ ] The steps to reproduce above no longer show the problem.")
            }
        }

        if omitted > 0 {
            out.append("")
            out.append("\(omitted) lower-severity issue\(omitted == 1 ? " is" : "s are") not listed here; see \(report.markdownURL.path).")
        }
        out.append("")
        out.append("## Done when")
        out.append("- [ ] Every acceptance criterion above passes at both desktop and mobile widths.")
        out.append("- [ ] Re-running the UI audit on \(meta.startURL) no longer reports: \(included.map(\.id).joined(separator: ", ")).")
        out.append("- [ ] No new console errors, failed requests or accessibility violations were introduced.")
        out.append("- [ ] Reply with a short list: issue id → file(s) changed → how it was verified.")
        return out.joined(separator: "\n")
    }

    static func order(_ a: UIAuditFinding, _ b: UIAuditFinding) -> Bool {
        if a.severityLevel != b.severityLevel { return a.severityLevel < b.severityLevel }
        if a.page != b.page { return a.page < b.page }
        return a.id < b.id
    }

    /// Pages ordered by their most severe finding, then by URL.
    static func groupedByPage(_ findings: [UIAuditFinding]) -> [(String, [UIAuditFinding])] {
        var groups: [String: [UIAuditFinding]] = [:]
        for f in findings { groups[f.page, default: []].append(f) }
        return groups.map { ($0.key, $0.value.sorted(by: order)) }.sorted { lhs, rhs in
            let l = lhs.1.first?.severityLevel.rank ?? 9, r = rhs.1.first?.severityLevel.rank ?? 9
            return l != r ? l < r : lhs.0 < rhs.0
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func clean(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "`", with: "'")
        return flat.count > fieldLimit ? String(flat.prefix(fieldLimit)) + "…" : flat
    }
}

/// Short summary of a report: always a deterministic one; optionally the
/// on-device model (Apple Intelligence) or, only with the user's opt-in, Groq.
enum UIAuditSummarizer {
    /// Rule ids grouped into themes for the deterministic summary.
    private static let themes: [(String, @Sendable (UIAuditFinding) -> Bool)] = [
        ("form validation gaps", { ["field-accepts-invalid", "validation-no-feedback", "empty-required-submitted", "required-marker-not-enforced", "rejects-valid-data", "submit-blocked-valid"].contains($0.rule) }),
        ("form labelling problems", { ["field-no-accessible-name", "placeholder-as-label", "placeholder-misleading", "placeholder-empty", "placeholder-pattern-mismatch", "format-hint-missing", "required-not-indicated", "label-for-missing-target", "autocomplete-missing", "wrong-input-type", "validation-vague-message", "validation-message-not-associated"].contains($0.rule) }),
        ("accessibility violations (axe)", { $0.rule == "axe" }),
        ("keyboard/focus problems", { $0.category == "keyboard" }),
        ("layout problems (overflow, clipped/overlapping text, tap targets)", { $0.category == "layout" }),
        ("broken links or pages", { $0.category == "link" || $0.rule == "page-http-error" || $0.rule == "page-load-failed" }),
        ("console errors", { $0.category == "console" }),
        ("failed requests / server errors", { $0.rule == "request-failed" || $0.rule == "submit-server-error" }),
        ("dead buttons", { $0.rule == "dead-button" }),
        ("image problems", { $0.category == "image" }),
    ]

    static func deterministic(_ report: UIAuditReport) -> String {
        let issues = report.file.findings.filter(\.isIssue)
        guard !issues.isEmpty else {
            return "No issues found on \(report.file.pages.count) page(s). Info items: \(report.file.findings.count)."
        }
        var lines = ["\(report.oneLine)."]
        var parts: [String] = []
        for (name, match) in themes {
            let hits = issues.filter(match)
            guard !hits.isEmpty else { continue }
            let pages = Set(hits.map { UIAuditURL.shortPath($0.page) }).sorted()
            parts.append("\(hits.count) \(name) on \(pages.prefix(3).joined(separator: ", "))\(pages.count > 3 ? " +\(pages.count - 3)" : "")")
        }
        if !parts.isEmpty { lines.append("Main themes: " + parts.prefix(5).joined(separator: "; ") + ".") }
        let top = issues.sorted(by: UIAuditPromptBuilder.order).prefix(3)
        lines.append("Fix first: " + top.map { "\($0.title) (\(UIAuditURL.shortPath($0.page)))" }.joined(separator: "; ") + ".")
        return lines.joined(separator: " ")
    }

    /// Compact, bounded description of the findings used as model input.
    static func digest(_ report: UIAuditReport, limit: Int) -> String {
        var text = "Site: \(report.file.meta.startURL)\n\(report.oneLine)\n"
        for f in report.file.findings.filter(\.isIssue).sorted(by: UIAuditPromptBuilder.order) {
            let line = "- [\(f.severity)] \(f.title) — \(UIAuditURL.shortPath(f.page))\((f.alsoOn?.isEmpty ?? true) ? "" : " (+\(f.alsoOn!.count) pages)")\n"
            if text.count + line.count > limit { break }
            text += line
        }
        return text
    }

    private static let task = "Summarize this website audit for the site owner in 3-5 sentences: the overall state, the biggest themes, and what to fix first. Plain text, no lists, no preamble."

    /// Groq when allowed and a key exists; else on-device; else deterministic.
    /// Returns the text and which path produced it.
    static func summarize(_ report: UIAuditReport) async -> (text: String, source: String) {
        let fallback = deterministic(report)
        if let key = UIAuditSettings.groqKeyIfAllowed() {
            do {
                let (text, model) = try await TrayAIGroq(key: key).transform(task: task, text: digest(report, limit: 12_000), maxTokens: 500)
                let cleaned = TrayAIText.clean(text)
                if !cleaned.isEmpty { return (cleaned, "Groq \(model)") }
            } catch {
                AppLog.log("UI audit: Groq summary failed: \(error.localizedDescription)")
            }
        }
        if TrayAIOnDevice.unavailableReason == nil {
            do {
                let text = try await TrayAIOnDevice.respond(
                    instructions: "You summarize website audit results for the site's owner. Be concrete and brief.",
                    prompt: digest(report, limit: 5000) + "\n\nTask: " + task,
                    maxTokens: 300, timeout: 30, permissive: true
                )
                let cleaned = TrayAIText.clean(text)
                if !cleaned.isEmpty { return (cleaned, "On-device (Apple Intelligence)") }
            } catch {
                AppLog.log("UI audit: on-device summary failed: \(error.localizedDescription)")
            }
        }
        return (fallback, "Rule-based")
    }
}
