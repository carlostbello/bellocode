#!/usr/bin/env bash
# The owner handoff build (docs/RELEASE.md). `make release` runs it after Scripts/fetch-opencode.sh.
#
#   1. Scripts/make-app.sh release: build/BelloCode.app, every helper and the app ad-hoc signed the same way
#      (BELLOCODE_SIGN_IDENTITY overrides the default "-"; Developer ID signing and notarisation are not done for 1.0).
#   2. The bundle's marketing version and build number are checked against VERSION and the build number used.
#   3. build/BelloCode-<version>.zip made with ditto (keeps the signature, symlinks and extended attributes).
#   4. Installability check on a copy unzipped from the zip, marked quarantined as a download would be:
#      codesign --verify --deep --strict, each nested signature, arm64-only executables, version, and the Gatekeeper
#      assessment (spctl). spctl's verdict is reported, not required: an ad-hoc signed app is expected to be
#      "rejected" by Gatekeeper; docs/RELEASE.md says how the owner opens it. The app is never launched.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
say() { echo "make-release: $*"; }
die() { echo "make-release: error: $*" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || die "BelloCode 1.0 is released for Apple silicon (arm64) only; build it on an arm64 Mac"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION '$VERSION' is not MAJOR.MINOR.PATCH"
BUILD_NUMBER="${BELLOCODE_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
export BELLOCODE_BUILD_NUMBER="$BUILD_NUMBER"
APP="$ROOT/build/BelloCode.app"
ZIP="$ROOT/build/BelloCode-$VERSION.zip"
IDENTITY="${BELLOCODE_SIGN_IDENTITY:--}"
if [[ -n "$(git -C "$ROOT" status --porcelain 2> /dev/null)" ]]; then
  say "warning: the checkout has uncommitted changes; build $BUILD_NUMBER does not name one commit"
fi

# BELLOCODE_APP_PATH would send the app elsewhere; the release is always build/BelloCode.app.
unset BELLOCODE_APP_PATH
"$ROOT/Scripts/make-app.sh" release

plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
check_bundle() { # app label
  local app="$1" label="$2"
  [[ "$(plist "$app" CFBundleShortVersionString)" == "$VERSION" ]] || die "$label: CFBundleShortVersionString is $(plist "$app" CFBundleShortVersionString), expected $VERSION"
  [[ "$(plist "$app" CFBundleVersion)" == "$BUILD_NUMBER" ]] || die "$label: CFBundleVersion is $(plist "$app" CFBundleVersion), expected $BUILD_NUMBER"
  for executable in "$app/Contents/MacOS/BelloCode" "$app/Contents/Helpers/"*; do
    [[ "$(lipo -archs "$executable")" == "arm64" ]] || die "$label: $(basename "$executable") is $(lipo -archs "$executable"), not arm64 only"
  done
  # Every nested code object and the app carry the same kind of signature (ad-hoc unless an identity was given).
  for code in "$app/Contents/Helpers/"* "$app"; do
    codesign --verify --strict "$code" || die "$label: signature of $(basename "$code") does not verify"
    local details
    details="$(codesign -dv "$code" 2>&1)"
    if [[ "$IDENTITY" == "-" ]]; then
      grep -q "Signature=adhoc" <<< "$details" || die "$label: $(basename "$code") is not ad-hoc signed like the rest"
    else
      grep -q "Authority=" <<< "$details" || die "$label: $(basename "$code") has no signing authority"
    fi
  done
  codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed "s|^|make-release: [$label] |"
}

say "checking build/BelloCode.app"
check_bundle "$APP" "built"

say "zipping ${ZIP#"$ROOT"/}"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Installability: what the owner gets after downloading and unzipping.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ditto -x -k "$ZIP" "$WORK"
COPY="$WORK/BelloCode.app"
[[ -d "$COPY" ]] || die "the zip does not contain BelloCode.app at its top level"
# Mark it as a browser download would (com.apple.quarantine), so the assessment sees what a transferred copy sees.
xattr -w com.apple.quarantine "0081;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$COPY"
say "checking the unzipped, quarantined copy"
check_bundle "$COPY" "unzipped"
[[ "$(plist "$COPY" BelloCodeOpenCodeVersion)" == "$(plist "$APP" BelloCodeOpenCodeVersion)" ]] || die "unzipped copy bundles a different opencode"
diff -rq "$APP" "$COPY" > /dev/null || die "the unzipped copy differs from build/BelloCode.app"

say "Gatekeeper assessment of the unzipped copy (spctl --assess --type execute):"
set +e
SPCTL_OUTPUT="$(spctl --assess --type execute --verbose=4 "$COPY" 2>&1)"
SPCTL_STATUS=$?
set -e
sed 's/^/make-release:   /' <<< "$SPCTL_OUTPUT"
if [[ $SPCTL_STATUS -eq 0 ]]; then
  GATEKEEPER="accepted"
else
  GATEKEEPER="rejected (exit $SPCTL_STATUS)"
  if [[ "$IDENTITY" == "-" ]]; then
    say "  expected for an ad-hoc signed build: the owner opens it once as docs/RELEASE.md describes"
  fi
fi

say "release ready"
say "  app:        build/BelloCode.app"
say "  zip:        ${ZIP#"$ROOT"/} ($(du -h "$ZIP" | awk '{print $1}'), SHA-256 $(shasum -a 256 "$ZIP" | awk '{print $1}'))"
say "  version:    $VERSION (build $BUILD_NUMBER), opencode $(plist "$APP" BelloCodeOpenCodeVersion), arm64, macOS $(plist "$APP" LSMinimumSystemVersion)+"
say "  signature:  $([[ "$IDENTITY" == "-" ]] && echo "ad-hoc (not Developer ID, not notarised)" || echo "$IDENTITY")"
say "  codesign:   --verify --deep --strict passed on the built app and on the unzipped copy"
say "  gatekeeper: $GATEKEEPER"
