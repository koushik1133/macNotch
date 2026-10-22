#!/bin/zsh
# package-for-friends.sh: turns build/SparkV.app into files you can send to
# friends: SparkV.dmg (drag-to-Applications disk image) and SparkV.zip.
#
# USAGE
#   ./build.sh                                  # first, as usual
#   ./Scripts/package-for-friends.sh            # writes dist/SparkV.dmg, dist/SparkV.zip
#   ./Scripts/package-for-friends.sh --app path/to/SparkV.app --out some/folder
#
# OPTIONS
#   --app PATH     the app to package (default: build/SparkV.app)
#   --out DIR      where SparkV.dmg / SparkV.zip go (default: dist/)
#   --notarized    the app is Developer ID signed and notarized (used by
#                  Scripts/notarize.sh): the Read Me drops the "Open Anyway" steps
#
# WHAT GOES IN
#   Only the app bundle exactly as build.sh signed it, an /Applications
#   shortcut (DMG) and "Read Me First.txt". Nothing is read from your home
#   folder: your settings, Spaces, Flow canvases, tray files, meeting notes,
#   browser profile, Face Unlock data and API keys live in ~/Library and in the
#   login keychain, never inside the app. The script still checks the bundle
#   for anything that looks personal and stops if it finds some.
#
# It never modifies the source app, never writes to build/, and needs no
# third-party tools (ditto, xattr, codesign, hdiutil, shasum ship with macOS).
set -euo pipefail
ROOT="${0:A:h:h}"

APP="$ROOT/build/SparkV.app"
OUT="$ROOT/dist"
NOTARIZED=0
while (( $# )); do
  case "$1" in
    --app) APP="${2:?--app needs a path}"; shift 2 ;;
    --out) OUT="${2:?--out needs a folder}"; shift 2 ;;
    --notarized) NOTARIZED=1; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
APP="${APP:A}"
OUT="${OUT:A}"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

# ---- 1. Is this a complete SparkV build? -----------------------------------
[[ -d "$APP" ]] || die "$APP not found. Run ./build.sh first."
[[ "${APP:t}" == "SparkV.app" ]] || die "expected a bundle named SparkV.app, got ${APP:t}"
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || die "$APP has no Contents/Info.plist (incomplete build?)"
pl() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
EXE="$(pl CFBundleExecutable)"
BUNDLE_ID="$(pl CFBundleIdentifier)"
VERSION="$(pl CFBundleShortVersionString)"
BUILD="$(pl CFBundleVersion)"
MIN_OS="$(pl LSMinimumSystemVersion)"
[[ -n "$EXE" && -x "$APP/Contents/MacOS/$EXE" ]] || die "the app's executable is missing (incomplete build?)"
[[ "$BUNDLE_ID" == "com.sparkv.app" ]] || warn "bundle id is '$BUNDLE_ID', expected com.sparkv.app"
case "$OUT/" in "$APP/"*) die "--out must not be inside the app bundle" ;; esac
case "$OUT/" in "$ROOT/build/"*) die "--out must not be inside build/ (build.sh replaces that folder)" ;; esac

# ---- 2. Stage a clean copy (temp folder: iCloud Desktop sync re-adds Finder
#         xattrs to files it watches, which breaks codesign --strict) ----------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/SparkV"
mkdir -p "$STAGE"
ditto --noextattr --noqtn "$APP" "$STAGE/SparkV.app"
xattr -cr "$STAGE/SparkV.app"
STAGED_APP="$STAGE/SparkV.app"

# ---- 3. Signature: must be intact, says which kind it is -------------------
codesign --verify --deep --strict "$STAGED_APP" 2>"$WORK/verify.txt" \
  || die "the app's signature does not verify, so macOS would refuse it on other Macs. Rebuild with ./build.sh.
