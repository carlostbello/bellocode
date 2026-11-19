# A tiny MCP client for `make browser-verify`: runs INSIDE the browser container (`docker exec -i … python3 - '<calls>'`
# with this file on stdin), starts `browse-mcp` there and makes the calls. Never run on the Mac.
# usage: python3 - '[["tool", {args}], ["__list", {}]]'
import json, subprocess, sys, os
calls = json.loads(sys.argv[1])
p = subprocess.Popen(["browse-mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
def rpc(i, method, params):
    p.stdin.write(json.dumps({"jsonrpc":"2.0","id":i,"method":method,"params":params})+"\n"); p.stdin.flush()
    while True:
        line = p.stdout.readline()
        if not line: return None
        m = json.loads(line)
        if m.get("id") == i: return m
rpc(1, "initialize", {"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":os.environ.get("CLIENT","opencode"),"version":"1"}})
p.stdin.write(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized"})+"\n"); p.stdin.flush()
i = 10
for tool, args in calls:
    i += 1
    if tool == "__list":
        r = rpc(i, "tools/list", {})
        print(json.dumps(r["result"]["tools"]))
        continue
    r = rpc(i, "tools/call", {"name": tool, "arguments": args})
    res = r.get("result", r)
    out = [c.get("text", "[%s]" % c.get("type")) for c in res.get("content", [])] if isinstance(res, dict) else res
    print(json.dumps({"tool": tool, "isError": res.get("isError"), "out": out})[:1500])
p.stdin.close(); p.wait(timeout=10)
