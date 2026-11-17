import AVFoundation
import CoreAudio
import Darwin
import QuartzCore
import Synchronization

// SparkV DJ: system-wide sound processing without a driver.
//
// How it works (public API only, macOS 14.4+):
//   1. a private global stereo process tap of everything the Mac plays except
//      SparkV itself, with `muteBehavior = .mutedWhenTapped`: macOS mutes the
//      original sound only while SparkV reads the tap. If SparkV stops, quits
//      or crashes, the tap dies with it and the Mac plays normally again;
//   2. a private aggregate device: the current default output (speakers,
//      AirPods, …) plus the tap, so the tap's samples and the output's
//      buffer arrive in the same IO cycle (lowest possible latency);
//   3. an IO block on that aggregate that renders the tap through an
//      AVAudioEngine in realtime manual-rendering mode (10-band
//      AVAudioUnitEQ → AVAudioUnitReverb), then applies stereo width, a
//      bypass crossfade, a fade in/out and a peak limiter, and writes the
//      result to the output.
// The IO block runs on the HAL's realtime thread: atomics and preallocated
// buffers only (no locks, allocation, logging or Swift concurrency). Audio
// is never written anywhere but the output and the in-memory analysis ring.

enum DJError: Error, LocalizedError, Equatable {
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)
    case sampleRateMismatch(tap: Double, device: Double)
    case engine(String)
    case noOutput

    var errorDescription: String? {
        switch self {
        case .coreAudio(let step, let status): "\(step) failed (\(status))"
        case .unsupportedFormat(let what): "\(what) isn’t 32-bit float audio"
        case .sampleRateMismatch(let tap, let device):
            "The Mac plays at \(Int(tap)) Hz but the output runs at \(Int(device)) Hz"
        case .engine(let what): "Audio engine: \(what)"
        case .noOutput: "No output device"
        }
    }

    var shortText: String {
        switch self {
        case .coreAudio: "Couldn’t start sound processing"
        case .unsupportedFormat: "This output isn’t supported"
        case .sampleRateMismatch: "Output rate changed; retrying"
        case .engine: "Audio engine didn’t start"
        case .noOutput: "No output device"
        }
    }
}

// MARK: - Realtime state

/// Shared between the main thread and the IO block. Layout fields and
/// buffers are set up before the IO proc starts.
final class DJRealtimeState: @unchecked Sendable {
    static let maxFrames = 4096

    // Targets written by the UI (Float bits), read per IO cycle.
    /// 1 = processed, 0 = dry (bypass / A-B compare, and the fade before stop).
    let wetTarget = Atomic<UInt32>(Float(1).bitPattern)
    let widthTarget = Atomic<UInt32>(Float(1).bitPattern)
    /// Master gain: ramps up at start, down before an orderly stop.
    let masterTarget = Atomic<UInt32>(Float(1).bitPattern)

    // Health and meters.
    let cycles = Atomic<Int>(0)
    let audibleCycles = Atomic<Int>(0)
    let renderFailures = Atomic<Int>(0)
    /// Output peak since the UI last read it (Float bits).
    let peakBits = Atomic<UInt32>(0)
    /// Input (tap) peak since the UI last read it (Float bits).
    let inputPeakBits = Atomic<UInt32>(0)

    var tapInterleaved = true
    var tapChannels = 2
    var sampleRate: Double = 48_000 {
        didSet { smoothing = Float(exp(-1 / (0.025 * sampleRate))); release = Float(exp(-1 / (0.18 * sampleRate))) }
    }
    /// The engine's render block (set before the IO proc starts).
    var render: AVAudioEngineManualRenderingBlock?
    /// Analysis input: mono of what is played.
    let ring: AmbientSampleRing

    // Preallocated buffers.
    let dryL: UnsafeMutablePointer<Float>
    let dryR: UnsafeMutablePointer<Float>
    let wetL: UnsafeMutablePointer<Float>
    let wetR: UnsafeMutablePointer<Float>
    let mono: UnsafeMutablePointer<Float>
    let renderList: UnsafeMutableAudioBufferListPointer

