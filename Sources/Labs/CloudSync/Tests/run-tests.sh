#!/bin/zsh
# CloudSync tests. Never touch iCloud Drive: all files go to a scratch folder.
#
#   Sources/Labs/CloudSync/Tests/run-tests.sh [quick|full] [project root] [scratch dir]
#
# quick (default): the mirror engine, Inbox import, names, owner file and
#   secret filter, compiled on their own (seconds).
# full: also rendering of real SparkV types and complete sync runs; compiles
#   the whole app minus its @main, so it needs GlanceKit built (GLANCE_DIR
#   with modules/ and lib/libGlanceKit.a, as build.sh makes them).
set -euo pipefail
MODE="${1:-quick}"
ROOT="${2:-${0:A:h}/../../../..}"
ROOT="${ROOT:A}"
SCRATCH="${3:-$(mktemp -d)/cloudsync-tests}"
GLANCE_DIR="${GLANCE_DIR:-}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$SCRATCH"
CS="$ROOT/Sources/Labs/CloudSync"

if [[ "$MODE" == "quick" ]]; then
  xcrun swiftc -parse-as-library -swift-version 6 -target arm64-apple-macos15.0 -sdk "$SDK" \
    "$CS/CloudSyncModels.swift" "$CS/CloudSyncPaths.swift" "$CS/CloudSyncEngine.swift" \
    "$CS/CloudSyncInbox.swift" "$CS/CloudSyncSecrets.swift" "$CS/Tests/CloudSyncTests.swift" \
    -o "$OUT/cloudsync-tests"
else
  [[ -n "$GLANCE_DIR" ]] || { echo "full mode needs GLANCE_DIR (modules/ and lib/)"; exit 2; }
  cd "$ROOT"
  LABS=(${(f)"$(sed -n "s#^cp \(Sources/Labs/[A-Za-z]*\)/\*.swift.*#\1#p" build.sh | grep -v CloudSync)"})
  FILES=(Sources/*.swift(N))
  FILES=(${FILES:#Sources/NotchIslandApp.swift})
  for d in $LABS; do FILES+=($d/*.swift(N)); done
  FILES+=($CS/*.swift(N))
  xcrun swiftc -parse-as-library -swift-version 5 -Onone -target arm64-apple-macos15.0 -sdk "$SDK" \
    -D CLOUDSYNC_FULL -I "$GLANCE_DIR/modules" -L "$GLANCE_DIR/lib" -lGlanceKit \
    $FILES "$CS/Tests/CloudSyncTests.swift" -o "$OUT/cloudsync-tests"
fi
"$OUT/cloudsync-tests" "$SCRATCH"
