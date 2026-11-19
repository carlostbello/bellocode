#!/bin/bash
# Regression gate for the shared browser image (docs/features/shared-browser.md "Upgrade gate"), like
# `make opencode-verify`: builds Containers/browser (or a candidate folder) with a throwaway packing key, runs it with the
# production hardening on Rancher Desktop, and checks: sandbox, policy-installed extension + automatic pairing, the
# MCP tool schema against Contracts/browse-<version>/tools.json, a test CA trusted through NSS, a sign-in cookie set just
# before an orderly stop surviving it. Report: build/browser-verify/<hash>/REPORT.md. Leaves nothing behind but the
# report (and, with KEEP_IMAGE=1, the candidate image). Usage: Scripts/browser-verify.sh [context-dir]
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
ctx=${1:-$here/Containers/browser}
docker=$HOME/.rd/bin/docker
[[ -x "$docker" ]] || { echo "browser-verify: Rancher Desktop's docker not found at $docker"; exit 2; }
export DOCKER_HOST=unix://$HOME/.rd/docker.sock
run_id=bcverify-$$-$RANDOM
label=app.bellocode.test=browser-verify
work=$(mktemp -d); chmod 700 "$work"
tag=bellocode-browser-verify:$run_id
cleanup() {
  "$docker" rm -f "$run_id" >/dev/null 2>&1 || true
  "$docker" volume rm "$run_id" >/dev/null 2>&1 || true
  [[ "${KEEP_IMAGE:-0}" == 1 ]] || "$docker" rmi "$tag" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
hash=$(cd "$ctx" && cat Dockerfile entrypoint.sh ctl.sh browse-mcp policy.json view.html versions.env seccomp-chromium.json | shasum -a 256 | cut -c1-16)
out=$here/build/browser-verify/$hash; mkdir -p "$out"; report=$out/REPORT.md
browse_version=$(sed -n 's/^BROWSE_VERSION=//p' "$ctx/versions.env")
chromium_version=$(sed -n 's/^CHROMIUM_VERSION=//p' "$ctx/versions.env")
pass=0; fail=0
check() { if [[ "$2" == ok ]]; then pass=$((pass + 1)); echo "- PASS $1 ${3:-}" >>"$report"; else fail=$((fail + 1)); echo "- FAIL $1 ${3:-}" >>"$report"; fi; }
{ echo "# browser-verify $hash"; echo; echo "Chromium $chromium_version, browse $browse_version, $(date -u +%FT%TZ)"; echo; } >"$report"

# 1. Build with a throwaway key (the gate needs no stable ID).
args=(); while IFS='=' read -r k v; do [[ -z "$k" || "$k" == \#* ]] && continue; args+=(--build-arg "$k=$v"); done <"$ctx/versions.env"
umask 077; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/k.pem" 2>/dev/null
t=$(ms)
if BELLOCODE_BROWSER_EXTENSION_KEY="$(cat "$work/k.pem")" "$docker" buildx build --load --progress=plain "${args[@]}" \
    --secret id=extkey,env=BELLOCODE_BROWSER_EXTENSION_KEY --label "$label" -t "$tag" "$ctx" >"$out/build.log" 2>&1; then
  check build ok "($(( ($(ms) - t) / 1000 )) s)"
else
  check build fail "(see build.log)"; echo "$report"; exit 1
fi
rm -f "$work/k.pem"
size=$("$docker" image inspect "$tag" --format '{{.Size}}'); echo "- image size $((size / 1000000)) MB" >>"$report"
"$docker" run --rm --entrypoint /bin/sh "$tag" -c 'command -v node >/dev/null && echo has-node || echo no-node' | grep -q no-node && check "no Node in the image" ok || check "no Node in the image" fail

# 2. Test CA: a CA certificate the browser must trust, mounted like the company bundle.
mkdir -p "$work/certs"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca.key" -out "$work/certs/enterprise-roots.pem" -days 2 -subj "/CN=BelloCode verify CA" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "$work/site.key" -out "$work/site.csr" -subj "/CN=fixture.test" >/dev/null 2>&1
printf 'subjectAltName=DNS:fixture.test\nbasicConstraints=CA:FALSE\n' >"$work/ext.cnf"
openssl x509 -req -in "$work/site.csr" -CA "$work/certs/enterprise-roots.pem" -CAkey "$work/ca.key" -CAcreateserial -out "$work/site.pem" -days 2 -extfile "$work/ext.cnf" >/dev/null 2>&1
mkdir -p "$work/site"; mv "$work/site.pem" "$work/site.key" "$work/site/"
chmod 755 "$work" "$work/certs" "$work/site"; chmod 644 "$work/certs/enterprise-roots.pem" "$work/site/site.pem" "$work/site/site.key"

# 3. Run hardened (the production settings), no network at all.
"$docker" volume create --label "$label" "$run_id" >/dev/null
t=$(ms)
"$docker" run -d --name "$run_id" --label "$label" --network none --shm-size=1g -v "$run_id:/data" \
  -v "$work/certs:/etc/bellocode/certs:ro" -v "$work/site:/etc/bellocode/verify:ro" --read-only --tmpfs /tmp:rw,nosuid,nodev,size=512m \
  --cap-drop ALL --security-opt no-new-privileges --security-opt "seccomp=$ctx/seccomp-chromium.json" \
  --memory 2g --cpus 2 --pids-limit 1024 --add-host fixture.test:127.0.0.1 "$tag" >/dev/null
ok=fail; for _ in $(seq 1 600); do "$docker" exec "$run_id" browse status 2>/dev/null | grep -q '^Extension: connected' && { ok=ok; break; }; sleep 0.1; done
check "extension installed by policy and paired automatically" $ok "($(( $(ms) - t )) ms from docker run)"
st=$("$docker" exec "$run_id" bellocode-browser-ctl status)
echo "$st" | grep -q '"sandbox":"ok"' && check "Chromium namespace sandbox + seccomp-BPF in renderers" ok || check "Chromium sandbox" fail "$st"
echo "$st" | grep -q '"caCount":1' && check "test CA imported into NSS" ok || check "test CA imported" fail "$st"

# 4. MCP schema against the contract.
"$docker" exec -i "$run_id" python3 - '[["__list",{}]]' <"$here/Scripts/browser_mcp.py" >"$out/tools.json"
contract=$here/Contracts/browse-$browse_version/tools.json
if [[ -f "$contract" ]] && python3 -I -c 'import json,sys;a=json.load(open(sys.argv[1]));b=json.load(open(sys.argv[2]));sys.exit(0 if sorted(a,key=lambda t:t["name"])==sorted(b,key=lambda t:t["name"]) else 1)' "$out/tools.json" "$contract"; then
  check "MCP tools/list matches Contracts/browse-$browse_version" ok
else
  check "MCP tools/list matches the contract" fail "(diff $out/tools.json against $contract; a new browse needs a new contract folder and a review of the broker)"
fi

# 5. TLS with the test CA, and a cookie set immediately before an orderly stop.
"$docker" exec -d "$run_id" python3 -I -c '
import http.server,ssl
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.send_header("Content-Type","text/html")
        if s.path.startswith("/set"): s.send_header("Set-Cookie","bcverify=signed-in; Max-Age=86400; Path=/; Secure")
        s.end_headers(); s.wfile.write(b"<h1>verify fixture</h1>")
    def log_message(s,*a): pass
srv=http.server.HTTPServer(("127.0.0.1",8443),H)
c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain("/etc/bellocode/verify/site.pem","/etc/bellocode/verify/site.key")
srv.socket=c.wrap_socket(srv.socket,server_side=True); srv.serve_forever()' 2>/dev/null || true
sleep 0.5
r=$("$docker" exec -i "$run_id" python3 - '[["tabs",{"action":"new","id":"bc-verify","group":"bc-verify","url":"https://fixture.test:8443/set"}],["eval",{"tab":"bc-verify","expression":"() => document.title + \"|\" + document.body.innerText + \"|\" + document.cookie"}]]' <"$here/Scripts/browser_mcp.py" || true)
echo "$r" | grep -q 'verify fixture' && check "HTTPS page signed by the test CA loads" ok || check "HTTPS page signed by the test CA" fail "$(echo "$r" | tail -1 | cut -c1-300)"
t=$(ms); "$docker" stop -t 30 "$run_id" >/dev/null; echo "- orderly stop $(( $(ms) - t )) ms" >>"$report"
"$docker" start "$run_id" >/dev/null
for _ in $(seq 1 300); do "$docker" exec "$run_id" browse status 2>/dev/null | grep -q '^Extension: connected' && break; sleep 0.1; done
"$docker" exec -d "$run_id" python3 -I -c '
import http.server,ssl
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.send_header("Content-Type","text/html"); s.end_headers(); s.wfile.write(b"<h1>verify fixture</h1>")
    def log_message(s,*a): pass
srv=http.server.HTTPServer(("127.0.0.1",8443),H)
c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.load_cert_chain("/etc/bellocode/verify/site.pem","/etc/bellocode/verify/site.key")
srv.socket=c.wrap_socket(srv.socket,server_side=True); srv.serve_forever()' 2>/dev/null || true
sleep 0.5
r=$("$docker" exec -i "$run_id" python3 - '[["tabs",{"action":"new","id":"bc-verify-2","group":"bc-verify","url":"https://fixture.test:8443/"}],["eval",{"tab":"bc-verify-2","expression":"() => document.cookie"}]]' <"$here/Scripts/browser_mcp.py" || true)
echo "$r" | grep -q 'bcverify=signed-in' && check "sign-in cookie set just before an orderly stop survives it" ok || check "sign-in cookie survives stop" fail "$(echo "$r" | tail -1 | cut -c1-300)"

{ echo; echo "**$pass passed, $fail failed.**"; } >>"$report"
cat "$report"
[[ "$fail" == 0 ]]
