#!/usr/bin/env bash
# Fetch the pinned opencode binary (and a ripgrep for bundling) into the git-ignored Vendor/ directory.
#
#   Scripts/fetch-opencode.sh           download the official release archive, verify SHA-256, extract
#   Scripts/fetch-opencode.sh --local   skip the download; copy the locally installed opencode if it matches the pin
#
# The version is pinned in Scripts/opencode-version and checksums live in Scripts/opencode-checksums.
# If the download fails, the script falls back to the local `opencode` when, and only when, its version equals the
# pin and its binary SHA-256 matches the recorded one. Verified archives are cached in
# ~/Library/Caches/BelloCode/downloads so parallel checkouts download once. Safe to run repeatedly.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/Scripts/opencode-version")"
DEST="$ROOT/Vendor/opencode/$VERSION"
BIN="$DEST/opencode"
RG_DEST="$ROOT/Vendor/ripgrep/rg"
CACHE="${BELLOCODE_DOWNLOAD_CACHE:-$HOME/Library/Caches/BelloCode/downloads}"

mode="download"
case "${1:-}" in
  "") ;;
  --local) mode="local" ;;
  *) echo "usage: $0 [--local]" >&2; exit 2 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say() { echo "fetch-opencode: $*"; }
warn() { echo "fetch-opencode: warning: $*" >&2; }
die() { echo "fetch-opencode: error: $*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

case "$(uname -m)" in
  arm64) PLATFORM="darwin-arm64" ;;
  x86_64) PLATFORM="darwin-x64-baseline" ;;
  *) die "unsupported architecture $(uname -m)" ;;
esac

read -r ARCHIVE_SHA BINARY_SHA < <(
  awk -v v="$VERSION" -v p="$PLATFORM" '!/^#/ && $1 == v && $2 == p { print $3, $4 }' "$ROOT/Scripts/opencode-checksums"
) || true
[[ -n "${ARCHIVE_SHA:-}" ]] || die "no checksum for opencode $VERSION $PLATFORM in Scripts/opencode-checksums"
[[ "${BINARY_SHA:-}" == "-" ]] && BINARY_SHA=""

binary_ok() {
  [[ -x "$1" ]] || return 1
  [[ -z "$BINARY_SHA" ]] || [[ "$(sha256 "$1")" == "$BINARY_SHA" ]]
}

install_binary() { # source
  mkdir -p "$DEST"
  cp -f "$1" "$BIN.partial"
  chmod 755 "$BIN.partial"
  mv -f "$BIN.partial" "$BIN"
}

fetch_release() {
  local url="https://opencode.ai/files/bin/$VERSION/opencode-$PLATFORM.zip"
  local archive="$CACHE/opencode-$VERSION-$PLATFORM.zip"
  mkdir -p "$CACHE"
  if [[ -f "$archive" && "$(sha256 "$archive")" == "$ARCHIVE_SHA" ]]; then
    say "using cached archive $archive"
  else
    say "downloading $url"
    curl -fL --retry 3 --connect-timeout 20 --progress-bar -o "$archive.partial" "$url" || return 1
    local got
    got="$(sha256 "$archive.partial")"
    if [[ "$got" != "$ARCHIVE_SHA" ]]; then
      rm -f "$archive.partial"
      warn "archive SHA-256 mismatch: expected $ARCHIVE_SHA, got $got"
      return 1
    fi
    mv -f "$archive.partial" "$archive"
  fi
  local extract="$WORK/extract"
  rm -rf "$extract" && mkdir -p "$extract"
  ditto -x -k "$archive" "$extract" || return 1
  [[ -f "$extract/opencode" ]] || { warn "archive has no top-level opencode binary"; return 1; }
  chmod 755 "$extract/opencode"
  binary_ok "$extract/opencode" || { warn "extracted binary SHA-256 does not match the recorded one"; return 1; }
  install_binary "$extract/opencode"
  say "installed opencode $VERSION from the release archive (archive SHA-256 verified)"
}

copy_local() {
  local local_bin reported
  local_bin="$(command -v opencode || true)"
  [[ -n "$local_bin" ]] || { warn "no local opencode on PATH"; return 1; }
  reported="$("$local_bin" --version 2>/dev/null | head -n 1 | sed -E 's/^opencode[[:space:]]+//; s/^v//')"
  if [[ "$reported" != "$VERSION" ]]; then
    warn "local opencode reports '$reported', pin is $VERSION; not using it"
    return 1
  fi
  local resolved
  resolved="$(realpath "$local_bin")"
  binary_ok "$resolved" || { warn "local opencode SHA-256 $(sha256 "$resolved") does not match the recorded one"; return 1; }
  install_binary "$resolved"
  say "installed opencode $VERSION copied from $resolved (SHA-256 $(sha256 "$BIN"))"
}

# opencode
if binary_ok "$BIN"; then
  say "opencode $VERSION already present at ${BIN#"$ROOT"/}"
else
  if [[ "$mode" == "download" ]]; then
    fetch_release || { warn "release download failed; trying the local opencode"; copy_local; } \
      || die "could not obtain opencode $VERSION"
  else
    copy_local || die "could not obtain opencode $VERSION from the local install"
  fi
fi

# ripgrep (optional): opencode looks for rg on PATH and would otherwise download one at runtime.
rg_source="$(command -v rg || true)"
if [[ -z "$rg_source" ]]; then
  warn "no local rg found; the bundle will ship without ripgrep"
else
  rg_source="$(realpath "$rg_source")"
  if [[ -f "$RG_DEST" ]] && cmp -s "$rg_source" "$RG_DEST"; then
    say "ripgrep already present at ${RG_DEST#"$ROOT"/}"
  else
    mkdir -p "$(dirname "$RG_DEST")"
    cp -f "$rg_source" "$RG_DEST"
    chmod 755 "$RG_DEST"
    say "copied ripgrep from $rg_source"
  fi
  # A Homebrew rg links Homebrew's libpcre2, so the bundled copy only runs where that library exists.
  nonsystem="$(otool -L "$RG_DEST" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/)' || true)"
  if [[ -n "$nonsystem" ]]; then
    warn "bundled rg links non-system libraries and is not portable to other Macs: $(echo "$nonsystem" | tr '\n' ' ')"
  fi
fi

say "done"
