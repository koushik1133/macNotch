# Fan Control: wiring steps for the lead

Fan Control recreates Macs Fan Control inside SparkV. It shows live fan speeds and temperatures, and each fan can run on Auto, at a constant RPM, or on a sensor-based curve. It has presets, a live activity, a drawer page, an Agents hub tile, gear-menu items and a full window.

Setting speeds goes through a tiny root helper (`sparkv-fanhelper`), installed once with one admin approval. This is the same design Macs Fan Control uses: its `com.crystalidea.macsfancontrol.smcwrite` daemon is on this Mac too.

All code lives in two folders:
- `Sources/Labs/FanControl/`: the app side.
- `Helpers/FanHelper/`: the helper.

No other file was edited.

Steps 1 to 5 below were applied to a snapshot of the current app (build.sh, NotchState, NotchNookLayoutView, AgentsHubView, NotchWindowController) and typechecked clean in Swift 5 and Swift 6. Step 1b was run on a throwaway bundle: compile, ad-hoc sign, nest, then `codesign --verify --strict` on the app passed.

## Files

| File | What it is |
| --- | --- |
| `FanCoreSMC.swift` | **Shared with the helper.** Four-character codes, the `flt`/`fpe2`/`spXY`/`fpXY`/`ui8`-`ui32`/`si*`/`flag`/`ioft` codec, the 80-byte AppleSMC parameter block (built byte by byte, checked against the C layout in tests), and `FanAppleSMC` (the IOKit user client on selector 2 with lock and key-info cache). Includes `FanSMCBackend`, the protocol the tests fake. |
| `FanCoreModel.swift` | **Shared.** `FanInfo` and `FanSMCReader`: FNum, F<i>Ac/Tg/Mn/Mx, F<i>Md (or F<i>md on M5, or the FS! bitmask on old Intel). Sensor catalog: names and groups are type-aware, because Apple silicon `flt` keys differ from Intel `sp78` keys. `FanSMCSensorList` discovers the temperature keys once. |
| `FanCoreProtocol.swift` | **Shared.** Constants (socket, plist, state file, limits), the JSON-line protocol, strict syntax validation (`FanRequestCodec`), range validation against the helper's own SMC readings (`FanRequestValidator`), and the failsafe policy (`FanFailsafe`). |
| `FanCurve.swift` | `FanControlMode` (auto / constant / sensor), the curve math, `FanCurveFollower` (2 °C hysteresis, 50 rpm dead band), presets, settings and their store. |
| `FanHIDTemperatures.swift` | Apple silicon IOHIDEventSystem temperature sensors, using the same idea as Stats. The symbols are resolved with `dlsym` and the reader degrades to nothing if they are missing. |
| `FanSensorSampler.swift` | Reads fans and sensors on a utility queue. Its scopes are minimal, standard and all. |
| `FanHelperClient.swift` | The app's socket client. It trusts only a root-owned socket, keeps one persistent connection (its closing is what the helper watches), and uses 2 s timeouts with one reconnect. |
| `FanController.swift` | `FanController.shared` (@MainActor). It holds modes, presets and helper state; handles sleep/wake, quit and App Nap; detects other fan apps; and drives the live activity. |
| `FanHelperInstaller.swift` | "Install / Update / Uninstall Helper…": the bundled script runs through macOS's own administrator dialog (`osascript … with administrator privileges`, with paths passed as arguments). |
| `FanViews.swift` | `FanTabView` (508x114 drawer page), `FanHubTile`, `FanMenuItems` (gear menu), the live-activity views and shared pieces. |
| `FanWindow.swift` | `FanControlWindowController.shared.show()`: the Macs Fan Control-style window. |
| `FanActivity.swift` | The only file that touches `ActivityCenter` / `LiveActivity` / `NotchState`: `FanController.connect(activities:opensTab:)`. |
| `Tests/` | `run-tests.sh`, `main.swift`, `FakeSMC.swift`, `smc-layout.h`. Not compiled into the app, because build.sh copies only `FanControl/*.swift`. |
| `../../../Helpers/FanHelper/` | `main.swift`, `FanHelperEngine.swift`, `FanHelperServer.swift`, `com.sparkv.fanhelper.plist`, `install-fanhelper.sh`, `uninstall-fanhelper.sh`. |

