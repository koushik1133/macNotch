import AVFoundation
import Foundation

/// `open SparkV.app --args --meeting-selftest`: records 20 s through the
/// meeting pipeline (your microphone and the other side's system audio) and
/// translates the other side's phrases, then logs counts only, never words.
/// Nothing is saved as a meeting. A launch argument, so no link or web page
/// can start it.
@MainActor
enum MeetingSelfTest {
    static func run() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            AppLog.log("Meeting self-test: starting (20 s)")
            let recorder = MeetingRecorder()
            var finals: [MeetingSpeaker: [String]] = [:]
            recorder.onSegment = { segment in
                guard segment.isFinal, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                finals[segment.speaker, default: []].append(segment.text)
            }
            do {
                try await recorder.start()
            } catch {
                AppLog.log("Meeting self-test: failed to start: \(error.localizedDescription)")
                return
            }
            var peakMic: Float = 0, peakSystem: Float = 0
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(250))
                peakMic = max(peakMic, recorder.micLevel)
                peakSystem = max(peakSystem, recorder.systemLevel)
            }
            let capturing = recorder.isCapturingSystemAudio
            let problem = recorder.systemAudioProblem != nil
            await recorder.stop()
            let mine = finals[.me]?.count ?? 0
            let others = finals[.others]?.count ?? 0
            AppLog.log("Meeting self-test: system audio \(capturing ? "captured" : "NOT captured")\(problem ? " (problem shown)" : ""), "
                       + "levels mic \(String(format: "%.2f", peakMic)) others \(String(format: "%.2f", peakSystem)), "
                       + "phrases me \(mine) others \(others)")

            // Translation of the other side's phrases (English → Spanish).
            let engine = LiveTranslationAppleEngine()
            let source = Locale.Language(identifier: "en")
            let target = Locale.Language(identifier: "es")
            let status = await engine.status(source: source, target: target)
            var translated = 0
            var failed = 0
            for text in (finals[.others] ?? []).prefix(10) {
                do {
                    let out = try await engine.translate(text, source: source, target: target)
                    if !out.isEmpty { translated += 1 }
                } catch {
                    failed += 1
                }
            }
            AppLog.log("Meeting self-test: translation en>es \(status), \(translated) translated, \(failed) failed")
        }
    }
}
