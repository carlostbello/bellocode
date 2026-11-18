#!/usr/bin/env bash
# Prepare a candidate opencode release for BelloCode (docs/features/opencode-upgrades.md). Does not change the pin.
#
#   Scripts/opencode-upgrade.sh <version> [--no-prompt]      (make opencode-upgrade VERSION=x.y.z)
#
# 1. Downloads the darwin-arm64 and darwin-x64-baseline archives (cached in ~/Library/Caches/BelloCode/downloads).
# 2. Verifies each archive's SHA-256 against the anomalyco/homebrew-tap `opencode-v2.rb` formula of that version. When
#    the tap has no formula for it, the observed digest is recorded and marked `first-seen` for a human to confirm.
# 3. Records archive and binary digests in Scripts/opencode-checksums and installs Vendor/opencode/<version>/opencode.
# 4. Captures Contracts/opencode-<version>/ from a sandboxed server (Scripts/opencode_contract.py: OpenAPI, one recorded
#    turn on a zero-cost model, built-ins, bridge and plugin versions, permission evaluation, catalog presence).
# 5. Writes Contracts/opencode-<version>/upgrade-diff.json and UPGRADE-DIFF.md against the pinned contract
#    (FROM=x.y.z compares with another captured contract).
#
# Sandboxed: temporary HOME and XDG directories, never ~/.config/opencode or ~/.local/share/opencode; every server
# runs in its own process group and is killed at the end; the script checks that none is left.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <x.y.z> [--no-prompt]" >&2; exit 2; }
shift
PROMPT_FLAG=""
[[ "${1:-}" == "--no-prompt" ]] && PROMPT_FLAG="--no-prompt"
PIN="$(tr -d '[:space:]' < "$ROOT/Scripts/opencode-version")"
FROM="${FROM:-$PIN}"
CACHE="${BELLOCODE_DOWNLOAD_CACHE:-$HOME/Library/Caches/BelloCode/downloads}"
CHECKSUMS="$ROOT/Scripts/opencode-checksums"
CONTRACT="$ROOT/Contracts/opencode-$VERSION"
DEST="$ROOT/Vendor/opencode/$VERSION"

