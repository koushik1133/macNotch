import Foundation

/// The dictation hotkey's gestures, kept apart from the microphone so they
/// can be tested on their own:
///
/// - Hold the key: after `holdDelay` the microphone opens (push-to-talk);
///   releasing it finishes and types the text.
/// - Double-tap the key: hands-free; one more press finishes.
/// - hotkey+Space: hands-free right away.
/// - A plain tap, or the key used in a shortcut (fn+Arrow, fn+F5,
///   fn+Delete, fn+Control…), never opens the microphone, so the macOS
///   indicator, AirPods' call mode and the island stay quiet.
///
/// Times are seconds (system uptime). The owner feeds key events and the
/// two deadlines (`holdDeadline`, `tapDeadline`) and acts on the returned
/// `Action`.
struct DictationKeyMachine: Equatable {
    /// How long the key must be held before the microphone opens. Long
    /// enough that taps and fn+key shortcuts never start it.
    static let holdDelay: TimeInterval = 0.2
    /// A second press within this time of the first release locks hands-free.
    static let doubleTapWindow: TimeInterval = 0.35
    /// A shortcut that uses the hotkey within this time of opening the mic
    /// discards the session (fn held, then an arrow pressed).
    static let chordWindow: TimeInterval = 0.8

    enum State: Equatable {
        case idle
        /// Key down, waiting to see a hold (`since` = press time).
        case pressed(since: TimeInterval)
        /// One short tap seen; a second press makes it hands-free.
        case tapped(releasedAt: TimeInterval)
        /// Push-to-talk session (mic open while held).
        case holding(startedAt: TimeInterval)
        /// Hands-free session; `keyDown` is the press that started it (its
        /// release is ignored).
        case handsFree(keyDown: Bool)
    }

    enum Input: Equatable {
        case press(TimeInterval)
        case release(TimeInterval)
        /// Space while the key is held.
        case space(TimeInterval)
        /// Another key or modifier used with the hotkey.
        case chord(TimeInterval)
        /// The owner's timer: `holdDeadline` or `tapDeadline` passed.
        case tick(TimeInterval)
    }

    enum Action: Equatable {
        case none
        case startHold
        case startHandsFree
        /// A hold became hands-free (hotkey+Space while talking).
        case lockHandsFree
        case finish
        case cancel
    }

    private(set) var state: State = .idle

    /// When the owner should send `.tick`: the end of the hold wait or the
    /// double-tap window. nil while nothing is pending.
    var deadline: TimeInterval? {
        switch state {
        case .pressed(let since): since + Self.holdDelay
        case .tapped(let releasedAt): releasedAt + Self.doubleTapWindow
        default: nil
        }
    }

    var isListening: Bool {
        switch state {
        case .holding, .handsFree: true
        default: false
        }
    }

    /// A session ended for another reason (Esc, an error, the Dictate
    /// button, the maximum duration).
    mutating func reset() { state = .idle }

    /// A hands-free session started without the key (the Dictate button):
    /// the next press finishes it.
    mutating func startedHandsFreeElsewhere() { state = .handsFree(keyDown: false) }

    mutating func handle(_ input: Input) -> Action {
        switch (state, input) {
        // Waiting for a hold.
        case (.idle, .press(let t)):
            state = .pressed(since: t)
            return .none
        case (.pressed(let since), .tick(let t)) where t >= since + Self.holdDelay:
            state = .holding(startedAt: t)
            return .startHold
        case (.pressed(let since), .release(let t)):
            // Released before the hold delay: a tap (maybe half a double-tap).
            state = t - since < Self.holdDelay ? .tapped(releasedAt: t) : .idle
            return .none
        case (.pressed, .chord):
            state = .idle
            return .none
        case (.pressed, .space):
            state = .handsFree(keyDown: true)
            return .startHandsFree

        // One tap seen.
        case (.tapped(let releasedAt), .press(let t)):
            if t - releasedAt <= Self.doubleTapWindow {
                state = .handsFree(keyDown: true)
                return .startHandsFree
            }
            state = .pressed(since: t)
            return .none
        case (.tapped(let releasedAt), .tick(let t)) where t >= releasedAt + Self.doubleTapWindow:
            state = .idle
            return .none

        // Push-to-talk.
        case (.holding, .release):
            state = .idle
            return .finish
        case (.holding(let startedAt), .chord(let t)):
            guard t - startedAt < Self.chordWindow else { return .none }
            state = .idle
            return .cancel
        case (.holding, .space):
            state = .handsFree(keyDown: true)
            return .lockHandsFree

        // Hands-free.
        case (.handsFree(true), .release):
            state = .handsFree(keyDown: false)
            return .none
        case (.handsFree(false), .press):
            // The finishing press; its release comes back to idle.
            state = .idle
            return .finish

        default:
            return .none
        }
    }
}
