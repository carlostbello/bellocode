# G7: Chrome-family browser + real `browse`, in a container

Status: run 2026-11-18 on Rancher Desktop (dockerd 29.9.2, linux/arm64, 2 vCPU / 6 GB VM), opencode 2.3.0, browse
0.1.5 (source read at `e1e3b75`, which is the 0.1.5 release). Prototype: [Spikes/ChromeBrowse/](../../Spikes/ChromeBrowse/)
(Dockerfile, entrypoint, policy, seccomp profile, `browse-mcp`, `run.sh`, `e2e.py`, `novnc-probe.mjs`, `cdp.mjs`,
`measure.sh`, fixtures), demo target `ChromeLiveViewDemo`. Evidence: [G7/](G7/). Production code untouched.

## Verdict on the owner's condition: **PASS**

Chromium, the browse extension, browse's relay and `browse mcp` all run in one Linux arm64 container. On the Mac:
only Rancher's `docker` CLI (allowed) and a WKWebView showing the browser over noVNC. An agent on `opencode/big-pickle`
in a sandboxed opencode filled a form, screenshotted it and read a public page through it. Pairing is automatic.
Chromium keeps its own sandbox, with no capabilities added. Two things need a security decision: a seccomp profile that
allows user namespaces, and the fact that cookies in the profile volume can be read by anyone who can read the volume.

## Answers

**1. Browser in an arm64 container.** Yes. As of 2026-11, Google Chrome (158) and Chrome for Testing (158) **do**
publish linux-arm64 builds ([availability.txt](G7/availability.txt)), so the brief's premise is out of date. The spike
used Debian's `chromium` 156 (arm64, security-maintained, unbranded), because Docker Hub pulls time out inside this
Rancher VM. The base is therefore the locally cached `node:22-bookworm-slim`; use an approved digest-pinned Debian base
in production. amd64 emulation was not needed and not measured (no amd64 image was available offline).
- **Headful vs headless:** both work. Headful runs on TigerVNC `Xvnc` (X server and VNC server in one process). In
  `--headless=new` the extension worker runs and `chrome.debugger` drives navigate, snapshot, screenshot and click, but
  the pairing link must be opened over a loopback CDP port ([headless.txt](G7/headless.txt)). Headful is needed for a
  live view in any case.
- **Loading the extension** ([extension-loading.txt](G7/extension-loading.txt)): Chromium honours `--load-extension`.
  With an `ExtensionInstallBlocklist ["*"]` or `ExtensionSettings` wildcard block, unpacked loading is refused
  ("disabled by the administrator") even when the extension is allowlisted. **Recipe:** pack the pinned release zip as
  a CRX3 with a dedicated key, and force-install it with `ExtensionInstallForcelist` from a `file://` update manifest.
  This works together with "block every other extension". Branded Chrome ignores `--load-extension` since 137, so it
  would need the same route.
- **Sandbox:** with `--cap-drop ALL` + `no-new-privileges`, Docker's default seccomp profile blocks Chromium's
  namespace sandbox. Chromium then never starts, and the setuid fallback is blocked too. The fix is
  [seccomp-chromium.json](../../Spikes/ChromeBrowse/seccomp-chromium.json): Docker's default profile plus
  `clone/unshare/setns/chroot` without `CAP_SYS_ADMIN` ([make-seccomp.py](../../Spikes/ChromeBrowse/make-seccomp.py)).
  The alternative, `--no-sandbox`, makes the container the only boundary around renderers.

**2. Relay + MCP + pairing.** The relay (`browse serve`, 127.0.0.1:19988) and `browse mcp` run in the browser
container. The bundled-code path and the HTTP API only work on loopback, so all three must share one network
namespace. The relay **rejects** the policy-installed extension's origin (`403`) until it is listed in
`OPENCODE_BROWSER_EXTENSION_ORIGINS`. The entrypoint and the `browse-mcp` wrapper set it from the build's ID.
Pairing needs no person: when the live extension is not connected as paired, the entrypoint mints a code
(`browse pair --wait-seconds 1`) and opens `chrome-extension://<id>/welcome.html#code=<code>` in the running Chromium.
That is browse's own install link, and its ECDH exchange is unchanged. The key lives in `/data` (profile + relay
state). A new packing key gives a new extension ID, which is detected and re-paired in about 5 s. Auto-update is off
(`OPENCODE_BROWSER_AUTO_UPDATE=off`; the npm-tarball binary also reports "not installed in a way that updates").

