import AppKit
import SwiftUI

// MARK: - Palette

enum OnboardingStyle {
    // Computed, so they follow a change of look.
    static var background: Color { SparkVTheme.background }
    static var card: Color { SparkVTheme.surface }
    /// Apple cards are flat; SparkV Red draws a hairline.
    static var cardBorder: Color { SparkVTheme.choose(apple: Color.white.opacity(0.05), sparkv: SparkVTheme.stroke) }
    /// System accent (blue) in Apple, signal red in SparkV Red.
    static var accent: Color { SparkVTheme.accent }
    static var accentDeep: Color { SparkVTheme.accentPressed }
    static var warning: Color { SparkVTheme.warning }
    static let windowSize = CGSize(width: 780, height: 680)
}

/// SparkV's mark: a signal-red squircle with a spark (the logo stays red
/// in both looks).
struct OnboardingMark: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [SparkVTheme.brandRed, Color(red: 215 / 255, green: 19 / 255, blue: 29 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: max(0.5, size * 0.015))
            )
            .shadow(color: SparkVTheme.choose(apple: Color.black.opacity(0.35), sparkv: SparkVTheme.brandRed.opacity(0.4)), radius: size * 0.3, y: size * 0.08)
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    var isEnabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.45))
            .padding(.horizontal, 18)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(isEnabled
                          ? (configuration.isPressed ? OnboardingStyle.accentDeep : OnboardingStyle.accent)
                          : SparkVTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .strokeBorder(isEnabled ? Color.clear : SparkVTheme.stroke)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct OnboardingSecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 13, weight: .medium))
            .foregroundStyle(SparkVTheme.text)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 32)
            .background(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .strokeBorder(SparkVTheme.stroke)
            )
    }
}

// MARK: - Root

struct OnboardingRootView: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        VStack(spacing: 0) {
            OnboardingHeader(step: controller.step)
                .padding(.top, 30)
                .padding(.horizontal, 28)
            ZStack {
                switch controller.step {
                case .welcome:
                    OnboardingWelcomePage()
                        .transition(pageTransition)
                case .terms:
                    OnboardingTermsPage(controller: controller)
                        .transition(pageTransition)
                case .permissions:
                    OnboardingPermissionsPage(controller: controller)
                        .transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.42, dampingFraction: 0.88), value: controller.step)
            OnboardingFooter(controller: controller)
        }
        .frame(minWidth: OnboardingStyle.windowSize.width, maxWidth: .infinity, minHeight: OnboardingStyle.windowSize.height, maxHeight: .infinity)
        .background {
            if SparkVTheme.isApple {
                // macOS Setup Assistant: plain vibrant dark ground.
                AppearanceWindowBackground()
            } else {
                ZStack {
                    OnboardingStyle.background
                    RadialGradient(colors: [OnboardingStyle.accent.opacity(0.22), .clear], center: .topTrailing, startRadius: 10, endRadius: 560)
                    RadialGradient(colors: [OnboardingStyle.accent.opacity(0.06), .clear], center: .bottomLeading, startRadius: 10, endRadius: 420)
                }
            }
        }
        .foregroundStyle(SparkVTheme.text)
        .tint(SparkVTheme.accent)
        .environment(\.colorScheme, .dark)
    }

    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 28)),
            removal: .opacity.combined(with: .offset(x: -28))
        )
    }
}

private struct OnboardingHeader: View {
    let step: OnboardingController.Step

    var body: some View {
        HStack(spacing: 10) {
            OnboardingMark(size: 26)
            Text("SparkV")
                .font(.system(size: 15, weight: .bold))
                .tracking(-0.3)
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingController.Step.allCases) { item in
                    let isCurrent = item == step
                    let isDone = item.rawValue < step.rawValue
                    HStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isCurrent || isDone ? OnboardingStyle.accent : SparkVTheme.surface)
                                .overlay(Circle().strokeBorder(isCurrent || isDone ? Color.clear : SparkVTheme.stroke))
                                .frame(width: 18, height: 18)
                            if isDone {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                            } else {
                                Text("\(item.rawValue + 1)").font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(isCurrent ? Color.white : SparkVTheme.textSecondary)
                            }
                        }
                        Text(item.title)
                            .font(.system(size: 11.5, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? SparkVTheme.text : SparkVTheme.textSecondary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Capsule().fill(isCurrent ? SparkVTheme.surface : Color.clear))
                    .overlay(Capsule().strokeBorder(isCurrent ? SparkVTheme.stroke : Color.clear))
                    if item != OnboardingController.Step.allCases.last {
                        Rectangle().fill(SparkVTheme.stroke).frame(width: 14, height: 1)
                    }
                }
            }
        }
    }
}

