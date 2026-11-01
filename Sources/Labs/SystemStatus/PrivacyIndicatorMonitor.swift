import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreMediaIO
import SwiftUI

/// How the privacy indicator shows itself.
enum PrivacyDisplay: String, CaseIterable, Identifiable, Sendable {
    /// Dots beside the notch for as long as a sensor is in use (and a short
    /// band whenever a new app starts using one).
    case wings
    /// Only the short band when something starts.
    case band

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wings: "Dots Beside the Notch"
        case .band: "Only a Short Band"
        }
    }
}

/// Microphone, camera and screen-sharing indicators in the island, naming
/// the app where public APIs allow, visible over full-screen apps (the
/// notch panel floats above them, where macOS hides the menu-bar dots).
///
/// - Microphone: CoreAudio. `kAudioDevicePropertyDeviceIsRunningSomewhere`
///   on every input device, the HAL process list and each process's
///   `kAudioProcessPropertyIsRunningInput` name the app exactly (helpers
///   count as their app). SparkV's own process (dictation, meeting notes,
///   Clicky) never shows.
/// - Camera: CoreMediaIO `kCMIODevicePropertyDeviceIsRunningSomewhere` on
///   every camera, hot-plugged ones included. macOS has no public API that
///   names the app, so the band says "likely <app>": the app on the mic,
///   else the front app. Off while SparkV itself has the camera.
/// - Screen sharing: SmartMoments' window-title detector, when the
///   integrator connects it (best effort; nothing here reads windows).
///
/// Listeners only, never a timer. Everything stops when the feature is off.
@MainActor
final class PrivacyIndicatorMonitor: ObservableObject {
    static let shared = PrivacyIndicatorMonitor()

    static let enabledKey = "privacy.isEnabled"
    static let micKey = "privacy.microphone"
    static let cameraKey = "privacy.camera"
    static let screenKey = "privacy.screen"
    static let displayKey = "privacy.display"
    static let activityID = "privacy"

    @Published var isEnabled: Bool {
        didSet { guard isEnabled != oldValue else { return }; StatusDefaults.set(isEnabled, Self.enabledKey); apply() }
    }
    @Published var watchesMicrophone: Bool {
        didSet { guard watchesMicrophone != oldValue else { return }; StatusDefaults.set(watchesMicrophone, Self.micKey); apply() }
    }
    @Published var watchesCamera: Bool {
        didSet { guard watchesCamera != oldValue else { return }; StatusDefaults.set(watchesCamera, Self.cameraKey); apply() }
    }
    @Published var watchesScreen: Bool {
        didSet { guard watchesScreen != oldValue else { return }; StatusDefaults.set(watchesScreen, Self.screenKey); scheduleEvaluate() }
    }
    @Published var display: PrivacyDisplay {
        didSet {
            guard display != oldValue else { return }
            StatusDefaults.set(display.rawValue, Self.displayKey)
            shown = .idle
            SystemStatusCenter.shared.dismiss(id: Self.activityID)
            publish(snapshot, force: true)
        }
    }

    /// What is in use now (empty while off).
    @Published private(set) var snapshot = PrivacySnapshot.idle

    private let probe = PrivacyHardwareProbe()
    private var isStarted = false
    private var isProbing = false
    private var evaluateTask: Task<Void, Never>?
    /// What the island shows, and a counter that moves when something new
    /// starts (a new `peekKey` makes the band peek).
    private var shown = PrivacySnapshot.idle
    private var peekCounter = 0
    private var screenSharing = false
    private var screenSharer: (@MainActor () -> String?)?
    private var screenWatch: AnyCancellable?
    private var activationObserver: NSObjectProtocol?
    /// SparkV's own running capture sessions with a camera (mirror, Screen
    /// Distance, Face Unlock): from AVFoundation's in-process notifications.
    private var ownCameraSessions: Set<ObjectIdentifier> = []
    private var captureObservers: [NSObjectProtocol] = []