## 1. build.sh

### 1a. Compile the app side

Add this next to the other `Labs` copies:

```zsh
cp Sources/Labs/FanControl/*.swift "$WORK/src/"
```

No new frameworks or flags are needed. IOKit, Security and AppKit are autolinked, and no entitlement is needed: AppleSMC reads and the HID sensor service work in an unsandboxed Hardened Runtime app.

### 1b. Build, bundle and sign the helper

Put the first part after the `rsync … BrowserRecorder` lines (before `xattr -cr "$STAGED"`). It is a separate executable with top-level code, so it is compiled **without** `-parse-as-library`, from a copy in `$WORK` (the same iCloud reason as the app sources):

```zsh
# Fan Control's privileged helper (Helpers/FanHelper). A separate root
# executable, installed by the user once (Fans > Install Helper, or
# Contents/Resources/FanHelper/install-fanhelper.sh). It shares the FanCore*
# files with the app.
mkdir -p "$WORK/fanhelper-src" "$STAGED/Contents/Library/LaunchServices" "$STAGED/Contents/Resources/FanHelper"
cp Helpers/FanHelper/*.swift Sources/Labs/FanControl/FanCore*.swift "$WORK/fanhelper-src/"
xcrun swiftc \
  -swift-version 5 \
  "${OPT_FLAGS[@]}" \
  -target arm64-apple-macos15.0 \
  -sdk "$SDK" \
  "$WORK/fanhelper-src"/*.swift \
  -o "$STAGED/Contents/Library/LaunchServices/com.sparkv.fanhelper"
cp Helpers/FanHelper/com.sparkv.fanhelper.plist Helpers/FanHelper/install-fanhelper.sh Helpers/FanHelper/uninstall-fanhelper.sh \
  "$STAGED/Contents/Resources/FanHelper/"
chmod 755 "$STAGED/Contents/Resources/FanHelper/"*.sh
```

Then sign it as nested code. It must come **after** the block that decides `SIGN_IDENTITY` (and after the `$FW` signing / ad-hoc fallback), and **before** the line that signs `"$STAGED"`:

```zsh
# The fan helper: same identity, Hardened Runtime, its own identifier. The
# install script checks that its certificate matches SparkV's.
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_EXTRA[@]}" --options runtime \
  --identifier com.sparkv.fanhelper "$STAGED/Contents/Library/LaunchServices/com.sparkv.fanhelper"
```

The existing `codesign --verify --strict "$STAGED"` then checks the nested helper too. The install scripts are app resources, so the app's seal covers them, and the install script refuses an app whose signature does not verify.

## 2. NotchState.swift

```swift
// NotchState.Tab, after `case widgets`
/// Fan Control: fan speeds, temperatures, presets (Agents hub tile).
case fans

// Tab.agentTabs: append .fans
.focus, .search, .replyDrafter, .fileDrop, .downloads, .fans,

// NotchMetrics.tallTabs: append .fans (the page is designed for 508x114)
static let tallTabs: Set<NotchState.Tab> = [.tray, .converter, .clipboard, .search, .downloads, .widgets, .replyDrafter, .fans]
```

## 3. NotchNookLayoutView.swift

Add the drawer page and the gear menu:

