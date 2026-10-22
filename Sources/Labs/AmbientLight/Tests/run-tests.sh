#!/bin/zsh
# Builds and runs the Ambient Light harness: the analyzer on synthesized
# audio (beat accuracy, tempo, bands, CPU) and the renderers' per-frame
# cost on an offscreen layer tree. No audio capture, no window on screen.
set -euo pipefail
HERE="${0:A:h}"
LAB="${HERE:h}"
OUT="${TMPDIR:-/tmp}/ambient-light-tests"
mkdir -p "$OUT"
# Snapshot first: iCloud Desktop sync can touch files mid-compile.
rm -rf "$OUT/src"; mkdir -p "$OUT/src"
cp "$LAB"/AmbientLightModels.swift "$LAB"/AmbientSpectralAnalyzer.swift "$LAB"/AmbientLightPalette.swift \
   "$LAB"/AmbientLightChoreographer.swift "$LAB"/AmbientGlowLayers.swift "$HERE"/*.swift "$OUT/src/" 2>/dev/null || true
xcrun swiftc -O -parse-as-library -swift-version 6 -target arm64-apple-macos15.0 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" "$OUT"/src/*.swift -o "$OUT/ambient-tests"
"$OUT/ambient-tests"
