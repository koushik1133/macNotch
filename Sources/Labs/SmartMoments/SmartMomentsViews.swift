import AppKit
import SwiftUI

// Smart Moments UI: the offer band under the notch, the "Done" toast, the
// Agents hub tile and the gear-menu submenu. The Settings window lives in
// ui-SmartMomentsSettings.swift. Everything reads SparkVTheme tokens in
// `body`, so both looks (Apple / SparkV Red) come out right.
//
// No @State (Command Line Tools): view-local state uses ViewFlag.

// MARK: - Metrics

enum SmartMomentsMetrics {
    /// The offer band: a headline row over a chip row.
    static let bandHeight: CGFloat = 64
    /// The one-line "Done" toast.
    static let toastHeight: CGFloat = NotchMetrics.activityBandHeight
    static let toastDuration: TimeInterval = 3
    static let horizontalPadding: CGFloat = 13
    static let chipHeight: CGFloat = 24
    /// At most this many titled chips; the rest fold into "+N".
    static let maxTitledChips = 4
    static let feature = "Smart Moments"

    /// Band priority in ActivityCenter terms (HUDs 90, notifications 70,
    /// meetings 60): 52...75, low battery highest.
    static func activityPriority(_ moment: MomentID) -> Int { min(75, 50 + moment.priority / 4) }
}

// MARK: - Band model and presenter

/// Holds the offer the band shows, so chip toggles redraw in place.
@MainActor
final class SmartMomentsBandModel: ObservableObject {
    @Published private(set) var offer: MomentOffer?
    /// A "Do it" or Undo is running: buttons are disabled meanwhile.
    @Published var isWorking = false
    let engine: any SmartMomentsEngine

    init(engine: any SmartMomentsEngine) {
        self.engine = engine
        self.offer = engine.currentOffer
    }

    func update(_ offer: MomentOffer?) {
        if offer?.id != self.offer?.id { isWorking = false }
        self.offer = offer
    }

    var settings: SmartMomentsSettings { engine.settings }

    // Band actions -----------------------------------------------------

    func doIt() {
        guard let offer, !isWorking else { return }
        isWorking = true
        Task {
            await engine.accept(offer.id, actions: offer.selected)
            isWorking = false
        }
    }

    /// "Always": this moment runs on its own from now on, and this time.
    /// Consent actions keep asking (the engine never auto-runs them).
    func always() {
        guard let offer else { return }
        settings.setMode(.automatic, for: offer.moment)
        doIt()
    }

    func notNow() {
        guard let offer else { return }
        engine.dismiss(offer.id)
    }

    func snoozeToday() {
        guard let offer else { return }
        engine.snooze(offer.id)
    }

    func turnOffMoment() {
        guard let offer else { return }
        settings.setEnabled(false, for: offer.moment)
        engine.dismiss(offer.id)
    }

    func undo() {
        guard let offer, !isWorking else { return }
        isWorking = true
        Task {
            await engine.undo(offer.id)
            isWorking = false
        }
    }

    /// Chip tap: toggles it for "Do it". ⌥-click runs just that chip.
    /// A blocked chip asks PermissionCenter instead. In the auto-ran band,
    /// a consent chip runs on tap (the user started it).
    func tap(_ action: MomentAction, runNow: Bool) {
        guard let offer else { return }
        if offer.blocked[action] != nil {
            engine.requestPermission(for: action, offerID: offer.id)
        } else if runNow || !offer.autoRan.isEmpty {
            Task { _ = await engine.run(action, offerID: offer.id) }
        } else {
            engine.toggleSelection(action, offerID: offer.id)
        }
    }
}

/// Posts the offer band and the Done toast to ActivityCenter. Wiring makes
/// one and calls `start()`: it takes over the engine's `onOfferChanged`
/// and `onDone` (chain your own work through `extraOnOfferChanged`).
@MainActor
final class SmartMomentsPresenter {
    static let offerActivityID = "smartMoments.offer"
    static let doneActivityID = "smartMoments.done"