    // Ramp state, IO thread only.
    private var wet: Float = 1
    private var width: Float = 1
    private var master: Float = 0
    private var limiterGain: Float = 1
    private var smoothing: Float = 0.999
    private var release: Float = 0.9999

    init(ring: AmbientSampleRing) {
        self.ring = ring
        let n = Self.maxFrames
        func buffer() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        dryL = buffer(); dryR = buffer(); wetL = buffer(); wetR = buffer(); mono = buffer()
        renderList = AudioBufferList.allocate(maximumBuffers: 2)
        renderList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: wetL)
        renderList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: wetR)
        sampleRate = 48_000
    }

    deinit {
        dryL.deallocate(); dryR.deallocate(); wetL.deallocate(); wetR.deallocate(); mono.deallocate()
        free(renderList.unsafeMutablePointer)
    }

    func set(wet value: Float) { wetTarget.store(value.bitPattern, ordering: .relaxed) }
    func set(width value: Float) { widthTarget.store(value.bitPattern, ordering: .relaxed) }
    func set(master value: Float) { masterTarget.store(value.bitPattern, ordering: .relaxed) }

    /// Reads and resets the output / input peaks (main thread).
    func takePeaks() -> (output: Float, input: Float) {
        (Float(bitPattern: peakBits.exchange(0, ordering: .relaxed)),
         Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed)))
    }

    /// The source node's render body: hands the engine the current chunk.
    func provide(frames: Int, into list: UnsafeMutableAudioBufferListPointer) {
        let n = min(frames, Self.maxFrames)
        if list.count >= 2, let l = list[0].mData, let r = list[1].mData {
            l.assumingMemoryBound(to: Float.self).update(from: dryL, count: n)
            r.assumingMemoryBound(to: Float.self).update(from: dryR, count: n)
            list[0].mDataByteSize = UInt32(n * 4)
            list[1].mDataByteSize = UInt32(n * 4)
        } else if list.count == 1, let d = list[0].mData {
            let out = d.assumingMemoryBound(to: Float.self)
            for i in 0..<n { out[i] = 0.5 * (dryL[i] + dryR[i]) }
            list[0].mDataByteSize = UInt32(n * 4)
        }
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

        let wetGoal = Float(bitPattern: wetTarget.load(ordering: .relaxed))
        let widthGoal = Float(bitPattern: widthTarget.load(ordering: .relaxed))
        let masterGoal = Float(bitPattern: masterTarget.load(ordering: .relaxed))
        let a = smoothing, b = 1 - smoothing
        let threshold: Float = 0.94
        var outPeak: Float = 0
        var inPeak: Float = 0

        var done = 0
        while done < frames {
            let n = min(Self.maxFrames, frames - done)
            for i in 0..<n {
                let l = left[(done + i) * inStride]
                let r = right[(done + i) * inStride]
                dryL[i] = l
                dryR[i] = r
                let m = max(abs(l), abs(r))
                if m > inPeak { inPeak = m }
            }

            var rendered = false
            if let render {
                renderList[0].mData = UnsafeMutableRawPointer(wetL)
                renderList[1].mData = UnsafeMutableRawPointer(wetR)
                renderList[0].mDataByteSize = UInt32(n * 4)
                renderList[1].mDataByteSize = UInt32(n * 4)
                var error: OSStatus = noErr
                let status = render(AVAudioFrameCount(n), renderList.unsafeMutablePointer, &error)
                rendered = status == .success && error == noErr
            }
            if !rendered {
                renderFailures.add(1, ordering: .relaxed)
                wetL.update(from: dryL, count: n)
                wetR.update(from: dryR, count: n)
            }

            for i in 0..<n {
                wet = a * wet + b * wetGoal
                width = a * width + b * widthGoal
                master = a * master + b * masterGoal
                // Mid/side width on the processed signal; the side boost
                // is compensated so wider isn't simply louder.
                var pl = wetL[i], pr = wetR[i]
                let mid = 0.5 * (pl + pr)
                let side = 0.5 * (pl - pr) * width
                let comp: Float = width > 1 ? 1 / (1 + 0.25 * (width - 1)) : 1
                pl = (mid + side) * comp
                pr = (mid - side) * comp
                var l = (dryL[i] + (pl - dryL[i]) * wet) * master
                var r = (dryR[i] + (pr - dryR[i]) * wet) * master
                // Peak limiter: instant attack, ~180 ms release, no lookahead
                // (so dry and processed stay sample-aligned for the A/B fade).
                let peak = max(abs(l), abs(r))
                let needed: Float = peak > threshold ? threshold / peak : 1
                limiterGain = needed < limiterGain ? needed : (release * limiterGain + (1 - release) * needed)
                l *= limiterGain
                r *= limiterGain
                l = max(-1, min(1, l))
                r = max(-1, min(1, r))
                let o = max(abs(l), abs(r))
                if o > outPeak { outPeak = o }
                let at = (done + i) * outStride
                if let outRight {
                    outLeft[at] = l
                    outRight[at] = r
                } else {
                    outLeft[at] = 0.5 * (l + r)
                }
                mono[i] = 0.5 * (l + r)
            }
            ring.write(UnsafePointer(mono), frames: n, channels: 1)
            done += n
        }

        if outPeak > Float(bitPattern: peakBits.load(ordering: .relaxed)) {
            peakBits.store(outPeak.bitPattern, ordering: .relaxed)
        }
        if inPeak > Float(bitPattern: inputPeakBits.load(ordering: .relaxed)) {
            inputPeakBits.store(inPeak.bitPattern, ordering: .relaxed)
        }
        if inPeak > 1e-6 { audibleCycles.add(1, ordering: .relaxed) }
    }
}