    private init() {
        isEnabled = StatusDefaults.bool(Self.enabledKey, default: true)
        watchesMicrophone = StatusDefaults.bool(Self.micKey, default: true)
        watchesCamera = StatusDefaults.bool(Self.cameraKey, default: true)
        watchesScreen = StatusDefaults.bool(Self.screenKey, default: true)
        display = PrivacyDisplay(rawValue: StatusDefaults.string(Self.displayKey) ?? "") ?? .wings
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        apply()
    }

    func stop() {
        isStarted = false
        apply()
    }

    /// Screen sharing from SmartMoments (`sources.$isScreenSharing`) and,
    /// optionally, the sharing app's name.
    func connectScreenSharing(_ sharing: AnyPublisher<Bool, Never>, sharer: (@MainActor () -> String?)? = nil) {
        screenSharer = sharer
        screenWatch = sharing.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] on in
            MainActor.assumeIsolated {
                self?.screenSharing = on
                self?.scheduleEvaluate()
            }
        }
    }

    // MARK: Lifecycle

    private func apply() {
        let wantsProbe = isStarted && isEnabled && (watchesMicrophone || watchesCamera)
        if wantsProbe {
            probe.configure(microphone: watchesMicrophone, camera: watchesCamera) { [weak self] in
                Task { @MainActor [weak self] in self?.scheduleEvaluate() }
            }
            if !isProbing {
                isProbing = true
                AppLog.log("Privacy: watching \([watchesMicrophone ? "microphone" : nil, watchesCamera ? "camera" : nil].compactMap { $0 }.joined(separator: " and "))")
            }
            if captureObservers.isEmpty, watchesCamera { observeOwnCapture() }
            if activationObserver == nil, watchesCamera {
                // The camera's guess follows the front app.
                activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.snapshot.camera, self.snapshot.microphone.isEmpty else { return }
                        self.scheduleEvaluate()
                    }
                }
            }
        } else if isProbing {
            isProbing = false
            probe.stop()
            AppLog.log("Privacy: stopped")
        }
        if !wantsProbe || !watchesCamera {
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
            captureObservers.forEach { NotificationCenter.default.removeObserver($0) }
            captureObservers.removeAll()
            ownCameraSessions.removeAll()
        }
        guard isStarted, isEnabled else {
            evaluateTask?.cancel()
            evaluateTask = nil
            publish(.idle, force: true)
            return
        }
        scheduleEvaluate()
    }

    /// AVFoundation announces every capture session of this process: those
    /// with a camera input are SparkV's own camera use.
    private func observeOwnCapture() {
        let center = NotificationCenter.default
        let started = center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: nil, queue: nil) { [weak self] note in
            // On the session's own queue: read its inputs here.
            guard let session = note.object as? AVCaptureSession else { return }
            let id = ObjectIdentifier(session)
            let hasCamera = session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }
            guard hasCamera else { return }
            Task { @MainActor [weak self] in
                self?.ownCameraSessions.insert(id)
                self?.scheduleEvaluate()
            }
        }
        let stopped = center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: nil, queue: nil) { [weak self] note in
            guard let session = note.object as? AVCaptureSession else { return }
            let id = ObjectIdentifier(session)
            Task { @MainActor [weak self] in
                guard self?.ownCameraSessions.remove(id) != nil else { return }
                self?.scheduleEvaluate()
            }
        }
        captureObservers = [started, stopped]
    }

    /// Coalesces bursts of HAL notifications (an app opening the mic fires
    /// several) into one read.
    private func scheduleEvaluate() {
        guard isStarted, isEnabled else { return }
        evaluateTask?.cancel()
        evaluateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let state = await self.probe.read()
            guard !Task.isCancelled, self.isStarted, self.isEnabled else { return }
            self.publish(self.makeSnapshot(state), force: false)
        }
    }

    private func makeSnapshot(_ state: PrivacyHardwareState) -> PrivacySnapshot {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownBundle = Bundle.main.bundleIdentifier
        var snapshot = PrivacySnapshot()
        if watchesMicrophone {
            if let processes = state.processes {
                snapshot.microphone = PrivacyAttribution.microphoneApps(processes, ownPID: ownPID, ownBundleID: ownBundle, name: PrivacyAppNamer.app(for:))
            } else {
                snapshot.microphoneUnattributed = state.inputRunning
            }
        }
        if watchesCamera, state.cameraRunning, ownCameraSessions.isEmpty, !SystemStatusCenter.shared.isOwnCameraActive() {
            snapshot.camera = true
            snapshot.cameraLikelyApp = PrivacyAttribution.cameraGuess(
                micApps: snapshot.microphone, frontmost: PrivacyAppNamer.frontmost(), ownBundleID: ownBundle
            )
        }
        if watchesScreen, screenSharing {
            snapshot.screen = true
            snapshot.screenApp = screenSharer?()
        }
        return snapshot
    }

    private func publish(_ new: PrivacySnapshot, force: Bool) {
        let previous = snapshot
        if snapshot != new { snapshot = new }
        guard force || new != shown else { return }
        let adds = new.adds(over: shown)
        shown = new
        if new != previous {
            AppLog.log("Privacy: \(new.isIdle ? "nothing in use" : new.headline)")
        }
        guard isStarted, isEnabled, !new.isIdle else {
            SystemStatusCenter.shared.dismiss(id: Self.activityID)
            return
        }
        if adds { peekCounter &+= 1 }
        switch display {
        case .wings:
            SystemStatusCenter.shared.post(Self.activity(new, peekKey: "\(peekCounter)"))
        case .band:
            if adds { SystemStatusCenter.shared.post(Self.bandActivity(new)) }
        }
    }

    private static func activity(_ snapshot: PrivacySnapshot, peekKey: String) -> LiveActivity {
        let sensors = snapshot.sensors
        let app = snapshot.leadApp
        return LiveActivity(
            id: activityID,
            kind: .notification,
            priority: 18,
            duration: nil,
            opensTab: SystemStatusCenter.shared.statusTab,
            symbol: sensors.first?.symbol ?? "mic.fill",
            tint: PrivacyPalette.color(sensors.first ?? .microphone),
            peekKey: peekKey
        ) {
            PrivacyActivityView(snapshot: snapshot)
        }
        .titled("Microphone & Camera")
        .accessibility(snapshot.headline + " in use")
        .compact {
            PrivacyDots(sensors: sensors, size: 7)
                .accessibilityLabel(snapshot.headline)
        } trailing: {
            PrivacyAppBadge(app: app, size: 16)
        }
        .minimal {
            PrivacyDots(sensors: sensors, size: 6)
                .frame(width: 18, height: 18)
                .background(Circle().fill(SparkVTheme.surfaceHover))
                .accessibilityLabel(snapshot.headline)
        }
    }

    private static func bandActivity(_ snapshot: PrivacySnapshot) -> LiveActivity {
        LiveActivity(id: activityID, kind: .notification, priority: 45, duration: 3.5,
                     opensTab: SystemStatusCenter.shared.statusTab) {
            PrivacyActivityView(snapshot: snapshot)
        }
        .titled("Microphone & Camera")
        .accessibility(snapshot.headline + " in use")
    }
}