private struct OnboardingFooter: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        HStack(spacing: 10) {
            switch controller.step {
            case .welcome:
                Label("Everything runs on this Mac. Setup takes about a minute.", systemImage: "lock.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                Spacer()
                Button("Get Started") { controller.next() }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .terms:
                Button("Back") { controller.back() }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                Spacer()
                if !controller.store.hasAcceptedCurrentTerms {
                    Button("Decline and Quit") { NSApp.terminate(nil) }
                        .buttonStyle(OnboardingSecondaryButtonStyle())
                }
                Button("Agree and Continue") { controller.acceptTerms() }
                    .buttonStyle(OnboardingPrimaryButtonStyle(isEnabled: controller.agreesToTerms))
                    .disabled(!controller.agreesToTerms)
                    .keyboardShortcut(.defaultAction)
            case .permissions:
                Button("Back") { controller.back() }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                Text("Change these any time in System Settings › Privacy & Security.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .padding(.leading, 4)
                Spacer()
                Button(controller.essentialsGranted ? "Done" : "Done for Now") { controller.finish() }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 64)
        .background(Color.black.opacity(0.35))
        .overlay(alignment: .top) { Rectangle().fill(SparkVTheme.stroke).frame(height: 1) }
    }
}

// MARK: - Welcome

private struct OnboardingWelcomePage: View {
    private struct Highlight: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        let tint: Color
        var id: String { title }
    }

    private let highlights: [Highlight] = [
        Highlight(symbol: "music.note", title: "Now Playing", detail: "Album art, controls and a live scrubber in the notch.", tint: .pink),
        Highlight(symbol: "tray.full.fill", title: "Tray & AirDrop", detail: "Drop files on the notch, drag them out anywhere.", tint: .blue),
        Highlight(symbol: "mic.fill", title: "Dictation & Clicky", detail: "Hold a key to talk, ask about what’s on screen.", tint: .orange),
        Highlight(symbol: "timer", title: "Focus & Timer", detail: "Pomodoro sessions with a calm on-device recap.", tint: .indigo),
        Highlight(symbol: "calendar", title: "Meetings", detail: "“Standup in 4 min” with a one-click Join.", tint: .red),
        Highlight(symbol: "square.grid.2x2.fill", title: "Agents & Spaces", detail: "Clipboard, search, capture and AI helpers.", tint: .teal),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            OnboardingMark(size: 76)
                .padding(.bottom, 20)
            LabsBEyebrow("SparkV / Notch")
                .padding(.bottom, 10)
            Text("Welcome to SparkV")
                .font(.system(size: 34, weight: .bold))
                .tracking(-1.2)
            Text("Your MacBook’s notch, turned into a control center.")
                .font(.system(size: 14))
                .foregroundStyle(SparkVTheme.textSecondary)
                .padding(.top, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(highlights) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        // Apple: a System Settings icon in the feature's
                        // color; SparkV Red: a monochrome tile.
                        RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                            .fill(SparkVTheme.isApple ? AnyShapeStyle(item.tint.gradient) : AnyShapeStyle(SparkVTheme.surface))
                            .frame(width: 32, height: 32)
                            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.choose(apple: Color.white.opacity(0.14), sparkv: SparkVTheme.stroke)))
                            .overlay(Image(systemName: item.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(SparkVTheme.choose(apple: Color.white, sparkv: SparkVTheme.text)))
                        Text(item.title)
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(-0.2)
                        Text(item.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SparkVTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(OnboardingStyle.card))
                    .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(OnboardingStyle.cardBorder))
                }
            }
            .padding(.top, 30)
            .padding(.horizontal, 44)
            Spacer(minLength: 12)
        }
    }
}

