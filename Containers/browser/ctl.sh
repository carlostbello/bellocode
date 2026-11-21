#!/bin/sh
# BelloCode's control commands for the shared browser (run with `docker exec`; never given to an agent).
#   status          one JSON line: sandbox, relay, extension, CA count, Chromium restarts, profile and download bytes
#   verify-sandbox  waits for a renderer and checks it runs in its own PID namespace under seccomp-BPF; records ok|failed
#   vnc-password    reads the per-launch VNC password from stdin (never argv) into the VncAuth password file
#   downloads       one JSON line per file in /data/downloads (name, bytes, mtime)
#   download NAME   writes that file (≤ 256 MiB, plain file only) to stdout
set -eu
RUN=/tmp/bellocode
cmd=${1:-status}
case "$cmd" in
status)
  sandbox=$(cat "$RUN/sandbox" 2>/dev/null || echo pending)
  relay=down; ext=disconnected; paired=false
  if out=$(browse status 2>/dev/null); then
    relay=up
    echo "$out" | grep -q '^Extension: connected' && ext=connected
    echo "$out" | grep -qi 'paired' && paired=true
  fi
  [ "$ext" = connected ] && paired=true
  ca=$(cat "$RUN/ca-count" 2>/dev/null || echo 0)
  restarts=$(cat "$RUN/chromium-restarts" 2>/dev/null || echo 0)
  prof=$(du -sb /data 2>/dev/null | cut -f1); dl=$(du -sb /data/downloads 2>/dev/null | cut -f1)
  cache=$(du -sb /tmp/cache 2>/dev/null | cut -f1)
  chrome=$(chromium --version 2>/dev/null | tr -d '\n' | sed 's/"//g')
  bv=$(browse --version 2>/dev/null | head -1 | tr -d '\n' | sed 's/"//g')
  printf '{"sandbox":"%s","relay":"%s","extension":"%s","paired":%s,"caCount":%s,"chromiumRestarts":%s,"profileBytes":%s,"downloadBytes":%s,"cacheBytes":%s,"extensionID":"%s","chromium":"%s","browse":"%s"}\n' \
    "$sandbox" "$relay" "$ext" "$paired" "${ca:-0}" "${restarts:-0}" "${prof:-0}" "${dl:-0}" "${cache:-0}" "$(cat /opt/browse-crx/id)" "$chrome" "$bv"
  ;;
verify-sandbox)
  i=0
  while [ "$i" -lt 400 ]; do
    for d in /proc/[0-9]*; do
      grep -qa -- '--type=renderer' "$d/cmdline" 2>/dev/null || continue
      nspid=$(sed -n 's/^NSpid:[[:space:]]*//p' "$d/status" 2>/dev/null | wc -w)
      sec=$(sed -n 's/^Seccomp:[[:space:]]*//p' "$d/status" 2>/dev/null)
      if [ "${nspid:-0}" -ge 2 ] && [ "$sec" = 2 ]; then echo ok >"$RUN/sandbox"; echo ok; exit 0; fi
      echo failed >"$RUN/sandbox"; echo "failed: renderer pid-namespace depth $nspid, seccomp $sec"; exit 1
    done
    i=$((i + 1)); sleep 0.05
  done
  echo failed >"$RUN/sandbox"; echo "failed: no renderer appeared"; exit 1
  ;;
vnc-password)
  umask 077
  IFS= read -r pw
  printf '%s\n' "$pw" | vncpasswd -f >"$RUN/vncpass.new" && mv "$RUN/vncpass.new" "$RUN/vncpass"
  echo ok
  ;;
downloads)
  # JSON-encoded by Python (a name may hold quotes, backslashes or control characters); names that are not UTF-8 are
  # skipped, as are links and partial downloads.
  python3 -I -c '
import json, os, stat, sys
d = "/data/downloads"
try:
    names = os.listdir(d)
except OSError:
    sys.exit(0)
for n in sorted(names):
    if n.endswith(".crdownload"):
        continue
    try:
        n.encode("utf-8")
        st = os.lstat(os.path.join(d, n))
    except (UnicodeEncodeError, OSError):
        continue
    if not stat.S_ISREG(st.st_mode):
        continue
    print(json.dumps({"name": n, "bytes": st.st_size, "mtime": int(st.st_mtime)}, ensure_ascii=False))
' 2>/dev/null
  ;;
download)
  name=${2:?name}
  case "$name" in */*|.*) echo "bad name" >&2; exit 2 ;; esac
  f="/data/downloads/$name"
  [ -f "$f" ] && [ ! -L "$f" ] || { echo "no such download" >&2; exit 3; }
  [ "$(stat -c %s "$f")" -le 268435456 ] || { echo "too large" >&2; exit 4; }
  cat "$f"
  ;;
*) echo "unknown command" >&2; exit 2 ;;
esac
