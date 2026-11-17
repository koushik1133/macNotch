# Fans & Temperatures (Fan Control): integration

Read-only. SparkV shows fan speeds and temperatures and never writes to the
SMC; there is no privileged helper, no presets, curves or manual modes.

| File | What |
|---|---|
| `FanCoreSMC.swift` | AppleSMC access (key info, read, key at index; no write path). |
| `FanCoreModel.swift` | Fans (`FanInfo`) and the sensor catalog and groups. |
| `FanHIDTemperatures.swift` | HID temperature sensors (Apple silicon). |
| `FanSensorSampler.swift` | Reads SMC and HID on a utility queue (`FanSnapshot`). |
| `FanSettings.swift` | Settings (Show in the Notch, Fahrenheit, all sensors) and formatting. |
| `FanController.swift` | Samples only while a view is on screen, or every 3 s (9 s in Low Power Mode) when Show in the Notch is Always; pauses during sleep. |
| `FanActivity.swift` | The optional live activity (fan speed and hottest CPU beside the notch). |
| `FanViews.swift` | Drawer page, Agents hub tile, gear-menu items, activity views. |
| `FanWindow.swift` | The Fans & Temperatures window. |
| `Tests/` | Codec, parameter block and sensor tests on a fake SMC (`run-tests.sh`). |

Wiring (already in place): `FanController.shared.start()` / `stop()` and
`connect(activities:opensTab:)` in `NotchWindowController`; `.fans` drawer
tab shows `FanTabView()`; the hub tile and gear menu use `FanHubTile` and
`FanMenuItems`.