// MARK: - Terms

private struct OnboardingTermsPage: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LabsBEyebrow("Step 2 / Terms")
                .padding(.bottom, 8)
            Text("Terms of Use & Privacy")
                .font(.system(size: 26, weight: .bold))
                .tracking(-0.8)
            Text("Version \(OnboardingTerms.version) · Effective \(OnboardingTerms.effectiveDate). The short version: your data stays on your Mac.")
                .font(.system(size: 12.5))
                .foregroundStyle(SparkVTheme.textSecondary)
                .padding(.top, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(OnboardingTerms.sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(OnboardingStyle.accent)
                                    .frame(width: 18)
                                Text(section.title)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .tracking(-0.2)
                                    .foregroundStyle(SparkVTheme.text)
                            }
                            ForEach(Array(section.points.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    if SparkVTheme.isApple {
                                        Circle().fill(SparkVTheme.textTertiary).frame(width: 4, height: 4).offset(y: -2)
                                    } else {
                                        Capsule().fill(SparkVTheme.red.opacity(0.8)).frame(width: 6, height: 1.5).offset(y: -3)
                                    }
                                    Text(point)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(SparkVTheme.text.opacity(0.86))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(OnboardingStyle.card))
                        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(OnboardingStyle.cardBorder))
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.top, 16)
            HStack(spacing: 10) {
                Toggle(isOn: $controller.agreesToTerms) {
                    Text("I have read and agree to the Terms of Use and the Privacy summary.")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .toggleStyle(.checkbox)
                .disabled(controller.store.hasAcceptedCurrentTerms)
                Spacer()
                if let accepted = controller.termsAcceptedSummary {
                    Label(accepted, systemImage: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 44)
        .padding(.top, 22)
    }
}

// MARK: - Permissions

private struct OnboardingPermissionsPage: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    LabsBEyebrow("Step 3 / Permissions")
                        .padding(.bottom, 4)
                    Text("Permissions")
                        .font(.system(size: 26, weight: .bold))
                        .tracking(-0.8)
                    Text("SparkV asks only when you click Allow. Turn on what you use; everything else keeps working.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(SparkVTheme.textSecondary)
                }
                Spacer()
                OnboardingProgressRing(granted: controller.grantedCount, total: controller.countedPermissions.count)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if controller.showsStaleCard {
                        OnboardingStaleGrantCard(controller: controller)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    ForEach(OnboardingPermission.Group.allCases) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            LabsBEyebrow(group.rawValue)
                                .padding(.leading, 4)
                            VStack(spacing: 0) {
                                let rows = OnboardingPermission.allCases.filter { $0.group == group }
                                ForEach(rows) { permission in
                                    OnboardingPermissionRow(controller: controller, permission: permission)
                                    if permission != rows.last {
                                        Rectangle().fill(SparkVTheme.stroke).frame(height: 1).padding(.leading, 56)
                                    }
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(OnboardingStyle.card))
                            .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(OnboardingStyle.cardBorder))
                        }
                    }
                    OnboardingSigningNote(controller: controller)
                }
                .padding(.vertical, 2)
                .animation(.easeInOut(duration: 0.25), value: controller.showsStaleCard)
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 36)
        .padding(.top, 22)
    }
}

private struct OnboardingProgressRing: View {
    let granted: Int
    let total: Int

    var body: some View {
        let fraction = total == 0 ? 0 : Double(granted) / Double(total)
        ZStack {
            Circle().stroke(SparkVTheme.stroke, lineWidth: 5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(OnboardingStyle.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: fraction)
            VStack(spacing: 0) {
                Text("\(granted)/\(total)")
                    .font(.system(size: 14, weight: .bold).monospacedDigit())
                Text("ALLOWED")
                    .font(SparkVTheme.eyebrow(7.5))
                    .tracking(LabsBStyle.eyebrowTracking(0.8))
                    .foregroundStyle(SparkVTheme.textTertiary)
            }
        }
        .frame(width: 58, height: 58)
    }
}

private struct OnboardingPermissionRow: View {
    @ObservedObject var controller: OnboardingController
    let permission: OnboardingPermission

