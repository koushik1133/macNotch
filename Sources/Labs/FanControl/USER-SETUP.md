# Fan Control: one-time setup

SparkV can **read** your fans and temperatures with no setup at all.

To **set** fan speeds, macOS requires administrator rights, so SparkV uses a tiny helper program, the same approach Macs Fan Control takes. You install it once and approve it with your password once. After that it just works, including after restarts, with no further prompts.

## Install (once)

**In SparkV:** open Agents › Fans, or the gear menu › Fans, and click **Install Helper…**. macOS asks for your password once, and the helper is installed and running.

**Or in Terminal**, if you prefer:

```sh
sudo "/path/to/SparkV.app/Contents/Resources/FanHelper/install-fanhelper.sh"
```

The window's gear menu › **Copy Install Command** puts the exact command, with your app's path, on the clipboard.

What the installer does, and nothing else:

1. Checks that SparkV and the helper are validly signed by the same certificate.
2. Copies the helper to `/Library/PrivilegedHelperTools/com.sparkv.fanhelper`.
3. Writes `/Library/LaunchDaemons/com.sparkv.fanhelper.plist`. The plist records SparkV's code signature, so the helper only takes orders from your SparkV and refuses every other program.
4. Starts it.

macOS may then show a **"Background Items Added"** notification. The helper appears as **SparkV** under System Settings › General › Login Items › Allow in the Background. Leave it on: if you turn it off, SparkV goes back to reading only.

## Using it

Each fan can be set to one of three modes:

- **Auto:** macOS controls the fan. This is the default, and SparkV always starts on Auto unless you turn on "Restore My Fan Settings When SparkV Starts" in the window's gear menu.
- **Constant RPM:** a fixed speed. It can never be set below the fan's own minimum or above its maximum.
- **Sensor-based:** pick a sensor (for example CPU Hottest), a start temperature and a maximum temperature. The fan sits at its minimum up to the start temperature, rises in a straight line, and reaches full speed at the maximum temperature.

Presets: **Auto**, **Quiet** (CPU 70→95 °C), **Performance** (CPU 50→80 °C), **Full Blast**, plus your own (**Save as Preset…**).

A fan under SparkV's control is always visibly marked:
- a red fan icon and a red row;
- a "MANUAL" badge;
- "2 MANUAL" in the Fans page header;
- the fan icon and RPM next to the notch.

## Safety: what happens without you

Every fan returns to **Auto** automatically when any of these happens:
- a CPU or GPU sensor goes above **95 °C**;
- no CPU or GPU temperature can be read;
- SparkV quits, crashes or stops responding for 10 seconds;
- the Mac goes to sleep;
- the helper is stopped, updated or restarted.

After an overheat, manual control stays off until the chip is below 85 °C for 30 seconds, and SparkV shows a red "Failsafe" line.

Under heavy load an Apple silicon chip often runs at 90 to 100 °C. When that happens, the failsafe hands the fans back to macOS, which then runs them fast on its own. This is on purpose: the failsafe only ever gives control back to macOS, never the other way round.

## Macs Fan Control, TG Pro, Stats, iStat Menus

Two fan programs on the same fan fight each other. If another app has a fan in manual mode, SparkV marks that fan **OTHER APP** and leaves it alone.

To use SparkV's control, set that app's fans to Auto. In Macs Fan Control, click "Auto" for each fan or quit it. If you no longer want it, uninstall it with its own uninstaller; that also removes its helper, `com.crystalidea.macsfancontrol.smcwrite`.

## Update

After you rebuild or update SparkV, the Fans page offers **Update Helper…** whenever the bundled helper differs from the installed one. Click it: one password prompt, done.

If SparkV was rebuilt **ad hoc** (without the "NotchIsland Developer" certificate), the helper no longer recognises it and SparkV shows "Helper does not trust this SparkV build". Click **Reinstall Helper…**.

## Uninstall

**In SparkV:** the window's gear menu › **Uninstall Fan Helper…**.

**Or in Terminal:**

```sh
sudo "/path/to/SparkV.app/Contents/Resources/FanHelper/uninstall-fanhelper.sh"
```

This stops the helper (it puts every fan it controls back to Auto first) and removes four things:
- `/Library/LaunchDaemons/com.sparkv.fanhelper.plist`
- `/Library/PrivilegedHelperTools/com.sparkv.fanhelper`
- its socket and state file in `/var/run`
- `/Library/Logs/SparkV/fanhelper.log`

macOS then controls the fans exactly as before.

**If SparkV is already deleted**, run these four commands in Terminal:

```sh
sudo launchctl bootout system/com.sparkv.fanhelper
sudo rm -f /Library/LaunchDaemons/com.sparkv.fanhelper.plist /Library/PrivilegedHelperTools/com.sparkv.fanhelper
sudo rm -f /var/run/com.sparkv.fanhelper.sock /var/run/com.sparkv.fanhelper.state
sudo rm -rf /Library/Logs/SparkV
```

## Troubleshooting

- **"Helper not running":** check System Settings › General › Login Items › Allow in the Background › SparkV. If it is on, reinstall. The log is at `/Library/Logs/SparkV/fanhelper.log`.
- **Check the fans without SparkV.** This only reads, and needs no sudo:

  ```sh
  /Library/PrivilegedHelperTools/com.sparkv.fanhelper --status
  ```

- **A restart** always clears any fan setting: the Mac starts on Auto.

## Sharing SparkV with friends

Each friend has to install the helper once on their own Mac, from their copy of SparkV. The helper only trusts the exact certificate that signed the SparkV it was installed from.
