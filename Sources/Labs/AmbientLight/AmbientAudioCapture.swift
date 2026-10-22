import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit
import Synchronization

// System-audio capture for Ambient Light.
//
// Preferred: a Core Audio process tap (macOS 14.4+): a private, global mono
// tap of everything the Mac plays except SparkV itself, read through a
// private aggregate device. Its IO block runs on the HAL's realtime thread
// and only copies samples into a lock-free ring buffer: no locks, no
// allocation, no Objective-C, no logging.
// Fallback: a ScreenCaptureKit audio stream, only when Screen Recording is
// already granted (via PermissionCenter, so it never prompts).

// MARK: - Lock-free ring buffer

/// Single-producer / single-consumer float ring. The capture thread writes,
/// the analysis queue reads. When the reader falls behind, the writer drops
/// the newest samples instead of blocking (the reader skips ahead anyway).
final class AmbientSampleRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total samples written / read (monotonic; index = count % capacity).
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)

    init(capacity: Int = 1 << 16) {
        precondition(capacity.nonzeroBitCount == 1)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Realtime-safe. `stride` > 1 averages interleaved channels to mono.
    func write(_ source: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        let free = capacity - (w - r)
        let count = min(frames, free)
        guard count > 0 else { return }
        let mask = capacity - 1
        if channels == 1 {
            let start = w & mask
            let first = min(count, capacity - start)
            (storage + start).update(from: source, count: first)
            if count > first { storage.update(from: source + first, count: count - first) }
        } else {
            let scale = 1 / Float(channels)
            for frame in 0..<count {
                var sum: Float = 0
                let base = source + frame * channels
                for channel in 0..<channels { sum += base[channel] }
                storage[(w + frame) & mask] = sum * scale
            }
        }
        written.store(w + count, ordering: .releasing)
    }

    /// Realtime-safe; for non-interleaved stereo (two separate buffers).
    func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        let w = written.load(ordering: .relaxed)
        let r = read.load(ordering: .acquiring)
        let count = min(frames, capacity - (w - r))
        guard count > 0 else { return }
        let mask = capacity - 1
        for frame in 0..<count {
            storage[(w + frame) & mask] = 0.5 * (left[frame] + right[frame])
        }
        written.store(w + count, ordering: .releasing)
    }

    var available: Int {
        written.load(ordering: .acquiring) - read.load(ordering: .relaxed)
    }

    /// Copies `count` samples into `destination`; false when not enough.
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        let r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        guard w - r >= count else { return false }
        let mask = capacity - 1
        let start = r & mask
        let first = min(count, capacity - start)
        destination.update(from: storage + start, count: first)
        if count > first { (destination + first).update(from: storage, count: count - first) }
        read.store(r + count, ordering: .releasing)
        return true
    }

    /// Drops all but the newest `keep` samples (the reader fell behind).
    func skip(keeping keep: Int) {
        let r = read.load(ordering: .relaxed)
        let w = written.load(ordering: .acquiring)
        if w - r > keep { read.store(w - keep, ordering: .releasing) }
    }

    func clear() {
        read.store(written.load(ordering: .acquiring), ordering: .releasing)
    }
}

// MARK: - Sources

enum AmbientCaptureError: Error, LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): "\(step) failed (\(status))"
        case .unsupportedFormat: "unsupported audio format"
        case .noDisplay: "no display to capture audio from"
        }
    }
}

/// Something that fills an `AmbientSampleRing` with mono system audio.
protocol AmbientAudioSource: AnyObject, Sendable {
    /// Short name for the status line.
    var name: String { get }
    /// Starts capture; returns the sample rate.
    func start() async throws -> Double
    func stop()
}

/// Core Audio process tap + private aggregate device.
final class AmbientProcessTapSource: AmbientAudioSource, @unchecked Sendable {
    let name = "System Audio"
    private let ring: AmbientSampleRing
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Called on the main queue when the default output device changes (the
    /// owner restarts capture so the aggregate follows the new device).
    var onRouteChange: (@Sendable () -> Void)?
    private var routeListener: AudioObjectPropertyListenerBlock?

    init(ring: AmbientSampleRing) {
        self.ring = ring
    }

    deinit {
        stop()
    }

    func start() async throws -> Double {
        stop()
        // Exclude SparkV itself (its own sounds would echo into the lights).
        var excluded: [AudioObjectID] = []
        if let own = Self.processObject(pid: getpid()) { excluded.append(own) }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "SparkV Ambient Light"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw AmbientCaptureError.coreAudio("Creating the audio tap", status) }
        tapID = tap

        do {
            let outputUID = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SparkV Ambient Light",
                kAudioAggregateDeviceUIDKey: "com.sparkv.ambientlight." + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
            guard status == noErr else { throw AmbientCaptureError.coreAudio("Creating the aggregate device", status) }
            aggregateID = device

            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
            guard status == noErr else { throw AmbientCaptureError.coreAudio("Reading the tap format", status) }
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { throw AmbientCaptureError.unsupportedFormat }
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000

            // The IO block: realtime thread (nil queue), copy only. The tap's
            // stream is the last input buffer (sub-device inputs come first).
            let ring = self.ring
            var proc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                guard list.count > 0 else { return }
                if !interleaved, list.count >= 2,
                   let l = list[list.count - 2].mData, let r = list[list.count - 1].mData,
                   list[list.count - 2].mDataByteSize == list[list.count - 1].mDataByteSize,
                   format.mChannelsPerFrame == 2 {
                    let frames = Int(list[list.count - 1].mDataByteSize) / 4
                    ring.write(left: l.assumingMemoryBound(to: Float.self), right: r.assumingMemoryBound(to: Float.self), frames: frames)
                    return
                }
                let buffer = list[list.count - 1]
                guard let data = buffer.mData else { return }
                let channels = max(1, Int(buffer.mNumberChannels))
                let frames = Int(buffer.mDataByteSize) / (4 * channels)
                ring.write(UnsafePointer(data.assumingMemoryBound(to: Float.self)), frames: frames, channels: channels)
            }
            guard status == noErr, let proc else { throw AmbientCaptureError.coreAudio("Adding the audio callback", status) }
            procID = proc

            // This start is what shows macOS's "System Audio Recording"
            // prompt the first time (only reached from the user's action, or
            // after the user already answered it).
            status = AudioDeviceStart(device, proc)
            guard status == noErr else { throw AmbientCaptureError.coreAudio("Starting capture", status) }
            listenForRouteChanges()
            return sampleRate
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if let routeListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, routeListener)
            self.routeListener = nil
        }
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func listenForRouteChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onRouteChange?()
        }
        var address = Self.defaultOutputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            routeListener = block
        }
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputUID() throws -> String {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { throw AmbientCaptureError.coreAudio("Finding the output device", status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid)
        guard status == noErr, let uid else { throw AmbientCaptureError.coreAudio("Reading the output device", status) }
        return uid.takeRetainedValue() as String
    }
}

