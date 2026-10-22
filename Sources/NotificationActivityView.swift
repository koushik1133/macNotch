import AppKit
import SwiftUI

/// Band content for a mirrored notification: app icon on the left, sender /
/// title over one line of body text in the middle, the app's name trailing.
/// With `hidesBody`, only the sender and the app are shown.
struct NotificationActivityView: View {
    let content: NotificationContent
    let icon: NSImage?
    let hidesBody: Bool

    var body: some View {
        HStack(spacing: 10) {
            leading
                .frame(width: 34, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let detail {
                    Text(detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hidesBody ? SparkVTheme.textTertiary : SparkVTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var leading: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(SparkVTheme.choose(apple: Color.red, sparkv: SparkVTheme.red), SparkVTheme.text)
        }
    }

    private var headline: String {
        if hidesBody { return content.title }
        if let subtitle = content.subtitle, !subtitle.isEmpty {
            return "\(content.title) · \(subtitle)"
        }
        return content.title
    }

    /// Second line: the message, or the app's name when the body is hidden.
    private var detail: String? {
        if hidesBody {
            guard let app = content.appName, app != content.title else { return "New notification" }
            return app
        }
        return content.body
    }

    @ViewBuilder
    private var trailing: some View {
        if !hidesBody, let app = content.appName, app != content.title {
            Text(app)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: 84, alignment: .trailing)
                .layoutPriority(1)
        } else if hidesBody {
            Image(systemName: "eye.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SparkVTheme.textTertiary)
        }
    }
}
