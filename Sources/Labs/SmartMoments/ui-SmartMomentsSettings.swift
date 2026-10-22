import AppKit
import SwiftUI

// The "Smart Moments" settings window: a master switch, then every moment
// with its on/off switch, Ask first | Do automatically, and (expanded) its
// actions with permission state and the moment's tunables.

/// A ModeEngine mode the Night / Presentation pickers can use. Wiring
/// passes `ModeEngine.shared.modes.map { .init(id: $0.id, name: $0.name, symbol: $0.symbol) }`.
struct SmartMomentsModeChoice: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let symbol: String
}

@MainActor
final class SmartMomentsSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SmartMomentsSettingsWindowController()

    /// Set in wiring; nil shows only the built-in presets.
    var modeChoices: () -> [SmartMomentsModeChoice] = { [] }
    /// Set in wiring: false for an action this build has no hook for (its
    /// row says so and can't be ticked, so Settings never promises it).
    var isActionAvailable: @MainActor (MomentAction) -> Bool = { _ in true }
    /// Expanded rows (shared with the window, kept between openings).
    let expansion = SmartMomentsExpansion()

    private var window: NSWindow?

    func show(settings: SmartMomentsSettings, focus moment: MomentID? = nil) {
        if let moment { expansion.expanded = [moment] }
        let window = window ?? makeWindow(settings: settings)
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(settings: SmartMomentsSettings) -> NSWindow {
        let root = SmartMomentsSettingsView(settings: settings, expansion: expansion, modeChoices: modeChoices())
            .followsAppearance()
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Smart Moments"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(SparkVTheme.background)
        window.isReleasedWhenClosed = false
        window.setContentSize(SmartMomentsSettingsView.preferredSize)
        window.contentMinSize = NSSize(width: 560, height: 480)
        window.center()
        window.setFrameAutosaveName("SparkV.SmartMoments")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        let stillOpen = NSApp.windows.contains { $0 !== window && $0.canBecomeMain && $0.isVisible }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Which moment rows are expanded.
@MainActor
final class SmartMomentsExpansion: ObservableObject {
    @Published var expanded: Set<MomentID> = []

    func toggle(_ moment: MomentID) {
        if expanded.contains(moment) { expanded.remove(moment) } else { expanded.insert(moment) }
    }
}

struct SmartMomentsSettingsView: View {
    static let preferredSize = NSSize(width: 640, height: 720)

    @ObservedObject var settings: SmartMomentsSettings
    @ObservedObject var expansion: SmartMomentsExpansion
    var modeChoices: [SmartMomentsModeChoice] = []
    /// Offscreen renders pass a fixed height (a ScrollView has no size of its own).
    var scrolls = true

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 14)
            Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
            if scrolls {
                ScrollView { content }
            } else {
                content
            }
        }
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { AppearanceWindowBackground().ignoresSafeArea() }
        .background(alignment: .topTrailing) { Rectangle().fill(SparkVTheme.glow).ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
    }

    // Header -------------------------------------------------------------

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Rectangle().fill(SparkVTheme.eyebrowDash).frame(width: 10, height: 1.5)
                    Text("SPARKV / SMART MOMENTS")
                        .font(SparkVTheme.eyebrow())
                        .tracking(1.2)
                        .foregroundStyle(SparkVTheme.textTertiary)
                }
                Text("Smart Moments")
                    .font(SparkVTheme.title(22))
                    .foregroundStyle(SparkVTheme.text)
                Text("SparkV notices what you're doing and offers one tap of help in the notch: before a call, while you share or present, when a download lands.")
                    .font(SparkVTheme.body(12))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                promises
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(get: { settings.isEnabled }, set: { settings.isEnabled = $0 }))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SparkVTheme.accent)
                .help(settings.isEnabled ? "Turn every Smart Moment off" : "Turn Smart Moments on")
        }
    }

    private var promises: some View {
        HStack(spacing: 14) {
            promise("record.circle", "Recording & captions always ask")
            promise("eye.slash", "Never hides or quits apps")
            promise("arrow.uturn.backward", "Undo what it changed")
        }
    }

    private func promise(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
            Text(text)
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .lineLimit(1)
        }
    }

    // Moments --------------------------------------------------------------

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(SmartMomentGroup.allCases) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title.uppercased())
                        .font(SparkVTheme.eyebrow())
                        .tracking(1.0)
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .padding(.leading, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(group.moments.enumerated()), id: \.element) { index, moment in
                            if index > 0 {
                                Rectangle().fill(SparkVTheme.stroke).frame(height: 1).padding(.leading, 52)
                            }
                            SmartMomentSettingsRow(
                                moment: moment, settings: settings, expansion: expansion, modeChoices: modeChoices
                            )
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(SparkVTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(SparkVTheme.stroke)
                    )
                }
            }
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .disabled(!settings.isEnabled)
        .opacity(settings.isEnabled ? 1 : 0.5)
    }

    private var footer: some View {
        HStack {
            Text("Moments marked Do automatically run on their own and show a short Done · Undo. Anything that records audio, captions others, joins a call or moves a file always waits for your tap.")
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            Button("Reset Smart Moments") { settings.resetToDefaults() }
                .buttonStyle(SparkVSecondaryButtonStyle())
                .help("Put every moment, action and number back to its default")
        }
        .padding(.top, 2)
    }
}