$(cat "$WORK/verify.txt")"
SIGN_INFO="$(codesign -dv --verbose=2 "$STAGED_APP" 2>&1)"
AUTHORITY="$(print -r -- "$SIGN_INFO" | sed -n 's/^Authority=//p' | head -1)"
if print -r -- "$SIGN_INFO" | grep -q '^Signature=adhoc'; then
  SIGN_KIND="ad hoc"
  warn "signed ad hoc. It runs, but friends must re-allow every permission after each update you send. Run Scripts/create-signing-identity.sh once, then ./build.sh, so updates keep their permissions."
elif [[ "$AUTHORITY" == "Developer ID Application:"* ]]; then
  SIGN_KIND="$AUTHORITY"
else
  SIGN_KIND="${AUTHORITY:-unknown} (self-signed, not trusted by other Macs)"
fi
(( NOTARIZED )) && [[ "$AUTHORITY" != "Developer ID Application:"* ]] \
  && die "--notarized was given but the app is not Developer ID signed"
print -r -- "$SIGN_INFO" | grep -q 'flags=.*runtime' \
  || warn "the Hardened Runtime is off; camera and microphone need it on with the entitlements from NotchIsland.entitlements"

# ---- 4. Nothing personal inside the bundle ----------------------------------
# A clean build only holds sources' output, vendored resources and node
# packages. These patterns would mean something leaked in.
LEAKS=("${(@f)$(cd "$STAGED_APP" && find . \( \
    -name '.DS_Store' -o -name '.env' -o -name '.env.*' -o -name '*.log' \
    -o -name '*.sqlite*' -o -name '*.db' -o -name '*.db-*' -o -name '*.sparkvspace' \
    -o -name '*.p12' -o -name '*.pem' -o -name '*.key' -o -name '*.keychain*' \
    -o -name '*.mov' -o -name '*.m4a' -o -name '*.wav' -o -name '*.caf' \
    -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '.npmrc' -o -name '.git' \
    -o -name 'Cookies' -o -name 'Login Data' -o -name 'Local State' -o -name 'History' \
    -o \( -name '*.plist' -not -name 'Info.plist' \) \
    -o -name 'report.json' -o -name 'row*-step*.png' \
    -o \( -type d \( -name 'Profile' -o -name 'ms-playwright' \) \) \
    -o -path './Contents/Resources/*/test' -o -path './Contents/Resources/*/results' \
    -o -path './Contents/Resources/*/runs' \) -print 2>/dev/null)}")
