#!/bin/sh
# Starts the G7 browser container the way BelloCode would (no capabilities, no-new-privileges, derived seccomp
# profile, limits, named profile volume), publishing noVNC on host loopback only for the spike's measurements
# (production: nothing published; BelloCode's exec-relay forwarder). Prints ms from `docker run` to "extension paired
# and connected". Usage: run.sh [volume] [extra docker args...]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
vol=${1:-bellocode-g7-profile}; [ $# -gt 0 ] && shift
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
t0=$(ms)
docker run -d --name bellocode-g7-browser --label bellocode.spike=g7 --network bellocode-g7-net --shm-size=1g \
  -v "$vol":/data -e BELLOCODE_VIEW_BIND=0.0.0.0 -p 127.0.0.1:16080:6080 \
  --cap-drop ALL --security-opt no-new-privileges --security-opt "seccomp=$here/seccomp-chromium.json" \
  --memory 2g --cpus 2 --pids-limit 1024 "$@" bellocode-g7-browser:spike >/dev/null
until docker exec bellocode-g7-browser browse status 2>/dev/null | grep -q '^Extension: connected'; do
  [ $(( $(ms) - t0 )) -gt 90000 ] && { echo "not connected after 90 s"; exit 1; }
  sleep 0.1
done
echo "connected $(( $(ms) - t0 )) ms after docker run"
