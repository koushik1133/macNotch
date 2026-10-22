import AVFoundation
import CoreAudio
import EventKit
import Foundation
import SwiftUI

// Smart Moments: "Meeting in 2 minutes" (DESIGN.md moment 1).
//
// Trigger: MeetingsController has a meeting with a call link that starts
// within `meetingLeadMinutes` (SmartMomentsLiveSources reports
// `.meetingSoon(meeting, minutesUntilStart:)`, once per occurrence).
// Offer: "Standup in 2 min · Google Meet".
// Actions:
//   joinMeeting     -> `MeetingsController.join(_:)` (opens the call link in its
//                      app or the browser). A tap only, never automatic. Nothing
//                      to put back (a joined call is left alone).
//   openMirror      -> `ScreenDistanceController.yieldCamera()`, then
//                      `CameraController.start()`, and the drawer opens on
//                      `.nook` where the mirror lives. A tap only (the camera
//                      light). Put back (Undo) = `CameraController.stop()`, only
//                      when this moment turned the mirror on and it is still on.
//                      The drawer stops the camera when it closes anyway.
//   checkDevices    -> read only: mic and camera access through PermissionCenter,
//                      the default input and output devices (CoreAudio), whether
//                      a camera is there and free (AVCaptureDevice, never
//                      opened), and the AirPods / headset battery the way
//                      PowerMonitor reads it (`SystemProfilerBluetooth`). Shown
//                      as a strip under the notch; under 20 % it warns.
//                      Put back = closes the strip.
//   showAgendaBrief -> MeetingIntel's brief (`MeetingBriefBuilder`) when that lab
//                      is wired, else the agenda lines of the event's notes
//                      (EventKit, read only when PermissionCenter says Calendars
//                      is granted; never requested here). Put back = closes it.
// Nothing here hides or quits an app, records, or asks for a permission.

// MARK: - Dependencies

/// A camera as the device check sees it (never opened to check).
enum MeetingSoonCameraState: Equatable, Sendable {
    case ready(name: String)
    case inUse(name: String)
    case none
}

/// A connected Bluetooth headset with a battery reading.
struct MeetingSoonHeadset: Equatable, Sendable {
    var name: String
    var batteries: AudioBatteries

    /// Lowest earbud (or single) level; the case doesn't count.
    var lowestLevel: Int? {
        [batteries.left, batteries.right, batteries.single].compactMap { $0 }.min()
    }
}

/// What the moment needs from the app, as closures so tests can use fakes.
/// `live(...)` builds it from the real controllers.
@MainActor
struct MeetingSoonMomentDeps {
    // Join
    var join: @MainActor (CalendarMeeting) -> Void
    // Mirror
    var mirrorIsOn: @MainActor () -> Bool
    var startMirror: @MainActor () -> Void
    var stopMirror: @MainActor () -> Void
    var openMirrorDrawer: @MainActor () -> Void
    // Device check (read only)
    var permissionGranted: @MainActor (PermissionCenter.Permission) -> Bool = { PermissionCenter.shared.isGranted($0) }
    var inputDeviceName: @MainActor () -> String? = { MeetingSoonAudioReader.defaultInputName() }
    var outputDeviceName: @MainActor () -> String? = { SmartMomentsSystemReaders.defaultOutput()?.name }
    var camera: @MainActor () -> MeetingSoonCameraState = { MeetingSoonCameraReader.state() }
    var headsets: @MainActor () async -> [MeetingSoonHeadset] = { await MeetingSoonHeadsetReader.connected() }
    // Agenda brief
    /// MeetingIntel's brief lines for the meeting; nil = no MeetingIntel
    /// (or nothing in its brief), then the event notes are used.
    var meetingIntelBrief: (@MainActor (CalendarMeeting) async -> [String]?)?
    /// The event's notes (callers checked Calendars access).
    var eventNotes: @MainActor (CalendarMeeting) -> String? = { MeetingSoonCalendarReader.notes(eventID: $0.eventID) }
    // Showing the strip and the brief
    var post: @MainActor (LiveActivity) -> Void
    var dismissActivity: @MainActor (String) -> Void
}