    let model: SmartMomentsBandModel
    private let activities: ActivityCenter
    /// Called after the band was updated, for other observers.
    var extraOnOfferChanged: ((MomentOffer?) -> Void)?

    init(engine: any SmartMomentsEngine, activities: ActivityCenter) {
        self.model = SmartMomentsBandModel(engine: engine)
        self.activities = activities
    }

    func start() {
        model.engine.onOfferChanged = { [weak self] offer in
            self?.show(offer)
            self?.extraOnOfferChanged?(offer)
        }
        model.engine.onDone = { [weak self] moment, text in self?.showDone(moment, text) }
        show(model.engine.currentOffer)
    }

    func show(_ offer: MomentOffer?) {
        let previous = model.offer
        model.update(offer)
        guard let offer else {
            activities.dismiss(id: Self.offerActivityID)
            return
        }
        // Same offer, chips toggled: the band redraws from the model, no repost.
        if previous?.id == offer.id, previous?.autoRan == offer.autoRan,
           previous?.suggestsTurningOff == offer.suggestsTurningOff { return }
        activities.post(Self.activity(for: offer, model: model))
    }

    func showDone(_ moment: MomentID, _ text: String) {
        activities.post(LiveActivity(
            id: Self.doneActivityID, kind: .notification, priority: SmartMomentsMetrics.activityPriority(moment),
            duration: SmartMomentsMetrics.toastDuration, height: SmartMomentsMetrics.toastHeight,
            presentation: .expanded, symbol: "checkmark.circle.fill", tint: SparkVTheme.success
        ) {
            SmartMomentDoneToast(moment: moment, text: text)
        })
    }

    static func activity(for offer: MomentOffer, model: SmartMomentsBandModel) -> LiveActivity {
        let moment = offer.moment
        let duration = offer.expiresAt.map { max(1, $0.timeIntervalSinceNow) }
        return LiveActivity(
            id: offerActivityID, kind: .notification, priority: SmartMomentsMetrics.activityPriority(moment),
            duration: duration, height: SmartMomentsMetrics.bandHeight, presentation: .expanded,
            urgent: moment == .lowBatteryRecording, symbol: moment.symbol, tint: moment.tint
        ) {
            SmartMomentBandRoot(model: model)
        }
    }
}

// MARK: - Offer band

/// Follows the model, so a toggled chip redraws without a repost.
struct SmartMomentBandRoot: View {
    @ObservedObject var model: SmartMomentsBandModel

    var body: some View {
        if let offer = model.offer {
            SmartMomentBand(offer: offer, model: model)
        }
    }
}

/// The band: moment symbol and headline over 2-4 action chips, with
/// Do it / Not now / Always. After auto mode ran it shows what was done,
/// any consent chips still left for a tap, and Undo.
struct SmartMomentBand: View {
    let offer: MomentOffer
    @ObservedObject var model: SmartMomentsBandModel

