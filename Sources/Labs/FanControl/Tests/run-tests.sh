#!/bin/zsh
# Builds and runs the Fan Control tests (fake SMC; no hardware writes).
#   Sources/Labs/FanControl/Tests/run-tests.sh [--live] [work dir]
# --live adds a READ-ONLY pass over this Mac's real fans and temperatures.
set -euo pipefail
HERE="${0:A:h}"
ROOT="${HERE:h:h:h:h}"
LIVE=()
WORK=""
for arg in "$@"; do
  if [[ "$arg" == "--live" ]]; then LIVE=(--live); else WORK="$arg"; fi
done
WORK="${WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
F="$ROOT/Sources/Labs/FanControl"
H="$ROOT/Helpers/FanHelper"
# The app's Foundation-level files plus the helper's engine and server
# (not its main.swift), and the tests.
xcrun swiftc -swift-version 6 -target arm64-apple-macos15.0 -sdk "$SDK" \
  -import-objc-header "$HERE/smc-layout.h" \
  "$F"/FanCore*.swift "$F/FanCurve.swift" "$F/FanSensorSampler.swift" "$F/FanHIDTemperatures.swift" \
  "$F/FanHelperClient.swift" "$F/FanController.swift" \
  "$H/FanHelperEngine.swift" "$H/FanHelperServer.swift" \
  "$HERE/FakeSMC.swift" "$HERE/main.swift" \
  -o "$WORK/fan-tests"
"$WORK/fan-tests" "$WORK" "${LIVE[@]}"