extension MeetingSoonMomentDeps {
    /// The real controllers (weak: the moment never keeps them alive).
    /// `openTab` opens the drawer on a tab (the mirror lives on `.nook`).
    static func live(
        meetings: MeetingsController,
        camera: CameraController,
        screenDistance: ScreenDistanceController?,
        activities: ActivityCenter,
        openTab: @escaping @MainActor (NotchState.Tab) -> Void,
        meetingIntelBrief: (@MainActor (CalendarMeeting) async -> [String]?)? = nil
    ) -> MeetingSoonMomentDeps {
        MeetingSoonMomentDeps(
            join: { [weak meetings] meeting in meetings?.join(meeting) },
            mirrorIsOn: { [weak camera] in (camera?.isRunning ?? false) || (camera?.isStarting ?? false) },
            startMirror: { [weak camera, weak screenDistance] in
                screenDistance?.yieldCamera()
                camera?.start()
            },
            stopMirror: { [weak camera] in camera?.stop() },
            openMirrorDrawer: { openTab(.nook) },
            meetingIntelBrief: meetingIntelBrief,
            post: { [weak activities] activity in activities?.post(activity) },
            dismissActivity: { [weak activities] id in activities?.dismiss(id: id) }
        )
    }
}

// MARK: - State

/// What this moment changed, by offer, so Undo puts back exactly that.
@MainActor
final class MeetingSoonMomentState {
    /// Offers whose tap turned the mirror on.
    fileprivate(set) var mirrorStartedBy: Set<UUID> = []
    /// Offers whose strip / brief is on screen (activity id by offer).
    fileprivate(set) var deviceStrips: [UUID: String] = [:]
    fileprivate(set) var briefs: [UUID: String] = [:]
    /// The latest device check (tests and the strip read it).
    fileprivate(set) var lastCheck: MeetingSoonDeviceCheck?
    /// The headset battery lookup in flight (slow: system_profiler).
    fileprivate(set) var headsetLookup: Task<Void, Never>?
    /// The latest brief lines shown, and where they came from.
    fileprivate(set) var lastBrief: (lines: [String], source: String)?

    fileprivate func trim() {
        // The engine forgets put-backs once the band goes; keep these small.
        if mirrorStartedBy.count > 20 { mirrorStartedBy.removeAll() }
        if deviceStrips.count > 20 { deviceStrips.removeAll() }
        if briefs.count > 20 { briefs.removeAll() }
    }
}

// MARK: - Device check