    private var isAutoRan: Bool { !offer.autoRan.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            if isAutoRan {
                autoRanRow
            } else {
                chipRow
            }
        }
        .padding(.horizontal, SmartMomentsMetrics.horizontalPadding)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contextMenu {
            Button("Snooze for Today") { model.snoozeToday() }
            Button("Turn Off “\(offer.moment.title)”") { model.turnOffMoment() }
            Divider()
            Button("Smart Moments Settings…") { SmartMomentsSettingsWindowController.shared.show(settings: model.settings, focus: offer.moment) }
        }
    }

    // Row 1 -----------------------------------------------------------

    private var headerRow: some View {
        HStack(spacing: 8) {
            SmartMomentGlyph(moment: offer.moment, size: 20)
            HStack(spacing: 6) {
                Text(offer.headline)
                    .font(SparkVTheme.headline(12.5))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if isAutoRan {
                    Label("Done", systemImage: "checkmark")
                        .labelStyle(SmartMomentTightLabelStyle())
                        .font(SparkVTheme.caption(10.5))
                        .foregroundStyle(SparkVTheme.success)
                        .fixedSize()
                } else if showsConsent {
                    SmartMomentConsentNote()
                } else if let detail = offer.detail {
                    Text(detail)
                        .font(SparkVTheme.body(11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingLinks
        }
        .frame(height: 20)
    }

    /// The consent note shows while a recording or caption chip is picked.
    private var showsConsent: Bool {
        offer.showsConsentNote && offer.actions.contains { $0.needsConsent && offer.selected.contains($0) }
    }

    @ViewBuilder
    private var trailingLinks: some View {
        HStack(spacing: 2) {
            if offer.suggestsTurningOff && !isAutoRan {
                SmartMomentLinkButton(title: "Turn off", help: "You've skipped this a few times. Turn “\(offer.moment.title)” off (Settings can bring it back).") {
                    model.turnOffMoment()
                }
            } else if showsAlways {
                SmartMomentLinkButton(title: "Always", help: "Do this on its own next time. Recording, captions and joining still ask.") {
                    model.always()
                }
            }
            if isAutoRan {
                SmartMomentCloseButton { model.notNow() }
            } else {
                SmartMomentLinkButton(title: "Not now", help: "Dismiss. Right-click to snooze for today.") { model.notNow() }
            }
        }
        .disabled(model.isWorking)
    }

    /// "Always" only when the moment asks today and auto mode would do
    /// something (not when every chip always asks anyway).
    private var showsAlways: Bool {
        model.settings.settings(for: offer.moment).mode == .ask && offer.actions.contains { !$0.alwaysAsks }
    }

    // Row 2: chips ------------------------------------------------------

    private var chipRow: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                chips(titled: min(offer.actions.count, SmartMomentsMetrics.maxTitledChips))
                chips(titled: min(offer.actions.count, 3))
                chips(titled: min(offer.actions.count, 2))
                chips(titled: min(offer.actions.count, 1))
                chips(titled: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: model.doIt) {
                HStack(spacing: 4) {
                    if model.isWorking {
                        ProgressView().controlSize(.mini).tint(Color.white)
                    }
                    Text("Do it")
                }
            }
            .buttonStyle(SmartMomentDoItButtonStyle())
            .disabled(offer.selected.isEmpty || model.isWorking)
            .help(offer.selected.isEmpty ? "Pick at least one" : "Run the picked actions")
        }
        .frame(height: SmartMomentsMetrics.chipHeight)
    }

    /// The first `titled` chips with a title, the rest as icons.
    private func chips(titled: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(offer.actions.enumerated()), id: \.element) { index, action in
                SmartMomentChip(
                    action: action,
                    isSelected: offer.selected.contains(action),
                    blockedBy: offer.blocked[action],
                    showsTitle: index < titled
                ) { runNow in model.tap(action, runNow: runNow) }
            }
        }
        .fixedSize()
    }

    // Row 2 after auto mode ---------------------------------------------

    private var leftovers: [MomentAction] {
        let left = offer.actions.filter { !offer.autoRan.contains($0) }
        return left.filter(\.needsConsent) + left.filter { !$0.needsConsent }
    }

    private var autoRanRow: some View {
        HStack(spacing: 6) {
            Text(offer.autoRan.map(\.doneText).joined(separator: " · "))
                .font(SparkVTheme.body(11))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            // What auto mode left for a tap: recording and captions first,
            // then chips that open something (Join, Open, the mirror).
            ForEach(Array(leftovers.prefix(2).enumerated()), id: \.element) { index, action in
                SmartMomentChip(
                    action: action, isSelected: false, blockedBy: offer.blocked[action],
                    showsTitle: index == 0 || leftovers.count == 1
                ) { _ in
                    model.tap(action, runNow: true)
                }
            }
            if model.engine.canUndo(offer.id) {
                Button("Undo", action: model.undo)
                    .buttonStyle(SmartMomentQuietButtonStyle())
                    .disabled(model.isWorking)
                    .help("Put back what Smart Moments just changed")
            }
        }
        .frame(height: SmartMomentsMetrics.chipHeight)
    }
}

