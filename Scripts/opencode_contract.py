#!/usr/bin/env python3
"""Capture and compare opencode contracts (docs/features/opencode-upgrades.md).

    opencode_contract.py capture <opencode-binary> <out-dir> --plugin <Plugin dir> [--no-prompt]
    opencode_contract.py diff <old-contract-dir> <new-contract-dir> --sources <Sources dir> --out <dir>

Standard library only; run with `python3 -I`. Every server runs in a fresh temporary sandbox (HOME, XDG_*, TMPDIR and
the project directory), never the user's opencode config or data, in its own process group that is killed at the end.
The capture sends at most ONE model prompt, to a zero-cost built-in model (`opencode/big-pickle` or another model whose
every cost is 0). Nothing printed or written contains a credential: the server password is per run and redacted, and
the only key ever stored is a dummy one used to list a provider's catalog inside the sandbox.
"""

import argparse
import base64
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

PROMPT_MODEL_PREFERENCE = ["big-pickle"]
# Session rule sets BelloCode's permission modes produce (Engine/Sync/Mapping.swift `PermissionModeRules`). The agent's
# own restrictions on governed actions are appended exactly as the app does (`restrictions(of:)`).
MODE_RULES = {
    "none": [],
    "ask": [("edit", "*", "ask"), ("shell", "*", "ask"), ("external_directory", "*", "ask")],
    "autoEdit": [("edit", "*", "allow"), ("shell", "*", "ask"), ("external_directory", "*", "ask")],
    "fullAccess": [("*", "*", "allow")],
}
GOVERNED = ["edit", "shell", "external_directory"]
# (action, resource) pairs the modes and the browser bridge depend on.
PERMISSION_PROBES = [
    ("edit", "src/main.swift"),
    ("edit", "<home>/.opencode/plan/plan.md"),
    ("shell", "ls -la"),
    ("external_directory", "/private/tmp/elsewhere/*"),
    ("read", "README.md"),
    ("read", ".env"),
    ("webfetch", "https://example.com"),
    ("browser", "*"),
    ("skill", "browser"),
    ("subagent", "general"),
]
PROBE_AGENTS = ["build", "plan"]


def log(message):
    print("opencode-contract: " + message, file=sys.stderr, flush=True)


def wildcard(pattern, value):
    rx = "^" + "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in pattern) + "$"
    return re.match(rx, value, re.S) is not None


def restrictions(agent_rules):
    denied, result = [], []
    for rule in agent_rules:
        action, effect = rule.get("action", ""), rule.get("effect", "")
        governed = any(wildcard(action, g) or wildcard(g, action) for g in GOVERNED)
        if not governed:
            continue
        if effect == "deny":
            denied.append(action)
            result.append((action, rule.get("resource", "*"), effect))
        elif any(wildcard(d, action) for d in denied):
            result.append((action, rule.get("resource", "*"), effect))
    return result