/// ScreenCaptureKit audio-only fallback (needs Screen Recording, which is
/// checked through PermissionCenter and never requested from here).
final class AmbientScreenCaptureSource: NSObject, AmbientAudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let name = "Screen Capture Audio"
    private let ring: AmbientSampleRing
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "SparkV.AmbientLight.sck", qos: .userInteractive)

    init(ring: AmbientSampleRing) {
        self.ring = ring
    }

    func start() async throws -> Double {
        stop()
        let content = try await PermissionCenter.shared.shareableContent(from: "Ambient Light")
        guard let display = content.displays.first else { throw AmbientCaptureError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // Video is mandatory; keep it as small and slow as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        await MainActor.run { PermissionCenter.shared.noteScreenCaptureUse(from: "Ambient Light") }
        self.stream = stream
        return 48_000
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        stream.stopCapture { _ in }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        let ring = self.ring
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard list.count > 0 else { return }
            if list.count >= 2, let l = list[0].mData, let r = list[1].mData {
                let frames = Int(min(list[0].mDataByteSize, list[1].mDataByteSize)) / 4
                ring.write(left: l.assumingMemoryBound(to: Float.self), right: r.assumingMemoryBound(to: Float.self), frames: frames)
            } else if let data = list[0].mData {
                let channels = max(1, Int(list[0].mNumberChannels))
                ring.write(UnsafePointer(data.assumingMemoryBound(to: Float.self)),
                           frames: Int(list[0].mDataByteSize) / (4 * channels), channels: channels)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        AppLog.log("AmbientLight: screen capture audio stopped: \(error.localizedDescription)")
    }
}

// MARK: - System Audio Recording permission

/// macOS's "System Audio Recording" (TCC service kTCCServiceAudioCapture)
/// has no public status API. `rawPreflight` / `rawRequest` use the TCC
/// framework's preflight / request functions when they're present (looked up
/// at run time, as AudioCap does) and report `.unknown` otherwise; then the
/// first `AudioDeviceStart` of a tap is the prompt.
///
/// Ambient Light calls only `preflight()` (never prompts) and, from the
/// user's click, `request()`. Once PermissionCenter has a `.systemAudio` case
/// (INTEGRATION.md step 7) those two route through PermissionCenter, which
/// in turn uses the raw functions.
enum AmbientAudioPermission {
    enum State: String, Sendable {
        case granted, denied, notDetermined, unknown
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    /// Never prompts.
    @MainActor
    static func preflight() -> State {
        state(PermissionCenter.shared.status(.systemAudio))
    }

    /// Shows the system prompt when macOS hasn't asked yet. Call only from a
    /// user action. `.unknown`: the TCC functions aren't available and the
    /// caller starts the tap, which prompts.
    @MainActor
    static func request() async -> State {
        state(await PermissionCenter.shared.request(.systemAudio, from: "Ambient Light", openingSettings: true))
    }

    @MainActor
    private static func state(_ status: PermissionCenter.Status) -> State {
        switch status {
        case .granted: .granted
        case .denied, .restricted: .denied
        case .notDetermined, .limited: .notDetermined
        default: .unknown
        }
    }

    // MARK: Raw TCC access (also for PermissionCenter's `.systemAudio`)

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    nonisolated(unsafe) private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    nonisolated static func rawPreflight() -> State {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let function = unsafeBitCast(symbol, to: Preflight.self)
        switch function(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    nonisolated static func rawRequest() async -> State {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return .unknown }
        let function = unsafeBitCast(symbol, to: Request.self)
        let granted: Bool = await withCheckedContinuation { continuation in
            function(service, nil) { granted in continuation.resume(returning: granted) }
        }
        return granted ? .granted : .denied
    }
}