// MARK: - Done toast

/// "Paused music · Do Not Disturb on", 30 pt, three seconds.
struct SmartMomentDoneToast: View {
    let moment: MomentID
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SparkVTheme.success)
            Text(text)
                .font(SparkVTheme.headline(12))
                .foregroundStyle(SparkVTheme.text)
                .lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: moment.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
        }
        .padding(.horizontal, SmartMomentsMetrics.horizontalPadding + 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

/// The moment symbol in a circle washed with the moment's tint.
struct SmartMomentGlyph: View {
    let moment: MomentID
    var size: CGFloat = 20
    var isDimmed = false

    var body: some View {
        let tint = isDimmed ? SparkVTheme.textTertiary : moment.tint
        ZStack {
            Circle().fill(tint.opacity(SparkVTheme.isApple ? 0.22 : 0.14))
            Circle().strokeBorder(tint.opacity(SparkVTheme.isApple ? 0 : 0.35), lineWidth: 0.75)
            Image(systemName: moment.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// One action chip. Selected: accent wash with accent text and a check.
/// Off: a quiet surface. Blocked: a lock and a dashed hairline (tap to
/// allow). Consent chips carry a small recording-red dot.
struct SmartMomentChip: View {
    let action: MomentAction
    let isSelected: Bool
    let blockedBy: PermissionCenter.Permission?
    let showsTitle: Bool
    let onTap: (_ runNow: Bool) -> Void

    @StateObject private var hover = ViewFlag()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: (SmartMomentsMetrics.chipHeight - 2) / 2, style: .circular)
        let blocked = blockedBy != nil
        Button {
            onTap(NSEvent.modifierFlags.contains(.option))
        } label: {
            HStack(spacing: 4) {
                Image(systemName: blocked ? "lock.fill" : action.symbol)
                    .font(.system(size: blocked ? 8.5 : 10, weight: .semibold))
                    .frame(width: 12)
                if showsTitle {
                    Text(action.title)
                        .font(SparkVTheme.caption(10.5))
                        .lineLimit(1)
                        .fixedSize()
                }
                if action.needsConsent {
                    Circle().fill(SparkVTheme.recording).frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(foreground(blocked: blocked))
            .padding(.horizontal, showsTitle ? 7 : 5)
            .frame(height: SmartMomentsMetrics.chipHeight - 2)
            .background(shape.fill(fill(blocked: blocked)))
            .overlay {
                if blocked {
                    shape.strokeBorder(stroke(blocked: true), style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 2]))
                } else {
                    shape.strokeBorder(stroke(blocked: false), lineWidth: 0.75)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(help)
        .accessibilityLabel(action.title)
        .accessibilityValue(isSelected ? "On" : "Off")
    }

    private func foreground(blocked: Bool) -> Color {
        if blocked { return SparkVTheme.warning }
        return isSelected ? SparkVTheme.choose(apple: SparkVTheme.text, sparkv: SparkVTheme.accent) : SparkVTheme.textSecondary
    }

    private func fill(blocked: Bool) -> Color {
        if blocked { return SparkVTheme.warning.opacity(0.10) }
        if isSelected { return SparkVTheme.accentSoft }
        return hover.isOn ? SparkVTheme.surfaceHover : SparkVTheme.surface
    }

    private func stroke(blocked: Bool) -> Color {
        if blocked { return SparkVTheme.warning.opacity(0.55) }
        if isSelected { return SparkVTheme.accent.opacity(SparkVTheme.isApple ? 0.45 : 0.40) }
        return SparkVTheme.stroke
    }

    private var help: String {
        if let blockedBy { return "\(action.title) needs \(blockedBy.smartMomentsName) access. Click to allow." }
        var text = isSelected ? "\(action.title): on. Click to skip it this time." : "\(action.title): off. Click to include it."
        if action.needsConsent { text += " Let others on the call know." }
        return text + " ⌥-click to run just this."
    }
}

/// Small red dot + "Let others know": shown while a recording or caption chip is picked.
struct SmartMomentConsentNote: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(SparkVTheme.recording).frame(width: 5, height: 5)
            Text("Let others know")
                .font(SparkVTheme.caption(10))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
        }
        .help("Recording and captions start only when you tap Do it. Tell the people on the call.")
    }
}

/// Quiet text button ("Not now", "Always").
struct SmartMomentLinkButton: View {
    let title: String
    var help: String? = nil
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(Capsule(style: .continuous).fill(hover.isOn ? SparkVTheme.hoverFill : Color.clear))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help(help ?? title)
    }
}

struct SmartMomentCloseButton: View {
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : SparkVTheme.textTertiary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(hover.isOn ? SparkVTheme.hoverFill : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .help("Close")
    }
}

/// The band's primary: an accent capsule (blue in Apple, red in SparkV Red).
struct SmartMomentDoItButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SmartMomentDoItLabel(configuration: configuration)
    }

    private struct SmartMomentDoItLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = Capsule(style: .continuous)
            configuration.label
                .font(SparkVTheme.headline(11.5))
                .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.55))
                .padding(.horizontal, 12)
                .frame(height: SmartMomentsMetrics.chipHeight)
                .background(shape.fill(configuration.isPressed ? SparkVTheme.accentPressed : SparkVTheme.accent).opacity(isEnabled ? 1 : 0.4))
                .contentShape(shape)
                .fixedSize()
        }
    }
}

