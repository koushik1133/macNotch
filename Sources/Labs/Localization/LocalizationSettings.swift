import AppKit
import SwiftUI

// The language picker: Settings › General (LocalizationSettingsSection) and
// the gear menu (LocalizationMenuItems). Nothing here talks to the network;
// the translations ship inside the app.

/// The per-app language choice. Created once (`.shared`); `start()` follows
/// the Mac's language order through NSLocale's change notification, so
/// "Same as Mac" stays truthful without polling.
@MainActor
final class LocalizationController: ObservableObject {
    static let shared = LocalizationController()

    @Published private(set) var choice: SparkVLanguage
    /// What "Same as Mac" resolves to right now.
    @Published private(set) var systemResolved: SparkVLanguage
    /// The language the running app picked at launch.
    let running: SparkVLanguage

    private let defaults: UserDefaults
    private var localeObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        choice = LocalizationPreferences.choice(in: defaults)
        running = LocalizationPreferences.running(preferred: bundle.preferredLocalizations)
        systemResolved = LocalizationPreferences.systemResolved(preferredLanguages: Self.macLanguages(defaults: defaults))
    }

    var needsRestart: Bool {
        LocalizationPreferences.needsRestart(choice: choice, running: running, systemResolved: systemResolved)
    }

    /// The language SparkV will use after a restart.
    var effective: SparkVLanguage { choice == .system ? systemResolved : choice }

    func start() {
        guard localeObserver == nil else { return }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystem() }
        }
    }

    func stop() {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
        localeObserver = nil
    }

    func select(_ language: SparkVLanguage) {
        guard language != choice else { return }
        LocalizationPreferences.save(language, in: defaults)
        choice = language
        AppLog.log("Localization: language set to \(language.rawValue) (applies after restart)")
    }

    func restartNow() {
        AppLog.log("Localization: restarting to apply \(effective.code ?? "the Mac's language")")
        PermissionCenter.shared.relaunch(from: "Language")
    }

    /// A language's second line in the picker, in the language on screen
    /// now: "Spanisch" in a German SparkV. The running language's own row
    /// says "Current language" instead of repeating its name.
    func detail(for language: SparkVLanguage) -> String {
        if language == .system {
            let name = systemResolved.displayName(inUILanguage: running.rawValue, standalone: false) ?? systemResolved.nativeName
            return String(format: "Now %@".sparkVLocalized, name)
        }
        if language == running { return "Current language".sparkVLocalized }
        return uiName(language)
    }

    /// The name in the running UI language (native name as the fallback).
    func uiName(_ language: SparkVLanguage) -> String {
        language.displayName(inUILanguage: running.rawValue) ?? language.nativeName
    }

    /// The submenu title: translated, plus the English word when SparkV is
    /// not in English, so someone who switched by mistake can find it.
    var menuTitle: String {
        let local = "Language".sparkVLocalized
        return running == .english || local == "Language" ? local : "\(local) · Language"
    }

    func openLanguageAndRegion() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshSystem() {
        systemResolved = LocalizationPreferences.systemResolved(preferredLanguages: Self.macLanguages(defaults: defaults))
    }

    /// The Mac's language order, ignoring SparkV's own AppleLanguages
    /// override (which `Locale.preferredLanguages` would report).
    private static func macLanguages(defaults: UserDefaults) -> [String] {
        let global = defaults.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return global ?? Locale.preferredLanguages
    }
}

// MARK: - Settings › General

/// Language card for Settings › General.
struct LocalizationSettingsSection: View {
    @ObservedObject private var controller = LocalizationController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(spacing: 6) {
                LocalizationLanguageRow(
                    language: .system,
                    detail: controller.detail(for: .system),
                    isSelected: controller.choice == .system
                ) { select(.system) }
                ForEach(SparkVLanguage.shipped) { language in
                    LocalizationLanguageRow(
                        language: language,
                        detail: controller.detail(for: language),
                        isSelected: controller.choice == language
                    ) { select(language) }
                }
            }
            if controller.needsRestart {
                restartBanner
                    .transition(.sparkVEnter)
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .fill(SparkVTheme.surface.opacity(SparkVTheme.isApple ? 0.6 : 0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous)
                .strokeBorder(SparkVTheme.stroke, lineWidth: 1)
        )
        .animation(SparkVMotion.respecting(SparkVMotion.easeOut()), value: controller.needsRestart)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    private func select(_ language: SparkVLanguage) {
        controller.select(language)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SparkVTheme.isApple ? SparkVTheme.textSecondary : SparkVTheme.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Language")
                    .font(SparkVTheme.headline(13))
                    .tracking(-0.2)
                    .foregroundStyle(SparkVTheme.text)
                Text("SparkV follows your Mac's language. Pick another one to use it for SparkV only.")
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var restartBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(SparkVTheme.accentText)
                .accessibilityHidden(true)
            Text(String(format: "Restart SparkV to switch to %@.".sparkVLocalized, controller.effective.nativeName))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(SparkVTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                controller.restartNow()
            } label: {
                Text("Restart Now")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SparkVTheme.onPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(SparkVTheme.primaryFill))
            }
            .buttonStyle(SparkVPressStyle())
            .help("Quits and reopens SparkV in the chosen language.")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                .fill(SparkVTheme.accentSoft)
        )
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Translations ship inside SparkV; nothing is sent off your Mac. Names from macOS and your apps, your own notes and AI replies stay in their own language.")
                .font(.system(size: 10.5))
                .foregroundStyle(SparkVTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            LocalizationLinkButton(title: "Language & Region Settings…") {
                LocalizationController.shared.openLanguageAndRegion()
            }
        }
    }
}

/// One selectable language: native name, a detail line, a check.
private struct LocalizationLanguageRow: View {
    let language: SparkVLanguage
    let detail: String
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    private var title: String {
        language == .system ? "Same as Mac".sparkVLocalized : language.nativeName
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if language == .system {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 11, weight: .semibold))
                    } else {
                        Text(verbatim: badge)
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                }
                    .foregroundStyle(isSelected ? SparkVTheme.onPrimary : SparkVTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isSelected ? SparkVTheme.primaryFill : SparkVTheme.surface)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SparkVTheme.text)
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SparkVTheme.accentText)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(isSelected ? SparkVTheme.accentSoft : Color.clear)
            )
            .sparkVHoverFill(hover.isOn && !isSelected, cornerRadius: SparkVTheme.cornerSmall)
            .contentShape(Rectangle())
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .animation(SparkVMotion.respecting(SparkVMotion.hover()), value: hover.isOn)
        .animation(SparkVMotion.respecting(SparkVMotion.snappy), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityValue(isSelected ? "Selected".sparkVLocalized : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var badge: String {
        language.rawValue.uppercased()
    }
}

/// Text button with the link color.
private struct LocalizationLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.sparkVLocalized)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SparkVTheme.link)
        }
        .buttonStyle(SparkVPressStyle())
    }
}

// MARK: - Gear menu

/// A Language submenu for the gear menu: the choice, then Restart when the
/// choice is waiting for one.
struct LocalizationMenuItems: View {
    @ObservedObject private var controller = LocalizationController.shared

    var body: some View {
        Menu {
            Picker("Language", selection: Binding(
                get: { controller.choice },
                set: { controller.select($0) }
            )) {
                Text("Same as Mac".sparkVLocalized).tag(SparkVLanguage.system)
                Divider()
                ForEach(SparkVLanguage.shipped) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if controller.needsRestart {
                Divider()
                Button("Restart SparkV to Apply") { controller.restartNow() }
            }
        } label: {
            Label(controller.menuTitle, systemImage: "globe")
        }
    }
}
