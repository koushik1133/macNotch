#!/bin/zsh
# release.sh: cut a SparkV release end to end.
#
#   1. sets CFBundleShortVersionString / CFBundleVersion in Info.plist
#      (the build number must grow every release; update checks and crash
#      reports rely on it),
#   2. ./build.sh, then ./Scripts/notarize.sh (Developer ID, notarized and
#      stapled dist/SparkV.dmg + dist/SparkV.zip + dist/SHA256.txt),
#   3. keeps the debug symbols of this build in build/symbols/<ver>-<build>/
#      (if build.sh produced them, see Sources/Labs/AppShell/INTEGRATION.md),
#   4. commits and pushes the Info.plist bump, then creates the GitHub
#      release v<version> on exactly that commit (--target), so the tag
#      matches the shipped binary, with both files (gh CLI); a
#      version with "-" (1.3.0-beta.1) is marked as a pre-release, which
#      SparkV offers only to people who turned on beta versions,
#   5. writes version + sha256 into the Homebrew cask of your tap.
#
# USAGE
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=sparkv-notary ./Packaging/release.sh 1.2.0 [build-number]
#
# OPTIONAL ENV
#   NOTES=path.md     release notes (default: gh --generate-notes)
#   TAP_DIR=path      a clone of github.com/koushik1133/homebrew-sparkv
#                     (default ../homebrew-sparkv next to this repo)
#   PUSH_TAP=1        commit and push the cask change in TAP_DIR
#   DRY_RUN=1         print every command instead of running it
set -euo pipefail
ROOT="${0:A:h:h}"
PLIST="$ROOT/Info.plist"
CASK_TEMPLATE="$ROOT/Packaging/homebrew/sparkv.rb"
DRY_RUN="${DRY_RUN:-0}"
TAP_DIR="${TAP_DIR:-$ROOT/../homebrew-sparkv}"

die() { echo "error: $*" >&2; exit 1; }
step() { print -r -- "==> $*"; }
run() {
  if [[ "$DRY_RUN" == 1 ]]; then print -r -- "   [dry run] ${(q-)@}"; else "$@"; fi
}

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: release.sh <version> [build]   e.g. release.sh 1.2.0"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.]+)?$' ]] || die "version must look like 1.2 or 1.2.0 or 1.3.0-beta.1"
[[ -f "$PLIST" ]] || die "$PLIST not found"
CURRENT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
BUILD="${2:-$(( CURRENT_BUILD + 1 ))}"
[[ "$BUILD" =~ '^[0-9]+$' ]] || die "build number must be a whole number"
(( BUILD > CURRENT_BUILD )) || die "build $BUILD must be greater than the current $CURRENT_BUILD"
PRERELEASE=()
[[ "$VERSION" == *-* ]] && PRERELEASE=(--prerelease)
command -v gh >/dev/null 2>&1 || [[ "$DRY_RUN" == 1 ]] || die "the GitHub CLI (gh) is needed: brew install gh"
# The release is tagged on the commit that holds the version bump, so the
# tree must be clean apart from what this script changes.
if [[ "$DRY_RUN" != 1 ]]; then
  git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git checkout"
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || die "commit or stash your changes first (git status is not clean)"
fi

step "SparkV $VERSION ($BUILD)${PRERELEASE:+ pre-release}"
run /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
run /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

step "Commit the version bump"
run git -C "$ROOT" add Info.plist
run git -C "$ROOT" commit -m "SparkV $VERSION ($BUILD)"
run git -C "$ROOT" push
TARGET="HEAD"
[[ "$DRY_RUN" != 1 ]] && TARGET="$(git -C "$ROOT" rev-parse HEAD)"

step "Build and notarize"
run "$ROOT/build.sh"
run "$ROOT/Scripts/notarize.sh"
DIST="$ROOT/dist"
if [[ "$DRY_RUN" != 1 ]]; then
  for f in SparkV.zip SparkV.dmg SHA256.txt; do [[ -f "$DIST/$f" ]] || die "$DIST/$f is missing after notarize.sh"; done
fi

step "Keep debug symbols"
if [[ -d "$ROOT/build/symbols/$VERSION-$BUILD" ]]; then
  print -r -- "   symbols in build/symbols/$VERSION-$BUILD (keep them; .ips reports match by UUID)"
  run /usr/bin/dwarfdump --uuid "$ROOT/build/symbols/$VERSION-$BUILD/SparkV.dSYM"
else
  print -r -- "   none for this build (add the dsymutil step from INTEGRATION.md to build.sh)"
fi

step "GitHub release v$VERSION"
NOTES_ARGS=(--generate-notes)
[[ -n "${NOTES:-}" ]] && NOTES_ARGS=(--notes-file "$NOTES")
run gh release create "v$VERSION" "$DIST/SparkV.zip" "$DIST/SparkV.dmg" \
  --repo koushik1133/macNotch --target "$TARGET" --title "SparkV $VERSION" "${NOTES_ARGS[@]}" "${PRERELEASE[@]}"

step "Homebrew cask"
if [[ -n "${PRERELEASE[*]}" ]]; then
  print -r -- "   pre-release: the cask stays on the last stable version"
  exit 0
fi
SHA="0000000000000000000000000000000000000000000000000000000000000000"
if [[ "$DRY_RUN" != 1 ]]; then
  SHA="$(awk '$2 == "SparkV.zip" { print $1 }' "$DIST/SHA256.txt")"
  [[ "$SHA" =~ '^[0-9a-f]{64}$' ]] || die "no sha256 for SparkV.zip in $DIST/SHA256.txt"
fi
CASK="$TAP_DIR/Casks/sparkv.rb"
if [[ ! -d "$TAP_DIR" ]]; then
  print -r -- "   no tap clone at $TAP_DIR; create github.com/koushik1133/homebrew-sparkv and clone it there"
  print -r -- "   (copy $CASK_TEMPLATE to Casks/sparkv.rb), then rerun this step"
  exit 0
fi
run mkdir -p "$TAP_DIR/Casks"
[[ -f "$CASK" ]] || run cp "$CASK_TEMPLATE" "$CASK"
run /usr/bin/sed -i '' -E "s/^  version \"[^\"]+\"/  version \"$VERSION\"/; s/^  sha256 \"[0-9a-f]+\"/  sha256 \"$SHA\"/" "$CASK"
if [[ "${PUSH_TAP:-0}" == 1 ]]; then
  run git -C "$TAP_DIR" add Casks/sparkv.rb
  run git -C "$TAP_DIR" commit -m "sparkv $VERSION"
  run git -C "$TAP_DIR" push
else
  print -r -- "   updated $CASK; commit and push it (or rerun with PUSH_TAP=1)"
fi
step "Done: SparkV $VERSION is released."
