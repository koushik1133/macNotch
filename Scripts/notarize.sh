#!/bin/zsh
# notarize.sh: the proper way to give SparkV to people outside your circle.
# Re-signs build/SparkV.app with your Apple "Developer ID Application"
# certificate, has Apple notarize it, staples the ticket, then builds a signed,
# notarized and stapled SparkV.dmg plus SparkV.zip. Those open with a plain
# double-click on any Mac, offline too, with no "Open Anyway" step.
#
# ONE-TIME SETUP (needs the paid Apple Developer Program, 99 USD a year)
#   1. developer.apple.com > Certificates > + > "Developer ID Application".
#      Create it from Keychain Access (Certificate Assistant > Request a
#      Certificate From a Certificate Authority), download it, double-click it.
#      Check: security find-identity -v -p codesigning
#   2. An app-specific password: account.apple.com > Sign-In and Security.
#   3. Store notary credentials in your keychain under a profile name:
#        xcrun notarytool store-credentials sparkv-notary \
#          --apple-id you@example.com --team-id ABCDE12345 --password <app-specific>
#
# USAGE
#   ./build.sh
#   DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)" \
#   NOTARY_PROFILE=sparkv-notary ./Scripts/notarize.sh
#
# OPTIONAL ENV
#   APP=path/to/SparkV.app   default build/SparkV.app (never modified)
#   OUT=folder               default dist/
#   DRY_RUN=1                check everything and print the signing and
#                            notarization commands without running them
#
# Takes 2 to 15 minutes (two uploads to Apple: the app, then the disk image).
# Needs only the Command Line Tools (notarytool and stapler ship with them).
set -euo pipefail
ROOT="${0:A:h:h}"
APP="${APP:-$ROOT/build/SparkV.app}"; APP="${APP:A}"
OUT="${OUT:-$ROOT/dist}"; OUT="${OUT:A}"
ENTITLEMENTS="$ROOT/NotchIsland.entitlements"
DRY_RUN="${DRY_RUN:-0}"

die() { echo "error: $*" >&2; exit 1; }
step() { print -r -- "==> $*"; }
# Runs a command, or only prints it in a dry run.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then print -r -- "   [dry run] ${(q-)@}"; else "$@"; fi
}

# ---- Preflight -------------------------------------------------------------
[[ -n "${DEVELOPER_ID:-}" ]] || die 'set DEVELOPER_ID, e.g. DEVELOPER_ID="Developer ID Application: Your Name (ABCDE12345)"'
[[ "$DEVELOPER_ID" == "Developer ID Application:"* ]] \
  || die "DEVELOPER_ID must be a \"Developer ID Application: ...\" identity (Apple Development or Mac App Distribution certificates can't be notarized for direct download)"
[[ -n "${NOTARY_PROFILE:-}" ]] || die "set NOTARY_PROFILE to the name you gave xcrun notarytool store-credentials"
[[ -d "$APP" ]] || die "$APP not found. Run ./build.sh first."
[[ -f "$ENTITLEMENTS" ]] || die "$ENTITLEMENTS not found"
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found; install the Command Line Tools (xcode-select --install)"
xcrun --find stapler >/dev/null 2>&1 || die "stapler not found; install the Command Line Tools"
# Notarization rejects get-task-allow (a debugging entitlement).
/usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$ENTITLEMENTS" >/dev/null 2>&1 \
  && die "remove com.apple.security.get-task-allow from NotchIsland.entitlements; notarization rejects it"
if ! security find-identity -v -p codesigning | grep -qF "\"$DEVELOPER_ID\""; then
  [[ "$DRY_RUN" == 1 ]] || die "no valid code-signing identity named \"$DEVELOPER_ID\" in your keychains (security find-identity -v -p codesigning)"
  print -r -- "   [dry run] note: \"$DEVELOPER_ID\" is not in your keychain yet"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SIGNED="$WORK/SparkV.app"

