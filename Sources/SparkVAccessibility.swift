import AppKit
import SwiftUI

// Shared accessibility pieces: the assistive-technology state hover-only
// controls follow, status dots that never rely on colour alone, and the
// spoken announcements keyboard navigation makes. Nothing here polls:
// VoiceOver is observed by KVO on NSWorkspace, Full Keyboard Access is read
// when a view asks (it has no notification), and Differentiate Without
// Color comes from the look options the theme already keeps current.

extension SparkVTheme {
    /// System Settings › Accessibility › Display › Differentiate without
    /// color: status glyphs switch from coloured dots to shapes.
    static var differentiateWithoutColor: Bool { options.display.differentiateWithoutColor }
}

/// VoiceOver and Full Keyboard Access, for controls that otherwise appear
/// only under the pointer. Views observe `shared`; with either on, those
/// controls stay visible (and in the accessibility tree) without hover.
@MainActor
final class SparkVAssistive: ObservableObject {
    static let shared = SparkVAssistive()

    @Published private(set) var voiceOverOn: Bool
    @Published private(set) var fullKeyboardAccessOn: Bool

    private var voiceOverObservation: NSKeyValueObservation?

    private init() {
        voiceOverOn = NSWorkspace.shared.isVoiceOverEnabled
        fullKeyboardAccessOn = NSApp?.isFullKeyboardAccessEnabled ?? false
        // KVO-compliant since macOS 10.13; no timer.
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { _, _ in
            Task { @MainActor in SparkVAssistive.shared.refresh() }
        }
    }

    /// Re-reads both switches (the drawer calls this when it opens, since
    /// Full Keyboard Access posts nothing when it changes).
    func refresh() {
        let voiceOver = NSWorkspace.shared.isVoiceOverEnabled
        let keyboard = NSApp?.isFullKeyboardAccessEnabled ?? false
        if voiceOver != voiceOverOn { voiceOverOn = voiceOver }
        if keyboard != fullKeyboardAccessOn { fullKeyboardAccessOn = keyboard }
    }

    /// Hover-only buttons show without hover.
    var revealsHoverControls: Bool { voiceOverOn || fullKeyboardAccessOn }

    /// Speaks `text` through VoiceOver (nothing when VoiceOver is off).
    static func announce(_ text: String, highPriority: Bool = false) {
        guard NSWorkspace.shared.isVoiceOverEnabled, !text.isEmpty else { return }
        let priority: NSAccessibilityPriorityLevel = highPriority ? .high : .medium
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: priority.rawValue]
        )
    }
}

/// What a status dot means, so it can be drawn as a shape (and spoken)
/// as well as coloured.
enum SparkVStatusKind: Sendable {
    /// Recording or live (a red dot).
    case recording
    /// Running, connected, healthy.
    case good
    /// Needs attention soon.
    case warning
    /// Failed or critical.
    case error
    /// Off, idle, waiting.
    case idle
    /// Working (in progress).
    case busy

    /// The shape used with Differentiate Without Color.
    var symbol: String {
        switch self {
        case .recording: "record.circle.fill"
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .idle: "circle.dashed"
        case .busy: "arrow.triangle.2.circlepath"
        }
    }

    var spoken: String {
        switch self {
        case .recording: "Recording"
        case .good: "OK"
        case .warning: "Needs attention"
        case .error: "Error"
        case .idle: "Off"
        case .busy: "Working"
        }
    }
}

/// A small coloured status dot that becomes a distinct glyph when
/// Differentiate Without Color is on, and carries its meaning for
/// VoiceOver (`label`, or the kind's own word). Pass `label: ""` when the
/// text beside the dot already says it: the dot is then decorative.
struct SparkVStatusDot: View {
    let kind: SparkVStatusKind
    let color: Color
    var size: CGFloat = 6
    var label: String? = nil

    var body: some View {
        Group {
            if SparkVTheme.differentiateWithoutColor {
                Image(systemName: kind.symbol)
                    .font(.system(size: size * 1.5, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: max(size, size * 1.5), height: max(size, size * 1.5))
            } else {
                Circle().fill(color).frame(width: size, height: size)
            }
        }
        .accessibilityHidden(label == "")
        .accessibilityLabel(label ?? kind.spoken)
    }
}

extension View {
    /// Shows a hover-revealed control while hovered, or always while
    /// VoiceOver or Full Keyboard Access is on (so it can be reached
    /// without a pointer). Hidden controls also leave the accessibility tree.
    func sparkVHoverRevealed(_ hovered: Bool, assistive: SparkVAssistive) -> some View {
        let shown = hovered || assistive.revealsHoverControls
        return opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