// MARK: - Naming apps

/// Process → app name and icon (main actor: NSRunningApplication).
@MainActor
enum PrivacyAppNamer {
    /// Shared system processes that do the capturing for an app.
    private static let aliases: [String: String] = [
        "avconferenced": "com.apple.FaceTime",
        "com.apple.avconferenced": "com.apple.FaceTime",
    ]

    /// WebKit's shared helpers capture for Safari and for every app with a
    /// web view (Mail, Messages, Electron-free apps…). They are XPC
    /// services (parent: launchd), so the real owner can't be read with
    /// public API: Safari when Safari is in front, else "A web page".
    static let webKitHelpers: Set<String> = ["com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"]
    static let webPageName = "A web page"

    static func app(for process: PrivacyAudioProcess) -> PrivacyApp {
        if process.ownerBundleID == nil, webKitHelpers.contains(process.bundleID ?? "")
            || process.executable.hasPrefix("com.apple.WebKit") {
            if let front = frontmost(), front.bundleID == "com.apple.Safari" { return front }
            return PrivacyApp(name: webPageName, bundleID: nil, pid: process.pid)
        }
        let candidates = [process.ownerBundleID, process.bundleID, aliases[process.bundleID ?? ""], aliases[process.executable]].compactMap { $0 }
        for bundleID in candidates {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let name = running.localizedName {
                return PrivacyApp(name: name, bundleID: bundleID, pid: running.processIdentifier)
            }
        }
        if let running = NSRunningApplication(processIdentifier: process.pid), let name = running.localizedName {
            return PrivacyApp(name: name, bundleID: running.bundleIdentifier, pid: process.pid)
        }
        if let bundleID = candidates.first, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return PrivacyApp(name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), bundleID: bundleID, pid: process.pid)
        }
        return PrivacyApp(name: process.executable.isEmpty ? "An app" : process.executable, bundleID: process.bundleID, pid: process.pid)
    }

    static func frontmost() -> PrivacyApp? {
        guard let front = NSWorkspace.shared.frontmostApplication, let name = front.localizedName else { return nil }
        return PrivacyApp(name: name, bundleID: front.bundleIdentifier, pid: front.processIdentifier)
    }

    private static var iconCache: [String: NSImage] = [:]

    static func icon(for app: PrivacyApp) -> NSImage? {
        let key = app.bundleID ?? app.name
        if let cached = iconCache[key] { return cached }
        var image: NSImage?
        if let bundleID = app.bundleID {
            image = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        } else if let pid = app.pid {
            image = NSRunningApplication(processIdentifier: pid)?.icon
        }
        if let image {
            if iconCache.count > 32 { iconCache.removeAll() }
            iconCache[key] = image
        }
        return image
    }
}