/// One moment: symbol, title and trigger, Ask | Auto, on/off; expands to
/// its actions and tunables.
struct SmartMomentSettingsRow: View {
    let moment: MomentID
    @ObservedObject var settings: SmartMomentsSettings
    @ObservedObject var expansion: SmartMomentsExpansion
    let modeChoices: [SmartMomentsModeChoice]
    @StateObject private var hover = ViewFlag()

    private var momentSettings: MomentSettings { settings.settings(for: moment) }
    private var isExpanded: Bool { expansion.expanded.contains(moment) }

    var body: some View {
        let s = momentSettings
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { expansion.toggle(moment) }
                } label: {
                    HStack(spacing: 12) {
                        SmartMomentGlyph(moment: moment, size: 28, isDimmed: !s.isEnabled)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(moment.title)
                                    .font(SparkVTheme.headline(13))
                                    .foregroundStyle(s.isEnabled ? SparkVTheme.text : SparkVTheme.textSecondary)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(SparkVTheme.textTertiary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                            Text(subtitle(s))
                                .font(SparkVTheme.body(11))
                                .foregroundStyle(SparkVTheme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide actions" : "Choose what this moment does")

                SmartMomentModePicker(selection: settings.binding(mode: moment))
                    .disabled(!s.isEnabled)
                    .opacity(s.isEnabled ? 1 : 0.45)
                Toggle("", isOn: settings.binding(enabled: moment))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(SparkVTheme.accent)
                    .help(s.isEnabled ? "Turn \(moment.title) off" : "Turn \(moment.title) on")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if isExpanded {
                SmartMomentDetail(moment: moment, settings: settings, modeChoices: modeChoices)
                    .padding(.leading, 52)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .disabled(!s.isEnabled)
                    .opacity(s.isEnabled ? 1 : 0.5)
            }
        }
        .background(hover.isOn && !isExpanded ? SparkVTheme.hoverFill.opacity(0.5) : Color.clear)
        .onHover { hover.isOn = $0 }
    }

    private func subtitle(_ s: MomentSettings) -> String {
        if s.isEnabled, s.isSnoozed(at: Date()), let until = s.snoozedUntil {
            return "Snoozed until " + until.formatted(date: .omitted, time: .shortened) + " · " + moment.triggerDescription
        }
        return moment.triggerDescription
    }
}

/// Ask first | Do automatically, as a compact two-segment control.
struct SmartMomentModePicker: View {
    @Binding var selection: MomentMode

    var body: some View {
        HStack(spacing: 2) {
            segment(.ask, "Ask first")
            segment(.automatic, "Automatic")
        }
        .padding(2)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(Capsule(style: .continuous).strokeBorder(SparkVTheme.stroke))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("When it happens")
    }

    private func segment(_ mode: MomentMode, _ title: String) -> some View {
        let on = selection == mode
        return Button {
            selection = mode
        } label: {
            Text(title)
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(on ? SparkVTheme.choose(apple: SparkVTheme.text, sparkv: SparkVTheme.accent) : SparkVTheme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(Capsule(style: .continuous).fill(on ? SparkVTheme.choose(apple: Color.white.opacity(0.16), sparkv: SparkVTheme.accentSoft) : Color.clear))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(mode == .ask ? "Show a band and wait for your tap" : "Do Not Disturb, pausing music and the like run on their own, with Undo. Recording and captions still ask.")
    }
}

/// The expanded part of a row: actions, then tunables.
struct SmartMomentDetail: View {
    let moment: MomentID
    @ObservedObject var settings: SmartMomentsSettings
    let modeChoices: [SmartMomentsModeChoice]
    @ObservedObject private var permissions = PermissionCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(moment.actions) { action in
                    actionRow(action)
                }
            }
            if settings.settings(for: moment).mode == .automatic, moment.actions.contains(where: \.alwaysAsks) {
                note("hand.tap", "Runs on its own, except \(alwaysAskTitles) — those wait for your tap.")
            }
            tunables
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).fill(Color.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke)
        )
    }

