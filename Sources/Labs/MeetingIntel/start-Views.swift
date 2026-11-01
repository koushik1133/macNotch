import AppKit
import SwiftUI

// Meeting Intelligence, part A: views. The island bands (start prompt,
// auto-start countdown, consent toast), the brief card (also used by the
// Today tab) and the Today row. Tokens come from SparkVTheme only, so both
// looks (Apple, SparkV Red) work; Record uses the recording red in both.
//
// The lab's signature: a thin "thread" line (1.5 pt, `stroke`) left of
// stacked lines, with a small glyph node on each.

// MARK: - Thread

/// One node on the thread.
struct MeetingThreadItem: Identifiable, Equatable {
    let id: String
    var symbol: String
    var text: String
    var detail: String?
    var tint: Color

    static func == (lhs: MeetingThreadItem, rhs: MeetingThreadItem) -> Bool {
        lhs.id == rhs.id && lhs.symbol == rhs.symbol && lhs.text == rhs.text && lhs.detail == rhs.detail
    }
}

/// Lines hung on a thin vertical thread with a glyph node on each.
struct MeetingThreadStack: View {
    let items: [MeetingThreadItem]
    var nodeSize: CGFloat = 11
    var spacing: CGFloat = 4
    var textSize: CGFloat = 11
    var detailLines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 7) {
                    MeetingThreadNode(symbol: item.symbol, tint: item.tint, size: nodeSize)
                        .padding(.top, max(0, (textSize * 1.25 - nodeSize) / 2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.text)
                            .font(.system(size: textSize, weight: .medium))
                            .foregroundStyle(SparkVTheme.text.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(SparkVTheme.caption(textSize - 1))
                                .foregroundStyle(SparkVTheme.textSecondary)
                                .lineLimit(detailLines)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(alignment: .topLeading) {
            if items.count > 1 {
                Rectangle()
                    .fill(SparkVTheme.stroke)
                    .frame(width: 1.5)
                    .padding(.vertical, nodeSize / 2 + 1)
                    .padding(.leading, nodeSize / 2 - 0.75)
            }
        }
    }
}

struct MeetingThreadNode: View {
    let symbol: String
    var tint: Color = SparkVTheme.textSecondary
    var size: CGFloat = 11

    var body: some View {
        ZStack {
            Circle().fill(SparkVTheme.islandBackground)
            Circle().fill(SparkVTheme.surface)
            Circle().strokeBorder(tint.opacity(0.55), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

extension MeetingStartBriefLine {
    var threadItem: MeetingThreadItem {
        MeetingThreadItem(id: "\(kind)-\(text)", symbol: symbol, text: text, detail: nil,
                          tint: kind == .owe ? SparkVTheme.text : SparkVTheme.textSecondary)
    }
}

// MARK: - Start prompt band

/// The band when a call starts:
///
///     [icon] Google Meet · Design sync              ◦ 2 people you met Tue
///      ┃ ◦ Agenda: pricing v2, launch date
///      ┃ ◦ You owe: send the deck to Priya
///     [● Record notes] [Captions] [Translate · ES]                     ✕
///      Let everyone know you're taking notes.           ☐ Always for Meet
struct MeetingStartPromptBand: View {
    @ObservedObject var coordinator: MeetingStartCoordinator
    let call: DetectedCall
    let icon: NSImage?

    static let maxBriefLines = 2

    /// Band height for a brief (the band is posted with it).
    static func height(for brief: MeetingBrief?) -> CGFloat {
        let lines = brief?.bandLines(max: maxBriefLines).count ?? 0
        return 80 + (lines == 0 ? 0 : CGFloat(lines) * 15 + CGFloat(lines - 1) * 4 + 6)
    }

    var body: some View {
        let lines = coordinator.brief?.bandLines(max: Self.maxBriefLines) ?? []
        VStack(alignment: .leading, spacing: 7) {
            MeetingStartHeader(call: call, icon: icon, chip: coordinator.brief?.peopleChip(now: coordinator.clock()))
            if !lines.isEmpty {
                MeetingThreadStack(items: lines.map(\.threadItem), spacing: 4)
                    .padding(.leading, 3)
                    .transition(.opacity)
            }
            MeetingStartChoices(coordinator: coordinator, call: call)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: lines)
    }
}

/// "[icon] Google Meet · Design sync      ◦ 2 people you met Tue".
struct MeetingStartHeader: View {
    let call: DetectedCall
    let icon: NSImage?
    var chip: String?

    var body: some View {
        HStack(spacing: 7) {
            MeetingProviderBadge(provider: call.provider, appIcon: icon, calendarColor: SparkVTheme.recording, size: 16)
            HStack(spacing: 4) {
                Text(call.serviceName)
                    .font(SparkVTheme.headline(12))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .fixedSize()
                if !call.hasGenericTitle {
                    Text("·").foregroundStyle(SparkVTheme.textTertiary)
                    Text(call.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text("· call started")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let chip {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(chip)
                        .lineLimit(1)
                }
                .font(SparkVTheme.caption(10))
                .foregroundStyle(SparkVTheme.textSecondary)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(Capsule().fill(SparkVTheme.surface))
                .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                .fixedSize()
            }
        }
        .frame(height: 18)
    }
}

/// The three choices, ✕ (Not now; its menu has "Never for <service>"), the
/// consent line and "Always for <service>".
struct MeetingStartChoices: View {
    @ObservedObject var coordinator: MeetingStartCoordinator
    let call: DetectedCall
    /// Shorter labels for the Today tab's ~280 pt column.
    var narrow = false

    var body: some View {
        let service = call.provider?.shortName ?? call.serviceName
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: narrow ? 5 : 6) {
                Button {
                    coordinator.choose(.notes, remember: coordinator.rememberChoice)
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Color.white).frame(width: 6, height: 6)
                        Text(narrow ? "Notes" : "Record notes")
                    }
                }
                .buttonStyle(SparkVPrimaryButtonStyle(tint: SparkVTheme.recording))
                .help("Record this call on this Mac and write notes. \(MeetingIntelConsent.reminder)")

                Button("Captions") {
                    coordinator.choose(.captionsOnly, remember: coordinator.rememberChoice)
                }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .help("Live captions under the notch. Transcribed on this Mac.")

                if let translation = coordinator.translation {
                    Button {
                        var plan = MeetingStartPlan.translated
                        plan.targetLanguage = translation.targetLanguage
                        coordinator.choose(plan, remember: coordinator.rememberChoice)
                    } label: {
                        HStack(spacing: 4) {
                            if narrow {
                                Image(systemName: "character.bubble")
                                    .font(.system(size: 11, weight: .medium))
                            } else {
                                Text("Translate")
                            }
                            Text(LiveTranslationLanguages.shortTag(translation.targetLanguage))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(SparkVTheme.textSecondary)
                                .padding(.horizontal, 4)
                                .frame(height: 14)
                                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(SparkVTheme.surface))
                        }
                    }
                    .buttonStyle(SparkVSecondaryButtonStyle())
                    .help("Translated captions in \(LiveTranslationLanguages.displayName(translation.targetLanguage)), on device.")
                    .accessibilityLabel("Translate to \(LiveTranslationLanguages.displayName(translation.targetLanguage))")
                }

                Spacer(minLength: 4)

                Menu {
                    Button("Not now") { coordinator.notNow() }
                    Button("Never for \(service)") { coordinator.never() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(SparkVTheme.surface))
                } primaryAction: {
                    coordinator.notNow()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Not now (hold for Never for \(service))")
                .accessibilityLabel("Not now (hold for Never for \(service))")
            }

            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textTertiary)
                Text(MeetingIntelConsent.reminder)
                    .font(SparkVTheme.caption(10))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .help(MeetingIntelConsent.detail)
                Spacer(minLength: 6)
                MeetingRememberToggle(isOn: $coordinator.rememberChoice, label: narrow ? "Always" : "Always for \(service)")
            }
            .frame(height: 14)
        }
    }
}

/// A small check box drawn with theme tokens.
struct MeetingRememberToggle: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isOn ? SparkVTheme.accent : Color.clear)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(isOn ? Color.clear : SparkVTheme.textTertiary, lineWidth: 1)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 11, height: 11)
                Text(label)
                    .font(SparkVTheme.caption(10))
                    .foregroundStyle(isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .fixedSize()
        .help("Next time, start this choice on its own after a short countdown you can cancel")
    }
}