class Server:
    """One sandboxed `opencode serve --stdio --port 0`."""

    def __init__(self, binary, config_content=None):
        self.root = tempfile.mkdtemp(prefix="bellocode-contract-")
        self.project = os.path.join(self.root, "project")
        for name in ["home", "config", "data", "state", "cache", "tmp", "project"]:
            os.makedirs(os.path.join(self.root, name))
        self.password = secrets.token_hex(24)
        env = {
            "HOME": os.path.join(self.root, "home"),
            "XDG_CONFIG_HOME": os.path.join(self.root, "config"),
            "XDG_DATA_HOME": os.path.join(self.root, "data"),
            "XDG_STATE_HOME": os.path.join(self.root, "state"),
            "XDG_CACHE_HOME": os.path.join(self.root, "cache"),
            "TMPDIR": os.path.join(self.root, "tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OPENCODE_PASSWORD": self.password,
            "OPENCODE_CLIENT": "bellocode-contract",
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE": "1",
            "OPENCODE_DISABLE_PROJECT_CONFIG": "1",
        }
        if config_content:
            env["OPENCODE_CONFIG_CONTENT"] = json.dumps(config_content)
        self.stderr = open(os.path.join(self.root, "server.log"), "wb")
        self.process = subprocess.Popen(
            [binary, "serve", "--stdio", "--port", "0"], env=env, cwd=self.project, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.stderr, start_new_session=True)
        line = self.process.stdout.readline().decode("utf-8", "replace").strip()
        try:
            ready = json.loads(line)
        except ValueError:
            self.close()
            raise RuntimeError("server printed no ready line")
        self.url = (ready.get("url") or (ready.get("urls") or [""])[0]).rstrip("/")
        self.auth = "Basic " + base64.b64encode(("opencode:" + self.password).encode()).decode()
        # Drain stdout so the child never blocks on a full pipe.
        threading.Thread(target=lambda: self.process.stdout.read(), daemon=True).start()
        self.info = self.get("/api/info")

    def normalize(self, text):
        """Sandbox paths are per run: written as <sandbox> so captures compare."""
        for root in (self.root, os.path.realpath(self.root), "/private" + self.root):
            text = text.replace(root, "<sandbox>")
        return text

    def location(self):
        return "location%5Bdirectory%5D=" + urllib.parse.quote(self.project, safe="")

    def request(self, method, path, body=None, timeout=60, located=True):
        url = self.url + path
        if located:
            url += ("&" if "?" in url else "?") + self.location()
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method, headers={"Authorization": self.auth})
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                return error.code, json.loads(raw)
            except ValueError:
                return error.code, raw.decode("utf-8", "replace")[:500]

    def get(self, path, **kw):
        status, body = self.request("GET", path, **kw)
        if status != 200:
            raise RuntimeError("GET %s -> %s %s" % (path, status, redact(str(body), self.password)[:300]))
        return body

    def warm_list(self, path, attempts=40):
        """A cold location answers empty lists for a few seconds: retry until it has data."""
        body = None
        for _ in range(attempts):
            body = self.get(path)
            items = body.get("data") if isinstance(body, dict) else body
            if items:
                return items
            time.sleep(0.25)
        return (body.get("data") if isinstance(body, dict) else body) or []

    def stable_list(self, path, attempts=20):
        """`warm_list` until two reads half a second apart agree (plugins keep adding to a list as they load)."""
        previous = self.warm_list(path)
        for _ in range(attempts):
            time.sleep(0.5)
            current = self.warm_list(path)
            if current == previous:
                return current
            previous = current
        return previous

    def close(self):
        try:
            if self.process.stdin:
                self.process.stdin.close()
            self.process.wait(timeout=10)
        except Exception:
            pass
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except Exception:
            pass
        self.stderr.close()
        shutil.rmtree(self.root, ignore_errors=True)


def redact(text, password):
    return text.replace(password, "<password>")