// MARK: - CoreAudio / CoreMediaIO listeners

struct PrivacyHardwareState: Sendable {
    /// Processes running input; nil when the HAL can't list them.
    var processes: [PrivacyAudioProcess]?
    var inputRunning: Bool
    var cameraRunning: Bool
}

/// Owns every HAL and CMIO listener. All state lives on `queue`; listener
/// blocks run there too and only call `onChange`.
final class PrivacyHardwareProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SparkV.Privacy", qos: .utility)

    // Touched on `queue` only.
    private var onChange: (@Sendable () -> Void)?
    private var watchesMicrophone = false
    private var watchesCamera = false
    private var audioListeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var processListeners: [AudioObjectID: (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = [:]
    private var cameraListeners: [(object: CMIOObjectID, address: CMIOObjectPropertyAddress, block: CMIOObjectPropertyListenerBlock)] = []
    /// pid → (executable path, owner bundle ID).
    private var owners: [Int32: (path: String, owner: String?)] = [:]

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// (Re)installs the listeners for the sensors asked for.
    func configure(microphone: Bool, camera: Bool, onChange: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            self.onChange = onChange
            if microphone != watchesMicrophone || (microphone && audioListeners.isEmpty) {
                removeAudioListeners()
                watchesMicrophone = microphone
                if microphone { installAudioListeners() }
            }
            if camera != watchesCamera || (camera && cameraListeners.isEmpty) {
                removeCameraListeners()
                watchesCamera = camera
                if camera { installCameraListeners() }
            }
        }
    }

    /// Removes every listener; returns once none can fire any more.
    func stop() {
        queue.sync {
            removeAudioListeners()
            removeCameraListeners()
            watchesMicrophone = false
            watchesCamera = false
            onChange = nil
            owners.removeAll()
        }
    }

    func read() async -> PrivacyHardwareState {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let processes = watchesMicrophone ? readProcesses() : []
                let input = watchesMicrophone ? inputDevices().contains { uint32(device: $0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 } : false
                let camera = watchesCamera ? cameraDevices().contains(where: cameraRunning) : false
                continuation.resume(returning: PrivacyHardwareState(processes: processes, inputRunning: input, cameraRunning: camera))
            }
        }
    }

    private func changed() {
        onChange?()
    }

    // MARK: Audio

    private func installAudioListeners() {
        addAudioListener(Self.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.refreshProcessListeners()
            self?.changed()
        }
        addAudioListener(Self.system, kAudioHardwarePropertyDevices) { [weak self] in
            // A headset or webcam mic came or went: listen to its device too
            // (re-installed on the next turn, not from inside this callback).
            self?.queue.async { [weak self] in
                guard let self, self.watchesMicrophone else { return }
                self.removeAudioListeners()
                self.installAudioListeners()
                self.changed()
            }
        }
        addAudioListener(Self.system, kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.changed() }
        for device in inputDevices() {
            addAudioListener(device, kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in self?.changed() }
        }
        refreshProcessListeners()
    }

    private func removeAudioListeners() {
        for listener in audioListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        audioListeners.removeAll()
        for (object, listener) in processListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener.block)
        }
        processListeners.removeAll()
    }

    private func addAudioListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping @Sendable () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
        audioListeners.append((object, address, block))
    }

    /// One `IsRunningInput` listener per audio client process: catches a
    /// second app opening a mic that is already running.
    private func refreshProcessListeners() {
        let current = Set(processObjects())
        for (object, listener) in processListeners where !current.contains(object) {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener.block)
            processListeners.removeValue(forKey: object)
        }
        for object in current where processListeners[object] == nil {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
            if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                processListeners[object] = (address, block)
            }
        }
    }

    private func processObjects() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private func readProcesses() -> [PrivacyAudioProcess]? {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr else { return nil }
        var result: [PrivacyAudioProcess] = []
        var alive: Set<Int32> = []
        for object in processObjects() where uint32(device: object, kAudioProcessPropertyIsRunningInput) != 0 {
            var pid: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid > 0 else { continue }
            alive.insert(pid)
            let owner = owner(of: pid)
            result.append(PrivacyAudioProcess(
                pid: pid,
                bundleID: string(object, kAudioProcessPropertyBundleID),
                ownerBundleID: owner.owner,
                executable: (owner.path as NSString).lastPathComponent,
                isRunningInput: true
            ))
        }
        if owners.count > 64 { owners = owners.filter { alive.contains($0.key) } }
        return result
    }

    /// Executable path and the bundle ID of the outermost .app it lives in.
    private func owner(of pid: pid_t) -> (path: String, owner: String?) {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        if let cached = owners[pid], cached.path == path { return cached }
        var ownerID: String?
        if let range = path.range(of: ".app/") {
            ownerID = Bundle(path: String(path[..<range.lowerBound]) + ".app")?.bundleIdentifier
        }
        let entry = (path: path, owner: ownerID)
        owners[pid] = entry
        return entry
    }

    private func inputDevices() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(Self.system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { device in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr && streamSize > 0
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func uint32(device object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = Self.address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    // MARK: Camera

    private static func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private func installCameraListeners() {
        let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
        addCameraListener(systemObject, Int(kCMIOHardwarePropertyDevices)) { [weak self] in
            // A webcam was plugged in or out: listen to the new list.
            self?.queue.async { [weak self] in
                guard let self, self.watchesCamera else { return }
                self.removeCameraListeners()
                self.installCameraListeners()
                self.changed()
            }
        }
        for device in cameraDevices() {
            addCameraListener(device, Int(kCMIODevicePropertyDeviceIsRunningSomewhere)) { [weak self] in self?.changed() }
        }
    }

    private func removeCameraListeners() {
        for listener in cameraListeners {
            var address = listener.address
            CMIOObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
        }
        cameraListeners.removeAll()
    }

    private func addCameraListener(_ object: CMIOObjectID, _ selector: Int, _ handler: @escaping @Sendable () -> Void) {
        var address = Self.cmioAddress(selector)
        let block: CMIOObjectPropertyListenerBlock = { _, _ in handler() }
        guard CMIOObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return }
        cameraListeners.append((object, address, block))
    }

    private func cameraDevices() -> [CMIOObjectID] {
        var address = Self.cmioAddress(Int(kCMIOHardwarePropertyDevices))
        let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(systemObject, &address, 0, nil, size, &used, &devices) == noErr else { return [] }
        return Array(devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private func cameraRunning(_ device: CMIOObjectID) -> Bool {
        var address = Self.cmioAddress(Int(kCMIODevicePropertyDeviceIsRunningSomewhere))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return false }
        return value != 0
    }
}