// MARK: - Effects chain

/// AVAudioEngine in realtime manual-rendering mode: no hardware of its own,
/// the DJ route's IO block pulls it. Parameters can be changed from any
/// thread (they are AU parameters); `apply` ramps them on the main thread.
final class DJEffectsChain: @unchecked Sendable {
    let engine = AVAudioEngine()
    let eq = AVAudioUnitEQ(numberOfBands: DJBands.count)
    let reverb = AVAudioUnitReverb()
    private var source: AVAudioSourceNode?
    private(set) var room: DJRoom = .none

    init(sampleRate: Double, state: DJRealtimeState) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw DJError.engine("no stereo format at \(Int(sampleRate)) Hz")
        }
        // Manual rendering first: the engine then never opens a device of
        // its own (no input node, no microphone).
        do {
            try engine.enableManualRenderingMode(.realtime, format: format,
                                                 maximumFrameCount: AVAudioFrameCount(DJRealtimeState.maxFrames))
        } catch {
            throw DJError.engine("manual rendering unavailable")
        }
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, list in
            state.provide(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(list))
            return noErr
        }
        self.source = source
        engine.attach(source)
        engine.attach(eq)
        engine.attach(reverb)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)

        for (index, band) in eq.bands.enumerated() {
            band.frequency = DJBands.frequencies[index]
            band.gain = 0
            band.bypass = false
            switch index {
            case 0:
                band.filterType = .lowShelf
            case DJBands.count - 1:
                band.filterType = .highShelf
            default:
                band.filterType = .parametric
                band.bandwidth = 1.0
            }
        }
        eq.globalGain = 0
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 0

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw DJError.engine("didn’t start")
        }
        state.render = engine.manualRenderingBlock
    }

    func stop() {
        engine.stop()
    }

    /// Sets the parameters at once (the caller ramps by calling repeatedly).
    func set(gains: [Float], globalGain: Float, reverbMix: Float) {
        for (index, band) in eq.bands.enumerated() where index < gains.count {
            band.gain = gains[index]
        }
        eq.globalGain = globalGain
        reverb.wetDryMix = reverbMix
    }

    /// Switches the simulated room (call while the reverb's wet mix is 0).
    func set(room newRoom: DJRoom) {
        guard newRoom != room else { return }
        room = newRoom
        switch newRoom {
        case .none: break
        case .smallRoom: reverb.loadFactoryPreset(.smallRoom)
        case .mediumHall: reverb.loadFactoryPreset(.mediumHall)
        case .largeHall: reverb.loadFactoryPreset(.largeHall)
        case .cathedral: reverb.loadFactoryPreset(.cathedral)
        }
    }
}