class EventRecorder:
    """Records `/api/event` raw bytes on a background thread (one connection)."""

    def __init__(self, server):
        self.server = server
        self.chunks = []
        self.lock = threading.Lock()
        self.text = ""
        self.response = None
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        req = urllib.request.Request(self.server.url + "/api/event", headers={"Authorization": self.server.auth})
        try:
            self.response = urllib.request.urlopen(req, timeout=300)
            while True:
                chunk = self.response.read1(65536) if hasattr(self.response, "read1") else self.response.read(1)
                if not chunk:
                    break
                with self.lock:
                    self.chunks.append(chunk)
                    self.text += chunk.decode("utf-8", "replace")
        except Exception:
            pass

    def frames(self):
        with self.lock:
            text = self.text
        out = []
        for block in re.split(r"\r?\n\r?\n", text):
            data = [line[5:].lstrip(" ") for line in block.splitlines() if line.startswith("data:")]
            if data:
                try:
                    out.append(json.loads("\n".join(data)))
                except ValueError:
                    pass
        return out

    def wait_for(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for frame in self.frames():
                if predicate(frame):
                    return frame
            time.sleep(0.2)
        return None

    def raw(self):
        with self.lock:
            return b"".join(self.chunks)

    def close(self):
        try:
            if self.response:
                self.response.close()
        except Exception:
            pass


def free(model):
    costs = model.get("cost") or []
    if not costs:
        return False
    for cost in costs:
        values = [cost.get("input", 1), cost.get("output", 1)] + list((cost.get("cache") or {}).values())
        if any(v not in (0, 0.0) for v in values):
            return False
    return True


def static_surface(binary):
    """Facts read from the binary's embedded JavaScript (no execution)."""
    out = subprocess.run(["strings", "-n", "6", binary], capture_output=True, check=True).stdout.decode("utf-8", "replace")
    facts = {}
    m = re.search(r'experimental\.browser",methods:\{attach:\{input:[A-Za-z_$]+\(\{\.\.\.[A-Za-z_$]+,version:[A-Za-z_$]+\((\d+)\)', out)
    facts["browserBridgeVersion"] = int(m.group(1)) if m else None
    m = re.search(r'new Set\(\[("shell","glob"[^\]]*)\]\)', out)
    facts["toolRendererNames"] = sorted(json.loads("[" + m.group(1) + "]")) if m else []
    files = sorted({re.sub(r"-[a-z0-9]{8}(\.[a-z]+)$", r"\1", f) for f in re.findall(r"\$bunfs/root/([A-Za-z0-9_.-]+\.(?:txt|md))", out)})
    facts["embeddedPromptFiles"] = files
    return facts


def capture(args):
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)
    binary = os.path.abspath(args.binary)
    surface = {"capturedAt": time.strftime("%Y-%m-%d"), "prompts": 0}
    surface.update(static_surface(binary))

    # 1. Plain server (no BelloCode plugin): OpenAPI, built-in agents, skills, commands, plugins, catalog, permissions.
    server = Server(binary)
    try:
        info = server.info
        surface["version"] = info.get("version")
        surface["capabilities"] = info.get("capabilities")
        status, openapi = server.request("GET", "/openapi.json", located=False)
        if status != 200:
            raise RuntimeError("no /openapi.json")
        with open(os.path.join(out_dir, "openapi.json"), "w") as f:
            json.dump(openapi, f, separators=(",", ":"))
        agents = server.stable_list("/api/agent")
        surface["agents"] = agent_list(server, agents)
        surface["skills"] = sorted(s.get("id") for s in server.warm_list("/api/skill"))
        surface["commands"] = sorted(c.get("name") for c in server.warm_list("/api/command"))
        surface["plugins"] = sorted(p.get("id") or p.get("name") or json.dumps(p, sort_keys=True) for p in (server.get("/api/plugin").get("data") or []))
        models = server.warm_list("/api/model")
        catalog = {"free": sorted("%s/%s" % (m.get("providerID"), m.get("id")) for m in models if free(m))}
        integrations = server.warm_list("/api/integration")
        catalog["integrations"] = len(integrations)
        # Catalog presence for a paid provider: a dummy key is stored inside the sandbox only (the server does not
        # contact the provider on connect/key); no prompt is ever sent to it.
        for provider in args.catalog_provider:
            status, _ = server.request("POST", "/api/integration/%s/connect/key" % provider, {"key": "bellocode-catalog-probe"})
            listed = []
            if status in (200, 204):
                for _ in range(40):
                    body = server.get("/api/model")
                    listed = [m for m in (body if isinstance(body, list) else body.get("data", [])) if m.get("providerID") == provider]
                    if listed:
                        break
                    time.sleep(0.25)
            catalog[provider] = sorted(m.get("id") for m in listed)
            # The raw entries (for decoder tests), without anything that can carry a credential or request settings.
            stripped = [{k: v for k, v in m.items() if k not in ("settings", "headers", "body", "request", "options")} for m in listed]
            with open(os.path.join(out_dir, "catalog-%s.json" % provider), "w") as f:
                json.dump(sorted(stripped, key=lambda m: m.get("id") or ""), f, indent=1, sort_keys=True)
            catalog[provider + ":nonchat"] = sorted("%s (%s)" % (m.get("id"), m.get("type")) for m in listed if m.get("type") not in (None, "chat"))
        with open(os.path.join(out_dir, "catalog.json"), "w") as f:
            json.dump(catalog, f, indent=1, sort_keys=True)
        surface["permissions"] = permission_matrix(server, {a["id"]: a for a in surface["agents"]})
        surface["browser"] = browser_probe(server, surface.get("browserBridgeVersion"))
        # Built-in plugins add agent rules as they load (the browser plugin's denies), so the first list of a cold
        # location can be incomplete: record the list once the location has served everything above.
        surface["agents"] = agent_list(server, server.stable_list("/api/agent"))
    finally:
        server.close()

    # 2. With BelloCode's plugin loaded by path (as the app does): plugin API facts, then the one recorded prompt.
    plugin_dir = tempfile.mkdtemp(prefix="bellocode-contract-plugin-")
    try:
        shutil.copy(os.path.join(args.plugin, "server.ts"), plugin_dir)
        shutil.copytree(os.path.join(args.plugin, "src"), os.path.join(plugin_dir, "src"))
        config = {"plugins": [{"package": plugin_dir, "options": {}}], "experimental": {"subagent_depth": 2}}
        server = Server(binary, config)
        try:
            recorder = EventRecorder(server)
            recorder.wait_for(lambda f: f.get("type") == "server.connected", 15)
            surface["plugin"] = plugin_probe(server)
            if not args.no_prompt:
                surface["prompts"] = record_turn(server, recorder, catalog["free"])
            time.sleep(1.0)
            recorder.close()
            raw = recorder.raw()
            if raw:
                with open(os.path.join(out_dir, "events-sample.sse"), "wb") as f:
                    f.write(raw.replace(server.password.encode(), b"<password>"))
            surface["eventTypes"] = sorted({f.get("type") for f in recorder.frames() if f.get("type")})
        finally:
            server.close()
    finally:
        shutil.rmtree(plugin_dir, ignore_errors=True)

    with open(os.path.join(out_dir, "surface.json"), "w") as f:
        json.dump(surface, f, indent=1, sort_keys=True)
    log("captured %s into %s (%d model prompt%s)" % (surface.get("version"), out_dir, surface["prompts"], "" if surface["prompts"] == 1 else "s"))