/// Undo: a hairline capsule.
struct SmartMomentQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .font(SparkVTheme.headline(11))
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, 11)
            .frame(height: SmartMomentsMetrics.chipHeight - 2)
            .background(shape.fill(configuration.isPressed ? SparkVTheme.surfaceHover : SparkVTheme.surface))
            .overlay(shape.strokeBorder(SparkVTheme.stroke, lineWidth: 0.75))
            .contentShape(shape)
            .fixedSize()
    }
}

struct SmartMomentTightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 8.5, weight: .bold))
            configuration.title
        }
    }
}

// MARK: - Agents hub tile

/// The hub tile: opens Smart Moments settings; right-click lists every
/// moment with its switch. Dims when Smart Moments is off.
struct SmartMomentsHubTile: View {
    @ObservedObject var settings: SmartMomentsSettings
    var onOpen: (() -> Void)? = nil
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button {
            if let onOpen { onOpen() } else { SmartMomentsSettingsWindowController.shared.show(settings: settings) }
        } label: {
            face
        }
        .buttonStyle(.plain)
        .onHover { hover.isOn = $0 }
        .contextMenu { SmartMomentsMenuItems(settings: settings) }
        .help(settings.isEnabled
              ? "Smart Moments: \(enabledCount) moments on. Click for settings."
              : "Smart Moments is off. Click to set it up.")
    }

    private var enabledCount: Int {
        MomentID.allCases.filter { settings.settings(for: $0).isEnabled }.count
    }

    private var face: some View {
        let on = settings.isEnabled
        let shape = RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
        let apple = SparkVTheme.usesTileTints
        let glyph: Color = apple
            ? (on ? Color.yellow : SparkVTheme.textTertiary)
            : (hover.isOn ? SparkVTheme.red : (on ? SparkVTheme.text.opacity(0.88) : SparkVTheme.textTertiary))
        return VStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(glyph)
            Text(on ? "Moments" : "Moments Off")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(hover.isOn ? SparkVTheme.text : (apple ? Color.white.opacity(on ? 0.82 : 0.55) : SparkVTheme.textSecondary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, minHeight: AgentHubMetrics.tileHeight)
        .background(
            shape.fill(apple
                       ? Color.white.opacity(hover.isOn ? 0.14 : 0.08)
                       : (hover.isOn ? SparkVTheme.red.opacity(0.10) : SparkVTheme.surface))
        )
        .overlay(
            shape.strokeBorder(apple ? Color.clear : (hover.isOn ? SparkVTheme.red.opacity(0.35) : SparkVTheme.stroke), lineWidth: 1)
        )
        .contentShape(shape)
        .animation(.easeOut(duration: 0.12), value: hover.isOn)
    }
}

