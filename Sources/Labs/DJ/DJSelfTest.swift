import AppKit
import Foundation

/// `open SparkV.app --args --dj-selftest`: runs SparkV DJ for ~20 s on what
/// the Mac is playing and logs counts and levels only (IO cycles, render
/// failures, peak levels, beats, tempo), never audio. Listen-only stats,
/// then Sound FX on through Flat, Bass Boost, Concert and Vocal, A/B, then
/// off; the preset and on/off state are put back. A launch argument, so no
/// link or web page can start it.
@MainActor
enum DJSelfTest {
    static func run() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            let dj = DJController.shared
            let settings = DJSettings.shared
            let savedPreset = settings.preset
            let savedIntensity = settings.intensity
            func log(_ text: String) { AppLog.log("DJ self-test: " + text) }

            log("permission \(AmbientAudioPermission.preflight().rawValue)"
                + (dj.otherCopyHoldingIdentity.map { "; another copy is registered: \($0.path)" } ?? ""))

            // 1. Listen-only stats (the page open, Sound FX off).
            dj.pageAppeared()
            var beats0: UInt64 = 0
            var maxBar: Float = 0
            for step in 0..<16 {
                try? await Task.sleep(for: .milliseconds(250))
                let stats = dj.pump?.mailbox.load() ?? .idle
                if step == 0 { beats0 = stats.features.beatCount }
                maxBar = max(maxBar, stats.bars.max() ?? 0)
            }
            let listen = dj.pump?.mailbox.load() ?? .idle
            log("listen-only: analysis \(dj.pump == nil ? "NOT running" : "running"), "
                + "beats \(listen.features.beatCount &- beats0), bpm \(Int(listen.features.bpm)), "
                + "max bar \(String(format: "%.2f", maxBar)), silent \(listen.features.isSilent)")

            // 2. Sound FX on.
            settings.intensity = 1
            dj.setEnabled(true)
            for _ in 0..<40 where dj.status != .running {
                try? await Task.sleep(for: .milliseconds(200))
                if case .failed = dj.status { break }
                if dj.status == .needsPermission { break }
            }
            log("on: status \(describe(dj.status)), output \(dj.outputName), \(Int(dj.sampleRate)) Hz")
            guard dj.status == .running else {
                dj.setEnabled(false)
                dj.pageDisappeared()
                settings.preset = savedPreset
                settings.intensity = savedIntensity
                log("FAILED: Sound FX didn't start")
                return
            }
            var firstCycle = 0
            while firstCycle < 40, (dj.selfTestSnapshot()?.cycles ?? 0) == 0, dj.status == .running {
                try? await Task.sleep(for: .milliseconds(250))
                firstCycle += 1
            }
            log("first IO cycle after \(Double(firstCycle) / 4) s")
            _ = dj.selfTestSnapshot()
            for preset in [DJPreset.flat, .bass, .concert, .vocal] {
                dj.choose(preset)
                var beats: UInt64 = dj.pump?.mailbox.load().features.beatCount ?? 0
                let start = dj.selfTestSnapshot()?.cycles ?? 0
                var inPeak: Float = 0, outPeak: Float = 0, bass: Float = 0, samples: Float = 0
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if let snap = dj.selfTestSnapshot() { inPeak = max(inPeak, snap.input); outPeak = max(outPeak, snap.output) }
                    let stats = dj.pump?.mailbox.load() ?? .idle
                    bass += stats.features.bass; samples += 1
                }
                let snap = dj.selfTestSnapshot()
                beats = (dj.pump?.mailbox.load().features.beatCount ?? 0) &- beats
                log("\(preset.title): cycles +\((snap?.cycles ?? 0) - start), render failures \(snap?.failures ?? -1), "
                    + "peak in \(String(format: "%.2f", inPeak)) out \(String(format: "%.2f", outPeak)), "
                    + "avg bass \(String(format: "%.2f", bass / max(1, samples))), beats \(beats), bpm \(Int(dj.pump?.mailbox.load().features.bpm ?? 0))")
            }
            dj.isBypassed = true
            try? await Task.sleep(for: .milliseconds(1_200))
            let bypass = dj.selfTestSnapshot()
            log("A/B bypass: peak in \(String(format: "%.2f", bypass?.input ?? 0)) out \(String(format: "%.2f", bypass?.output ?? 0))")
            dj.isBypassed = false

            // 3. Off: the tap is removed and the Mac plays untouched again.
            dj.setEnabled(false)
            try? await Task.sleep(for: .milliseconds(800))
            log("off: status \(describe(dj.status)), route \(dj.selfTestSnapshot() == nil ? "removed" : "STILL RUNNING")")
            dj.pageDisappeared()
            settings.preset = savedPreset
            settings.intensity = savedIntensity
            log("done")
        }
    }

    private static func describe(_ status: DJController.Status) -> String {
        switch status {
        case .off: "off"
        case .starting: "starting"
        case .running: "running"
        case .needsPermission: "needs permission"
        case .failed(let text): "failed (\(text))"
        }
    }
}