/// The wings while the prompt rests: "Notes?".
struct MeetingStartCompactTrailing: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(SparkVTheme.recording).frame(width: 5, height: 5)
            Text("Notes?")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
        }
        .fixedSize()
    }
}

// MARK: - Countdown band

/// A remembered `.auto` rule, never silent:
///
///     ( 4 )  Starting notes · Design sync                    [Cancel]
///            Let everyone know you're taking notes. Audio stays on this Mac.
struct MeetingCountdownBand: View {
    let call: DetectedCall
    let icon: NSImage?
    let plan: MeetingStartPlan
    let secondsLeft: Int
    let total: Int
    let onCancel: () -> Void

    static let height: CGFloat = 48

    var body: some View {
        HStack(spacing: 10) {
            MeetingCountdownRing(secondsLeft: secondsLeft, total: total)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(Self.verb(plan))
                        .font(SparkVTheme.headline(12))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                        .fixedSize()
                    Text("·").foregroundStyle(SparkVTheme.textTertiary)
                    MeetingProviderBadge(provider: call.provider, appIcon: icon, calendarColor: SparkVTheme.recording, size: 12)
                    Text(call.hasGenericTitle ? call.serviceName : call.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(SparkVTheme.text)
                            .padding(.horizontal, 10)
                            .frame(height: 20)
                            .background(Capsule().fill(SparkVTheme.surfaceHover))
                            .overlay(Capsule().strokeBorder(SparkVTheme.stroke))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(SparkVPressStyle())
                    .keyboardShortcut(.cancelAction)
                    .fixedSize()
                    .help("Don't start for this call")
                }
                Text("\(MeetingIntelConsent.reminder) Audio stays on this Mac.")
                    .font(SparkVTheme.caption(10))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(MeetingIntelConsent.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func verb(_ plan: MeetingStartPlan) -> String {
        if plan.translate { return "Translating" }
        if plan.keepNotes { return "Starting notes" }
        return "Starting captions"
    }
}

/// A draining ring with the seconds left in the middle.
struct MeetingCountdownRing: View {
    let secondsLeft: Int
    let total: Int
    var size: CGFloat = 30

    var body: some View {
        let fraction = total > 0 ? CGFloat(secondsLeft) / CGFloat(total) : 0
        ZStack {
            Circle().strokeBorder(SparkVTheme.stroke, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(SparkVTheme.recording, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(1.25)
                .animation(.linear(duration: 0.9), value: secondsLeft)
            Text("\(secondsLeft)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(SparkVTheme.text)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Starting in \(secondsLeft) seconds")
    }
}

// MARK: - Consent toast

/// Three seconds at every start: "● Let everyone know you're taking notes.   On this Mac".
struct MeetingConsentToast: View {
    let plan: MeetingStartPlan

    var body: some View {
        HStack(spacing: 8) {
            MeetingIntelLiveBadge(text: "Recording", compact: true)
            Text(MeetingIntelConsent.reminder)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(plan.keepNotes ? "Notes · on this Mac" : "Captions · on this Mac")
                .font(SparkVTheme.caption(10))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(MeetingIntelConsent.detail)
    }
}

// MARK: - Brief card

/// The pre-meeting brief: agenda, what I still owe these people, last
/// time, Spaces. Used under the Today tab's row and anywhere else a card
/// fits (about 320-420 pt wide).
struct MeetingBriefCard: View {
    let brief: MeetingBrief
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                MeetingIntelEyebrow(text: "Brief")
                Spacer(minLength: 4)
                if !brief.sources.isEmpty {
                    Text(brief.sources.joined(separator: " · ") + " · on this Mac")
                        .font(SparkVTheme.caption(9.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(brief.title)
                    .font(SparkVTheme.headline(13))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                if let when = whenText {
                    Text(when)
                        .font(SparkVTheme.caption(10.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            if !people.isEmpty {
                MeetingAttendeeRow(names: people, more: max(0, brief.attendees.filter { !$0.isMe }.count - people.count))
            }

            if brief.isEmpty {
                Text("Nothing from earlier meetings or Spaces yet.")
                    .font(SparkVTheme.caption(10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            } else {
                MeetingThreadStack(items: items, nodeSize: 13, spacing: 7, textSize: 11.5)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke))
    }

    private var people: [String] {
        Array(brief.attendees.filter { !$0.isMe }.map(\.firstName).prefix(4))
    }

    private var whenText: String? {
        guard let start = brief.start else { return nil }
        let time = start.formatted(.dateTime.hour().minute())
        guard let end = brief.end else { return time }
        return "\(time) – \(end.formatted(.dateTime.hour().minute()))"
    }

    var items: [MeetingThreadItem] {
        var result: [MeetingThreadItem] = []
        for (index, line) in brief.agenda.enumerated() {
            result.append(MeetingThreadItem(id: "agenda-\(index)", symbol: "list.bullet", text: line, detail: nil,
                                            tint: SparkVTheme.textSecondary))
        }
        for task in brief.openTasks {
            let detail = [task.due.map { "Due \($0)" }, "From an earlier meeting"].compactMap { $0 }.joined(separator: " · ")
            result.append(MeetingThreadItem(id: "task-\(task.id)", symbol: "circle.dashed", text: "You owe: \(task.task)",
                                            detail: detail, tint: SparkVTheme.text))
        }
        for past in brief.pastMeetings {
            let when = MeetingBrief.shortWhen(past.date, now: now)
            let with = past.sharedPeople.isEmpty ? "" : " · with " + past.sharedPeople.joined(separator: ", ")
            result.append(MeetingThreadItem(id: "past-\(past.id)", symbol: "clock.arrow.circlepath",
                                            text: "\(when.prefix(1).uppercased() + when.dropFirst()) · \(past.title)\(with)",
                                            detail: past.summary.isEmpty ? nil : past.summary, tint: SparkVTheme.textSecondary))
        }
        for hit in brief.spaceHits {
            result.append(MeetingThreadItem(id: "space-\(hit.id)", symbol: "square.stack", text: hit.title,
                                            detail: [hit.spaceName, hit.snippet].compactMap { $0 }.joined(separator: " · "),
                                            tint: SparkVTheme.textSecondary))
        }
        return result
    }
}

/// "P  S  A  +2" initials and first names.
struct MeetingAttendeeRow: View {
    let names: [String]
    var more: Int = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 4) {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(SparkVTheme.text)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(SparkVTheme.surfaceHover))
                    Text(name)
                        .font(SparkVTheme.caption(10.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
                .fixedSize()
            }
            if more > 0 {
                Text("+\(more)")
                    .font(SparkVTheme.caption(10.5))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
    }
}

// MARK: - Today tab row

/// For the Today tab (above the meeting list): while a call is offered,
/// the same choices as the band plus the brief; while a countdown runs,
/// its Cancel; while live, the brief to glance at. Renders nothing
/// otherwise, so it can sit there unconditionally. `compact` (the Today
/// drawer) shows the brief as the band's two thread lines; otherwise the
/// full `MeetingBriefCard`.
struct MeetingStartTodayRow: View {
    @ObservedObject var coordinator: MeetingStartCoordinator
    var compact = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch coordinator.stage {
            case .prompting(let call):
                VStack(alignment: .leading, spacing: 7) {
                    MeetingStartHeader(call: call, icon: MeetingCallIcon.icon(for: call),
                                       chip: coordinator.brief?.peopleChip(now: coordinator.clock()))
                    if compact { briefLines }
                    MeetingStartChoices(coordinator: coordinator, call: call)
                }
                if !compact { briefCard }
            case .countingDown(let call, let plan, let left):
                MeetingCountdownBand(call: call, icon: MeetingCallIcon.icon(for: call), plan: plan, secondsLeft: left,
                                     total: max(1, Int(coordinator.prefs.autoCountdown.rounded())),
                                     onCancel: { coordinator.cancelCountdown() })
                    .frame(height: MeetingCountdownBand.height)
                if compact { briefLines } else { briefCard }
            case .live:
                if compact {
                    if let brief = coordinator.brief, !brief.isEmpty {
                        HStack(spacing: 6) {
                            MeetingIntelLiveBadge(compact: true)
                            MeetingIntelEyebrow(text: "Brief")
                        }
                        briefLines
                    }
                } else {
                    briefCard
                }
            case .idle:
                EmptyView()
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: coordinator.stage)
    }

    @ViewBuilder private var briefLines: some View {
        let lines = coordinator.brief?.bandLines(max: MeetingStartPromptBand.maxBriefLines) ?? []
        if !lines.isEmpty {
            MeetingThreadStack(items: lines.map(\.threadItem), spacing: 4)
                .padding(.leading, 3)
        }
    }

    @ViewBuilder private var briefCard: some View {
        if let brief = coordinator.brief, !brief.isEmpty {
            MeetingBriefCard(brief: brief, now: coordinator.clock())
        }
    }
}

// MARK: - Today tab slot

/// The Today tab's left column (INTEGRATION.md step 8). The drawer is short
/// (about 280 × 69 pt), so while a call is offered or counting down the offer
/// takes the column's place; otherwise `fallback` (the calendar list) shows.
/// The brief stays in the notch band and in `MeetingStartTodayRow(compact:
/// false)` for roomier places.
struct MeetingStartTodaySlot<Fallback: View>: View {
    @ObservedObject var coordinator: MeetingStartCoordinator
    let fallback: Fallback

    init(coordinator: MeetingStartCoordinator, @ViewBuilder fallback: () -> Fallback) {
        self.coordinator = coordinator
        self.fallback = fallback()
    }

    var body: some View {
        Group {
            switch coordinator.stage {
            case .prompting(let call):
                VStack(alignment: .leading, spacing: 6) {
                    MeetingStartHeader(call: call, icon: MeetingCallIcon.icon(for: call), chip: nil)
                    MeetingStartChoices(coordinator: coordinator, call: call, narrow: true)
                }
                .transition(.opacity)
            case .countingDown(let call, let plan, let left):
                MeetingCountdownBand(call: call, icon: MeetingCallIcon.icon(for: call), plan: plan, secondsLeft: left,
                                     total: max(1, Int(coordinator.prefs.autoCountdown.rounded())),
                                     onCancel: { coordinator.cancelCountdown() })
                    .frame(height: MeetingCountdownBand.height)
                    .transition(.opacity)
            case .idle, .live:
                fallback
            }
        }
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: coordinator.offeredCall?.key)
    }
}

// MARK: - Menu items

/// For the gear menu's Meetings submenu: the start prompt's switches.
struct MeetingStartMenuItems: View {
    @ObservedObject var prefs: MeetingIntelPreferences

    var body: some View {
        Toggle("Offer Notes, Captions or Translation When a Call Starts", isOn: $prefs.isEnabled)
        Toggle("Show a Brief Before Calls", isOn: $prefs.showBrief)
            .disabled(!prefs.isEnabled)
        Button("Forget Remembered Call Choices") { prefs.forgetAllRules() }
            .disabled(prefs.rules.isEmpty)
    }
}
