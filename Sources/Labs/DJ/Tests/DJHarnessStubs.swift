import CoreAudio
import Foundation

// Stand-ins for the HAL helpers DJAudioEngine.swift uses: the harness only
// drives the DSP (no taps, no devices).
enum MPAudioHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] { [] }
    static func defaultOutput() -> AudioObjectID { AudioObjectID(kAudioObjectUnknown) }
}

enum AmbientProcessTapSource {
    static func defaultOutputUID() throws -> String { "" }
    static func processObject(pid: pid_t) -> AudioObjectID? { nil }
}

enum AppGainRoute {
    static func nominalRate(of device: AudioObjectID) -> Double? { nil }
    static func useOnlyLastInputStream(of device: AudioObjectID, proc: AudioDeviceIOProcID) {}
}