def agent_list(server, agents):
    return sorted(
        [{"id": a.get("id"), "mode": a.get("mode"), "hidden": a.get("hidden"),
          "permissions": [[r.get("action"), server.normalize(r.get("resource") or ""), r.get("effect")]
                          for r in (a.get("permissions") or a.get("permission") or [])]}
         for a in agents], key=lambda a: a["id"] or "")


def permission_matrix(server, agents):
    results = []
    for agent in PROBE_AGENTS:
        agent_rules = [{"action": a, "resource": r.replace("<sandbox>", server.root), "effect": e} for a, r, e in (agents.get(agent) or {}).get("permissions", [])]
        for mode, base in MODE_RULES.items():
            rules = base + (restrictions(agent_rules) if base else [])
            status, created = server.request("POST", "/api/session", {
                "title": "permission probe", "agent": agent, "location": {"directory": server.project},
                "permissions": [{"action": a, "resource": r, "effect": e} for a, r, e in rules]})
            if status != 200:
                results.append({"agent": agent, "mode": mode, "error": "session create %s" % status})
                continue
            sid = created["data"]["id"]
            for action, resource in PERMISSION_PROBES:
                resource = resource.replace("<home>", os.path.join(server.root, "home"))
                status, body = server.request("POST", "/api/session/%s/permission" % sid, {"action": action, "resources": [resource]})
                effect = body.get("data", {}).get("effect") if status == 200 and isinstance(body, dict) else "HTTP %s" % status
                results.append({"agent": agent, "mode": mode, "action": action, "resource": server.normalize(resource), "effect": effect})
                if effect == "ask":
                    rid = body["data"]["id"]
                    server.request("POST", "/api/session/%s/permission/%s/reply" % (sid, rid), {"decision": "reject"})
            server.request("DELETE", "/api/session/%s" % sid)
    return results


def browser_probe(server, static_version):
    """Attach at each candidate version; the accepted one answers `attached` on the event stream."""
    result = {"accepted": [], "rejected": []}
    recorder = EventRecorder(server)
    try:
        recorder.wait_for(lambda f: f.get("type") == "server.connected", 15)
        candidates = sorted({v for v in [3, 4, 5, static_version, (static_version or 4) + 1] if v})
        for version in candidates:
            status, created = server.request("POST", "/api/session", {"title": "browser probe", "location": {"directory": server.project}})
            sid = created["data"]["id"]
            connection = "00000000-0000-4000-8000-%012d" % version
            outcome = {}

            def attach():
                outcome["status"], outcome["body"] = server.request(
                    "POST", "/api/rpc/experimental.browser/attach",
                    {"input": {"sessionID": sid, "connectionID": connection, "version": version}}, timeout=30)

            thread = threading.Thread(target=attach, daemon=True)
            thread.start()
            attached = recorder.wait_for(
                lambda f: f.get("type") == "rpc.experimental.browser.control"
                and (f.get("data") or {}).get("type") == "attached" and (f.get("data") or {}).get("connectionID") == connection, 8)
            if attached:
                rules = (server.get("/api/session/%s" % sid, located=False).get("data") or {}).get("permissions") or []
                result["accepted"].append(version)
                result["grantedRules"] = [[r.get("action"), r.get("resource"), r.get("effect")] for r in rules]
            server.request("DELETE", "/api/session/%s" % sid, located=False)
            thread.join(10)
            if attached:
                result["closedWith"] = outcome.get("body", {}).get("output") if isinstance(outcome.get("body"), dict) else None
            else:
                result["rejected"].append(version)
    finally:
        recorder.close()
    return result


def plugin_probe(server):
    result = {"loaded": False}
    for _ in range(30):
        status, body = server.request("POST", "/api/rpc/bellocode/info", {"input": {}})
        if status == 200 and isinstance(body, dict) and "output" in body:
            output = body["output"] or {}
            result = {"loaded": True, "contract": output.get("contract"), "tools": sorted(output.get("tools") or [])}
            break
        time.sleep(0.3)
    status, plugins = server.request("GET", "/api/plugin")
    listed = [p.get("id") or p.get("name") for p in ((plugins or {}).get("data") or [])] if status == 200 else []
    result["listed"] = "bellocode" in listed
    return result


