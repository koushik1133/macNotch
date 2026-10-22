#!/bin/zsh
# Compiles and runs the clipboard-history core harness against private
# NSPasteboard(name:) pasteboards (never .general). Swift 5 and Swift 6 modes.
set -euo pipefail
HERE="${0:A:h}"
ROOT="${HERE:h:h:h}"
SRC="$ROOT/Sources/Labs/Clipboard"
OUT="${TMPDIR:-/tmp}/sparkv-clipboard-tests"
mkdir -p "$OUT"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
for v in 5 6; do
  xcrun swiftc -parse-as-library -swift-version $v -target arm64-apple-macos15.0 -sdk "$SDK" \
    "$SRC/ClipboardModel.swift" "$SRC/ClipboardPasteboard.swift" "$SRC/ClipboardDiskStore.swift" \
    "$HERE/CoreHarness.swift" -o "$OUT/core-swift$v"
  echo "== core harness (Swift $v)"
  "$OUT/core-swift$v"
done

# Controller end-to-end: the app's sources (minus @main and AppLog, stubbed)
# plus the Labs/Clipboard folder, linked against a scratch GlanceKit build.
# Skip with CORE_ONLY=1.
[[ -n "${CORE_ONLY:-}" ]] && exit 0
W="$OUT/ctl"
rm -rf "$W" "$OUT/controller"; mkdir -p "$W/src" "$W/mod" "$W/lib"
cp "$ROOT"/Sources/*.swift "$W/src/"
rm -f "$W/src/NotchIslandApp.swift" "$W/src/AppLog.swift"
# Every Labs folder build.sh compiles (the app's sources refer to them).
for d in Converter Spaces UIAudit JobAgent ScreenRegion PromptRefiner Clipboard BrowserRecorder; do
  cp "$ROOT/Sources/Labs/$d"/*.swift "$W/src/"
done
cp "$HERE/AppLogStub.swift" "$HERE/ControllerHarness.swift" "$W/src/"
cp -R "$ROOT/Vendor/glance/Sources" "$W/glance"
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -sdk "$SDK" \
  -module-name GlanceKit -default-isolation MainActor \
  -enable-upcoming-feature DisableOutwardActorInference -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature MemberImportVisibility \
  -emit-library -static -emit-module -emit-module-path "$W/mod/GlanceKit.swiftmodule" \
  $(find "$W/glance" -name '*.swift') -o "$W/lib/libGlanceKit.a" 2>/dev/null
xcrun swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 -sdk "$SDK" \
  -I "$W/mod" -L "$W/lib" -lGlanceKit "$W/src"/*.swift -o "$OUT/controller" 2>&1 | grep -E "error:" && exit 1
echo "== controller harness"
"$OUT/controller"
