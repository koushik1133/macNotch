import Foundation
import Security

// sparkv-fanhelper: SparkV's privileged fan helper (com.sparkv.fanhelper).
//
// Runs as root under launchd (/Library/LaunchDaemons/com.sparkv.fanhelper.plist,
// installed once by install-fanhelper.sh). It only sets fan modes and
// targets, validated against the fan's own limits, for a client that passes
// the code-signing requirement given on the command line.
//
//   sparkv-fanhelper --client-requirement '<designated requirement of SparkV>'
//   sparkv-fanhelper --status     (read-only: print fans and temperatures, then exit)

func helperLog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) sparkv-fanhelper: \(message)\n".utf8))
}

let arguments = CommandLine.arguments

if arguments.contains("--status") {
    do {
        let smc = try FanAppleSMC()
        for fan in FanSMCReader.fans(smc) {
            print("fan \(fan.index): \(Int(fan.actual ?? 0)) rpm, target \(Int(fan.target ?? 0)), "
                + "min \(Int(fan.minimum ?? 0)), max \(Int(fan.maximum ?? 0)), mode \(fan.mode ?? -1)")
        }
        let sensors = FanSMCSensorList(smc: smc)
        print("CPU/GPU sensors: \(sensors.sensors.filter(\.isDie).count), hottest: \(sensors.hottestDie(smc).map { String(format: "%.1f °C", $0) } ?? "none")")
        exit(0)
    } catch {
        print("SMC unavailable: \(error)")
        exit(1)
    }
}

guard getuid() == 0 else {
    helperLog("must run as root (launchd starts it from \(FanHelperConstants.launchdPlist))")
    exit(1)
}

// Configuration problems exit 0 so launchd (KeepAlive: SuccessfulExit=false)
// does not restart a helper that can never work; crashes still restart it.
guard let flag = arguments.firstIndex(of: "--client-requirement"), arguments.indices.contains(flag + 1) else {
    helperLog("not starting: no --client-requirement (reinstall with install-fanhelper.sh)")
    exit(0)
}
var requirement: SecRequirement?
let requirementText = arguments[flag + 1]
guard !requirementText.isEmpty,
      SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
      let requirement else {
    helperLog("not starting: the client requirement does not parse")
    exit(0)
}

let smc: FanAppleSMC
do {
    smc = try FanAppleSMC()
} catch {
    helperLog("not starting: \(error)")
    exit(0)
}
guard FanSMCReader.fanCount(smc) > 0 else {
    helperLog("not starting: this Mac reports no fans")
    exit(0)
}

let engine = FanHelperEngine(smc: smc, held: FanHeldFile(), log: helperLog)
let server = FanHelperServer(engine: engine, requirement: requirement, log: helperLog)
do {
    try server.start()
} catch {
    helperLog("not starting: socket: \(error)")
    exit(0)
}
helperLog("started (protocol \(FanHelperConstants.protocolVersion), client: \(requirementText))")
dispatchMain()