def record_turn(server, recorder, free_models):
    model = next((m for pref in PROMPT_MODEL_PREFERENCE for m in free_models if m.endswith("/" + pref)), free_models[0] if free_models else None)
    if not model:
        log("no zero-cost model in the catalog: recording without a prompt")
        return 0
    provider, model_id = model.split("/", 1)
    status, created = server.request("POST", "/api/session", {
        "title": "contract capture", "model": {"id": model_id, "providerID": provider}, "location": {"directory": server.project},
        "permissions": [{"action": "shell", "resource": "*", "effect": "ask"}]})
    if status != 200:
        raise RuntimeError("session create %s" % status)
    sid = created["data"]["id"]
    status, _ = server.request("POST", "/api/session/%s/prompt" % sid, {
        "text": "Use your shell tool to run exactly this command once: echo bellocode-contract. Then reply with the single word done."}, located=False)
    if status != 200:
        raise RuntimeError("prompt %s" % status)
    asked = recorder.wait_for(lambda f: f.get("type") == "permission.asked", 120)
    if asked:
        rid = (asked.get("data") or {}).get("id") or ((asked.get("data") or {}).get("request") or {}).get("id")
        server.request("POST", "/api/session/%s/permission/%s/reply" % (sid, rid), {"decision": "once"}, located=False)
    done = recorder.wait_for(lambda f: f.get("type", "").startswith("session.execution.") and f.get("type") != "session.execution.started"
                             and (f.get("data") or {}).get("sessionID") == sid, 180)
    if not done:
        log("the turn did not finish within 180 s; interrupting")
        server.request("POST", "/api/session/%s/interrupt" % sid, {}, located=False)
    else:
        log("turn ended with %s on %s" % (done.get("type"), model))
    return 1


# ---------------------------------------------------------------------------------------------------------------------
# Diff