    var body: some View {
        let status = controller.status(of: permission)
        let action = controller.action(for: permission)
        let isPending = controller.pending.contains(permission)
        HStack(alignment: .center, spacing: 12) {
            if SparkVTheme.isApple {
                // System Settings › Privacy & Security: white glyph on the
                // permission's color.
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(permission.tint.gradient)
                    .frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
                    .overlay(Image(systemName: permission.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.white))
            } else {
                RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous)
                    .fill(status.isGranted ? SparkVTheme.surface : SparkVTheme.surfaceHover)
                    .frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerSmall, style: .continuous).strokeBorder(SparkVTheme.stroke))
                    .overlay(Image(systemName: permission.symbol).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(status.isGranted ? SparkVTheme.textSecondary : SparkVTheme.text))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 13, weight: .semibold))
                    if permission.isEssential && !status.isGranted {
                        Text("RECOMMENDED")
                            .font(SparkVTheme.eyebrow(8))
                            .tracking(LabsBStyle.eyebrowTracking(0.8))
                            .foregroundStyle(OnboardingStyle.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(OnboardingStyle.accent.opacity(0.15)))
                    }
                }
                Text(permission.features)
                    .font(.system(size: 11))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                hint(status: status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            OnboardingStatusPill(status: status)
            trailing(status: status, action: action, isPending: isPending)
                .frame(width: 128, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func hint(status: OnboardingPermissionStatus) -> some View {
        if permission == .accessibility, !status.isGranted, status != .unknown, !controller.staleAccessibility {
            Button("Already on in System Settings?") { controller.userReportsGranted() }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
                .padding(.top, 2)
        } else if permission == .screenRecording, controller.screenRecordingNeedsRestart {
            HStack(spacing: 6) {
                Text("Turned it on? It takes effect after a restart.")
                    .font(.system(size: 11))
                    .foregroundStyle(OnboardingStyle.warning)
                Button("Restart SparkV") { controller.relaunch() }
                    .buttonStyle(.link)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.top, 2)
        } else if permission == .screenRecording, status.isGranted {
            // macOS 15+ re-confirms screen access now and then; say so up
            // front so the reminder isn't mistaken for a lost permission.
            Label("macOS may ask about once a month to confirm screen access. Click Allow; nothing was lost.", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
                .help(PermissionCenter.screenCaptureReminderNote)
        } else if permission == .screenRecording, !status.isGranted, status != .unknown, !controller.staleScreenRecording {
            Button("Already on in System Settings?") { controller.userReportsGranted(.screenRecording) }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
                .padding(.top, 2)
        } else if permission.automationBundleID != nil, status == .appNotRunning {
            Text("macOS can check this only while the app is open.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
    }

    @ViewBuilder
    private func trailing(status: OnboardingPermissionStatus, action: OnboardingRowAction, isPending: Bool) -> some View {
        HStack(spacing: 6) {
            if isPending {
                ProgressView().controlSize(.small)
                Text("Waiting…").font(.system(size: 11.5)).foregroundStyle(SparkVTheme.textSecondary)
            } else if status.isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(OnboardingPermissionStatus.granted.color)
            } else if action != .none {
                Button(buttonTitle(action)) { controller.perform(permission) }
                    .buttonStyle(OnboardingSecondaryButtonStyle(compact: true))
                if action != .openSettings {
                    Button {
                        controller.openSettings(for: permission)
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(OnboardingSecondaryButtonStyle(compact: true))
                    .help("Open \(permission.title) in System Settings")
                }
            }
        }
    }

    private func buttonTitle(_ action: OnboardingRowAction) -> String {
        if action == .launchAndRequest, let id = permission.automationBundleID {
            return id == "com.google.Chrome" ? "Open Chrome…" : (id == "com.apple.mail" ? "Open Mail…" : "Open Safari…")
        }
        return action.title
    }
}

private struct OnboardingStatusPill: View {
    let status: OnboardingPermissionStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 6, height: 6)
            Text(status.label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(status.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(status.color.opacity(0.12)))
        .fixedSize()
    }
}

// MARK: - Stale grant

private struct OnboardingStaleGrantCard: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        let adHoc = !controller.identity.grantsSurviveRebuilds
        let permissions = controller.stalePermissions.isEmpty ? [OnboardingPermission.accessibility] : controller.stalePermissions
        let names = permissions.map(\.title).joined(separator: " and ")
        let first = permissions[0]
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(OnboardingStyle.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(permissions.count > 1 ? "SparkV can’t use the \(names) switches you turned on" : "SparkV can’t use the \(names) switch you turned on")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(explanation(adHoc: adHoc, names: names))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    controller.hideStaleCard()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Hide")
            }
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Open \(names), select SparkV and click the minus (−) button to remove the old entry.")
                step(2, "Drag SparkV in from the card in the corner (or from Finder) and turn it on." + (permissions.contains(.screenRecording) ? " Then restart SparkV for Screen Recording." : ""))
            }
            HStack(spacing: 8) {
                Button("Open \(first.title) & Show SparkV") { OnboardingFixes.openSettingsAndRevealApp(for: first) }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                Button("Remove Old Entry & Ask Again") { controller.resetAccessibilityEntry() }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .help("Runs “tccutil reset” for SparkV only (\(names)), then shows the macOS prompt again.")
            }
            if let note = controller.resetNote {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if adHoc {
                Rectangle().fill(SparkVTheme.stroke).frame(height: 1)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "signature")
                        .font(.system(size: 14))
                        .foregroundStyle(OnboardingStyle.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stop this from happening after every rebuild")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("Run Scripts/create-signing-identity.sh once in Terminal, then ./build.sh. Builds are then signed with a stable “NotchIsland Developer” certificate and keep their permissions. You renew the grants one last time after that.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Copy Terminal Command") { OnboardingFixes.copySigningCommand() }
                                .buttonStyle(OnboardingSecondaryButtonStyle(compact: true))
                            if OnboardingFixes.projectDirectory != nil {
                                Button("Show Script in Finder") { OnboardingFixes.revealSigningScript() }
                                    .buttonStyle(OnboardingSecondaryButtonStyle(compact: true))
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).fill(OnboardingStyle.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: SparkVTheme.cornerMedium, style: .continuous).strokeBorder(OnboardingStyle.warning.opacity(0.30)))
    }

    private func explanation(adHoc: Bool, names: String) -> String {
        let cause: String
        if controller.staleAccessibility, !controller.staleScreenRecording, case .stale(_, .rebuilt) = controller.diagnosis {
            cause = "Accessibility was on for an earlier build of SparkV. This build has a different code signature, so macOS treats it as a new app, while the switch in System Settings still belongs to the old one."
        } else {
            cause = "macOS keeps each grant with the exact app that received it. If SparkV was rebuilt or moved after you turned it on, the switch in System Settings still belongs to the old copy."
        }
        return adHoc ? cause + " This build is signed ad hoc, so every rebuild has a new signature." : cause
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 17, height: 17)
                .background(Circle().fill(SparkVTheme.surfaceHover))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingSigningNote: View {
    @ObservedObject var controller: OnboardingController

    var body: some View {
        let identity = controller.identity
        HStack(spacing: 8) {
            Image(systemName: identity.grantsSurviveRebuilds ? "checkmark.shield.fill" : "info.circle")
                .foregroundStyle(identity.grantsSurviveRebuilds ? OnboardingPermissionStatus.granted.color : .secondary)
            Text(text(identity))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private func text(_ identity: OnboardingCodeIdentity) -> String {
        if identity.grantsSurviveRebuilds {
            return "Signed by \(identity.signer ?? "a certificate"). Permissions carry over when SparkV is rebuilt."
        }
        if identity.isAdHoc {
            return "This build is signed ad hoc, so macOS asks again after each rebuild. Scripts/create-signing-identity.sh fixes that."
        }
        return "This copy isn’t code signed, so macOS may not keep its permissions."
    }
}