// MARK: - The route

/// Tap + aggregate + IO proc + effects. Create, start and stop it on
/// `DJAudio.queue` only.
final class DJRoute: @unchecked Sendable {
    let state: DJRealtimeState
    private(set) var chain: DJEffectsChain?
    private(set) var outputUID = ""
    private(set) var outputID = AudioObjectID(kAudioObjectUnknown)
    private(set) var sampleRate: Double = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var tapDescription: CATapDescription?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var isRunning = false

    init(ring: AmbientSampleRing) {
        state = DJRealtimeState(ring: ring)
    }

    deinit {
        stop()
    }

    /// Builds and starts everything. `excluding`: process objects that must
    /// not be tapped (apps App Volumes already plays itself).
    func start(excluding: [AudioObjectID]) throws {
        stop()
        do {
            outputUID = try AmbientProcessTapSource.defaultOutputUID()
        } catch {
            throw DJError.noOutput
        }
        outputID = MPAudioHAL.defaultOutput()

        var excluded = excluding
        if let own = AmbientProcessTapSource.processObject(pid: getpid()) { excluded.append(own) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "SparkV DJ"
        description.isPrivate = true
        // Muted only while SparkV reads the tap: if this route stops for any
        // reason (quit, crash, error), the Mac is heard untouched again.
        description.muteBehavior = .mutedWhenTapped
        tapDescription = description

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw DJError.coreAudio("Creating the tap", status) }
        tapID = tap

        do {
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = MPAudioHAL.address(kAudioTapPropertyFormat)
            status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
            guard status == noErr else { throw DJError.coreAudio("Reading the tap format", status) }
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else { throw DJError.unsupportedFormat("The Mac’s audio") }
            state.tapInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            state.tapChannels = max(1, Int(format.mChannelsPerFrame))

            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SparkV DJ",
                kAudioAggregateDeviceUIDKey: "com.sparkv.dj." + UUID().uuidString,
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
            guard status == noErr else { throw DJError.coreAudio("Creating the aggregate device", status) }
            aggregateID = device

            try Self.checkOutputFormat(of: device)
            let deviceRate = AppGainRoute.nominalRate(of: device) ?? format.mSampleRate
            // A tap that isn't at the device's rate would play at the wrong
            // pitch; better to leave the Mac alone than to garble it.
            if format.mSampleRate > 0, abs(deviceRate - format.mSampleRate) > 1 {
                throw DJError.sampleRateMismatch(tap: format.mSampleRate, device: deviceRate)
            }
            sampleRate = format.mSampleRate > 0 ? format.mSampleRate : deviceRate
            state.sampleRate = sampleRate
            chain = try DJEffectsChain(sampleRate: sampleRate, state: state)

            let state = self.state
            var proc: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, output, _ in
                state.process(input: input, output: output)
            }
            guard status == noErr, let proc else { throw DJError.coreAudio("Adding the audio callback", status) }
            procID = proc
            AppGainRoute.useOnlyLastInputStream(of: device, proc: proc)
            status = AudioDeviceStart(device, proc)
            guard status == noErr else { throw DJError.coreAudio("Starting playback", status) }
            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    /// Changes which processes the tap leaves alone, without a rebuild.
    /// Returns false when Core Audio refused (the caller rebuilds).
    func updateExclusions(_ excluding: [AudioObjectID]) -> Bool {
        guard isRunning, tapID != kAudioObjectUnknown, let description = tapDescription else { return false }
        var excluded = excluding
        if let own = AmbientProcessTapSource.processObject(pid: getpid()) { excluded.append(own) }
        description.processes = excluded
        var address = MPAudioHAL.address(kAudioTapPropertyDescription)
        var object: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &object) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        return status == noErr
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
        tapDescription = nil
        state.render = nil
        chain?.stop()
        chain = nil
        isRunning = false
    }