    private var alwaysAskTitles: String {
        let titles = moment.actions.filter(\.alwaysAsks).map(\.title)
        return ListFormatter.localizedString(byJoining: titles)
    }

    private func actionRow(_ action: MomentAction) -> some View {
        let available = SmartMomentsSettingsWindowController.shared.isActionAvailable(action)
        return HStack(spacing: 8) {
            Toggle(isOn: available ? settings.binding(action: action, in: moment) : .constant(false)) {
                HStack(spacing: 7) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SparkVTheme.textSecondary)
                        .frame(width: 16)
                    Text(action.title)
                        .font(SparkVTheme.body(12))
                        .foregroundStyle(SparkVTheme.text)
                }
            }
            .toggleStyle(.checkbox)
            .tint(SparkVTheme.accent)
            .disabled(!available)
            .opacity(available ? 1 : 0.5)
            Spacer(minLength: 8)
            trailing(for: action, available: available)
        }
        .frame(minHeight: 20)
    }

    @ViewBuilder
    private func trailing(for action: MomentAction, available: Bool) -> some View {
        if !available {
            tag("Not available yet", dot: nil)
        } else if let missing = action.requiredPermissions.first(where: { !permissions.isGranted($0) }) {
            HStack(spacing: 6) {
                Text("Needs \(missing.smartMomentsName) access")
                    .font(SparkVTheme.caption(10.5))
                    .foregroundStyle(SparkVTheme.warning)
                Button("Allow") {
                    Task { await PermissionCenter.shared.request(missing, from: SmartMomentsMetrics.feature) }
                }
                .buttonStyle(SmartMomentQuietButtonStyle())
                .controlSize(.small)
            }
        } else if action.needsConsent {
            tag("Always asks · uses the mic", dot: SparkVTheme.recording)
        } else if action.alwaysAsks {
            tag("Always asks", dot: nil)
        } else if action.reversal != nil {
            tag("Undone when it ends", dot: nil)
        }
    }

    private func tag(_ text: String, dot: Color?) -> some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 5, height: 5) }
            Text(text)
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
        }
    }

    private func note(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(SparkVTheme.caption(10.5))
        .foregroundStyle(SparkVTheme.textSecondary)
    }

    // Tunables -------------------------------------------------------------

    @ViewBuilder
    private var tunables: some View {
        switch moment {
        case .meetingSoon:
            stepper("Offer it", value: tunable(\.meetingLeadMinutes), range: 1...10) { "\($0) min before" }
        case .deepWork:
            stepper("After", value: tunable(\.deepWorkMinutes), range: 20...120, step: 5) { "\($0) min in one app" }
        case .lowBatteryRecording:
            stepper("At", value: tunable(\.lowBatteryPercent), range: 5...30) { "\($0) % battery" }
        case .lateNight:
            VStack(alignment: .leading, spacing: 8) {
                tunableRow("From") {
                    Picker("", selection: tunable(\.lateNightHour)) {
                        ForEach([20, 21, 22, 23, 0, 1, 2, 3], id: \.self) { hour in
                            Text(Self.hourText(hour)).tag(hour)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                modePicker("Night mode", selection: tunable(\.nightModeID), builtIn: "Built-in wind-down")
            }
        case .presentation:
            modePicker("Presentation mode", selection: tunable(\.presentationModeID), builtIn: "Do Not Disturb, hide previews, pause music")
        default:
            EmptyView()
        }
    }

    private func tunable<T>(_ path: WritableKeyPath<MomentTunables, T>) -> Binding<T> {
        Binding(
            get: { settings.tunables[keyPath: path] },
            set: { value in
                var t = settings.tunables
                t[keyPath: path] = value
                settings.tunables = t
            }
        )
    }

    private func tunableRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(SparkVTheme.caption(10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .frame(width: 112, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, text: @escaping (Int) -> String) -> some View {
        tunableRow(label) {
            Stepper(value: value, in: range, step: step) {
                Text(text(value.wrappedValue))
                    .font(SparkVTheme.body(12).monospacedDigit())
                    .foregroundStyle(SparkVTheme.text)
            }
            .fixedSize()
        }
    }

    private func modePicker(_ label: String, selection: Binding<UUID?>, builtIn: String) -> some View {
        tunableRow(label) {
            Picker("", selection: selection) {
                Text(builtIn).tag(UUID?.none)
                if !modeChoices.isEmpty { Divider() }
                ForEach(modeChoices) { mode in
                    Label(mode.name, systemImage: mode.symbol).tag(UUID?.some(mode.id))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    static func hourText(_ hour: Int) -> String {
        var c = DateComponents()
        c.hour = hour
        c.minute = 0
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}
