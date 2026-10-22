#!/bin/zsh
# Removes SparkV's fan helper completely. Run it yourself:
#
#   sudo "/Applications/SparkV.app/Contents/Resources/FanHelper/uninstall-fanhelper.sh"
#
# (or Fans > Uninstall Helper in SparkV). Stopping the helper returns every
# fan to Auto first; afterwards macOS controls the fans exactly as before.
set -euo pipefail

LABEL="com.sparkv.fanhelper"

[[ $EUID -eq 0 ]] || { print -u2 "uninstall-fanhelper: run with sudo"; exit 1; }

# bootout sends SIGTERM; the helper sets every fan it controls back to Auto
# and clears the firmware's manual-mode flag before it exits.
launchctl bootout "system/$LABEL" 2>/dev/null || true

rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -f "/Library/PrivilegedHelperTools/$LABEL"
rm -f "/var/run/$LABEL.sock" "/var/run/$LABEL.state"
rm -f "/Library/Logs/SparkV/fanhelper.log"
rmdir "/Library/Logs/SparkV" 2>/dev/null || true

print "SparkV fan helper removed. macOS controls the fans again."