LEAKS=(${LEAKS:#})
(( ${#LEAKS} == 0 )) || die "the app contains files that look personal or temporary; rebuild with ./build.sh instead of sending it:
$(printf '  %s\n' "${LEAKS[@]}")"
# API keys pasted into code or configs (Groq gsk_, OpenAI sk-, Anthropic sk-ant-,
# GitHub ghp_/github_pat_, Google AIza, Slack xox?-, AWS AKIA).
KEY_RE='gsk_[A-Za-z0-9]{20,}|(^|[^A-Za-z0-9_-])sk-(ant-|proj-)?[A-Za-z0-9_-]{32,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AIza[0-9A-Za-z_-]{35}|xox[abprs]-[0-9A-Za-z-]{10,}|AKIA[0-9A-Z]{16}'
KEY_HITS="$(grep -rlE --binary-files=text "$KEY_RE" "$STAGED_APP" 2>/dev/null || true)"
[[ -z "$KEY_HITS" ]] || die "something that looks like an API key is inside the app:
${KEY_HITS//$STAGED_APP/  SparkV.app}"
HOME_HITS="$(grep -rlF --binary-files=text "$HOME/" "$STAGED_APP" 2>/dev/null || true)"
[[ -z "$HOME_HITS" ]] || warn "these files mention your home folder path ($HOME), which shows your macOS user name:
${HOME_HITS//$STAGED_APP/  SparkV.app}"

# ---- 5. Read Me ------------------------------------------------------------
README="$STAGE/Read Me First.txt"
p() { print -r -- "$@"; }
{
  p "SparkV $VERSION ($BUILD)"
  p "Needs a Mac with Apple silicon (M1 or later) and macOS ${MIN_OS:-15} or later."
  p
  p "INSTALL"
  p "1. Drag SparkV into Applications (from the disk image, or from the unzipped"
  p "   folder). Open it from Applications, not from the disk image or Downloads."
  if (( NOTARIZED )); then
    p "2. Double-click SparkV in Applications and click Open."
  else
    p "2. Double-click SparkV. macOS says it can't check it for malware, because it"
    p "   is not notarized by Apple. Click Done (not Move to Trash)."
    p "3. Open System Settings > Privacy & Security, scroll down to Security, find"
    p "   \"SparkV was blocked to protect your Mac\" and click Open Anyway. Enter your"
    p "   password, then click Open Anyway once more. (Right-click > Open no longer"
    p "   does this on macOS 15 and later.) Needed once for each new version."
  fi
  p
  p "SETUP"
  p "- SparkV lives in the notch (no Dock icon): hover over the notch to open it."
  p "  No notch? It sits at the top centre of the screen. The gear icon in it has"
  p "  the settings and Quit SparkV."
  p "- The Setup window lists each permission (Accessibility, Screen Recording,"
  p "  Camera, Microphone...). Click Allow only for what you use. Each is asked"
  p "  once. Reopen it any time: gear icon > Permissions & Setup..."
  p "- Screen Recording takes effect after SparkV restarts."
  p
  p "OPTIONAL"
  p "- On-device AI: turn on Apple Intelligence in System Settings."
  p "- Groq API key (free at console.groq.com): faster AI answers; paste it in"
  p "  Clicky's settings. It stays in your keychain."
  p "- UI Audit and Browser Flows need Node.js: brew install node"
  p "  then once: npx playwright-core@1.64.1 install chromium"
  p
  p "Face Unlock uses an ArcFace model licensed for non-commercial use only."
  p "This copy is a free gift between friends; please don't sell it."
  p
  p "Signed by: $SIGN_KIND"
} > "$README"

# ---- 6. SparkV.dmg ---------------------------------------------------------
DMG_SRC="$WORK/dmg"
mkdir -p "$DMG_SRC"
ditto --noextattr --noqtn "$STAGED_APP" "$DMG_SRC/SparkV.app"
cp "$README" "$DMG_SRC/"
ln -s /Applications "$DMG_SRC/Applications"
# HFS+ reads on every macOS; UDZO is compressed and read-only.
hdiutil create -quiet -volname "SparkV" -srcfolder "$DMG_SRC" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 -ov "$WORK/SparkV.dmg"
hdiutil verify -quiet "$WORK/SparkV.dmg" || die "hdiutil could not verify the new disk image"

# ---- 7. SparkV.zip (unzips to a SparkV folder: app + Read Me) --------------
# ditto keeps symlinks, permissions and the code signature intact; Finder's
# Compress does too, but zip(1) would break the framework's symlinks.
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$STAGE" "$WORK/SparkV.zip"

# ---- 8. Hand over ----------------------------------------------------------
mkdir -p "$OUT"
rm -f "$OUT/SparkV.dmg" "$OUT/SparkV.zip" "$OUT/SHA256.txt"
mv "$WORK/SparkV.dmg" "$WORK/SparkV.zip" "$OUT/"
(cd "$OUT" && shasum -a 256 SparkV.dmg SparkV.zip > SHA256.txt)

size() { du -h "$1" | cut -f1 | tr -d ' '; }
print "Packaged SparkV $VERSION ($BUILD), signed by: $SIGN_KIND"
print "  $OUT/SparkV.dmg  ($(size "$OUT/SparkV.dmg"))"
print "  $OUT/SparkV.zip  ($(size "$OUT/SparkV.zip"))"
print "  $OUT/SHA256.txt"
print "Send either file (AirDrop, Google Drive, iCloud link). Install steps for"
print "friends: docs/Share-With-Friends.md (also inside as \"Read Me First.txt\")."
