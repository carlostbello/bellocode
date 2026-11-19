#!/usr/bin/env bash
# Build BelloCode with SwiftPM and assemble an ad-hoc signed build/BelloCode.app.
#
#   Scripts/make-app.sh [debug|release]      (default: debug)
#
# Requires Scripts/fetch-opencode.sh to have run (Vendor/opencode/<pinned version>/opencode).
# Signing is inside-out: helpers first (hardened runtime; opencode with its JIT entitlements), then the app.
# Set BELLOCODE_SIGN_IDENTITY to a Developer ID identity to sign for distribution; the default "-" is ad-hoc.
# The opencode version is Scripts/opencode-version. The regression gate (`make opencode-verify`) bundles a candidate
# with BELLOCODE_OPENCODE_VERSION and writes the app to BELLOCODE_APP_PATH instead of build/BelloCode.app.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
case "$CONFIG" in
  debug | release) ;;
  *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

say() { echo "make-app: $*"; }
warn() { echo "make-app: warning: $*" >&2; }
die() { echo "make-app: error: $*" >&2; exit 1; }

IDENTITY="${BELLOCODE_SIGN_IDENTITY:--}"
BUNDLE_ID="com.bellocode.app"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
OPENCODE_VERSION="${BELLOCODE_OPENCODE_VERSION:-$(tr -d '[:space:]' < "$ROOT/Scripts/opencode-version")}"
OPENCODE_BIN="$ROOT/Vendor/opencode/$OPENCODE_VERSION/opencode"
RG_BIN="$ROOT/Vendor/ripgrep/rg"
ENTITLEMENTS="$ROOT/Scripts/entitlements"
APP="${BELLOCODE_APP_PATH:-$ROOT/build/BelloCode.app}"
CONTENTS="$APP/Contents"

[[ -x "$OPENCODE_BIN" ]] || die "missing $OPENCODE_BIN; run Scripts/fetch-opencode.sh first"

# Provenance (D2 in docs/reviews/deep-review-1.md): every helper binary in the bundle is either pinned by SHA-256 in
# this repository (opencode, rg) or built from source by this run (bellocode-exec). Anything else is refused, and the
# copies in the bundle are checked again just before signing.
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
# BelloCode 1.0 is Apple silicon (arm64) only: the shared browser image pins arm64 browse and Chromium binaries, and
# the release was verified on arm64 (docs/RELEASE.md). An Intel Mac is refused here instead of producing an app whose
# shared Chrome cannot be built.
case "$(uname -m)" in
  arm64) OC_PLATFORM="darwin-arm64"; RG_TARGET="aarch64-apple-darwin" ;;
  x86_64) die "BelloCode 1.0 supports Apple silicon (arm64) Macs only; this Mac is x86_64 (Intel). See docs/RELEASE.md." ;;
  *) die "unsupported architecture $(uname -m); BelloCode 1.0 supports arm64 only" ;;
esac
OPENCODE_PIN="$(awk -v v="$OPENCODE_VERSION" -v p="$OC_PLATFORM" '!/^#/ && $1 == v && $2 == p { print $4 }' "$ROOT/Scripts/opencode-checksums")"
RG_PIN="$(awk -v t="$RG_TARGET" '!/^#/ && $2 == t { print $4 }' "$ROOT/Scripts/ripgrep-checksums")"
[[ -n "$OPENCODE_PIN" && "$OPENCODE_PIN" != "-" ]] || die "no pinned binary SHA-256 for opencode $OPENCODE_VERSION $OC_PLATFORM"
[[ -n "$RG_PIN" && "$RG_PIN" != "-" ]] || die "no pinned binary SHA-256 for rg $RG_TARGET"
verify_pinned() { # file pin name
  [[ -f "$1" ]] || die "missing $3 ($1)"
  local got
  got="$(sha256 "$1")"
  [[ "$got" == "$2" ]] || die "$3 SHA-256 $got is not the pinned $2; refusing to bundle it (run Scripts/fetch-opencode.sh)"
}
verify_pinned "$OPENCODE_BIN" "$OPENCODE_PIN" "opencode"
[[ -x "$RG_BIN" ]] || die "missing $RG_BIN; run Scripts/fetch-opencode.sh (ripgrep is required: opencode would download one at runtime)"
verify_pinned "$RG_BIN" "$RG_PIN" "rg"