```swift
// tab switch, after `case .widgets: WidgetsTabView()`
case .fans: FanTabView()

// SettingsMenu, directly before `Menu("Agents") {`
Menu("Fans") { FanMenuItems() }
```

`FanMenuItems` shows:
- A line with the current speeds and CPU temperature.
- Whether any fan is manual.
- Every preset, with a checkmark on the active one.
- "All Fans to Auto" and "Open Fan Control…".
- "Install Fan Helper…" while the helper is missing.

## 4. AgentsHubView.swift: the "Fans" tile

The hub has 22 cells in 24 slots, so one more fits without a new row.

```swift
// enum Cell: add a case
case fans
// Cell.id
case .fans: "fans"
// cells: directly before the last entry `.clipboard,`
.fans,
// the ForEach switch, before `case .clipboard:`
case .fans:
    FanHubTile(onOpen: { withAnimation(.easeOut(duration: 0.15)) { state.select(.fans) } })
```

`FanHubTile` has the same 48 pt footprint as `AgentTile`. It lights red with the fastest fan's RPM while any fan is manual, and right-click shows the gear-menu items.

## 5. NotchWindowController.swift

```swift
// init/start: directly after `downloads.start()`
FanController.shared.start()
FanController.shared.connect(activities: activities, opensTab: .fans)

// tearDown(): directly after `focus.stop()`
// Every fan back to Auto before SparkV quits.
FanController.shared.stop()
```

`start()` does one cheap read to learn the fans, then asks the helper for its status if it is installed. After that **nothing runs** unless one of these is true:
- a Fan view is on screen (1.5 s passes);
- a fan is under manual control (2 s passes);
- the user picked "Show in the Notch: Always" (3 s passes).

`stop()` sends `allAuto` synchronously (2 s timeout) and closes the socket. If SparkV crashes, the socket closes anyway and the helper sets Auto itself.

Sleep and wake are handled inside the controller through `NSWorkspace` notifications, so nothing extra is needed.

## 6. Info.plist and entitlements

Nothing to add.

## Live activity

It is posted with `id: "fans"` and `kind: .battery` (with its own symbol and tint), priority 15 (55 while the failsafe has tripped), `presentation: .compact` and `duration: nil`.

- **Wings:** a red fan glyph, plus "3.5k 71°C" (fastest fan and hottest CPU).
- **Band:** "2 fans manual 2790 3550 rpm · CPU 71°C".

It peeks below the notch when the number of manual fans changes, or when the failsafe trips. By default it shows only while a fan is manual or the failsafe is active; the window's gear lets the user choose Always or Never. Hovering opens `.fans`.

## How the helper works (for review)

- **Transport.** A root-owned Unix socket at `/var/run/com.sparkv.fanhelper.sock`, carrying JSON lines of at most 512 bytes.
  - Before a connection may send anything, the peer's audit token (`LOCAL_PEERTOKEN`) goes through `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`, and must match the designated requirement of the SparkV that installed it: `identifier "com.sparkv.app" and certificate leaf = H"29e8…"`. That requirement is written into the LaunchDaemon plist by the install script.
  - Anyone else gets "not authorized" and is disconnected.
  - The app connects only to a socket owned by root.
- **Commands.** Only `hello`, `status`, `heartbeat`, `set {fan, rpm}`, `auto {fan}` and `allAuto` are accepted.
  - An unknown op, an extra or missing field, a bool where an int belongs, a fractional fan, a non-finite or out-of-range number, or an over-long line is refused.
  - RPM must be inside the fan's own `[F<i>Mn, F<i>Mx]` as the **helper** reads them. Nothing is clamped silently, and a fan reporting no limits (min 0) is refused.
- **Failsafe, inside the helper.** Every fan the helper holds goes back to Auto when any of these happens:
  - any CPU/GPU die sensor exceeds 95 °C (two consecutive 1 s samples, or one at 103 °C or more);
  - no CPU/GPU sensor is readable;
  - no request arrives for 10 s (SparkV heartbeats every 2 s while manual, and an App Nap activity keeps that timely);
  - the controlling client disconnects (quit or crash);
  - the system is about to sleep (`IORegisterForSystemPower`);
  - SIGTERM arrives (launchctl bootout or uninstall);
  - the helper restarts (it reads its root-only record `/var/run/com.sparkv.fanhelper.state`).

  After a thermal trip, manual control stays refused until every die sensor has stayed below 85 °C for 30 s (the cooldown restarts on any reading at or above 85 °C). While a fan is held, the helper re-reads F<i>Mn/F<i>Mx every second and never holds a speed outside them. install-fanhelper.sh copies the helper into a root-only staging folder before verifying its signature and installs that verified copy.
- **It never fights other tools.** It only ever switches back fans it switched itself. It never writes over the system's mode 3. It refuses a fan another app holds (mode 1 that is not its own), and it clears `Ftst` only if it set it.
- **Firmware paths.**
  - **Direct `F<i>Md=1`:** Intel with F<i>Md, M1 (this Mac: no `Ftst` key) and M5 (`F<i>md`).
  - **`Ftst=1` unlock:** used on M4-style firmware that refuses the mode write while in mode 3. It retries every 100 ms for up to 10 s, then gives up and goes back to Auto.
  - **`FS!` bitmask:** older Intel Macs.
  - While a fan is manual the helper re-asserts mode and target every second, in case thermalmonitord reclaims it.
- **Idle cost.** No timer runs at all while every fan is on Auto: the helper only waits on its socket.

## Why not SMAppService?

`SMAppService.daemon(plistName:)` needs launchd/BTM to accept a daemon bundled in an app signed with a Team ID. agoodkind/macos-smc-fan documents that it needs a paid Developer ID; SparkV is signed with the self-signed "NotchIsland Developer" identity, which has no Team ID. So the helper is installed by a script the user approves once. That gives the same result as Macs Fan Control's SMJobBless helper, which also lands in `/Library/PrivilegedHelperTools` with a `/Library/LaunchDaemons` plist. With a Developer ID later, the same binary can move to `Contents/Library/LaunchDaemons` with an `SMAppService` plist (`BundleProgram: Contents/Library/LaunchServices/com.sparkv.fanhelper`) without protocol changes.

## Other fan apps

`FanController` treats a fan in manual mode that SparkV's helper does not hold as held by another app. It names the app when it finds one running: Macs Fan Control, TG Pro, Stats, smcFanControl or iStat Menus, by bundle ID, checked at most every 10 s. SparkV then:
- shows "OTHER APP" on that fan;
- explains it in the footer;
- skips that fan in presets;
- refuses manual control of it.

**This Mac runs Macs Fan Control 1.5.21 right now, and it held both fans in manual mode during this work.** The user has to set it to Auto there, or quit it, before SparkV can control those fans.

## Tests

```zsh
Sources/Labs/FanControl/Tests/run-tests.sh            # fake SMC only
Sources/Labs/FanControl/Tests/run-tests.sh --live     # plus a READ-ONLY pass over this Mac's fans
```

There are 234 checks, plus 3 in the live pass. They cover:
- The codec, checked against real bytes read from this Mac, and the C layout of the parameter block (clang `offsetof`).
- Protocol fuzz cases and range validation.
- Curve and hysteresis math, presets, and settings round trips.
- The failsafe state machine.
- The helper engine on Apple silicon, M4 (Ftst) and Intel (FS!/fpe2/sp78) fakes, including restart recovery and other-app fans.
- A real socket server and client end to end. The signature check accepts `always` and refuses `never`, and a forged command is refused.
- The controller driving the real engine through a fake transport: modes, presets, heartbeat, missing sensor, failsafe, sleep/quit, helper lost or not installed, restore-on-launch, no-fan Macs, another app's fans.

Thread Sanitizer reported no races.

## References

| Source | Licence | What was taken |
| --- | --- | --- |
| https://github.com/morluto/rea | MIT | Checked as asked. It is "Reverse Engineer Anything", an MCP server and CLI for reverse engineering apps and binaries. It has nothing about SMC or fans, so **no code or data from it is used**. It would be the tool for inspecting a closed app's behaviour, but it was not needed: Macs Fan Control's architecture (root `smcwrite` LaunchDaemon) is visible from its installed files. |
| exelban/stats | MIT | Ideas only: the SMC parameter-block layout, IOHIDEventSystem temperature sensors (usage page 0xff00, usage 5), public key meanings. |
| agoodkind/macos-smc-fan | MIT | Research notes: mode values (0/1/3), the `Ftst` unlock sequence and timing on M4, `F<i>md` on M5, the error codes, and that SMAppService needs a Developer ID. |
| smcFanControl | GPL | Not used. No code copied. |

All code here is original.
