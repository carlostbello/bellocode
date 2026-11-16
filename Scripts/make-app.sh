#!/usr/bin/env bash
# Build BelloCode with SwiftPM and assemble an ad-hoc signed build/BelloCode.app.
#
#   Scripts/make-app.sh [debug|release]      (default: debug)
#
# Requires Scripts/fetch-opencode.sh to have run (Vendor/opencode/<pinned version>/opencode).
# Signing is inside-out: helpers first (hardened runtime; opencode with its JIT entitlements), then the app.
# Set BELLOCODE_SIGN_IDENTITY to a Developer ID identity to sign for distribution; the default "-" is ad-hoc.

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
OPENCODE_VERSION="$(tr -d '[:space:]' < "$ROOT/Scripts/opencode-version")"
OPENCODE_BIN="$ROOT/Vendor/opencode/$OPENCODE_VERSION/opencode"
RG_BIN="$ROOT/Vendor/ripgrep/rg"
ENTITLEMENTS="$ROOT/Scripts/entitlements"
APP="$ROOT/build/BelloCode.app"
CONTENTS="$APP/Contents"

[[ -x "$OPENCODE_BIN" ]] || die "missing $OPENCODE_BIN; run Scripts/fetch-opencode.sh first"

cd "$ROOT"
say "swift build -c $CONFIG"
swift build -c "$CONFIG" --product BelloCode
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
[[ -x "$BIN_DIR/BelloCode" ]] || die "swift build produced no executable at $BIN_DIR/BelloCode"

say "assembling ${APP#"$ROOT"/}"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources/opencode-plugin"

cp "$BIN_DIR/BelloCode" "$CONTENTS/MacOS/BelloCode"
cp "$OPENCODE_BIN" "$CONTENTS/Helpers/opencode"
if [[ -x "$RG_BIN" ]]; then
  cp "$RG_BIN" "$CONTENTS/Helpers/rg"
else
  warn "no Vendor/ripgrep/rg; bundling without ripgrep"
fi

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

BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2> /dev/null || echo 1)"
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
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
</dict>
</plist>
EOF
plutil -lint -s "$CONTENTS/Info.plist" || die "invalid Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

say "signing (identity: $IDENTITY)"
TIMESTAMP="--timestamp"
[[ "$IDENTITY" == "-" ]] && TIMESTAMP="--timestamp=none"
sign() { codesign --force "$TIMESTAMP" --options runtime --sign "$IDENTITY" "$@"; }
sign --identifier "$BUNDLE_ID.opencode" --entitlements "$ENTITLEMENTS/opencode.entitlements" "$CONTENTS/Helpers/opencode"
if [[ -f "$CONTENTS/Helpers/rg" ]]; then sign --identifier "$BUNDLE_ID.rg" "$CONTENTS/Helpers/rg"; fi
sign --entitlements "$ENTITLEMENTS/BelloCode.entitlements" "$APP"

codesign --verify --deep --strict --verbose=1 "$APP"
say "built $(du -sh "$APP" | awk '{print $1}') ${APP#"$ROOT"/} ($CONFIG, version $APP_VERSION build $BUILD_NUMBER, opencode $OPENCODE_VERSION)"
