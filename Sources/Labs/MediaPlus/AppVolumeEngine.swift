import AppKit
import CoreAudio
import Darwin
import Synchronization

// Per-app volume with Core Audio process taps (public API, macOS 14.2+).
//
// For each app whose volume isn't 100 % while it plays:
//   1. a private stereo-mixdown tap of the app's audio processes with
//      `muteBehavior = .mutedWhenTapped`: macOS mutes the app's own output
//      only while the tap is being read, so if SparkV stops (or crashes) the
//      app plays normally again;
//   2. a private aggregate device: the current output device plus the tap;
//   3. an IO block on that aggregate copying the tap to the output at the
//      chosen gain (ramped, soft-clipped above 100 %).
// The IO block runs on the HAL's realtime thread: atomics and raw pointers
// only (no locks, allocation, logging or Swift concurrency).
// Taps cost CPU and keep the output device awake, so one exists only while
// its app plays at a gain other than 100 %.

/// One Core Audio process object that is (or was) making sound.
struct AppAudioProcess: Equatable, Sendable {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let path: String
    let isRunningOutput: Bool
}

/// The processes of one app, grouped (Chrome's helpers count as Chrome).
struct AppAudioGroup: Identifiable, Equatable, Sendable {
    /// Stable key for saved volumes: the app's bundle id (or its process's).
    let id: String
    let name: String
    /// .app bundle path for the icon, when there is one.
    let appPath: String?
    var objects: [AudioObjectID]
    var isPlaying: Bool
    /// The objects that are sending output right now (a subset of objects).
    var playingObjects: [AudioObjectID] = []
}

enum AppVolumeError: Error, LocalizedError, Equatable {
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)
    case sampleRateMismatch(tap: Double, device: Double)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): "\(step) failed (\(status))"
        case .unsupportedFormat(let what): "\(what) isn’t 32-bit float audio"
        case .sampleRateMismatch(let tap, let device):
            "The app plays at \(Int(tap)) Hz but the output runs at \(Int(device)) Hz"
        case .noOutput: "No output device"
        }
    }

    /// Fits the mixer row's second line.
    var shortText: String {
        switch self {
        case .coreAudio: "Couldn’t adjust this app"
        case .unsupportedFormat: "Format not supported"
        case .sampleRateMismatch(let tap, let device):
            "Rate mismatch (\(Self.khz(tap)) / \(Self.khz(device)) kHz)"
        case .noOutput: "No output device"
        }
    }

    private static func khz(_ hz: Double) -> String {
        let value = hz / 1000
        return value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

// MARK: - Realtime state

/// Shared between the main thread and the IO block. The layout fields are
/// written once before the IO proc starts and only read afterwards.
final class AppGainState: @unchecked Sendable {
    /// Target gain as Float bits (written by the UI, read per IO cycle).
    let targetBits = Atomic<UInt32>(Float(1).bitPattern)
    /// IO cycles run / cycles that carried sound (for the health check).
    let cycles = Atomic<Int>(0)
    let audibleCycles = Atomic<Int>(0)
    /// Ramped gain, touched only by the IO thread.
    let current: UnsafeMutablePointer<Float>

    /// Tap stream layout: interleaved (one buffer, `tapChannels` wide) or
    /// one buffer per channel.
    var tapInterleaved = true
    var tapChannels = 2

    init(gain: Float) {
        current = .allocate(capacity: 1)
        current.initialize(to: gain)
        targetBits.store(gain.bitPattern, ordering: .relaxed)
    }

    deinit {
        current.deallocate()
    }

    func setGain(_ gain: Float) {
        targetBits.store(gain.bitPattern, ordering: .relaxed)
    }

    /// The IO block body. Realtime-safe.
    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        cycles.add(1, ordering: .relaxed)
        let outs = UnsafeMutableAudioBufferListPointer(output)
        for index in 0..<outs.count {
            if let data = outs[index].mData { memset(data, 0, Int(outs[index].mDataByteSize)) }
        }
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let tapBuffers = tapInterleaved ? 1 : max(1, tapChannels)
        guard outs.count > 0, ins.count >= tapBuffers else { return }
        // Sub-device inputs (a headset mic) come first; the tap is last.
        let first = ins.count - tapBuffers

        let left: UnsafePointer<Float>
        let right: UnsafePointer<Float>
        let inStride: Int
        var frames: Int
        if tapBuffers == 1 {
            let buffer = ins[first]
            guard let data = buffer.mData else { return }
            let channels = max(1, Int(buffer.mNumberChannels))
            let base = UnsafePointer(data.assumingMemoryBound(to: Float.self))
            left = base
            right = channels > 1 ? base + 1 : base
            inStride = channels
            frames = Int(buffer.mDataByteSize) / (4 * channels)
        } else {
            let l = ins[first], r = ins[first + 1]
            guard let ld = l.mData, let rd = r.mData else { return }
            left = UnsafePointer(ld.assumingMemoryBound(to: Float.self))
            right = UnsafePointer(rd.assumingMemoryBound(to: Float.self))
            inStride = 1
            frames = Int(min(l.mDataByteSize, r.mDataByteSize)) / 4
        }

        let outLeft: UnsafeMutablePointer<Float>
        var outRight: UnsafeMutablePointer<Float>?
        let outStride: Int
        let out0 = outs[0]
        guard let out0Data = out0.mData else { return }
        let out0Channels = max(1, Int(out0.mNumberChannels))
        if out0Channels >= 2 {
            outLeft = out0Data.assumingMemoryBound(to: Float.self)
            outRight = outLeft + 1
            outStride = out0Channels
            frames = min(frames, Int(out0.mDataByteSize) / (4 * out0Channels))
        } else if outs.count >= 2, let out1Data = outs[1].mData {
            outLeft = out0Data.assumingMemoryBound(to: Float.self)
            outRight = out1Data.assumingMemoryBound(to: Float.self)
            outStride = 1
            frames = min(frames, Int(min(out0.mDataByteSize, outs[1].mDataByteSize)) / 4)
        } else {
            outLeft = out0Data.assumingMemoryBound(to: Float.self)
            outRight = nil
            outStride = 1
            frames = min(frames, Int(out0.mDataByteSize) / 4)
        }
        guard frames > 0 else { return }

        let target = Float(bitPattern: targetBits.load(ordering: .relaxed))
        let from = current.pointee
        let peak = AppGainMath.render(left: left, right: right, inStride: inStride,
                                      outLeft: outLeft, outRight: outRight, outStride: outStride,
                                      frames: frames, from: from, to: target)
        current.pointee = target
        if peak > 1e-6 { audibleCycles.add(1, ordering: .relaxed) }
    }
}

