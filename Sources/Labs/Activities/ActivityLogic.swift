import Foundation

// Pure rules behind notifications, calls and the band under the notch.
// Foundation only, so the test harness compiles this file on its own.

// MARK: - Banner and call-window controls

/// What a banner button or named action does.
enum NotificationControlRole: Sendable, Equatable {
    case open, reply, close, accept, decline, other

    var logName: String {
        switch self {
        case .open: "open"
        case .reply: "reply"
        case .close: "dismiss"
        case .accept: "accept"
        case .decline: "decline"
        case .other: "action"
        }
    }
}

/// Sorts banner buttons and named actions into roles by title. Pure.
///
/// "Clear" (removes the item from Notification Center's history) and "Mark
/// as Read" (changes the mail) are deliberately not Dismiss: they are
/// `.other`, so Dismiss never presses them. "Ignore" is not Decline: it is
/// a Discord friend request's button, not a call's.
enum NotificationControlClassifier {
    private static let accept: Set<String> = [
        "accept", "answer", "accept call", "answer call", "pick up",
        "annehmen", "accepter", "répondre à l’appel", "aceptar", "accetta", "aceitar", "aannemen", "接受", "応答", "수락",
    ]
    private static let decline: Set<String> = [
        "decline", "reject", "decline call",
        "ablehnen", "refuser", "rechazar", "rifiuta", "recusar", "weigeren", "拒绝", "拒否", "거절",
    ]
    private static let reply: Set<String> = [
        "reply", "reply…", "quick reply", "antworten", "répondre", "responder", "rispondi", "beantwoorden", "回复", "返信",
    ]
    private static let close: Set<String> = [
        "close", "dismiss", "schließen", "fermer", "cerrar", "chiudi", "fechar", "sluiten", "关闭", "閉じる",
    ]
    private static let open: Set<String> = ["show", "open", "show details", "view", "anzeigen", "afficher", "mostrar", "mostra"]

    static func role(for title: String) -> NotificationControlRole {
        let key = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if accept.contains(key) { return .accept }
        if decline.contains(key) { return .decline }
        if reply.contains(key) { return .reply }
        if close.contains(key) { return .close }
        if open.contains(key) { return .open }
        return .other
    }

