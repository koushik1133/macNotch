import AppKit
import SwiftUI

/// Follows the look (computed, so a switch takes effect). Apple: a graphite
/// Spotlight card, system-blue filter, selection and Ask, each source in its
/// own color. SparkV Red: near-black card and one signal red.
enum UniversalSearchPalette {
    static var card: Color { SparkVTheme.background }
    static var stroke: Color { SparkVTheme.stroke }
    static let divider = Color.white.opacity(0.07)
    static var selection: Color { SparkVTheme.accentSoft }
    static var secondary: Color { SparkVTheme.textSecondary }
    static var tertiary: Color { SparkVTheme.textTertiary }
    static var accent: Color { SparkVTheme.accent }
    static var ask: Color { SparkVTheme.accent }
}

/// The floating search panel (Raycast/Spotlight layout): field, source and
/// date filters, grouped results or the Ask answer, and an action bar.
struct UniversalSearchPanelView: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        VStack(spacing: 0) {
            UniversalSearchHeader(controller: controller)
            UniversalSearchFilterBar(controller: controller)
            Rectangle().fill(UniversalSearchPalette.divider).frame(height: 1)
            Group {
                if controller.isRecordingShortcut {
                    UniversalSearchRecordingView(controller: controller)
                } else if controller.mode == .ask {
                    UniversalSearchAskView(controller: controller)
                } else if controller.sections.isEmpty {
                    UniversalSearchEmptyView(controller: controller)
                } else {
                    UniversalSearchResultsList(controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(UniversalSearchPalette.divider).frame(height: 1)
            UniversalSearchFooter(controller: controller)
        }
        .frame(width: UniversalSearchPanelMetrics.cardSize.width, height: UniversalSearchPanelMetrics.cardSize.height)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(UniversalSearchPalette.card)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        )
        .background(alignment: .topTrailing) {
            SparkVTheme.glow
                .frame(width: 360, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(UniversalSearchPalette.stroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(UniversalSearchPanelMetrics.margin)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Header

private struct UniversalSearchHeader: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.mode == .ask ? "sparkles" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(controller.mode == .ask ? UniversalSearchPalette.ask : UniversalSearchPalette.secondary)
                .frame(width: 22)
            UniversalSearchField(controller: controller, fontSize: 19, placeholder: controller.placeholder)
                .frame(height: 26)
            if controller.isSearching {
                Circle()
                    .fill(UniversalSearchPalette.accent.opacity(0.8))
                    .frame(width: 5, height: 5)
                    .help("Searching")
            }
            UniversalSearchMicButton(controller: controller, size: 28)
            UniversalSearchAskToggle(controller: controller)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

struct UniversalSearchMicButton: View {
    @ObservedObject var controller: UniversalSearchController
    var size: CGFloat
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            controller.toggleDictation()
        } label: {
            Image(systemName: controller.isDictating ? "waveform" : "mic.fill")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(controller.isDictating ? Color.white : UniversalSearchPalette.secondary)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(controller.isDictating ? SparkVTheme.recording : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
                )
                .contentShape(Circle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(controller.isDictating ? "Stop dictating" : "Dictate your search")
        .accessibilityLabel(controller.isDictating ? "Stop dictating" : "Dictate search")
    }
}

private struct UniversalSearchAskToggle: View {
    @ObservedObject var controller: UniversalSearchController
    @StateObject private var hover = ViewFlag()

    var body: some View {
        let on = controller.mode == .ask
        Button {
            controller.toggleAsk()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                Text("Ask").font(.system(size: 12, weight: .semibold))
                UniversalSearchKeyCap(text: "⇥", dim: !on)
            }
            .foregroundStyle(on ? Color.white : UniversalSearchPalette.secondary)
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .frame(height: 26)
            .background(
                Capsule().fill(on ? SparkVTheme.red : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            )
            .overlay(Capsule().strokeBorder(on ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(on ? "Back to search (Tab)" : "Ask a question about your results (Tab)")
    }
}

// MARK: Filters

private struct UniversalSearchFilterBar: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        HStack(spacing: 6) {
            UniversalSearchChip(title: "All", symbol: nil, tint: UniversalSearchPalette.accent,
                                isOn: controller.sourceFilter == nil, help: "All sources (⌘0)") {
                controller.setSourceFilter(nil)
            }
            ForEach(UniversalSearchSource.allCases.filter { controller.enabledSources.contains($0) }) { source in
                UniversalSearchChip(title: source.title, symbol: source.symbol, tint: SparkVTheme.isApple ? source.tint : UniversalSearchPalette.accent,
                                    isOn: controller.sourceFilter == source,
                                    help: "\(source.title) only (⌘\(source.digit))") {
                    controller.setSourceFilter(source)
                }
            }
            Spacer(minLength: 4)
            Menu {
                ForEach(UniversalSearchDateFilter.allCases) { filter in
                    Button {
                        controller.setDateFilter(filter)
                    } label: {
                        if filter == controller.dateFilter {
                            Label(filter.title, systemImage: "checkmark")
                        } else {
                            Text(filter.title)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
                    Text(controller.dateFilter.shortTitle).font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(controller.dateFilter == .any ? UniversalSearchPalette.secondary : Color.white)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(controller.dateFilter == .any ? SparkVTheme.surface : UniversalSearchPalette.accent))
                .overlay(Capsule().strokeBorder(controller.dateFilter == .any ? SparkVTheme.stroke : Color.clear, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Filter by date (⌘D)")
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

private struct UniversalSearchChip: View {
    let title: String
    let symbol: String?
    let tint: Color
    let isOn: Bool
    let help: String
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isOn ? Color.white : UniversalSearchPalette.secondary)
                }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isOn ? Color.white : (hover.isOn ? SparkVTheme.text : UniversalSearchPalette.secondary))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(isOn ? tint : (hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface)))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : SparkVTheme.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.hover(), value: hover.isOn)
        .help(help)
    }
}

// MARK: Results

private struct UniversalSearchResultsList: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(controller.sections) { section in
                        UniversalSearchSectionHeader(section: section) {
                            if let source = section.source { controller.setSourceFilter(source) }
                        }
                        ForEach(section.results) { result in
                            UniversalSearchRow(
                                result: result,
                                isSelected: controller.selectedID == result.id,
                                actionHint: controller.primaryTitle(for: result)
                            )
                            .id(result.id)
                            .onTapGesture(count: 2) { controller.activate(result) }
                            .onTapGesture { controller.select(result.id) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { controller.select(result.id) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: controller.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: nil)
            }
        }
    }
}

private struct UniversalSearchSectionHeader: View {
    let section: UniversalSearchSection
    let showAll: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(UniversalSearchPalette.tertiary)
            Spacer()
            if section.hiddenCount > 0, let source = section.source {
                Button(action: showAll) {
                    Text("\(section.hiddenCount) more  ⌘\(source.digit)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UniversalSearchPalette.secondary)
                }
                .buttonStyle(SparkVPressStyle())
                .help("Show all \(source.title) results")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}

struct UniversalSearchRow: View {
    let result: UniversalSearchResult
    let isSelected: Bool
    var actionHint: String?
    var compact = false

    var body: some View {
        let d = result.document
        HStack(spacing: compact ? 8 : 10) {
            RoundedRectangle(cornerRadius: compact ? 5 : 7, style: .continuous)
                .fill(SparkVTheme.isApple ? d.source.tint.opacity(isSelected ? 0.26 : 0.18) : (isSelected ? SparkVTheme.redSoft : SparkVTheme.surface))
                .frame(width: compact ? 17 : 30, height: compact ? 17 : 30)
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 5 : 7, style: .continuous)
                        .strokeBorder(SparkVTheme.isApple ? d.source.tint.opacity(0.30) : (isSelected ? SparkVTheme.red.opacity(0.5) : SparkVTheme.stroke), lineWidth: SparkVTheme.isApple ? 0.5 : 1)
                )
                .overlay(
                    // Apple: each source keeps its color, as in Spotlight.
                    Image(systemName: d.symbol)
                        .font(.system(size: compact ? 9 : 13, weight: .semibold))
                        .foregroundStyle(SparkVTheme.isApple ? d.source.tint : (isSelected ? SparkVTheme.red : SparkVTheme.textSecondary))
                )
            VStack(alignment: .leading, spacing: 2) {
                UniversalSearchHighlightedText(text: d.title, positions: result.titleHighlights,
                                               size: compact ? 11.5 : 13, weight: .medium,
                                               base: SparkVTheme.text.opacity(0.86), highlight: SparkVTheme.text)
                    .lineLimit(1)
                if !compact {
                    secondLine.lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if compact {
                Text(UniversalSearchText.relativeDate(d.date))
                    .font(.system(size: 9.5))
                    .foregroundStyle(UniversalSearchPalette.tertiary)
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(UniversalSearchText.relativeDate(d.date))
                        .font(.system(size: 10.5))
                        .foregroundStyle(UniversalSearchPalette.tertiary)
                    if isSelected, let actionHint {
                        Text(actionHint + "  ↩")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(UniversalSearchPalette.secondary)
                    } else if result.isRelated {
                        Text("Related")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(UniversalSearchPalette.ask.opacity(0.9))
                    }
                }
            }
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 1 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: compact ? 6 : 9, style: .continuous)
                .fill(isSelected ? UniversalSearchPalette.selection : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.source.title): \(d.title)")
    }

    private var secondLine: Text {
        let sub = Text(result.document.subtitle).foregroundColor(UniversalSearchPalette.tertiary)
        guard let snippet = result.snippet, !snippet.isEmpty else {
            return sub.font(.system(size: 11))
        }
        let excerpt = UniversalSearchHighlightedText.attributed(
            snippet, ranges: result.snippetHighlights, size: 11, weight: .regular,
            base: UniversalSearchPalette.secondary, highlight: Color.white.opacity(0.95), highlightWeight: .semibold
        )
        return (sub + Text("  ") + Text(excerpt)).font(.system(size: 11))
    }
}

/// Text with matched characters brighter and bolder (Raycast/Alfred style).
struct UniversalSearchHighlightedText: View {
    let text: String
    let positions: [Int]
    var size: CGFloat
    var weight: Font.Weight
    var base: Color
    var highlight: Color

    var body: some View {
        Text(Self.attributed(text, ranges: Self.ranges(from: positions), size: size, weight: weight,
                             base: base, highlight: highlight, highlightWeight: .bold))
    }

    static func ranges(from positions: [Int]) -> [Range<Int>] {
        UniversalSearchEngine.merge(positions.map { $0..<($0 + 1) })
    }

    static func attributed(_ text: String, ranges: [Range<Int>], size: CGFloat, weight: Font.Weight,
                           base: Color, highlight: Color, highlightWeight: Font.Weight) -> AttributedString {
        let chars = Array(text)
        var out = AttributedString()
        var cursor = 0
        func append(_ slice: ArraySlice<Character>, on: Bool) {
            guard !slice.isEmpty else { return }
            var part = AttributedString(String(slice))
            part.foregroundColor = on ? highlight : base
            part.font = .system(size: size, weight: on ? highlightWeight : weight)
            out.append(part)
        }
        for r in ranges where r.lowerBound >= cursor && r.upperBound <= chars.count {
            append(chars[cursor..<r.lowerBound], on: false)
            append(chars[r], on: true)
            cursor = r.upperBound
        }
        append(chars[cursor..<chars.count], on: false)
        return out
    }
}

// MARK: Empty / recording

private struct UniversalSearchEmptyView: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: controller.query.isEmpty ? "square.stack.3d.up" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(UniversalSearchPalette.tertiary)
            if controller.query.isEmpty {
                Text(controller.indexedCount == 0 ? "Nothing to search yet" : "Start typing to search")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                Text("Spaces, meeting notes, Flow dictations and notes, clipboard history and the Tray, in one box.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UniversalSearchPalette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            } else {
                Text("No results for “\(controller.query)”")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Press").foregroundStyle(UniversalSearchPalette.secondary)
                    UniversalSearchKeyCap(text: "↩")
                    Text("to ask instead").foregroundStyle(UniversalSearchPalette.secondary)
                    if controller.sourceFilter != nil || controller.dateFilter != .any {
                        Text("· or clear the filters").foregroundStyle(UniversalSearchPalette.secondary)
                    }
                }
                .font(.system(size: 11.5))
            }
            Text("Tip: in:meetings, in:clip, date:week narrow a search")
                .font(.system(size: 10.5))
                .foregroundStyle(UniversalSearchPalette.tertiary)
                .padding(.top, 6)
        }
        .padding(24)
    }
}

private struct UniversalSearchRecordingView: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(UniversalSearchPalette.accent)
            Text("Press the new search shortcut")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
            HStack(spacing: 6) {
                Text("Now:").foregroundStyle(UniversalSearchPalette.secondary)
                UniversalSearchKeyCap(text: controller.shortcut.displayString)
                Text("· hold ⌃, ⌥ or ⌘ · Esc cancels").foregroundStyle(UniversalSearchPalette.secondary)
            }
            .font(.system(size: 11.5))
        }
    }
}

// MARK: Footer

private struct UniversalSearchFooter: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        HStack(spacing: 10) {
            status
            Spacer(minLength: 6)
            if let r = controller.selected, !controller.isRecordingShortcut {
                UniversalSearchHint(key: "↩", title: controller.primaryTitle(for: r))
                if let alt = controller.alternateTitle(for: r) {
                    UniversalSearchHint(key: "⌘↩", title: alt)
                }
                if controller.primaryTitle(for: r) != "Copy" {
                    UniversalSearchHint(key: "⌘C", title: "Copy")
                }
            } else if controller.mode == .ask {
                UniversalSearchHint(key: "↩", title: "Ask")
            }
            UniversalSearchHint(key: "⇥", title: controller.mode == .ask ? "Search" : "Ask")
            UniversalSearchHint(key: "esc", title: controller.mode == .ask ? "Back" : "Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Color.white.opacity(0.025))
    }

    @ViewBuilder private var status: some View {
        if controller.isDictating {
            HStack(spacing: 5) {
                SparkVStatusDot(kind: .recording, color: SparkVTheme.recording, size: 6, label: "")
                Text("Listening… click the mic to finish")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SparkVTheme.text)
        } else if let toast = controller.toast {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(SparkVTheme.success)
                Text(toast).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(SparkVTheme.text)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 8))
                Text("\(controller.indexedCount.formatted()) items · on this Mac")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(UniversalSearchPalette.tertiary)
            .help("Search runs locally. Ask uses the on-device model\(controller.allowGroq ? " (Groq allowed in Settings)" : "").")
        }
    }
}