// MARK: - One app's route

/// Tap + aggregate + IO proc for one app. Create, start and stop it on one
/// serial queue (`AppVolumeEngine.queue`).
final class AppGainRoute: @unchecked Sendable {
    let key: String
    let name: String
    let objects: [AudioObjectID]
    let state: AppGainState
    /// The output this route plays to (read on start, on the HAL queue).
    private(set) var outputUID = ""

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    init(key: String, name: String, objects: [AudioObjectID], gain: Float) {
        self.key = key
        self.name = name
        self.objects = objects
        state = AppGainState(gain: gain)
    }

    deinit {
        stop()
    }

    func start() throws {
        stop()
        do {
            outputUID = try AmbientProcessTapSource.defaultOutputUID()
        } catch {
            throw AppVolumeError.noOutput
        }
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID()
        description.name = "SparkV App Volume (\(name))"
        description.isPrivate = true
        // Muted only while SparkV reads the tap: if this route stops for any
        // reason, the app is heard again at its normal level.
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw AppVolumeError.coreAudio("Creating the tap", status) }
        tapID = tap

        do {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = MPAudioHAL.address(kAudioTapPropertyFormat)
            status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
            guard status == noErr else { throw AppVolumeError.coreAudio("Reading the tap format", status) }
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { throw AppVolumeError.unsupportedFormat("The app’s audio") }
            state.tapInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            state.tapChannels = max(1, Int(format.mChannelsPerFrame))

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SparkV App Volume",
                kAudioAggregateDeviceUIDKey: "com.sparkv.appvolume." + UUID().uuidString,
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
            guard status == noErr else { throw AppVolumeError.coreAudio("Creating the aggregate device", status) }
            aggregateID = device

            try Self.checkOutputFormat(of: device)
            // A tap that isn't at the device's rate would play at the wrong
            // pitch; better to leave the app alone than to garble it.
            if let deviceRate = Self.nominalRate(of: device), format.mSampleRate > 0,
               abs(deviceRate - format.mSampleRate) > 1 {
                throw AppVolumeError.sampleRateMismatch(tap: format.mSampleRate, device: deviceRate)
            }

            let state = self.state
            var proc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, output, _ in
                state.process(input: input, output: output)
            }
            guard status == noErr, let proc else { throw AppVolumeError.coreAudio("Adding the audio callback", status) }
            procID = proc
            // Only the tap (the last input stream) is read: a headset's
            // microphone in the same device is left off.
            Self.useOnlyLastInputStream(of: device, proc: proc)
            status = AudioDeviceStart(device, proc)
            guard status == noErr else { throw AppVolumeError.coreAudio("Starting playback", status) }
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
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
        isRunning = false
    }

    private static func checkOutputFormat(of device: AudioObjectID) throws {
        let streams = MPAudioHAL.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard let stream = streams.first else { throw AppVolumeError.noOutput }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = MPAudioHAL.address(kAudioStreamPropertyVirtualFormat)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr else { return }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { throw AppVolumeError.unsupportedFormat("The output device") }
    }

    /// kAudioDevicePropertyIOProcStreamUsage: marks every input stream but
    /// the last (the tap) unused for this IO proc. Best effort.
    private static func useOnlyLastInputStream(of device: AudioObjectID, proc: AudioDeviceIOProcID) {
        let streams = MPAudioHAL.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        guard streams.count > 1 else { return }
        var address = MPAudioHAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
        // struct { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        raw.storeBytes(of: UnsafeMutableRawPointer(bitPattern: unsafeBitCast(proc, to: Int.self)), as: UnsafeMutableRawPointer?.self)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return }
        let count = Int(raw.load(fromByteOffset: MemoryLayout<UnsafeMutableRawPointer?>.size, as: UInt32.self))
        let flagsOffset = MemoryLayout<UnsafeMutableRawPointer?>.size + MemoryLayout<UInt32>.size
        guard count > 1, flagsOffset + count * 4 <= Int(size) else { return }
        for index in 0..<count {
            raw.storeBytes(of: UInt32(index == count - 1 ? 1 : 0), toByteOffset: flagsOffset + index * 4, as: UInt32.self)
        }
        AudioObjectSetPropertyData(device, &address, 0, nil, size, raw)
    }

    static func nominalRate(of device: AudioObjectID) -> Double? {
        var address = MPAudioHAL.address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
}