**3. End to end** ([e2e-tool-calls.json](G7/e2e-tool-calls.json)). Sandboxed opencode (temporary XDG directories) ran
`PUT /api/experimental/mcp/browse?location[directory]=…` with
`{"type":"local","command":["~/.rd/bin/docker","exec","-i","bellocode-g7-browser","browse-mcp"]}`, which connected in
55 ms. That command stands in for `bellocode-exec --stdio`. Prompt 1 (34 s): `navigate http://fixture:8080`
(a sibling container on the browser's network), `snapshot`, `fill`, `select` (one invalid-args retry), `eval`, `click`,
`screenshot`, `tabs close`. Reply: "Confirmation G7-PRO-12: welcome, Ada Lovelace." The screenshot (1279×712 PNG)
was taken, but big-pickle cannot view images. Prompt 2 (16 s): `navigate https://example.com` + `snapshot` →
"Example Domain". opencode 2.3.0 composed browse's plain tools in code mode (`execute` → `tools.browse.*`).

**4. Live view.**

| Option | Measured | Verdict |
| --- | --- | --- |
| **noVNC** (Xvnc 1.12 → websockify → RFB client in a web view) | input → pixel visible in the client canvas: key p50 **27.6 ms** / p90 30.5, click p50 28.4 / p90 31.4 (n=30 each); 42 fps on a full-motion page; viewer ~20 % of a core rendering motion; browser side 57 % with or without a viewer (Xvnc 33 %); clipboard both ways ✓ | **Recommended** |
| CDP `Page.startScreencast` | change → frame 8–10 ms in-container, 58–60 fps, 244–852 KiB/s | needs `--remote-debugging-port`: unauthenticated full CDP for anything in the container, bypassing pairing and browse's guardrails; input, clipboard and IME would have to be built natively. Reject for v1 |
| browse `screenshot` | 47–1648 ms per frame (bimodal ~60 / ~635 ms) | evidence only, not a live view |

In a WKWebView ([ChromeLiveViewDemo](../../Sources/ChromeLiveViewDemo/main.swift)), noVNC connects and paints in
244–376 ms ([snapshot](G7/novnc-in-wkwebview.png)), and 5/5 keys and 5/5 clicks reached the page. Continuous updates,
latency and WebContent CPU **could not be measured in WebKit**: this login session shows no windows, so WebKit
suspends the "hidden" page ([liveview-wkwebview.txt](G7/liveview-wkwebview.txt)). Those numbers come from the same
noVNC client in a headless Chromium ([liveview-novnc.txt](G7/liveview-novnc.txt)).

**Downloads** go via policy to `/data/downloads` in the volume. The agent's click downloaded the file, but browse's
result does not mention it. **Company CA:** a PEM mounted read-only at `/etc/bellocode/ca` is imported at every start
with `certutil -A -t C,, -d sql:$HOME/.pki/nssdb`. With it, a test-CA site went from `ERR_CERT_AUTHORITY_INVALID` to
`200` ([ca-and-downloads.txt](G7/ca-and-downloads.txt)).

**5. Resources** ([resources.jsonl](G7/resources.jsonl), [run-startup.txt](G7/run-startup.txt)). Image 1.77 GB
(Chromium 355 MB, the node base 346 MB, fonts and Mesa; a trimmed Debian base would be smaller). Build 53–84 s.
Startup to "extension connected":
- cold (new volume, first pairing): 2.4 s
- warm recreate: 0.47–0.85 s
- start after stop: 0.59 s; stop: 0.14–0.17 s

Usage:
- idle: 0.3 % of a core, 311 MiB fresh, 374 MiB after browsing; headless idle 291 MiB
- full-motion page: 57 % of a core
- agent loop (navigate + snapshot + screenshot, about one page every 1.5 s): 29 %; 789 MiB with 15 open tabs, 914 MiB peak

Limits used: 2 CPU / 2 GiB / 1024 pids, shm 1 GiB.

**One per project, not shared.** A profile holds sign-ins, and any agent that can reach the relay can drive every
signed-in site in it. A shared container with per-project profiles still means one relay, one X display, one
network, and Chromium processes that can read each other's profile directories. Per project, it joins that project's
network, can reach its services by name, and stops with the workspace. Idle cost is about 300 MiB per running browser.
An opt-in "Company browser" (one global profile for intranet SSO) is possible, but every project's agent would then
share those sessions, so it needs its own consent.

**6. Persistence and identity** ([persistence.txt](G7/persistence.txt)). A sign-in cookie survives container recreation
in the named volume. Chromium commits cookies on a ~30 s timer, and a SIGTERM 150 ms after sign-in lost the cookie.
Idle stop happens after minutes, so this only matters for an immediate stop. Without a keyring
(`--password-store=basic`), cookies are `v10`-encrypted with Chromium's **fixed public key**: the spike decrypted
the cookie from the volume. In effect, **the volume is a plaintext credential store**, readable by the Rancher VM,
any Docker API client, and any process in that container. The agent can reach every site the profile is signed in to.
browse's `allowedOrigins`/`readOnly` and its cookie-host limits are guardrails, not a boundary; `eval` runs as the page.

## What breaks or needs care

Unpacked load under a wildcard block (use force-install). Pairing link in headless (needs CDP). The extension ID is
tied to the packing key (keep one stable key per installation, or re-pair). Cookie flush (~30 s). Default seccomp vs
the Chromium sandbox. Agent tabs open in a collapsed background group, so the person watching sees them only after
opening the group (`OPENCODE_BROWSER_AGENT_WINDOW=separate` / `keepVisible`; not exercised). The "debugging" infobar
shows while attached (by design). browse 0.x changes weekly (pin it; contract-test each bump). Docker Hub pulls time
out in this VM. The WKWebView pane's own latency and CPU need a person at the screen.

## Recommended production design

- **Containers settings ▸ Browser:** an image like the prototype (approved base, pinned Chromium/CfT and browse, CRX
  packed at build with a BelloCode-held stable key), image policy as for workspaces, the seccomp choice shown to admins
  (`ContainerBrowserSandbox = namespaces | none`), and a "Delete browser data…" action for the profile volume.
- **Per project** (Project Settings ▸ Environment ▸ Browser, off by default): `bellocode-browser-<key>` on the project
  network, volume `bellocode-<key>-browser-profile`, CA bundle mounted read-only, nothing published, idle-stopped with
  the workspace (after the last activity plus 30 s).
- **MCP Servers:** registered like a project server, but executed in the browser container. This needs one small seam:
  `bellocode-exec --stdio --service browser -- browse-mcp`, since `--stdio` targets only the workspace today.
  `MCPRouting` and the self-check would treat it as a project server.
- **Live view:** Browser panel tab "Container Chrome" with a WKWebView running bundled noVNC, through `PortForwarder`
  to websockify on the container's loopback, with a per-launch VNC password. View-only by default; "Take Over" enables
  input. Clipboard sharing is a per-project toggle. A downloads shelf copies files from `/data/downloads` on request.
- **Agent guidance:** a session instruction entry like `bellocode.browser`. `browser.*` is the built-in WebKit pane, for
  loopback dev previews (the person's Mac). `browse_*` is the project's container Chromium, for Chrome-specific,
  authenticated or intranet work; it reaches the workspace by its network alias, not `localhost`.
- **Approvals:** enabling the server and the first `browse` use in a thread raise a card naming project, profile and
  signed-in state. Handoffs are pinned above the composer and counted in the sidebar. Stop and revoke unpair
  (`browse pair --revoke`) and stop the container.
- **For the security team:** user namespaces vs `--no-sandbox`; the profile volume as a credential store (alternatives:
  a tmpfs profile with no persistence, or a keyring-backed key that BelloCode injects per start); egress; whether the
  global "Company browser" is allowed.