struct MeetingSoonDeviceCheck: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        enum Tone: Equatable, Sendable { case ok, warning, neutral }
        var symbol: String
        var text: String
        var tone: Tone
    }

    var micGranted: Bool
    var inputName: String?
    var cameraGranted: Bool
    var camera: MeetingSoonCameraState
    var outputName: String?
    var headsets: [MeetingSoonHeadset]
    /// False while the headset batteries are still being read.
    var headsetsLoaded: Bool

    static let lowBattery = 20

    var lowHeadset: MeetingSoonHeadset? {
        headsets.first { ($0.lowestLevel ?? 100) < Self.lowBattery }
    }

    var rows: [Row] {
        var rows: [Row] = []
        if micGranted {
            rows.append(Row(symbol: "mic.fill", text: "Mic: " + (inputName ?? "ready"), tone: .ok))
        } else {
            rows.append(Row(symbol: "mic.slash.fill", text: "Mic needs access", tone: .warning))
        }
        switch (cameraGranted, camera) {
        case (_, .none): rows.append(Row(symbol: "video.slash.fill", text: "No camera found", tone: .warning))
        case (false, _): rows.append(Row(symbol: "video.slash.fill", text: "Camera needs access", tone: .warning))
        case (true, .inUse(let name)): rows.append(Row(symbol: "video.fill", text: "\(name) is in use by another app", tone: .warning))
        case (true, .ready(let name)): rows.append(Row(symbol: "video.fill", text: "Camera: \(name)", tone: .ok))
        }
        if let outputName { rows.append(Row(symbol: "speaker.wave.2.fill", text: "Sound: \(outputName)", tone: .neutral)) }
        if !headsetsLoaded {
            rows.append(Row(symbol: "airpods", text: "Checking AirPods battery…", tone: .neutral))
        }
        for headset in headsets {
            let low = (headset.lowestLevel ?? 100) < Self.lowBattery
            let text = "\(headset.name): \(headset.batteries.summary)" + (low ? " · charge them" : "")
            rows.append(Row(symbol: BluetoothAudioDevice(name: headset.name, address: "", batteries: headset.batteries).symbolName,
                            text: text, tone: low ? .warning : .ok))
        }
        return rows
    }

    /// One line for the "Done" toast.
    var summary: String {
        var parts = [micGranted ? "Mic ready" : "Mic needs access"]
        switch (cameraGranted, camera) {
        case (_, .none): parts.append("no camera")
        case (false, _): parts.append("camera needs access")
        case (true, .inUse): parts.append("camera in use")
        case (true, .ready): parts.append("camera ready")
        }
        if let low = lowHeadset, let level = low.lowestLevel { parts.append("\(low.name) at \(level) %") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The moment

@MainActor
enum MeetingSoonMoment {
    static let deviceStripID = "smartMoments.meetingSoon.devices"
    static let briefID = "smartMoments.meetingSoon.brief"
    /// Just under the Smart Moments band (72 for this moment), so a new
    /// offer still wins the band.
    static let activityPriority = 71
    static let briefDuration: TimeInterval = 20
    static let stripDuration: TimeInterval = 12
    static let briefLineLimit = 4

    /// Registers the moment's action and put-back handlers on the engine.
    /// Call after the shared hooks are installed (`SmartMomentsWiring.start()`):
    /// it replaces their meeting-soon handlers and keeps them for other
    /// triggers. Returns the state (tests read it).
    @discardableResult
    static func install(on engine: SmartMomentsController, deps: MeetingSoonMomentDeps) -> MeetingSoonMomentState {
        let state = MeetingSoonMomentState()
        var h = engine.hooks

        func meeting(_ trigger: MomentTrigger) -> CalendarMeeting? {
            if case .meetingSoon(let meeting, _) = trigger { return meeting }
            return nil
        }

        // Join (a tap only) -----------------------------------------------------

        chain(.joinMeeting, in: &h, isAvailable: { trigger in
            guard let meeting = meeting(trigger) else { return nil }
            return meeting.link != nil
        }) { context in
            guard let meeting = meeting(context.trigger) else { return nil }
            guard context.userInitiated else { return .skipped("Needs a tap") }
            guard let link = meeting.link else { return .skipped("No call link") }
            deps.join(meeting)
            return .done("Joining \(link.provider.shortName)")
        }

        // Mirror (a tap only; Undo turns it off again) -------------------------

        chain(.openMirror, in: &h, isAvailable: { trigger in
            guard meeting(trigger) != nil else { return nil }
            return !deps.mirrorIsOn()
        }) { context in
            guard meeting(context.trigger) != nil else { return nil }
            guard context.userInitiated else { return .skipped("Needs a tap") }
            deps.openMirrorDrawer()
            guard !deps.mirrorIsOn() else { return .skipped("Mirror is on") }
            deps.startMirror()
            guard deps.mirrorIsOn() else { return .failed("The camera didn't start") }
            state.mirrorStartedBy.insert(context.offerID)
            state.trim()
            return .done("Mirror on")
        }
        chainPutBack(.openMirror, on: engine) { context in
            guard state.mirrorStartedBy.remove(context.offerID) != nil else { return nil }
            guard deps.mirrorIsOn() else { return .skipped("Mirror is already off") }
            deps.stopMirror()
            return .done("Mirror off")
        }

        // Mic, camera and AirPods (read only) ----------------------------------

        chain(.checkDevices, in: &h, isAvailable: { trigger in
            meeting(trigger) != nil ? true : nil
        }) { context in
            guard meeting(context.trigger) != nil else { return nil }
            let check = MeetingSoonDeviceCheck(
                micGranted: deps.permissionGranted(.microphone),
                inputName: deps.inputDeviceName(),
                cameraGranted: deps.permissionGranted(.camera),
                camera: deps.camera(),
                outputName: deps.outputDeviceName(),
                headsets: [],
                headsetsLoaded: false
            )
            state.lastCheck = check
            state.deviceStrips[context.offerID] = deviceStripID
            state.trim()
            deps.post(deviceStrip(check))
            // AirPods report through system_profiler (a second or more): the
            // strip updates in place when it answers.
            state.headsetLookup?.cancel()
            state.headsetLookup = Task { @MainActor in
                let headsets = await deps.headsets()
                guard !Task.isCancelled, state.deviceStrips[context.offerID] != nil else { return }
                var loaded = check
                loaded.headsets = headsets
                loaded.headsetsLoaded = true
                state.lastCheck = loaded
                deps.post(deviceStrip(loaded))
            }
            return .done(check.summary)
        }
        chainPutBack(.checkDevices, on: engine) { context in
            guard let id = state.deviceStrips.removeValue(forKey: context.offerID) else { return nil }
            state.headsetLookup?.cancel()
            deps.dismissActivity(id)
            return .done("Closed the device check")
        }

        // Agenda brief (MeetingIntel, else the event notes) --------------------

        chain(.showAgendaBrief, in: &h, isAvailable: { trigger in
            meeting(trigger) != nil ? true : nil
        }) { context in
            guard let meeting = meeting(context.trigger) else { return nil }
            var lines: [String] = []
            var source = "MeetingIntel"
            if let brief = deps.meetingIntelBrief, let built = await brief(meeting) {
                lines = Array(built.filter { !$0.isEmpty }.prefix(briefLineLimit))
            }
            if lines.isEmpty {
                source = "Calendar"
                // Read only when access is already there; never asked for here.
                guard deps.permissionGranted(.calendars) else { return .needsPermission(.calendars) }
                lines = agendaLines(fromNotes: deps.eventNotes(meeting) ?? "", limit: briefLineLimit)
            }
            guard !lines.isEmpty else { return .skipped("No agenda in the invite") }
            state.lastBrief = (lines, source)
            state.briefs[context.offerID] = briefID
            state.trim()
            deps.post(briefCard(title: meeting.title, start: meeting.start, lines: lines, source: source))
            return .done("Agenda brief")
        }
        chainPutBack(.showAgendaBrief, on: engine) { context in
            guard let id = state.briefs.removeValue(forKey: context.offerID) else { return nil }
            deps.dismissActivity(id)
            return .done("Closed the brief")
        }

        engine.hooks = h
        return state
    }

    // MARK: Agenda from notes

    /// Agenda-like lines from an invite's notes: bullets and numbered lines
    /// first; otherwise the first short plain lines. Links, dial-in and
    /// separator boilerplate are left out.
    nonisolated static func agendaLines(fromNotes notes: String, limit: Int) -> [String] {
        let raw = notes
            .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        var bullets: [String] = []
        var plain: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isBoilerplate(trimmed) else { continue }
            if let body = bulletBody(trimmed) {
                bullets.append(body)
            } else if trimmed.count <= 90 {
                plain.append(trimmed)
            }
        }
        let picked = bullets.isEmpty ? plain : bullets
        return Array(picked.prefix(max(0, limit)))
    }

    nonisolated private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "• ", "– ", "· "] where line.hasPrefix(marker) {
            let body = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        if let match = line.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) {
            let body = line[match.upperBound...].trimmingCharacters(in: .whitespaces)
            return body.isEmpty ? nil : body
        }
        return nil
    }

    nonisolated private static func isBoilerplate(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") { return true }
        if line.allSatisfy({ "-_=*~─━ ".contains($0) }) { return true }
        let phrases = ["join zoom", "join with google meet", "microsoft teams meeting", "meeting id", "passcode",
                       "dial-in", "dial in", "join by phone", "click here to join", "one tap mobile", "agenda:"]
        return phrases.contains { lower.hasPrefix($0) }
    }

    // MARK: Activities

    static func deviceStrip(_ check: MeetingSoonDeviceCheck) -> LiveActivity {
        let rows = check.rows
        return LiveActivity(
            id: deviceStripID, kind: .meeting, priority: activityPriority,
            duration: stripDuration,
            height: MeetingSoonStripView.height(rows: rows.count),
            presentation: .expanded,
            symbol: check.lowHeadset != nil ? "battery.25percent" : "checkmark.circle",
            tint: check.lowHeadset != nil ? SparkVTheme.warning : SparkVTheme.success
        ) {
            MeetingSoonStripView(title: "Ready for the call?", caption: nil, rows: rows)
        }
    }

    static func briefCard(title: String, start: Date, lines: [String], source: String) -> LiveActivity {
        let rows = lines.map { MeetingSoonDeviceCheck.Row(symbol: "list.bullet", text: $0, tone: .neutral) }
        return LiveActivity(
            id: briefID, kind: .meeting, priority: activityPriority,
            duration: briefDuration,
            height: MeetingSoonStripView.height(rows: rows.count),
            opensTab: .today,
            presentation: .expanded,
            symbol: "list.bullet.rectangle"
        ) {
            MeetingSoonStripView(title: title, caption: source + " · on this Mac", rows: rows)
        }
    }

    // MARK: Chaining

    /// Installs `mine` for meeting-soon triggers (it returns nil for others)
    /// and keeps the previous hook and availability for every other trigger.
    private static func chain(
        _ action: MomentAction, in h: inout SmartMomentsHooks,
        isAvailable mineAvailable: @escaping @MainActor (MomentTrigger) -> Bool?,
        _ mine: @escaping @MainActor (MomentActionContext) async -> MomentActionResult?
    ) {
        let previousRun = h.actions[action]
        let previousAvailable = h.isAvailable[action]
        h.actions[action] = { context in
            if let result = await mine(context) { return result }
            guard let previousRun else { return .skipped("Not available") }
            return await previousRun(context)
        }
        h.isAvailable[action] = { trigger in
            if let available = mineAvailable(trigger) { return available }
            guard previousRun != nil else { return false }
            return previousAvailable?(trigger) ?? true
        }
    }

    /// Same for a put-back: mine first (nil = not ours), then the earlier one.
    private static func chainPutBack(
        _ action: MomentAction, on engine: SmartMomentsController,
        _ mine: @escaping @MainActor (MomentActionContext) async -> MomentActionResult?
    ) {
        let previous = engine.putBack[action]
        engine.putBack[action] = { context in
            if let result = await mine(context) { return result }
            guard let previous else { return .skipped("Nothing to put back") }
            return await previous(context)
        }
    }
}