def load(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def operations(openapi):
    ops = {}
    for path, item in openapi.get("paths", {}).items():
        for method, op in item.items():
            if method in ("get", "post", "put", "patch", "delete"):
                ops["%s %s" % (method.upper(), path)] = op
    return ops


def refs(node, out):
    if isinstance(node, dict):
        ref = node.get("$ref")
        if isinstance(ref, str) and ref.startswith("#/components/schemas/"):
            out.add(ref.split("/")[-1])
        for value in node.values():
            refs(value, out)
    elif isinstance(node, list):
        for value in node:
            refs(value, out)
    return out


def closure(schemas, roots):
    seen, stack = set(), list(roots)
    while stack:
        name = stack.pop()
        if name in seen or name not in schemas:
            continue
        seen.add(name)
        stack.extend(refs(schemas[name], set()))
    return seen


def schema_change(old, new):
    """A short description of how one schema changed (properties, required, enum)."""
    notes = []
    po, pn = old.get("properties") or {}, new.get("properties") or {}
    added, removed = sorted(set(pn) - set(po)), sorted(set(po) - set(pn))
    if added:
        notes.append("properties added: " + ", ".join(added))
    if removed:
        notes.append("properties removed: " + ", ".join(removed))
    changed = sorted(k for k in set(po) & set(pn) if po[k] != pn[k])
    if changed:
        notes.append("properties changed: " + ", ".join(changed))
    ro, rn = set(old.get("required") or []), set(new.get("required") or [])
    if ro != rn:
        if rn - ro:
            notes.append("now required: " + ", ".join(sorted(rn - ro)))
        if ro - rn:
            notes.append("no longer required: " + ", ".join(sorted(ro - rn)))

    def enums(s):
        values = set(s.get("enum") or [])
        for branch in s.get("anyOf") or s.get("oneOf") or []:
            values |= set(branch.get("enum") or [])
        return values

    eo, en = enums(old), enums(new)
    if eo != en:
        if en - eo:
            notes.append("enum added: " + ", ".join(sorted(map(str, en - eo))))
        if eo - en:
            notes.append("enum removed: " + ", ".join(sorted(map(str, eo - en))))
    return notes or ["changed (structure)"]


def event_types(openapi):
    """Event `type` values from the event union (every schema whose `type` property is a single-value enum)."""
    types = set()
    op = openapi.get("paths", {}).get("/api/event", {}).get("get", {})
    schemas = openapi.get("components", {}).get("schemas", {})
    for name in closure(schemas, refs(op, set())):
        prop = (schemas[name].get("properties") or {}).get("type") or {}
        values = prop.get("enum") or ([prop["const"]] if "const" in prop else [])
        if len(values) == 1 and "." in str(values[0]):
            types.add(values[0])
    for param in op.get("parameters", []):
        items = (param.get("schema") or {}).get("items") or {}
        for value in items.get("enum") or []:
            types.add(value)
    return types


def sse_types(path):
    types = set()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("data:"):
                    try:
                        types.add(json.loads(line[5:]).get("type"))
                    except ValueError:
                        pass
    except FileNotFoundError:
        pass
    types.discard(None)
    return types


def consumer_map(sources, openapi):
    """Which Swift files call each operation, decode each schema and handle each event type.

    Operations are found by their operationId (OpenCodeClient labels every request with it) and by `["api", …]` path
    arrays; a schema is attributed to the callers of every operation whose request or response reaches it, and to any
    file naming it in backticks (the DTO comments do)."""
    files = {}
    for base, _, names in os.walk(sources):
        for name in names:
            if name.endswith(".swift"):
                path = os.path.join(base, name)
                with open(path, encoding="utf-8", errors="replace") as f:
                    files[os.path.relpath(path, os.path.dirname(sources))] = f.read()
    ops = operations(openapi)
    by_id = {op.get("operationId"): key for key, op in ops.items()}
    templates = []
    for key in ops:
        method, path = key.split(" ", 1)
        templates.append((key, [seg for seg in path.strip("/").split("/")]))
    endpoints = {}
    for file, text in files.items():
        for op_id in set(re.findall(r'"([a-z][A-Za-z0-9_.-]+)"', text)):
            if op_id in by_id:
                endpoints.setdefault(by_id[op_id], set()).add(file)
        for array in re.findall(r'\[\s*"api"\s*((?:,\s*(?:"[^"]*"|[A-Za-z_][A-Za-z0-9_.()]*)\s*)*)\]', text):
            segs = ["api"] + [x.strip() for x in array.split(",") if x.strip()]
            for key, template in templates:
                if len(template) != len(segs):
                    continue
                if all((t.startswith("{") or t == "*") if not g.startswith('"') else t == g.strip('"') for t, g in zip(template, segs)):
                    endpoints.setdefault(key, set()).add(file)
    schemas = {}
    all_schemas = openapi["components"]["schemas"]
    for key, consumers in endpoints.items():
        for name in closure(all_schemas, refs(ops[key], set())):
            schemas.setdefault(name, set()).update(consumers)
    for file, text in files.items():
        for name in set(re.findall(r"`([A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)`", text)):
            if name in all_schemas:
                schemas.setdefault(name, set()).add(file)
    events = set()
    for file, text in files.items():
        if file.endswith("OpenCodeEvent.swift"):
            events |= set(re.findall(r'case "([a-z][a-z0-9_.-]+)"', text))
    return {"endpoints": {k: sorted(v) for k, v in endpoints.items()}, "schemas": {k: sorted(v) for k, v in schemas.items()},
            "events": sorted(events)}


def diff(args):
    old_dir, new_dir = os.path.abspath(args.old), os.path.abspath(args.new)
    a, b = load(os.path.join(old_dir, "openapi.json")), load(os.path.join(new_dir, "openapi.json"))
    sa, sb = load(os.path.join(old_dir, "surface.json"), {}), load(os.path.join(new_dir, "surface.json"), {})
    ca, cb = load(os.path.join(old_dir, "catalog.json"), {}), load(os.path.join(new_dir, "catalog.json"), {})
    dto_map = consumer_map(os.path.abspath(args.sources), a)
    oa, ob = operations(a), operations(b)
    schemas_a, schemas_b = a["components"]["schemas"], b["components"]["schemas"]
    result = {"from": os.path.basename(old_dir), "to": os.path.basename(new_dir)}

    used = dto_map.get("endpoints", {})
    used_schemas = dto_map.get("schemas", {})

    def endpoint_entry(key, kind, notes=None):
        entry = {"endpoint": key, "change": kind}
        if notes:
            entry["notes"] = notes
        consumer = used.get(key)
        if consumer:
            entry["usedBy"] = consumer
        entry["experimental"] = "/experimental/" in key or "/rpc/" in key
        return entry

    endpoints = [endpoint_entry(k, "removed") for k in sorted(set(oa) - set(ob))]
    endpoints += [endpoint_entry(k, "added") for k in sorted(set(ob) - set(oa))]
    for key in sorted(set(oa) & set(ob)):
        ra = closure(schemas_a, refs(oa[key], set()))
        rb = closure(schemas_b, refs(ob[key], set()))
        changed = sorted(n for n in ra & rb if schemas_a[n] != schemas_b[n])
        shape = json.dumps({k: v for k, v in oa[key].items() if k not in ("description", "summary")}, sort_keys=True) != \
            json.dumps({k: v for k, v in ob[key].items() if k not in ("description", "summary")}, sort_keys=True)
        if shape or changed or (ra ^ rb):
            notes = []
            if changed:
                notes.append("schemas changed: " + ", ".join(changed))
            if rb - ra:
                notes.append("schemas now referenced: " + ", ".join(sorted(rb - ra)))
            if ra - rb:
                notes.append("schemas no longer referenced: " + ", ".join(sorted(ra - rb)))
            endpoints.append(endpoint_entry(key, "changed", notes or ["parameters or responses changed"]))
    result["endpoints"] = endpoints

    schema_entries = []
    for name in sorted(set(schemas_a) | set(schemas_b)):
        if name in schemas_a and name in schemas_b and schemas_a[name] == schemas_b[name]:
            continue
        kind = "removed" if name not in schemas_b else "added" if name not in schemas_a else "changed"
        entry = {"schema": name, "change": kind}
        if kind == "changed":
            entry["notes"] = schema_change(schemas_a[name], schemas_b[name])
        if name in used_schemas:
            entry["decodedBy"] = used_schemas[name]
        schema_entries.append(entry)
    result["schemas"] = schema_entries

    ea, eb = event_types(a), event_types(b)
    ra_, rb_ = sse_types(os.path.join(old_dir, "events-sample.sse")), sse_types(os.path.join(new_dir, "events-sample.sse"))
    handled = set(dto_map.get("events", []))
    result["events"] = {
        "schemaAdded": sorted(eb - ea), "schemaRemoved": sorted(ea - eb),
        "recordedAdded": sorted(rb_ - ra_), "recordedRemoved": sorted(ra_ - rb_),
        "handledButRemoved": sorted(t for t in handled if t in ea and t not in eb),
    }

    def changed_list(key):
        x, y = sa.get(key) or [], sb.get(key) or []
        if isinstance(x, list) and all(isinstance(i, str) for i in x + y):
            return {"added": sorted(set(y) - set(x)), "removed": sorted(set(x) - set(y))}
        return {"changed": x != y}

    agents_a = {g["id"]: g for g in sa.get("agents", [])}
    agents_b = {g["id"]: g for g in sb.get("agents", [])}
    result["builtins"] = {
        "agents": {"added": sorted(set(agents_b) - set(agents_a)), "removed": sorted(set(agents_a) - set(agents_b)),
                   "permissionsChanged": sorted(k for k in set(agents_a) & set(agents_b) if agents_a[k].get("permissions") != agents_b[k].get("permissions"))},
        "skills": changed_list("skills"), "commands": changed_list("commands"), "plugins": changed_list("plugins"),
        "tools": changed_list("toolRendererNames"), "promptFiles": changed_list("embeddedPromptFiles"),
    }
    result["bridge"] = {
        "browserFrom": sa.get("browserBridgeVersion"), "browserTo": sb.get("browserBridgeVersion"),
        "acceptedFrom": (sa.get("browser") or {}).get("accepted"), "acceptedTo": (sb.get("browser") or {}).get("accepted"),
        "grantedRulesChanged": (sa.get("browser") or {}).get("grantedRules") != (sb.get("browser") or {}).get("grantedRules"),
        "pluginContractFrom": (sa.get("plugin") or {}).get("contract"), "pluginContractTo": (sb.get("plugin") or {}).get("contract"),
        "pluginLoaded": (sb.get("plugin") or {}).get("loaded"),
        "pluginToolsChanged": (sa.get("plugin") or {}).get("tools") != (sb.get("plugin") or {}).get("tools"),
    }

    def perm_key(r):
        return (r.get("agent"), r.get("mode"), r.get("action"), r.get("resource"))

    pa = {perm_key(r): r.get("effect", r.get("error")) for r in sa.get("permissions", [])}
    pb = {perm_key(r): r.get("effect", r.get("error")) for r in sb.get("permissions", [])}
    result["permissions"] = [
        {"agent": k[0], "mode": k[1], "action": k[2], "resource": k[3], "from": pa.get(k), "to": pb.get(k)}
        for k in sorted(set(pa) | set(pb), key=lambda k: tuple(str(x) for x in k)) if pa.get(k) != pb.get(k)]
    providers = sorted(k for k in set(ca) | set(cb) if isinstance(ca.get(k, cb.get(k)), list))
    result["catalog"] = {p: {"added": sorted(set(cb.get(p) or []) - set(ca.get(p) or [])),
                             "removed": sorted(set(ca.get(p) or []) - set(cb.get(p) or []))} for p in providers}

    impact = []
    for e in endpoints:
        if e.get("usedBy") and e["change"] != "added":
            impact.append({"what": e["endpoint"], "change": e["change"], "consumers": e["usedBy"]})
    for s in schema_entries:
        if s.get("decodedBy") and s["change"] != "added":
            impact.append({"what": "schema " + s["schema"], "change": s["change"], "consumers": s["decodedBy"], "notes": s.get("notes")})
    for t in result["events"]["handledButRemoved"]:
        impact.append({"what": "event " + t, "change": "removed", "consumers": ["OpenCodeKit/Events/OpenCodeEvent.swift"]})
    if result["bridge"]["browserFrom"] != result["bridge"]["browserTo"] or result["bridge"]["acceptedFrom"] != result["bridge"]["acceptedTo"]:
        impact.append({"what": "experimental.browser version", "change": "changed", "consumers": ["OpenCodeKit/Browser/BrowserContract.swift"]})
    if result["permissions"]:
        impact.append({"what": "permission evaluation", "change": "changed", "consumers": ["Engine/Sync/Mapping.swift PermissionModeRules"]})
    result["impact"] = impact

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "diff.json"), "w") as f:
        json.dump(result, f, indent=1, sort_keys=True)
    with open(os.path.join(args.out, "DIFF.md"), "w") as f:
        f.write(render(result))
    log("wrote %s/diff.json and DIFF.md (%d endpoint, %d schema changes, %d affecting BelloCode)" % (
        args.out, len(endpoints), len(schema_entries), len(impact)))


