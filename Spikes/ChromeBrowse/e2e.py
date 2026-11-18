#!/usr/bin/env python3 -I
"""G7 end to end: a sandboxed opencode 2.3.0 (temporary XDG dirs, never the user's config) registers the containerised
browse as a project MCP server (`docker exec -i <container> browse mcp`, the stand-in for
`bellocode-exec --stdio --service browser -- browse mcp`), then runs short prompts on a zero-cost model and records
every tool call and result to docs/spikes/G7/e2e-*.json.

Usage: e2e.py <opencode binary> <container> <fixture url> <out dir> [public url]
"""
import urllib.parse, base64, json, os, secrets, shutil, socket, subprocess, sys, tempfile, time, urllib.request

binary, container, fixture, out = sys.argv[1:5]
public = sys.argv[5] if len(sys.argv) > 5 else None
docker = os.path.expanduser("~/.rd/bin/docker")
root = tempfile.mkdtemp(prefix="g7-opencode-")
work = os.path.join(root, "work"); os.makedirs(work)
password = secrets.token_urlsafe(24)
with socket.socket() as s:
    s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
env = {
    "HOME": os.path.join(root, "home"), "XDG_CONFIG_HOME": os.path.join(root, "config"),
    "XDG_DATA_HOME": os.path.join(root, "data"), "XDG_STATE_HOME": os.path.join(root, "state"),
    "XDG_CACHE_HOME": os.path.join(root, "cache"), "TMPDIR": root, "PATH": "/usr/bin:/bin",
    "OPENCODE_PASSWORD": password, "OPENCODE_CLIENT": "bellocode-g7", "OPENCODE_DISABLE_AUTOUPDATE": "1",
    "OPENCODE_DISABLE_CLAUDE_CODE": "1",
}
for k in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME"):
    os.makedirs(env[k], exist_ok=True)
server = subprocess.Popen([binary, "serve", "--hostname", "127.0.0.1", "--port", str(port)], env=env,
                          stdout=open(os.path.join(root, "server.log"), "w"), stderr=subprocess.STDOUT)
auth = "Basic " + base64.b64encode(f"opencode:{password}".encode()).decode()
base = f"http://127.0.0.1:{port}/"


def call(method, path, body=None, timeout=60):
    req = urllib.request.Request(base + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": auth, "Content-Type": "application/json",
                                          "x-opencode-directory": work})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


record = {"opencode": binary, "container": container, "fixture": fixture, "prompts": []}
try:
    for _ in range(200):
        try:
            call("GET", "api/model"); break
        except Exception:
            time.sleep(0.1)
    models = call("GET", "api/model")["data"]
    def free(m):
        costs = m.get("cost") or []
        return costs and all(all((v or 0) == 0 for v in c.values() if not isinstance(v, dict)) for c in costs)
    cands = [m for m in models if free(m) and m.get("enabled") is not False]
    model = next((m for m in cands if m["id"] == os.environ.get("E2E_MODEL", "big-pickle")), cands[0])
    record["model"] = f'{model["providerID"]}/{model["id"]}'
    print("model", record["model"])

    # Project MCP server, scoped to this location (as MCPRouting does), command run through the docker CLI.
    t = time.time()
    cfg = {"type": "local", "command": [docker, "exec", "-i", container, "browse-mcp"],
           "environment": {"DOCKER_HOST": "unix://" + os.path.expanduser("~/.rd/docker.sock")}}
    call("PUT", f"api/experimental/mcp/browse?location[directory]={urllib.parse.quote(work)}", {"config": cfg})
    status = None
    for _ in range(300):
        servers = call("GET", f"api/mcp?location[directory]={urllib.parse.quote(work)}")
        status = json.dumps(servers)
        if '"connected"' in status: break
        time.sleep(0.1)
    record["mcp_register_ms"] = int((time.time() - t) * 1000)
    record["mcp_status"] = json.loads(status)
    print("mcp", record["mcp_register_ms"], "ms", status[:300])

    sess = call("POST", "api/session", {"title": "G7 browse", "location": {"directory": work},
                                        "model": {"id": model["id"], "providerID": model["providerID"]}})["data"]["id"]
    prompts = [
        f"Use the browse tools (not bash). Navigate to {fixture}/index.html, take a snapshot, fill the form "
        "(Full name: Ada Lovelace, Email: ada@example.com, Plan: Pro, accept the terms), click Create account, then take a "
        "screenshot and reply with the exact confirmation text shown under the form.",
    ]
    if public:
        prompts.append(f"Use the browse tools. Navigate to {public} in a new tab, take a snapshot and reply with the "
                       "page's main heading only.")
    for text in prompts:
        t = time.time()
        call("POST", f"api/session/{sess}/prompt", {"text": text})
        try:
            call("POST", f"api/experimental/session/{sess}/wait", timeout=420)
        except Exception as e:
            print("wait:", e)
        record["prompts"].append({"text": text, "seconds": round(time.time() - t, 1)})
    msgs = list(reversed(call("GET", f"api/session/{sess}/message")["data"]))
    record["tool_calls"], record["replies"] = [], []
    for m in msgs:
        for c in m.get("content") or []:
            if c.get("type") == "tool":
                st = c.get("state", {})
                result = " ".join(x.get("text", "") if x.get("type") == "text" else f"[{x.get('type')}]"
                                  for x in st.get("content") or [])
                record["tool_calls"].append({"tool": c["name"], "status": st.get("status"),
                                             "code": str(st.get("input", {}).get("code", st.get("input")))[:600],
                                             "result": result[:700]})
            elif c.get("type") == "text":
                record["replies"].append(c["text"])
finally:
    server.terminate()
    try: server.wait(10)
    except Exception: server.kill()
    with open(os.path.join(out, "e2e-tool-calls.json"), "w") as f:
        json.dump(record, f, indent=1, default=str)
    shutil.rmtree(root, ignore_errors=True)
print("written", os.path.join(out, "e2e-tool-calls.json"))