// MARK: - Readers (read only, nothing is opened or requested)

enum MeetingSoonAudioReader {
    /// Name of the default input device (CoreAudio).
    static func defaultInputName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        address.mSelector = kAudioObjectPropertyName
        var value: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

enum MeetingSoonCameraReader {
    /// The front (or first) camera and whether another app holds it. Lists
    /// devices only: the camera is never opened and no prompt appears.
    static func state() -> MeetingSoonCameraState {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        )
        guard let device = discovery.devices.first(where: { $0.position == .front }) ?? discovery.devices.first else {
            return .none
        }
        return device.isInUseByAnotherApplication ? .inUse(name: device.localizedName) : .ready(name: device.localizedName)
    }
}

enum MeetingSoonHeadsetReader {
    /// Connected Bluetooth devices that report a battery (AirPods and other
    /// headsets), through PowerMonitor's system_profiler reader.
    static func connected() async -> [MeetingSoonHeadset] {
        let devices = await SystemProfilerBluetooth.connectedDevices()
        return devices
            .filter { !$0.batteries.isEmpty }
            .map { MeetingSoonHeadset(name: $0.name, batteries: $0.batteries) }
    }
}

@MainActor
enum MeetingSoonCalendarReader {
    private static var store: EKEventStore?

    /// The event's notes. Callers check Calendars access through
    /// PermissionCenter first; this never requests it.
    static func notes(eventID: String) -> String? {
        let store = store ?? EKEventStore()
        Self.store = store
        guard let event = store.event(withIdentifier: eventID) else { return nil }
        let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return notes.isEmpty ? nil : notes
    }
}

// MARK: - View

/// The device strip and the agenda brief: a title and a few rows.
struct MeetingSoonStripView: View {
    let title: String
    let caption: String?
    let rows: [MeetingSoonDeviceCheck.Row]

    static func height(rows: Int) -> CGFloat {
        28 + CGFloat(max(1, rows)) * 17
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(SparkVTheme.headline(12))
                    .foregroundStyle(SparkVTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let caption {
                    Text(caption)
                        .font(SparkVTheme.caption(9.5))
                        .foregroundStyle(SparkVTheme.textTertiary)
                        .lineLimit(1)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Image(systemName: row.symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(row.tone))
                        .frame(width: 14)
                    Text(row.text)
                        .font(SparkVTheme.caption(11))
                        .foregroundStyle(row.tone == .warning ? SparkVTheme.warning : SparkVTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func color(_ tone: MeetingSoonDeviceCheck.Row.Tone) -> Color {
        switch tone {
        case .ok: SparkVTheme.success
        case .warning: SparkVTheme.warning
        case .neutral: SparkVTheme.textSecondary
        }
    }
}
