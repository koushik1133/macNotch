import SwiftUI

/// The only file that touches `ActivityCenter` / `LiveActivity` / `NotchState`.
extension ColorPickerController {
    static let activityID = "colorpicker"

    /// Posts the pick confirmation under the notch: `● #3B82F6  Copied ·
    /// blue-500 · Blue`, about 2 s. Priority 66, the same as Copy Text's
    /// band: above battery/AirPods (50), meetings (60) and notifications
    /// (70 waits for it), so a shortcut pick is confirmed at once instead of
    /// queueing. Hovering the band opens `opensTab` (the Color Picker page).
    /// Esc posts nothing.
    static let bandPriority = 66

    func connect(activities: ActivityCenter, opensTab: NotchState.Tab?) {
        bandPresenter = { [weak activities] info in
            activities?.post(LiveActivity(
                id: Self.activityID, kind: .notification, priority: Self.bandPriority, duration: info.duration,
                opensTab: opensTab, symbol: info.symbol ?? "eyedropper.full", tint: Color(cp: info.color)
            ) {
                ColorPickBandView(info: info)
            })
        }
    }
}

/// Band content, laid out in about 400×30 pt on black. The label ("Copied")
/// always shows in full; the value gives way next (capped, middle
/// truncation), the detail first.
struct ColorPickBandView: View {
    let info: CPBandInfo

    var body: some View {
        HStack(spacing: 8) {
            if let symbol = info.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .frame(width: 16, height: 16)
            } else {
                CPSwatchDot(color: info.color, size: 14)
            }
            CPWidthCap(maxWidth: 230) {
                Text(info.value)
                    .font(.system(size: 12, weight: .semibold, design: info.symbol == nil ? .monospaced : .default))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(2)
            if !info.label.isEmpty {
                Text(info.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(info.symbol == nil ? SparkVTheme.success : SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(3)
            }
            if let detail = info.detail {
                Text("· " + detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SparkVTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [info.value]
        if !info.label.isEmpty { parts.append(info.label) }
        if let detail = info.detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

/// Gives its child at most `maxWidth` without growing to it (unlike
/// `.frame(maxWidth:)`), so a short value sits right next to its label.
struct CPWidthCap: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.map { min($0, maxWidth) } ?? maxWidth
        let size = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
        return CGSize(width: min(size.width, maxWidth), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