// MARK: - Process list

/// Reads Core Audio's process objects and groups them by app. All calls on
/// the engine queue.
enum AppAudioProcesses {
    static func read(excludingPID own: pid_t) -> [AppAudioProcess] {
        MPAudioHAL.objects(MPAudioHAL.system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
            var pid: pid_t = -1
            var size = UInt32(MemoryLayout<pid_t>.size)
            var address = MPAudioHAL.address(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0, pid != own else { return nil }
            return AppAudioProcess(
                object: object,
                pid: pid,
                bundleID: MPAudioHAL.string(object, kAudioProcessPropertyBundleID),
                path: executablePath(pid),
                isRunningOutput: (MPAudioHAL.uint32(object, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            )
        }
    }

    static func executablePath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The outermost .app around `path` ("/Applications/Google Chrome.app"
    /// for Chrome's helpers).
    static func appBundlePath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Groups processes by app. `names` resolves a display name for a pid
    /// (NSRunningApplication on the main thread is the caller's job).
    static func group(_ processes: [AppAudioProcess], name: (AppAudioProcess, String?) -> String?) -> [AppAudioGroup] {
        var groups: [String: AppAudioGroup] = [:]
        var order: [String] = []
        for process in processes {
            let appPath = appBundlePath(process.path)
            let ownerID = appPath.flatMap { Bundle(path: $0)?.bundleIdentifier }
            let key: String
            if let ownerID {
                key = ownerID
            } else if let bundleID = process.bundleID {
                // XPC services (WebKit's media process) are per host app:
                // keep the host's name in the key.
                key = bundleID + "|" + (name(process, nil) ?? "")
            } else {
                continue // a bare daemon: not something to give a slider
            }
            guard let display = name(process, appPath) else { continue }
            if var existing = groups[key] {
                existing.objects.append(process.object)
                existing.isPlaying = existing.isPlaying || process.isRunningOutput
                if process.isRunningOutput { existing.playingObjects.append(process.object) }
                groups[key] = existing
            } else {
                groups[key] = AppAudioGroup(id: key, name: display, appPath: appPath,
                                            objects: [process.object], isPlaying: process.isRunningOutput,
                                            playingObjects: process.isRunningOutput ? [process.object] : [])
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }
    }
}
