import AppKit
import SwiftUI

/// Band content for a mirrored notification: app icon on the left, sender /
/// title over one line of body text in the middle, the app's name trailing,
/// and (when the banner can be reached) Reply and Dismiss buttons. Clicking
/// the text opens the notification like clicking the banner would.
/// Privacy (`NotificationPrivacy`): the message text, or the sender too,
/// can be hidden.
struct NotificationActivityView: View {
    let content: NotificationContent
    let icon: NSImage?
    let privacy: NotificationPrivacy
    let actions: NotificationBandActions?

    init(content: NotificationContent, icon: NSImage?, privacy: NotificationPrivacy, actions: NotificationBandActions? = nil) {
        self.content = content
        self.icon = icon
        self.privacy = privacy
        self.actions = actions
    }

    /// The original form: full text, or sender and app with `hidesBody`.
    init(content: NotificationContent, icon: NSImage?, hidesBody: Bool) {
        self.init(content: content, icon: icon, privacy: hidesBody ? .senderOnly : .full)
    }

    private var text: NotificationBandText { NotificationBandText(content: content, privacy: privacy) }

    var body: some View {
        let text = text
        HStack(spacing: 10) {
            openArea(text)
            if let actions {
                HStack(spacing: 6) {
                    if let reply = actions.reply {
                        NotificationBandButton(systemImage: "arrowshape.turn.up.left.fill", label: "Reply", action: reply)
                    }
                    NotificationBandButton(systemImage: "xmark", label: "Dismiss", action: actions.dismiss)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .modifier(NotificationBandContextMenu(actions: actions))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text.spokenSummary)
        .modifier(NotificationBandAccessibilityActions(actions: actions))
    }

    /// Icon and text; a click opens the notification.
    @ViewBuilder
    private func openArea(_ text: NotificationBandText) -> some View {
        let row = HStack(spacing: 10) {
            leading
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SparkVTheme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let caption = text.appCaption {
                        Text(caption)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .lineLimit(1)
                            .frame(maxWidth: 84, alignment: .trailing)
                            .layoutPriority(-1)
                    } else if text.showsPrivacyGlyph {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(SparkVTheme.textTertiary)
                            .accessibilityHidden(true)
                    }
                }

                if let detail = text.detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(text.detailIsPlaceholder ? SparkVTheme.textTertiary : SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        if let open = actions?.open {
            Button(action: open) { row }
                .buttonStyle(SparkVPressStyle())
                .help(content.appName.map { "Open in \($0)" } ?? "Open")
        } else {
            row
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red), SparkVTheme.text)
        }
    }

}

/// Right-click on the band: Open, Reply, Dismiss, Mute <App>, macOS
/// settings. Nothing without actions (a preview, or buttons turned off).
private struct NotificationBandContextMenu: ViewModifier {
    let actions: NotificationBandActions?

    func body(content: Content) -> some View {
        if let actions {
            content.contextMenu {
                Button("Open") { actions.open() }
                if let reply = actions.reply { Button("Reply") { reply() } }
                Button("Dismiss") { actions.dismiss() }
                if let mute = actions.mute, let app = actions.appName {
                    Divider()
                    Button("Mute Notifications from \(app)") { mute() }
                }
                Divider()
                Button("macOS Notification Settings…") { NotificationMonitor.openSystemNotificationSettings() }
            }
        } else {
            content
        }
    }
}

/// What the band's buttons do (built by `NotificationMonitor`).
struct NotificationBandActions {
    var open: () -> Void
    /// Only when the banner offers Reply.
    var reply: (() -> Void)?
    var dismiss: () -> Void
    /// Only when the app is known.
    var mute: (() -> Void)?
    var appName: String?
}

/// Small round icon button on a live band (Reply, Dismiss, Mute): a soft
/// fill that brightens on hover (ease, 150 ms) and presses to 0.97.
struct NotificationBandButton: View {
    let systemImage: String
    let label: String
    var tint: Color? = nil
    var size: CGFloat = 24
    let action: () -> Void
    @StateObject private var hover = ViewFlag()

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint == nil ? SparkVTheme.text.opacity(hover.isOn ? 1 : 0.86) : Color.white)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(SparkVTheme.isApple ? Color.clear : SparkVTheme.stroke, lineWidth: tint == nil ? 1 : 0))
                .contentShape(Circle())
                .animation(SparkVMotion.hover(), value: hover.isOn)
        }
        .buttonStyle(SparkVPressStyle())
        .onHover { hover.isOn = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    /// Apple: a white wash that brightens on hover. SparkV Red: the same
    /// wash, lit red on hover. A tinted button (Accept, Decline, Unmute)
    /// keeps its color and deepens a touch.
    private var fill: Color {
        if let tint { return hover.isOn ? tint.opacity(0.82) : tint }
        if hover.isOn { return SparkVTheme.isApple ? Color.white.opacity(0.24) : SparkVTheme.red.opacity(0.24) }
        return Color.white.opacity(SparkVTheme.isApple ? 0.14 : 0.11)
    }
}

/// VoiceOver actions for the band: Open, Reply, Dismiss.
private struct NotificationBandAccessibilityActions: ViewModifier {
    let actions: NotificationBandActions?

    func body(content: Content) -> some View {
        if let actions {
            content
                .accessibilityAction(named: "Open") { actions.open() }
                .accessibilityAction(named: "Reply") { (actions.reply ?? actions.open)() }
                .accessibilityAction(named: "Dismiss") { actions.dismiss() }
        } else {
            content
        }
    }
}

/// The band's words for a notification under a privacy setting. Pure.
struct NotificationBandText: Equatable {
    var headline: String
    var detail: String?
    /// Small app name at the end of the headline row.
    var appCaption: String?
    /// The detail is a stand-in ("New notification"), drawn fainter.
    var detailIsPlaceholder = false
    var showsPrivacyGlyph = false
    /// What VoiceOver reads for the band (only what is visible).
    var spokenSummary: String

    init(content: NotificationContent, privacy: NotificationPrivacy) {
        let app = content.appName.flatMap { $0.isEmpty ? nil : $0 }
        let source = app.map { "Notification from \($0)" } ?? "Notification"
        switch privacy {
        case .full:
            if let subtitle = content.subtitle, !subtitle.isEmpty {
                headline = "\(content.title) · \(subtitle)"
            } else {
                headline = content.title
            }
            detail = content.body
            appCaption = app == content.title ? nil : app
            let parts = [content.subtitle, content.body].compactMap { $0 }.filter { !$0.isEmpty }
            spokenSummary = parts.isEmpty ? "\(source): \(content.title)" : "\(source): \(content.title). \(parts.joined(separator: ". "))"
        case .senderOnly:
            headline = content.title
            if let app, app != content.title {
                detail = app
            } else {
                detail = "New notification"
                detailIsPlaceholder = true
            }
            showsPrivacyGlyph = true
            spokenSummary = app == content.title ? source : "\(source): \(content.title)"
        case .appOnly:
            headline = app ?? "Notification"
            detail = "New notification"
            detailIsPlaceholder = true
            showsPrivacyGlyph = true
            spokenSummary = source
        }
    }
}