def render(r):
    lines = ["# opencode contract diff: %s -> %s" % (r["from"], r["to"]), ""]
    lines += ["## Affecting BelloCode (%d)" % len(r["impact"]), ""]
    for i in r["impact"]:
        lines.append("- **%s** %s; consumers: %s%s" % (i["what"], i["change"], ", ".join(i["consumers"]),
                                                         "; " + "; ".join(i["notes"]) if i.get("notes") else ""))
    if not r["impact"]:
        lines.append("- none")
    lines += ["", "## Endpoints (%d changes)" % len(r["endpoints"]), ""]
    for e in r["endpoints"]:
        lines.append("- %s `%s`%s%s%s" % (e["change"], e["endpoint"], " (experimental)" if e["experimental"] else "",
                                          " used by " + ", ".join(e["usedBy"]) if e.get("usedBy") else "",
                                          ": " + "; ".join(e["notes"]) if e.get("notes") else ""))
    lines += ["", "## Schemas (%d changes)" % len(r["schemas"]), ""]
    for s in r["schemas"]:
        lines.append("- %s `%s`%s%s" % (s["change"], s["schema"], " decoded by " + ", ".join(s["decodedBy"]) if s.get("decodedBy") else "",
                                        ": " + "; ".join(s["notes"]) if s.get("notes") else ""))
    ev = r["events"]
    lines += ["", "## Events", "",
              "- in the schema: added %s; removed %s" % (ev["schemaAdded"] or "none", ev["schemaRemoved"] or "none"),
              "- in the recorded turn: newly seen %s; no longer seen %s" % (ev["recordedAdded"] or "none", ev["recordedRemoved"] or "none"),
              "- handled by BelloCode but removed: %s" % (ev["handledButRemoved"] or "none")]
    b = r["bridge"]
    lines += ["", "## Bridges", "",
              "- experimental.browser: static v%s -> v%s; attach accepted %s -> %s; granted rules changed: %s" % (
                  b["browserFrom"], b["browserTo"], b["acceptedFrom"], b["acceptedTo"], b["grantedRulesChanged"]),
              "- BelloCode plugin: loaded %s; contract %s -> %s; tools changed: %s" % (
                  b["pluginLoaded"], b["pluginContractFrom"], b["pluginContractTo"], b["pluginToolsChanged"])]
    lines += ["", "## Built-ins", ""]
    for key, value in r["builtins"].items():
        lines.append("- %s: %s" % (key, json.dumps(value)))
    lines += ["", "## Permission evaluation (%d differences)" % len(r["permissions"]), ""]
    for p in r["permissions"]:
        lines.append("- %s/%s `%s %s`: %s -> %s" % (p["agent"], p["mode"], p["action"], p["resource"], p["from"], p["to"]))
    lines += ["", "## Model catalog", ""]
    for provider, change in r["catalog"].items():
        lines.append("- %s: added %s; removed %s" % (provider, change["added"] or "none", change["removed"] or "none"))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("capture")
    c.add_argument("binary")
    c.add_argument("out")
    c.add_argument("--plugin", required=True)
    c.add_argument("--no-prompt", action="store_true")
    c.add_argument("--catalog-provider", action="append", default=[])
    d = sub.add_parser("diff")
    d.add_argument("old")
    d.add_argument("new")
    d.add_argument("--sources", required=True)
    d.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.command == "capture":
        capture(args)
    else:
        diff(args)


if __name__ == "__main__":
    main()
