#!/bin/sh
# G7 spike entrypoint: X/VNC server, noVNC, browse relay, one-time pairing through the extension's setup page,
# then Chromium (restarted if it exits). Every child is ours; tini reaps and forwards signals.
set -eu
W=${BELLOCODE_SCREEN_W:-1280} H=${BELLOCODE_SCREEN_H:-800}
VIEW_BIND=${BELLOCODE_VIEW_BIND:-127.0.0.1}
mkdir -p /data/profile /data/downloads /data/xdg "$HOME/.pki/nssdb" /tmp/bellocode
log() { printf '%s %s\n' "$(date +%T.%3N)" "$*"; }
t0=$(date +%s%3N)

# 1. Company CA: PEM files mounted read-only at /etc/bellocode/ca go into Chromium's NSS database (rebuilt each start).
[ -f "$HOME/.pki/nssdb/cert9.db" ] || certutil -N --empty-password -d "sql:$HOME/.pki/nssdb" </dev/null
for pem in /etc/bellocode/ca/*.pem /etc/bellocode/ca/*.crt; do
  [ -f "$pem" ] || continue
  certutil -A -d "sql:$HOME/.pki/nssdb" -n "bellocode-$(basename "$pem")" -t "C,," -i "$pem" && log "ca imported $(basename "$pem")"
done

# 2. Display + VNC (loopback only inside the container) + noVNC (websockify) for the live view.
SEC="-SecurityTypes None"
if [ -n "${BELLOCODE_VNC_PASSWORD:-}" ]; then
  printf '%s\n' "$BELLOCODE_VNC_PASSWORD" | vncpasswd -f > /tmp/bellocode/vncpass; chmod 600 /tmp/bellocode/vncpass
  SEC="-SecurityTypes VncAuth -PasswordFile /tmp/bellocode/vncpass"
fi
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1   # left by a previous run of this container
# shellcheck disable=SC2086
Xvnc :1 -geometry "${W}x${H}" -depth 24 -localhost yes -rfbport 5900 -AlwaysShared -AcceptSetDesktopSize=0 $SEC \
  -SendCutText=1 -AcceptCutText=1 >/tmp/bellocode/xvnc.log 2>&1 &
websockify --web /usr/share/novnc "$VIEW_BIND:6080" 127.0.0.1:5900 >/tmp/bellocode/websockify.log 2>&1 &
until [ -S /tmp/.X11-unix/X1 ]; do sleep 0.05; done
log "display ready +$(( $(date +%s%3N) - t0 ))ms"

# 3. browse relay (127.0.0.1:19988, HTTP API loopback only), accepting the policy-installed extension's origin.
#    Auto-update is off (the image is pinned; browse still checks hourly).
EXT_ID=$(cat /opt/browse-crx/id)
export OPENCODE_BROWSER_EXTENSION_ORIGINS="chrome-extension://$EXT_ID"
browse serve >/tmp/bellocode/relay.out 2>&1 &
until curl -s -o /dev/null "http://127.0.0.1:19988/"; do sleep 0.05; done
log "relay ready +$(( $(date +%s%3N) - t0 ))ms"

# 4. Pairing, without a person: when no browser is paired with this relay yet, mint a one-time code and open the
#    extension's own setup page with it in the fragment (what `browse install` does on a desktop). The key it gets is
#    kept in the profile (extension storage) and the relay's data, both in /data, so later starts are already paired.
#    The link is opened in the running Chromium only once policy has installed the extension (opened earlier, the
#    page does not exist yet and the code is never spent).
START=${BELLOCODE_START_URL:-about:blank}
if browse pair --list 2>/dev/null | grep -q '^No paired browsers'; then
  code=$(browse pair --wait-seconds 1 2>/dev/null | sed -n 's/^Pairing code: //p' | tr -d '-')
  (
    until [ -f "/data/profile/Default/Extensions/$EXT_ID/"*/manifest.json ] 2>/dev/null; do sleep 0.1; done
    sleep 0.5
    chromium --user-data-dir=/data/profile "chrome-extension://$EXT_ID/welcome.html#code=$code" >/dev/null 2>&1
    log "pairing: one-time code handed to the extension's setup page +$(( $(date +%s%3N) - t0 ))ms"
  ) &
else
  log "pairing: already paired"
fi

# 5. Chromium, headful on :1. Extra flags (e.g. --remote-debugging-port for the screencast experiment) via BELLOCODE_CHROMIUM_FLAGS.
# One container owns this profile; a lock left by a previous container (other hostname) is stale.
rm -f /data/profile/SingletonLock /data/profile/SingletonSocket /data/profile/SingletonCookie
SANDBOX=""; [ "${BELLOCODE_NO_SANDBOX:-0}" = 1 ] && SANDBOX="--no-sandbox"
while :; do
  # shellcheck disable=SC2086
  chromium --user-data-dir=/data/profile --no-first-run --no-default-browser-check \
    --password-store=basic --ozone-platform=x11 --window-position=0,0 --window-size="$W,$H" --start-maximized \
    --disable-dev-shm-usage $SANDBOX ${BELLOCODE_CHROMIUM_FLAGS:-} "$START" \
    >>/tmp/bellocode/chromium.log 2>&1 || true
  log "chromium exited; restarting"; sleep 1
done