cd "$ROOT"
# SwiftTerm's build plugin can stall asking git for metadata (deep-review-1 D1): pass the pinned values.
export SWIFTTERM_BUILD_TAG="${SWIFTTERM_BUILD_TAG:-v1.99.3}"
export SWIFTTERM_BUILD_COMMIT="${SWIFTTERM_BUILD_COMMIT:-282c3c3a932b55c129628876b70f37d993af1615}"
export SWIFTTERM_BUILD_BRANCH="${SWIFTTERM_BUILD_BRANCH:-HEAD}"
export SWIFTTERM_BUILD_DIRTY="${SWIFTTERM_BUILD_DIRTY:-false}"
say "swift build -c $CONFIG"
swift build -c "$CONFIG" --product BelloCode
swift build -c "$CONFIG" --product bellocode-exec
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
[[ -x "$BIN_DIR/BelloCode" ]] || die "swift build produced no executable at $BIN_DIR/BelloCode"
[[ -x "$BIN_DIR/bellocode-exec" ]] || die "swift build produced no executable at $BIN_DIR/bellocode-exec"
for built in "$BIN_DIR/BelloCode" "$BIN_DIR/bellocode-exec"; do
  [[ "$(lipo -archs "$built")" == "arm64" ]] || die "$(basename "$built") is $(lipo -archs "$built"), not arm64 only"
done
# Built from this checkout by the swift build above: record what is bundled and check the copy before signing.
EXEC_SHA="$(sha256 "$BIN_DIR/bellocode-exec")"

say "assembling ${APP#"$ROOT"/}"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources/opencode-plugin"

cp "$BIN_DIR/BelloCode" "$CONTENTS/MacOS/BelloCode"
cp "$OPENCODE_BIN" "$CONTENTS/Helpers/opencode"
# Containerised execution (docs/features/containers.md): opencode's shell and PTY command. Required.
cp "$BIN_DIR/bellocode-exec" "$CONTENTS/Helpers/bellocode-exec"
# The "bellocode" opencode server plugin (TypeScript, loaded by local path; no build step, no dependencies). Only the
# runtime sources are copied: tests and the package manifest stay in the repository.
[[ -f "$ROOT/Plugin/server.ts" ]] || die "missing Plugin/server.ts"
cp "$ROOT/Plugin/server.ts" "$CONTENTS/Resources/opencode-plugin/server.ts"
mkdir -p "$CONTENTS/Resources/opencode-plugin/src"
cp "$ROOT/Plugin/src/"*.ts "$CONTENTS/Resources/opencode-plugin/src/"
cp "$RG_BIN" "$CONTENTS/Helpers/rg"

# Licence texts and NOTICE files of everything shipped (Settings ▸ Acknowledgements shows them; D3): the Swift packages
# linked into the app (licence, then NOTICE where the package has one, as Apache-2.0 requires), opencode (its LICENSE at
# the pinned tag, Scripts/notices) and ripgrep (the texts from its verified release archive). A missing text fails.
ACK="$CONTENTS/Resources/Acknowledgements"
mkdir -p "$ACK"
notice() { # name licence-file [notice-file...]
  local name="$1"; shift
  [[ -f "$1" ]] || die "no licence text for $name ($1)"
  cat "$1" > "$ACK/$name.txt"; shift
  for extra in "$@"; do
    [[ -f "$extra" ]] || die "missing notice for $name ($extra)"
    printf '\n\n---- %s ----\n\n' "$(basename "$extra")" >> "$ACK/$name.txt"
    cat "$extra" >> "$ACK/$name.txt"
  done
}
CHECKOUTS="$ROOT/.build/checkouts"
notice "GRDB.swift" "$CHECKOUTS/GRDB.swift/LICENSE"
notice "SwiftTerm" "$CHECKOUTS/SwiftTerm/LICENSE"
notice "swift-markdown" "$CHECKOUTS/swift-markdown/LICENSE.txt" "$CHECKOUTS/swift-markdown/NOTICE.txt"
notice "swift-cmark" "$CHECKOUTS/swift-cmark/COPYING"
notice "swift-argument-parser" "$CHECKOUTS/swift-argument-parser/LICENSE.txt"
notice "swift-png" "$CHECKOUTS/swift-png/LICENSE" "$CHECKOUTS/swift-png/NOTICE"
notice "h" "$CHECKOUTS/h/LICENSE" "$CHECKOUTS/h/NOTICE"
notice "opencode" "$ROOT/Scripts/notices/opencode.txt"
RG_LICENCES="$ROOT/Vendor/ripgrep/licences"
notice "ripgrep" "$RG_LICENCES/COPYING" "$RG_LICENCES/LICENSE-MIT" "$RG_LICENCES/UNLICENSE"
# Every entry Settings ▸ Acknowledgements lists (except T3 Code, whose notice is embedded) has its text in the bundle.
for name in $(sed -n 's/.*Acknowledgement(name: "\([^"]*\)".*/\1/p' "$ROOT/Sources/BelloCodeApp/Settings/Acknowledgements.swift"); do
  [[ "$name" == "T3 Code" ]] || [[ -s "$ACK/$name.txt" ]] || die "no bundled licence text for acknowledgement '$name'"
