#!/bin/zsh
# Builds build/SparkV.app with the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "${0:A:h}"

CONFIG="${1:-release}"
OPT_FLAGS=(-O)
[[ "$CONFIG" == "debug" ]] && OPT_FLAGS=(-Onone -g)
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Compile, assemble and sign in a temp folder: iCloud Desktop sync touches
# files mid-build ("input file was modified during the build") and re-adds
# Finder xattrs that make codesign refuse the bundle.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/src" "$WORK/modules" "$WORK/lib"
cp Sources/*.swift "$WORK/src/"
cp Sources/Labs/Converter/*.swift "$WORK/src/"
cp Sources/Labs/Spaces/*.swift "$WORK/src/"
cp Sources/Labs/UIAudit/*.swift "$WORK/src/"
cp Sources/Labs/JobAgent/*.swift "$WORK/src/"
cp Sources/Labs/ScreenRegion/*.swift "$WORK/src/"
cp Sources/Labs/PromptRefiner/*.swift "$WORK/src/"
cp Sources/Labs/Clipboard/*.swift "$WORK/src/"
cp Sources/Labs/BrowserRecorder/*.swift "$WORK/src/"
cp Sources/Labs/ScreenDistance/*.swift "$WORK/src/"
cp Sources/Labs/FlowCanvas/*.swift "$WORK/src/"
cp Sources/Labs/Focus/*.swift "$WORK/src/"
cp Sources/Labs/UniversalSearch/*.swift "$WORK/src/"
cp Sources/Labs/QuickCapture/*.swift "$WORK/src/"
cp Sources/Labs/ReplyDrafter/*.swift "$WORK/src/"
cp Sources/Labs/FileDropActions/*.swift "$WORK/src/"
cp Sources/Labs/LiveTranslation/*.swift "$WORK/src/"
cp Sources/Labs/Downloads/*.swift "$WORK/src/"
cp Sources/Labs/Onboarding/*.swift "$WORK/src/"
cp Sources/Labs/ScreenRecorder/*.swift "$WORK/src/"
cp Sources/Labs/Media/*.swift "$WORK/src/"
cp Sources/Labs/Widgets/*.swift "$WORK/src/"
cp Sources/Labs/Modes/*.swift "$WORK/src/"
cp Sources/Labs/NotchThemes/*.swift "$WORK/src/"
cp Sources/Labs/FanControl/*.swift "$WORK/src/"
cp Sources/Labs/CloudSync/*.swift "$WORK/src/"
cp Sources/Labs/MeetingIntel/*.swift "$WORK/src/"
cp Sources/Labs/AmbientLight/*.swift "$WORK/src/"
cp Sources/Labs/SmartMoments/*.swift "$WORK/src/"
cp -R Vendor/mediaremote-adapter "$WORK/adapter-src"
cp -R Vendor/glance "$WORK/glance"

STAGED="$WORK/SparkV.app"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"

# Face unlock: glance (github.com/jonnyoo/glance, MIT) as the GlanceKit module,
# compiled with glance's own settings (Xcode's SWIFT_DEFAULT_ACTOR_ISOLATION =
# MainActor and SWIFT_APPROACHABLE_CONCURRENCY). See Vendor/glance/PORTING.md.
xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  "${OPT_FLAGS[@]}" \
  -target arm64-apple-macos15.0 \
  -sdk "$SDK" \
  -module-name GlanceKit \
  -default-isolation MainActor \
  -enable-upcoming-feature DisableOutwardActorInference \
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature MemberImportVisibility \
  -emit-library -static \
  -emit-module -emit-module-path "$WORK/modules/GlanceKit.swiftmodule" \
  $(find "$WORK/glance/Sources" -name '*.swift') \
  -o "$WORK/lib/libGlanceKit.a"

xcrun swiftc \
  -parse-as-library \
  -swift-version 5 \
  "${OPT_FLAGS[@]}" \
  -target arm64-apple-macos15.0 \
  -sdk "$SDK" \
  -I "$WORK/modules" \
  -L "$WORK/lib" -lGlanceKit \
  "$WORK/src"/*.swift \
  -o "$STAGED/Contents/MacOS/SparkV"

cp Info.plist "$STAGED/Contents/Info.plist"
# glance's videos, images and the ArcFace face-embedding model.
cp "$WORK/glance/Resources"/* "$STAGED/Contents/Resources/"
cp -R "$WORK/glance/Models/ArcFace.mlmodelc" "$STAGED/Contents/Resources/"
cp "$WORK/glance/LICENSE" "$STAGED/Contents/Resources/glance-LICENSE"

# Now Playing adapter (github.com/ungive/mediaremote-adapter, BSD-3). macOS
# 15.4+ only lets Apple-signed processes read system Now Playing, so the app
# runs Apple's /usr/bin/perl, which loads this framework and streams JSON.
ADAPTER_DIR="$STAGED/Contents/Resources/MediaRemoteAdapter"
FW="$ADAPTER_DIR/MediaRemoteAdapter.framework"
A="$WORK/adapter-src"
mkdir -p "$FW/Versions/A/Resources"
xcrun clang -arch arm64 -mmacosx-version-min=14.0 -isysroot "$SDK" \
  -fobjc-arc -fvisibility=default -dynamiclib -O2 \
  -I"$A/include" -I"$A/src" \
  "$A"/src/adapter/*.m "$A/src/private/MediaRemote.m" "$A"/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o "$FW/Versions/A/MediaRemoteAdapter"
cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
	<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
	<key>CFBundleName</key><string>MediaRemoteAdapter</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>0.1.0</string>
</dict></plist>
PLIST
ln -sfn A "$FW/Versions/Current"
ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -sfn Versions/Current/Resources "$FW/Resources"
cp "$A/bin/mediaremote-adapter.pl" "$ADAPTER_DIR/"
cp "$A/LICENSE" "$ADAPTER_DIR/LICENSE"

# Node runners for the UI audit and the browser recorder (Playwright; the
# machine's own node runs them). Their test sites stay out of the app.
rsync -a --delete --exclude test Vendor/ui-audit/ "$STAGED/Contents/Resources/ui-audit/"
rsync -a --delete --exclude test Vendor/browser-recorder/ "$STAGED/Contents/Resources/BrowserRecorder/"

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

xattr -cr "$STAGED"

# Signing identity. Face Unlock keeps its secrets in the login keychain, whose
# ACLs trust the exact code identity that created them; an ad-hoc signature
# changes on every build, so macOS would ask once ("NotchIsland wants to use
# confidential information...") after each rebuild. A self-signed code-signing
# certificate named "NotchIsland Developer" gives every build the same
# designated requirement, so the ACL keeps matching. Without one, sign ad hoc.
# How to create it: Vendor/glance/PORTING.md ("Stable signing identity").
SIGN_IDENTITY="-"
SIGN_EXTRA=()
# Look in the login keychain explicitly: some shells (IDE terminals,
# sandboxed tools) get an empty default keychain search list.
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
if security find-identity -p codesigning "$LOGIN_KEYCHAIN" 2>/dev/null | grep -q '"NotchIsland Developer"'; then
  SIGN_IDENTITY="NotchIsland Developer"
  # Offline and deterministic: no Apple timestamp server for a local cert.
  SIGN_EXTRA=(--timestamp=none --keychain "$LOGIN_KEYCHAIN")
fi

# Nested code first, then the app, with the Hardened Runtime and the
# camera/Apple Events/microphone entitlements. A certificate that can't sign
# (expired, private key missing) falls back to ad hoc rather than failing.
if [[ "$SIGN_IDENTITY" != "-" ]] && ! codesign --force --sign "$SIGN_IDENTITY" "${SIGN_EXTRA[@]}" "$FW"; then
  echo "warning: signing with \"$SIGN_IDENTITY\" failed; signing ad hoc instead" >&2
  SIGN_IDENTITY="-"
  SIGN_EXTRA=()
fi
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$FW"
fi
# The fan helper: same identity, Hardened Runtime, its own identifier. The
# install script checks that its certificate matches SparkV's.
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_EXTRA[@]}" --options runtime \
  --identifier com.sparkv.fanhelper "$STAGED/Contents/Library/LaunchServices/com.sparkv.fanhelper"
codesign --force --sign "$SIGN_IDENTITY" "${SIGN_EXTRA[@]}" --options runtime \
  --entitlements NotchIsland.entitlements "$STAGED"
codesign --verify --strict "$STAGED"
echo "Signed with: ${SIGN_IDENTITY/#-/ad hoc}"

mkdir -p build
rm -rf build/SparkV.app
ditto --noextattr --noqtn "$STAGED" build/SparkV.app
# Not --strict: iCloud tags the copied bundle root with Finder info, which
# --strict reports even though the signature itself is intact.
codesign --verify build/SparkV.app

echo "Built build/SparkV.app"