    private static func checkOutputFormat(of device: AudioObjectID) throws {
        let streams = MPAudioHAL.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        guard let stream = streams.first else { throw DJError.noOutput }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = MPAudioHAL.address(kAudioStreamPropertyVirtualFormat)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr else { return }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { throw DJError.unsupportedFormat("The output device") }
    }
}

enum DJAudio {
    /// Serial: every DJ HAL call (create, start, stop, destroy) runs here in
    /// order, never on the main thread.
    static let queue = DispatchQueue(label: "SparkV.DJ.hal", qos: .userInitiated)
}

// MARK: - Analysis

/// What the DJ page draws: Ambient Light's features plus spectrum bars.
struct DJStats: Sendable {
    static let barCount = 28
    var features = AmbientAudioFeatures.idle
    /// 0…1 per bar, auto-gained.
    var bars = [Float](repeating: 0, count: DJStats.barCount)

    static let idle = DJStats()
}

final class DJStatsMailbox: @unchecked Sendable {
    private var value = DJStats.idle
    private var lock = os_unfair_lock()

    func store(_ stats: DJStats) {
        os_unfair_lock_lock(&lock)
        value = stats
        os_unfair_lock_unlock(&lock)
    }

    func load() -> DJStats {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return value
    }
}

/// Drains the ring hop by hop through Ambient Light's analyzer (beats,
/// tempo, bands) and computes the bars. Its own queue; in-memory only.
final class DJAnalysisPump: @unchecked Sendable {
    let mailbox = DJStatsMailbox()
    private let ring: AmbientSampleRing
    private let analyzer: AmbientSpectralAnalyzer
    private let queue = DispatchQueue(label: "SparkV.DJ.analysis", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let hop: UnsafeMutablePointer<Float>
    private let hopSize: Int
    private let sampleRate: Double
    private var raw = [Float](repeating: 0, count: DJStats.barCount)
    private var smooth = [Float](repeating: 0, count: DJStats.barCount)
    private var scale: Float = 4

    init(ring: AmbientSampleRing, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate
        let hopSize = sampleRate > 90_000 ? 1024 : 512
        let fftSize = sampleRate > 90_000 ? 4096 : 2048
        self.hopSize = hopSize
        analyzer = AmbientSpectralAnalyzer(sampleRate: sampleRate, fftSize: fftSize, hopSize: hopSize)
        hop = .allocate(capacity: hopSize)
        hop.initialize(repeating: 0, count: hopSize)
    }

    deinit {
        timer?.cancel()
        hop.deallocate()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = Double(hopSize) / sampleRate
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        mailbox.store(.idle)
    }

    private func drain() {
        ring.skip(keeping: hopSize * 6)
        var latest: AmbientAudioFeatures?
        while ring.available >= hopSize, ring.read(into: hop, count: hopSize) {
            let delay = Double(ring.available) / sampleRate
            latest = analyzer.process(hop: UnsafeBufferPointer(start: hop, count: hopSize), at: CACurrentMediaTime() - delay)
        }
        guard let latest else { return }
        analyzer.barLevels(into: &raw)
        // Auto-gain on the loudest bar (slow fall), tilt up the highs a
        // little (music has less energy there), fast attack, slower fall.
        var loudest: Float = 0
        for (index, value) in raw.enumerated() {
            let tilt = 1 + 0.35 * Float(index) / Float(raw.count)
            raw[index] = value * tilt
            loudest = max(loudest, raw[index])
        }
        scale = max(2.5, max(loudest, scale * 0.997))
        for index in raw.indices {
            let target = latest.isSilent ? 0 : min(1, max(0, (raw[index] / scale - 0.18) / 0.82))
            smooth[index] = target > smooth[index] ? target : smooth[index] * 0.86 + target * 0.14
        }
        mailbox.store(DJStats(features: latest, bars: smooth))
    }
}
