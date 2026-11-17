#!/bin/zsh
# Offline test of the SparkV DJ signal path (no tap, no device, no sound
# played): presets change the tone, Flat and Bypass are transparent, the
# Concert hall leaves a tail, the limiter keeps peaks under full scale.
set -euo pipefail
HERE="${0:A:h}"
LAB="${HERE:h}"
SRC="${LAB:h:h}"
OUT="${TMPDIR:-/tmp}/sparkv-dj-tests"
rm -rf "$OUT/src"; mkdir -p "$OUT/src"
cp "$LAB"/DJModels.swift "$LAB"/DJAudioEngine.swift "$HERE"/*.swift "$OUT/src/"
cp "$SRC"/Labs/AmbientLight/AmbientSpectralAnalyzer.swift "$SRC"/Labs/AmbientLight/AmbientLightModels.swift "$OUT/src/"
# Only the ring buffer from the capture file (the rest needs the whole app).
sed -n '1,/^\/\/ MARK: - Sources/p' "$SRC"/Labs/AmbientLight/AmbientAudioCapture.swift | sed '/ScreenCaptureKit/d' > "$OUT/src/AmbientRing.swift"
xcrun swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos15.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" "$OUT"/src/*.swift -o "$OUT/dj-tests"
"$OUT/dj-tests"