struct UniversalSearchHint: View {
    let key: String
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(UniversalSearchPalette.secondary)
            UniversalSearchKeyCap(text: key)
        }
    }
}

struct UniversalSearchKeyCap: View {
    let text: String
    var dim = false

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white.opacity(dim ? 0.5 : 0.75))
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SparkVTheme.surfaceHover))
    }
}

// MARK: Ask

private struct UniversalSearchAskView: View {
    @ObservedObject var controller: UniversalSearchController

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 12) {
                    content
                    if !controller.askSources.isEmpty {
                        Text("SOURCES")
                            .font(.system(size: 10, weight: .semibold))
                            .kerning(0.4)
                            .foregroundStyle(UniversalSearchPalette.tertiary)
                            .padding(.top, 2)
                        VStack(spacing: 1) {
                            ForEach(Array(controller.askSources.enumerated()), id: \.element.id) { i, r in
                                HStack(spacing: 8) {
                                    Text("\(i + 1)")
                                        .font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(cited(i + 1) ? Color.white : SparkVTheme.text)
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(cited(i + 1) ? SparkVTheme.accent : SparkVTheme.surfaceHover))
                                    UniversalSearchRow(result: r, isSelected: controller.selectedID == r.id,
                                                       actionHint: controller.primaryTitle(for: r))
                                }
                                .id(r.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { controller.activate(r) }
                                .onTapGesture { controller.select(r.id) }
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { controller.select(r.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.selectedID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: nil)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "sparkv-cite", let n = Int(url.host ?? "") {
                controller.openCitation(n)
                return .handled
            }
            return .discarded
        })
    }

    private func cited(_ n: Int) -> Bool {
        if case .answered(let a) = controller.askState { return a.cited.contains(n) }
        return false
    }

    @ViewBuilder private var content: some View {
        let question = controller.askedQuestion.isEmpty ? controller.query : controller.askedQuestion
        if !question.isEmpty {
            Text(question)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        switch controller.askState {
        case .idle:
            VStack(alignment: .leading, spacing: 6) {
                Text(question.isEmpty ? "Ask anything about your meetings, notes, Spaces, dictations, clipboard and Tray."
                     : "Press ↩ to ask.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(UniversalSearchPalette.secondary)
                Text("Answers come only from your own items, on this Mac, with numbered sources.")
                    .font(.system(size: 11))
                    .foregroundStyle(UniversalSearchPalette.tertiary)
            }
        case .thinking:
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(UniversalSearchPalette.ask)
                Text("Reading your sources…")
                    .foregroundStyle(UniversalSearchPalette.secondary)
            }
            .font(.system(size: 12.5))
        case .answered(let answer):
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.answerText(answer.text))
                    .font(.system(size: 13.5))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(answer.producedBy) · \(controller.askSources.count) source\(controller.askSources.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(UniversalSearchPalette.tertiary)
            }
        }
    }

    /// The answer with [n] citations as tappable accent links.
    static func answerText(_ text: String) -> AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        let regex = try? NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)
        var cursor = 0
        let matches = regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        func plain(_ s: String) {
            var part = AttributedString(s)
            part.foregroundColor = Color.white.opacity(0.9)
            out.append(part)
        }
        for m in matches {
            if m.range.location > cursor { plain(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))) }
            let n = ns.substring(with: m.range(at: 1))
            var cite = AttributedString(n)
            cite.foregroundColor = UniversalSearchPalette.ask
            cite.font = .system(size: 10, weight: .bold)
            cite.baselineOffset = 4
            cite.link = URL(string: "sparkv-cite://\(n)")
            out.append(cite)
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { plain(ns.substring(from: cursor)) }
        return out
    }
}