# ---- 1. Re-sign a copy, nested code first ----------------------------------
step "Signing a copy with $DEVELOPER_ID"
ditto --noextattr --noqtn "$APP" "$SIGNED"
xattr -cr "$SIGNED"
SIGN=(codesign --force --timestamp --options runtime --sign "$DEVELOPER_ID")
MAIN_EXE="$SIGNED/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SIGNED/Contents/Info.plist")"
# Loose Mach-O files (helpers, dylibs, native node addons) outside frameworks.
find "$SIGNED/Contents" -type f -not -path '*.framework/*' -print0 | while IFS= read -r -d '' f; do
  [[ "$f" == "$MAIN_EXE" ]] && continue
  file -b "$f" | grep -q 'Mach-O' && run "${SIGN[@]}" "$f"
done
# Frameworks, deepest first (today: Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework).
find "$SIGNED/Contents" -type d -name '*.framework' -print0 | sort -rz | while IFS= read -r -d '' fw; do
  run "${SIGN[@]}" "$fw"
done
# The app last, with the camera, microphone, calendar and Apple Events entitlements.
run "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$SIGNED"
if [[ "$DRY_RUN" != 1 ]]; then
  codesign --verify --deep --strict --verbose=2 "$SIGNED"
  codesign -dv "$SIGNED" 2>&1 | grep -q '^TeamIdentifier=[A-Z0-9]\{10\}$' \
    || die "the signature has no Team ID; is DEVELOPER_ID really a Developer ID certificate?"
fi

# notarize FILE: uploads FILE, waits for Apple's verdict, prints the log on failure.
notarize() {
  local file="$1" result="$WORK/notary-${1:t}.plist" status id
  step "Notarizing ${file:t} (upload and Apple's scan, usually a few minutes)"
  if [[ "$DRY_RUN" == 1 ]]; then
    run xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait
    return 0
  fi
  xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait \
    --output-format plist > "$result" || true
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$result" 2>/dev/null || echo unknown)"
  id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    cat "$result" >&2 2>/dev/null || true
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "Apple did not accept ${file:t} (status: $status). The log above lists each problem."
  fi
  print -r -- "   accepted (submission $id)"
}

# ---- 2. Notarize and staple the app ----------------------------------------
ditto -c -k --keepParent "$SIGNED" "$WORK/SparkV-notarize.zip"
notarize "$WORK/SparkV-notarize.zip"
step "Stapling the ticket to SparkV.app (so it opens offline)"
run xcrun stapler staple "$SIGNED"
if [[ "$DRY_RUN" != 1 ]]; then
  xcrun stapler validate "$SIGNED"
  spctl --assess --type execute -vv "$SIGNED"   # expect: source=Notarized Developer ID
fi

# ---- 3. Disk image and zip from the stapled app ----------------------------
if [[ "$DRY_RUN" == 1 ]]; then
  print -r -- "   [dry run] $ROOT/Scripts/package-for-friends.sh --app <signed copy> --out $OUT --notarized"
  print -r -- "   [dry run] then sign, notarize and staple $OUT/SparkV.dmg"
  step "Dry run finished; nothing was signed or uploaded."
  exit 0
fi
"$ROOT/Scripts/package-for-friends.sh" --app "$SIGNED" --out "$OUT" --notarized

step "Signing, notarizing and stapling SparkV.dmg"
codesign --force --timestamp --sign "$DEVELOPER_ID" "$OUT/SparkV.dmg"
notarize "$OUT/SparkV.dmg"
xcrun stapler staple "$OUT/SparkV.dmg"
xcrun stapler validate "$OUT/SparkV.dmg"
spctl --assess --type open --context context:primary-signature -vv "$OUT/SparkV.dmg"
(cd "$OUT" && shasum -a 256 SparkV.dmg SparkV.zip > SHA256.txt)

step "Done: $OUT/SparkV.dmg and $OUT/SparkV.zip are notarized."
print -r -- "Selling it? Face Unlock's ArcFace model is licensed for non-commercial use"
print -r -- "only, so a paid build must drop Face Unlock or use a differently licensed model."