// MARK: - Gear menu

/// The gear menu's "Smart Moments" submenu: `SmartMomentsMenu(settings:)`.
struct SmartMomentsMenu: View {
    @ObservedObject var settings: SmartMomentsSettings

    var body: some View {
        Menu {
            SmartMomentsMenuItems(settings: settings)
        } label: {
            Label("Smart Moments", systemImage: "sparkles")
        }
    }
}

/// Master switch, one switch per moment (grouped), and Settings…
struct SmartMomentsMenuItems: View {
    @ObservedObject var settings: SmartMomentsSettings

    var body: some View {
        Toggle("Smart Moments", isOn: Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 }))
        Divider()
        ForEach(SmartMomentGroup.allCases) { group in
            Section(group.title) {
                ForEach(group.moments) { moment in
                    Toggle(isOn: settings.binding(enabled: moment)) {
                        Text(moment.title + (settings.settings(for: moment).mode == .automatic ? " (auto)" : ""))
                    }
                }
            }
            .disabled(!settings.isEnabled)
        }
        Divider()
        Button("Smart Moments Settings…") { SmartMomentsSettingsWindowController.shared.show(settings: settings) }
    }
}

// MARK: - Grouping and copy

/// How Settings and the menu group the moments.
enum SmartMomentGroup: String, CaseIterable, Identifiable {
    case meetings, focus, devices, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetings: "Meetings & presenting"
        case .focus: "Focus"
        case .devices: "Devices & power"
        case .files: "Files, clipboard & screenshots"
        }
    }

    var moments: [MomentID] {
        switch self {
        case .meetings: [.meetingSoon, .meetingStarted, .meetingEnded, .screenSharing, .presentation]
        case .focus: [.deepWork, .lateNight]
        case .devices: [.lowBatteryRecording, .displayConnected]
        case .files: [.downloadFinished, .screenshotTaken, .copiedSmart]
        }
    }
}

extension MomentAction {
    /// Past tense for the auto-ran band and toasts ("Paused music").
    var doneText: String {
        switch self {
        case .pauseMusic: "Paused music"
        case .resumeMusic: "Resumed music"
        case .doNotDisturbOn: "Do Not Disturb on"
        case .doNotDisturbOff: "Do Not Disturb off"
        case .hideNotificationPreviews: "Previews hidden"
        case .showNotificationPreviews: "Previews back"
        case .hideClipboardBand: "Clipboard band hidden"
        case .showClipboardBand: "Clipboard band back"
        case .mirrorOff: "Mirror off"
        case .notesWrapUp: "Notes ready"
        case .presentationMode: "Presentation mode on"
        case .quietNotchActivities: "Notch quiet"
        case .talkTimer: "Talk timer started"
        case .nightMode: "Night mode on"
        case .lowerBrightness: "Brightness lowered"
        case .windDownTimer: "Wind-down started"
        case .startFocusSession: "Focus started"
        case .sortDownload: "Sorted"
        case .cleanLink: "Link cleaned"
        case .formatCode: "Code formatted"
        case .copyImage: "Copied"
        default: title
        }
    }
}

extension PermissionCenter.Permission {
    /// "camera", "microphone": for "Needs camera access".
    var smartMomentsName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .camera: "camera"
        case .microphone: "microphone"
        case .speech: "speech recognition"
        case .calendars: "calendar"
        case .reminders: "reminders"
        case .systemAudio: "system audio"
        case .notifications: "notification"
        case .bluetooth: "Bluetooth"
        case .automation: "automation"
        case .downloadsFolder: "Downloads folder"
        }
    }
}