done

# The shared browser image's build context (docs/features/shared-browser.md): BelloCode builds it locally with
# Rancher's buildx on first use. Only the listed files (the packing key is never in the bundle).
BROWSER_CONTEXT="$CONTENTS/Resources/browser-image"
mkdir -p "$BROWSER_CONTEXT"
for f in Dockerfile entrypoint.sh ctl.sh browse-mcp policy.json view.html versions.env seccomp-chromium.json; do
  [[ -s "$ROOT/Containers/browser/$f" ]] || die "missing Containers/browser/$f"
  cp -p "$ROOT/Containers/browser/$f" "$BROWSER_CONTEXT/$f"
done

# SwiftPM resource bundles (none yet). Copied for when modules gain resources; check Bundle.module lookup then.
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  cp -R "$bundle" "$CONTENTS/Resources/"
done
shopt -u nullglob

# App icon from assets/icon.svg, rendered with Quick Look (no third-party tools needed).
ICON_KEY=""
ICON_WORK="$(mktemp -d)"
trap 'rm -rf "$ICON_WORK"' EXIT
if qlmanage -t -s 1024 -o "$ICON_WORK" "$ROOT/assets/icon.svg" > /dev/null 2>&1 && [[ -f "$ICON_WORK/icon.svg.png" ]]; then
  ICONSET="$ICON_WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_WORK/icon.svg.png" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_WORK/icon.svg.png" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
  done
  if iconutil -c icns -o "$CONTENTS/Resources/AppIcon.icns" "$ICONSET"; then
    ICON_KEY="<key>CFBundleIconFile</key>
	<string>AppIcon</string>"
  else
    warn "iconutil failed; bundling without an icon"
  fi
else
  warn "could not render assets/icon.svg with qlmanage; bundling without an icon"
fi

# Build number: BELLOCODE_BUILD_NUMBER (make release passes it), else the commit count of this checkout.
BUILD_NUMBER="${BELLOCODE_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2> /dev/null || echo 1)}"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || die "build number '$BUILD_NUMBER' is not a positive integer"
[[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION '$APP_VERSION' is not MAJOR.MINOR.PATCH"
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>BelloCode</string>
	<key>CFBundleExecutable</key>
	<string>BelloCode</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>BelloCode</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$APP_VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD_NUMBER</string>
	$ICON_KEY
	<key>BelloCodeOpenCodeVersion</key>
	<string>$OPENCODE_VERSION</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>LSMinimumSystemVersion</key>
	<string>15.0</string>
	<key>NSCameraUsageDescription</key>
	<string>A web page in BelloCode's built-in browser asked to use the camera. You allowed it in the browser bar.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>A web page in BelloCode's built-in browser asked to use the microphone. You allowed it in the browser bar.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
EOF
plutil -lint -s "$CONTENTS/Info.plist" || die "invalid Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# The bundled helpers are still exactly the verified ones (nothing replaced them between copy and signing).
verify_pinned "$CONTENTS/Helpers/opencode" "$OPENCODE_PIN" "bundled opencode"
verify_pinned "$CONTENTS/Helpers/rg" "$RG_PIN" "bundled rg"
[[ "$(sha256 "$CONTENTS/Helpers/bellocode-exec")" == "$EXEC_SHA" ]] || die "bundled bellocode-exec is not the one built by this run"
for helper in "$CONTENTS/Helpers/"*; do
  case "$(basename "$helper")" in opencode | rg | bellocode-exec) ;; *) die "unexpected helper $(basename "$helper") in the bundle" ;; esac
done

say "signing (identity: $IDENTITY)"
TIMESTAMP="--timestamp"
[[ "$IDENTITY" == "-" ]] && TIMESTAMP="--timestamp=none"
sign() { codesign --force "$TIMESTAMP" --options runtime --sign "$IDENTITY" "$@"; }
sign --identifier "$BUNDLE_ID.opencode" --entitlements "$ENTITLEMENTS/opencode.entitlements" "$CONTENTS/Helpers/opencode"
sign --identifier "$BUNDLE_ID.exec" "$CONTENTS/Helpers/bellocode-exec"
sign --identifier "$BUNDLE_ID.rg" "$CONTENTS/Helpers/rg"
sign --entitlements "$ENTITLEMENTS/BelloCode.entitlements" "$APP"

codesign --verify --deep --strict --verbose=1 "$APP"
say "built $(du -sh "$APP" | awk '{print $1}') ${APP#"$ROOT"/} ($CONFIG, version $APP_VERSION build $BUILD_NUMBER, opencode $OPENCODE_VERSION)"
