# Fans & Temperatures: setup

Nothing to set up. Fans & Temperatures is read-only: it shows each fan's
speed (with its minimum and maximum) and the CPU, GPU, memory, SSD and
battery temperatures, read from the SMC and HID sensors without any
password or helper. macOS controls the fans; SparkV never changes them.

## If an older SparkV installed the fan helper

Earlier builds could install a privileged helper for setting fan speeds.
This build has none. If you installed it before, remove it once in
Terminal (it asks for your password):

```sh
sudo launchctl bootout system/com.sparkv.fanhelper 2>/dev/null
sudo rm -f /Library/LaunchDaemons/com.sparkv.fanhelper.plist /Library/PrivilegedHelperTools/com.sparkv.fanhelper
sudo rm -f /var/run/com.sparkv.fanhelper.sock /var/run/com.sparkv.fanhelper.state
```

The Homebrew cask's `zap` removes the same files.