say() { echo "opencode-upgrade: $*"; }
warn() { echo "opencode-upgrade: warning: $*" >&2; }
die() { echo "opencode-upgrade: error: $*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$CACHE"

# Homebrew tap formula for this version: the commit "update opencode-v2 to <version>" (the tap keeps one formula file
# and updates it per release), else the current formula when it is this version.
FORMULA="$WORK/formula.rb"
formula_found=0
tap_api="https://api.github.com/repos/anomalyco/homebrew-tap/commits?path=opencode-v2.rb&per_page=100"
if curl -fsSL --retry 2 --connect-timeout 20 "$tap_api" -o "$WORK/commits.json" 2> /dev/null; then
  sha="$(python3 -I -c 'import json,sys
v=sys.argv[2]
for c in json.load(open(sys.argv[1])):
    m=c["commit"]["message"].splitlines()[0]
    if m.endswith(" to "+v):
        print(c["sha"]); break' "$WORK/commits.json" "$VERSION")"
  if [[ -n "$sha" ]] && curl -fsSL --retry 2 "https://raw.githubusercontent.com/anomalyco/homebrew-tap/$sha/opencode-v2.rb" -o "$FORMULA"; then
    grep -q "version \"$VERSION\"" "$FORMULA" && formula_found=1
  fi
fi
[[ $formula_found == 1 ]] && say "Homebrew tap formula for $VERSION found" || warn "no Homebrew tap formula for $VERSION: digests will be recorded as first-seen"

expected_digest() { # platform
  [[ $formula_found == 1 ]] || return 0
  # url "…/opencode-<platform>.zip" is followed by its sha256 line.
  awk -v p="opencode-$1.zip" 'index($0, p) { getline; gsub(/[" ]/, "", $0); sub(/^sha256/, "", $0); print; exit }' "$FORMULA"
}

HOST_PLATFORM="darwin-arm64"
[[ "$(uname -m)" == "x86_64" ]] && HOST_PLATFORM="darwin-x64-baseline"
lines=()
for platform in darwin-arm64 darwin-x64-baseline; do
  archive="$CACHE/opencode-$VERSION-$platform.zip"
  expected="$(expected_digest "$platform")"
  if [[ ! -f "$archive" || ( -n "$expected" && "$(sha256 "$archive")" != "$expected" ) ]]; then
    dl="$WORK/download-$platform"
    mkdir -p "$dl"
    say "downloading opencode $VERSION $platform"
    curl -fsSL --retry 3 --connect-timeout 20 -o "$dl/archive.zip" \
      "https://opencode.ai/files/bin/$VERSION/opencode-$platform.zip" || die "download failed for $platform"
    mv -f "$dl/archive.zip" "$archive"
  fi
  got="$(sha256 "$archive")"
  source="homebrew"
  if [[ -n "$expected" ]]; then
    [[ "$got" == "$expected" ]] || { rm -f "$archive"; die "$platform archive SHA-256 $got does not match the tap's $expected"; }
    say "$platform archive SHA-256 matches the Homebrew tap"
  else
    source="first-seen"
    warn "$platform archive SHA-256 $got is first-seen (no published digest): confirm it before pinning"
  fi
  extract="$WORK/extract-$platform"
  mkdir -p "$extract"
  ditto -x -k "$archive" "$extract"
  [[ -f "$extract/opencode" ]] || die "$platform archive has no top-level opencode binary"
  binary_sha="$(sha256 "$extract/opencode")"
  lines+=("$(printf '%-10s %-21s %s  %s  %s' "$VERSION" "$platform" "$got" "$binary_sha" "$source")")
  if [[ "$platform" == "$HOST_PLATFORM" ]]; then
    mkdir -p "$DEST"
    cp -f "$extract/opencode" "$DEST/opencode.partial"
    chmod 755 "$DEST/opencode.partial"
    mv -f "$DEST/opencode.partial" "$DEST/opencode"
  fi
done

# Record the digests (replacing any earlier lines for this version).
grep -vE "^$VERSION[[:space:]]" "$CHECKSUMS" > "$WORK/checksums"
printf '%s\n' "${lines[@]}" >> "$WORK/checksums"
cp "$WORK/checksums" "$CHECKSUMS"
say "recorded digests in Scripts/opencode-checksums"

# The binary reports the version it claims (in a throw-away HOME).
SANDBOX="$WORK/sandbox"
mkdir -p "$SANDBOX/home" "$SANDBOX/xdg"
reported="$(env -i HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/xdg/config" XDG_DATA_HOME="$SANDBOX/xdg/data" \
  XDG_STATE_HOME="$SANDBOX/xdg/state" XDG_CACHE_HOME="$SANDBOX/xdg/cache" PATH=/usr/bin:/bin OPENCODE_DISABLE_AUTOUPDATE=1 \
  "$DEST/opencode" --version 2> /dev/null | head -n 1 | sed -E 's/^opencode[[:space:]]+//; s/^v//')"
[[ "$reported" == "$VERSION" ]] || die "Vendor/opencode/$VERSION/opencode reports '$reported'"
say "installed Vendor/opencode/$VERSION/opencode (reports $reported)"

# Contract capture (at most one prompt, zero-cost model) and the diff against the pinned contract.
mkdir -p "$CONTRACT"
python3 -I "$ROOT/Scripts/opencode_contract.py" capture "$DEST/opencode" "$CONTRACT" --plugin "$ROOT/Plugin" \
  --catalog-provider openai --catalog-provider anthropic --catalog-provider google $PROMPT_FLAG
if [[ "$FROM" != "$VERSION" && -d "$ROOT/Contracts/opencode-$FROM" ]]; then
  python3 -I "$ROOT/Scripts/opencode_contract.py" diff "$ROOT/Contracts/opencode-$FROM" "$CONTRACT" \
    --sources "$ROOT/Sources" --out "$WORK/diff"
  cp "$WORK/diff/diff.json" "$CONTRACT/upgrade-diff.json"
  cp "$WORK/diff/DIFF.md" "$CONTRACT/UPGRADE-DIFF.md"
  say "diff against $FROM: Contracts/opencode-$VERSION/UPGRADE-DIFF.md"
fi

# Nothing left running from this binary.
if pgrep -f "$DEST/opencode" > /dev/null; then
  die "an opencode process from Vendor/opencode/$VERSION is still running"
fi
grep -q "first-seen" <<< "$(printf '%s\n' "${lines[@]}")" && warn "first-seen digests need a human to confirm before the pin moves"
say "done. Next: make opencode-verify VERSION=$VERSION"