    /// Display name of a raw AX action: "Name:Close\nTarget:0x0\nSelector:(null)"
    /// gives "Close"; standard actions (AXPress, AXShowMenu, …) give nil.
    static func displayName(ofAction raw: String) -> String? {
        guard raw.hasPrefix("Name:") else { return nil }
        let first = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let name = String(first.dropFirst("Name:".count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Something to accept and something to decline. Necessary for a call,
    /// never enough on its own (AirDrop, Screen Sharing and invitations
    /// have both too): see `IncomingCallClassifier`.
    static func hasAcceptAndDecline(roles: [NotificationControlRole]) -> Bool {
        roles.contains(.accept) && roles.contains(.decline)
    }
}

/// When Accept and Decline really mean a ringing call.
enum IncomingCallClassifier {
    /// Notification Center apps that ring: FaceTime (also iPhone calls
    /// relayed through Continuity) and the Phone app, by the names banners
    /// show in a few languages.
    static let callingApps: Set<String> = [
        "facetime", "phone", "telefon", "téléphone", "teléfono", "telefono", "telefone", "telefoon", "电话", "電話", "전화",
    ]

    /// Words a call app's ringing window shows (lowercased, matched inside
    /// the window title or its texts).
    static let ringingWording: [String] = [
        "incoming call", "incoming video call", "incoming audio call", "incoming voice call",
        "is calling", "calling you", "wants to call", "wants to video call", "wants to audio call",
        "video call from", "audio call from", "voice call from", "call from",
        "eingehender anruf", "appel entrant", "llamada entrante", "chiamata in arrivo", "chamada recebida",
        "inkomende oproep", "来电", "着信",
    ]

    /// A Notification Center item is a ringing call only when it is an
    /// alert (`AXNotificationCenterAlert`, it stays until answered) from
    /// FaceTime or Phone with both Accept and Decline. AirDrop, Screen
    /// Sharing, Calendar and Game Center invitations are not.
    static func isNotificationCenterCall(appName: String?, isAlert: Bool, roles: [NotificationControlRole]) -> Bool {
        guard isAlert, let appName else { return false }
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return callingApps.contains(app) && NotificationControlClassifier.hasAcceptAndDecline(roles: roles)
    }

    /// A call app's newly created window is ringing when it has Accept and
    /// Decline and says it's a call (a Teams meeting invitation or a
    /// Discord friend request has the buttons but not the words).
    static func isRingingWindow(title: String, texts: [String], roles: [NotificationControlRole]) -> Bool {
        guard NotificationControlClassifier.hasAcceptAndDecline(roles: roles) else { return false }
        return ([title] + texts).contains { text in
            let lower = text.lowercased()
            return ringingWording.contains { lower.contains($0) }
        }
    }
}

// MARK: - Clicks on the band

/// Decides when a band with buttons may take clicks, so a band that pops
/// up under the pointer never catches a click meant for what was there
/// (a browser tab right below the notch).
///
/// Clicks are taken only after the pointer came onto the band from outside
/// it after the band appeared, or (pointer already there) after it moved
/// over the band and the band has been up for `settle`. A band change
/// noticed without a pointer move never turns clicks on by itself.
struct ActivityBandClickGate: Equatable, Sendable {
    /// A band under a still pointer needs a move and this long on screen.
    static let settle: TimeInterval = 0.6

    private(set) var bandID: String?
    private(set) var appearedAt: Date = .distantPast
    /// The pointer has been off the band since it appeared.
    private(set) var wasOutside = false
    /// The pointer moved over the band since it appeared.
    private(set) var movedOver = false
    /// Came onto the band from outside after it appeared.
    private(set) var entered = false

    /// Feeds one pointer check. `bandID` is the interactive band on screen
    /// (nil when none), `onBand` whether the pointer is over it, `moved`
    /// whether this check comes from a real mouse move.
    mutating func update(bandID newID: String?, onBand: Bool, moved: Bool, now: Date) {
        if newID != bandID {
            bandID = newID
            appearedAt = now
            wasOutside = !onBand
            movedOver = false
            entered = false
            return
        }
        guard bandID != nil else { return }
        if !onBand {
            wasOutside = true
            entered = false
        } else if moved {
            if wasOutside { entered = true }
            movedOver = true
        }
    }

    func allowsClicks(onBand: Bool, now: Date) -> Bool {
        guard bandID != nil, onBand else { return false }
        if entered { return true }
        return movedOver && now.timeIntervalSince(appearedAt) >= Self.settle
    }
}

/// Accept and Decline ignore clicks this soon after the call band appears.
enum IncomingCallGuard {
    static let answerDelay: TimeInterval = 0.5

    static func acceptsAnswer(postedAt: Date?, now: Date) -> Bool {
        guard let postedAt else { return true }
        return now.timeIntervalSince(postedAt) >= answerDelay
    }
}

// MARK: - Notification Center polling

/// How often Notification Center is re-checked while something is on
/// screen (its destroyed events don't always arrive). Nothing polls while
/// nothing is on screen.
enum NotificationPollPolicy {
    static let fast: TimeInterval = 1.5
    static let slow: TimeInterval = 5
    /// After this long on screen, a banner that stays (an alert) is
    /// re-checked at `slow`.
    static let fastFor: TimeInterval = 10

    /// - `previewsOn`: mirroring notifications.
    /// - `ringing`: an incoming call alert is up (always fast: the band
    ///   must go when the call stops ringing).
    /// - `visibleFor`: how long something has been on screen, nil if nothing.
    static func interval(previewsOn: Bool, ringing: Bool, visibleFor: TimeInterval?) -> TimeInterval? {
        if ringing { return fast }
        guard previewsOn, let visibleFor else { return nil }
        if visibleFor < fastFor { return fast }
        // An alert left up (or an open Notification Center list) backs off
        // so it never means a full AX scan every 5 s all night.
        if visibleFor < 60 { return slow }
        if visibleFor < 300 { return 15 }
        return 60
    }
}

// MARK: - Calls

enum CallMutePolicy {
    /// At the end of a call: unmute only what this call's Mute muted, if
    /// the user wants that and it is still SparkV's mute.
    static func unmutesAtCallEnd(mutedForCall: Bool, mutedBySparkV: Bool, preference: Bool) -> Bool {
        mutedForCall && mutedBySparkV && preference
    }

    /// When a call started: the detector reports it once its evidence held
    /// for `startDelay`, so the call began that much earlier.
    static func startedAt(detectedAt: Date, startDelay: TimeInterval) -> Date {
        detectedAt.addingTimeInterval(-max(0, startDelay))
    }
}

// MARK: - Now Playing title in the wing

enum TrackTitlePolicy {
    /// Below this the marquee shows a few clipped letters, not a title.
    static let minimumWidth: CGFloat = 40

    /// The title rides in the wing after a track change (or always), but
    /// not beside another activity's icon unless the user asked for it
    /// always, and never in less than `minimumWidth`.
    static func showsTitle(peeking: Bool, always: Bool, besideMinimal: Bool, width: CGFloat) -> Bool {
        guard width >= minimumWidth else { return false }
        if besideMinimal { return always }
        return peeking || always
    }
}
