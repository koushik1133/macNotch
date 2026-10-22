#!/bin/zsh
# Installs SparkV's fan helper as a LaunchDaemon. Run it ONCE, yourself:
#
#   sudo "/Applications/SparkV.app/Contents/Resources/FanHelper/install-fanhelper.sh"
#
# (or let SparkV run it: Fans > Install Helper asks for your password once).
# Optional argument: the path of SparkV.app (default: the app this script is in).
#
# What it does, nothing else:
#   1. checks SparkV.app and the bundled helper are validly signed by the
#      same certificate;
#   2. copies the helper to /Library/PrivilegedHelperTools/com.sparkv.fanhelper;
#   3. writes /Library/LaunchDaemons/com.sparkv.fanhelper.plist with SparkV's
#      designated requirement, so the helper only obeys that exact app;
#   4. starts it with launchctl.
# Undo everything with uninstall-fanhelper.sh.
set -euo pipefail

LABEL="com.sparkv.fanhelper"
HERE="${0:A:h}"
APP="${1:-${HERE:h:h:h}}"
APP="${APP%/}"
HELPER_SRC="$APP/Contents/Library/LaunchServices/$LABEL"
PLIST_SRC="$APP/Contents/Resources/FanHelper/$LABEL.plist"
HELPER_DST="/Library/PrivilegedHelperTools/$LABEL"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"
SOCKET="/var/run/$LABEL.sock"

fail() { print -u2 "install-fanhelper: $*"; exit 1; }

[[ $EUID -eq 0 ]] || fail "run with sudo (it installs a root LaunchDaemon)"
[[ -d "$APP" ]] || fail "no app at $APP"
[[ -x "$HELPER_SRC" ]] || fail "no helper at $HELPER_SRC (build SparkV with the fan helper)"
[[ -f "$PLIST_SRC" ]] || fail "no plist template at $PLIST_SRC"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$BUNDLE_ID" == "com.sparkv.app" ]] || fail "$APP is not SparkV (bundle id '$BUNDLE_ID')"

# The app bundle may live in a user-writable folder. Copy the helper into a
# root-only staging folder FIRST and verify and install that copy, so the
# file that gets root is exactly the file that was checked (no swap between
# check and copy).
STAGE="$(mktemp -d -t sparkv-fanhelper)"
trap 'rm -rf "$STAGE"' EXIT
chmod 700 "$STAGE"
cp "$HELPER_SRC" "$STAGE/$LABEL"
HELPER_COPY="$STAGE/$LABEL"

# Not --strict for the app: iCloud tags bundles with Finder info that --strict reports.
codesign --verify "$APP" || fail "SparkV.app's signature is not valid"
codesign --verify --strict "$HELPER_COPY" || fail "the helper's signature is not valid"

designated() { codesign -d -r- "$1" 2>/dev/null | sed -n "s/^#* *designated => //p"; }
APP_REQ="$(designated "$APP")"
HELPER_REQ="$(designated "$HELPER_COPY")"
[[ -n "$APP_REQ" ]] || fail "could not read SparkV's designated requirement"
[[ "$APP_REQ" == *'identifier "com.sparkv.app"'* || "$APP_REQ" == *'cdhash'* ]] || fail "unexpected requirement: $APP_REQ"
[[ "$HELPER_REQ" == *'identifier "com.sparkv.fanhelper"'* || "$HELPER_REQ" == *'cdhash'* ]] || fail "the helper is not com.sparkv.fanhelper"

leaf() { print -r -- "$1" | grep -o 'certificate leaf = H"[0-9a-fA-F]*"' || true; }
if [[ "$APP_REQ" == *cdhash* ]]; then
  print "warning: SparkV is signed ad hoc. The helper will only accept this exact build;"
  print "         run this script again after every rebuild (or create the \"NotchIsland Developer\" identity)."
else
  [[ -n "$(leaf "$APP_REQ")" && "$(leaf "$APP_REQ")" == "$(leaf "$HELPER_REQ")" ]] \
    || fail "SparkV and the helper are not signed by the same certificate"
fi

# Stop an older copy first: on SIGTERM it returns every fan to Auto.
launchctl bootout "system/$LABEL" 2>/dev/null || true

install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
install -o root -g wheel -m 755 "$HELPER_COPY" "$HELPER_DST"
install -d -o root -g wheel -m 755 /Library/Logs/SparkV

TMP_PLIST="$STAGE/$LABEL.plist"
cp "$PLIST_SRC" "$TMP_PLIST"
# plutil takes the value as its own argument, so the quotes in the
# requirement need no escaping.
plutil -replace ProgramArguments.2 -string "$APP_REQ" "$TMP_PLIST"
plutil -lint "$TMP_PLIST" >/dev/null || fail "plist did not validate"
install -o root -g wheel -m 644 "$TMP_PLIST" "$PLIST_DST"

launchctl bootstrap system "$PLIST_DST"

for _ in {1..50}; do
  [[ -S "$SOCKET" ]] && break
  sleep 0.1
done
if [[ -S "$SOCKET" ]]; then
  print "SparkV fan helper installed and running."
  "$HELPER_DST" --status || true
else
  print -u2 "The helper was installed but is not running yet. Log: /Library/Logs/SparkV/fanhelper.log"
  exit 1
fi
