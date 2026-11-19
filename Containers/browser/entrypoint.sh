#!/bin/sh
# BelloCode shared browser entrypoint (docs/features/shared-browser.md). Order: sandbox check, CA trust, display + VNC
# (container loopback only), websockify, browse relay, pairing, Chromium (restarted if it exits on its own). Every child
# is ours; tini reaps them and forwards TERM here. Events go to /tmp/bellocode/events (read by bellocode-browser-ctl).
set -eu
W=${BELLOCODE_SCREEN_W:-1280} H=${BELLOCODE_SCREEN_H:-800}
RUN=/tmp/bellocode
mkdir -p "$RUN" "$HOME" /tmp/cache /data/profile /data/downloads /data/xdg
log() { printf '%s %s\n' "$(date +%s%3N)" "$*" | tee -a "$RUN/events"; }
t0=$(date +%s%3N)
log "start"

# 1. Sandbox. Chromium keeps its namespace sandbox (no --no-sandbox, ever): the container's seccomp profile must allow
#    user namespaces. If it cannot create one, Chromium would not start, so refuse now with a clear reason (exit 78).
if ! unshare --user --map-root-user --pid --fork true 2>/dev/null; then
  log "sandbox unavailable"
  echo "BelloCode: Chromium's sandbox is unavailable in this container (user namespaces refused). Not starting." >&2
  echo unavailable >"$RUN/sandbox"
  exit 78
fi

# 2. Trust: Chromium's NSS database is rebuilt at every start (in tmpfs), so removed certificates disappear too. Every
#    CA in the mounted bundle directory (company roots, BelloCode's egress CA) is imported as a trusted SSL issuer.
rm -rf "$HOME/.pki/nssdb"; mkdir -p "$HOME/.pki/nssdb"
certutil -N --empty-password -d "sql:$HOME/.pki/nssdb" </dev/null
n=0
for pem in /etc/bellocode/certs/enterprise-roots.pem /etc/bellocode/certs/egress-ca.pem /etc/bellocode/ca/*.pem /etc/bellocode/ca/*.crt; do
  [ -f "$pem" ] || continue
  # One certificate per file for certutil.
  rm -rf "$RUN/split"; mkdir -p "$RUN/split"
  awk -v d="$RUN/split" '/-----BEGIN CERTIFICATE-----/{i++} i{print > (d "/c" i ".pem")}' "$pem"
  for c in "$RUN/split"/*.pem; do
    [ -f "$c" ] || continue
    n=$((n + 1))
    certutil -A -d "sql:$HOME/.pki/nssdb" -n "bellocode-$n" -t "C,," -i "$c" 2>/dev/null || log "ca rejected $(basename "$pem")"
  done
done
rm -rf "$RUN/split"
echo "$n" >"$RUN/ca-count"
log "ca imported $n"

# 3. Display + VNC on the container's loopback; damage comparison and a 30 fps cap (review: fewer updates on motion).
#    The VNC password is written by BelloCode at every launch (`bellocode-browser-ctl vnc-password`, from stdin); until
#    then no password file exists and VncAuth refuses everyone.
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
Xvnc :1 -geometry "${W}x${H}" -depth 24 -localhost yes -rfbport 5900 -AlwaysShared -AcceptSetDesktopSize=0 \
  -SecurityTypes VncAuth -PasswordFile "$RUN/vncpass" -FrameRate 30 -CompareFB 2 \
  -SendCutText=1 -AcceptCutText=1 >"$RUN/xvnc.log" 2>&1 &
websockify --web /usr/share/novnc 127.0.0.1:6080 127.0.0.1:5900 >"$RUN/websockify.log" 2>&1 &
until [ -S /tmp/.X11-unix/X1 ]; do sleep 0.05; done
log "display ready +$(( $(date +%s%3N) - t0 ))ms"

# 4. browse relay on 127.0.0.1:19988, accepting only this build's extension. Auto-update off (the image is pinned).
EXT_ID=$(cat /opt/browse-crx/id)
export OPENCODE_BROWSER_EXTENSION_ORIGINS="chrome-extension://$EXT_ID"
browse serve >"$RUN/relay.log" 2>&1 &
until browse status >/dev/null 2>&1; do sleep 0.05; done
log "relay ready +$(( $(date +%s%3N) - t0 ))ms"

# 5. Pairing without a person: once policy installed the extension, if it is not connected as a paired browser within
#    ~1 s, mint a one-time code and open the extension's own setup page with it (browse's install link; its ECDH
#    exchange is unchanged). Pairing state lives in /data, so later starts are already paired.
START=${BELLOCODE_START_URL:-about:blank}
(
  until ls /data/profile/Default/Extensions/"$EXT_ID"/*/manifest.json >/dev/null 2>&1; do sleep 0.1; done
  i=0
  until browse status 2>/dev/null | grep -q '^Extension: connected'; do
    i=$((i + 1))
    if [ "$i" = 10 ] || [ "$i" = 100 ] || [ "$i" = 300 ]; then
      code=$(browse pair --wait-seconds 1 2>/dev/null | sed -n 's/^Pairing code: //p' | tr -d '-')
      chromium --user-data-dir=/data/profile "chrome-extension://$EXT_ID/welcome.html#code=$code" >/dev/null 2>&1 || true
      log "pairing requested"
    fi
    sleep 0.1
  done
  log "extension connected +$(( $(date +%s%3N) - t0 ))ms"
) &

# 6. Chromium, headful on :1, through BelloCode's routing/egress proxy when given (no DIRECT fallback: the container's
#    only network is internal). One container owns the profile: a Singleton lock from a previous container is stale.
rm -f /data/profile/SingletonLock /data/profile/SingletonSocket /data/profile/SingletonCookie
PROXY=""; [ -n "${BELLOCODE_PROXY:-}" ] && PROXY="--proxy-server=$BELLOCODE_PROXY"
# Stop and idle stop: SIGINT makes Chromium close its windows and profile normally, which commits the cookie store
# (SIGTERM is treated as "session ending" and exits without that commit: G7 lost a sign-in that way). Wait for it.
stopping=0; cpid=""
quit() {
  stopping=1
  log "quit requested"
  if [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null; then
    kill -INT "$cpid" 2>/dev/null || true
    i=0
    while kill -0 "$cpid" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
    kill -0 "$cpid" 2>/dev/null && { log "chromium forced"; kill -KILL "$cpid" 2>/dev/null || true; }
  fi
  log "chromium closed"
  [ "$(cat "$RUN/sandbox" 2>/dev/null)" = failed ] && exit 78
  exit 0
}
trap quit TERM INT
restarts=0
while [ "$stopping" = 0 ]; do
  # shellcheck disable=SC2086
  chromium --user-data-dir=/data/profile --no-first-run --no-default-browser-check \
    --password-store=basic --ozone-platform=x11 --window-position=0,0 --window-size="$W,$H" --start-maximized \
    --hide-crash-restore-bubble --disk-cache-dir=/tmp/cache/chromium $PROXY ${BELLOCODE_CHROMIUM_FLAGS:-} "$START" \
    >>"$RUN/chromium.log" 2>&1 &
  cpid=$!
  [ "$restarts" = 0 ] && ( /usr/local/bin/bellocode-browser-ctl verify-sandbox >/dev/null 2>&1 || kill -TERM $$ ) &
  wait "$cpid" || true
  [ "$stopping" = 1 ] && break
  restarts=$((restarts + 1)); echo "$restarts" >"$RUN/chromium-restarts"
  log "chromium exited; restart $restarts"
  [ "$restarts" -gt 5 ] && { log "chromium keeps exiting"; exit 70; }
  sleep 1
done
