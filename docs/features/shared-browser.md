# Shared browser (one Chromium for every thread)

Status: built 2026-11-18 on opencode 2.3.2, browse 0.1.5, Debian Chromium 156.0.8078.79 (arm64; the 1.0 release is arm64
only and an amd64 engine is refused before the image build), Rancher Desktop
(dockerd 29.9.2). Inputs: [G7 spike](../spikes/G7-chrome-browse-container.md), [review](../reviews/browser-integration-review.md),
[secrets routing](secrets.md#routing-for-the-shared-browser-package). The built-in WebKit browser ([browser.md](browser.md))
stays for previews.

> **Database migration `v13-shared-browser`** (named distinctly; after develop's `v12-secret-manager`;
> `currentVersion` 13): `app_browser_binding` (thread → tab group, default tab, its tabs), `app_browser_share`
> (deliberate shares: owner, grantee, tab, expiry), `app_browser_label` (project → `.bc` label). No URLs, titles or
> cookies. Another branch adding a thirteenth migration only needs `currentVersion` reconciled.

## Architecture

| Layer | What |
| --- | --- |
| `Containers/browser/` | Dockerfile, entrypoint, `ctl.sh`, `browse-mcp`, policy, viewer page, `versions.env`, seccomp profile (bundled as `Resources/browser-image`) |
| ContainerKit `Browser/` | `BrowserImageContext` (input hash, tag), `BrowserExtensionKey`, `BrowserImageBuilder` (buildx), `BrowserContainerSpec`, status parsing |
| Engine `SharedBrowser/` | `BrowserSupervisor` (lifecycle), `DockerBrowserRuntime`, `BrowserRouteTable` + `BrowserEgressRouter`, `SharedBrowserBroker` (client MCP `chrome`), `BrowserCallPolicy`, `BrowserTabGate`, `BrowseMCPClient`, `SharedBrowserService` (`engine.sharedBrowser`) |
| SecretKit | `EgressDial.terminatesTLS`; `PreviewProxyFront` (WebKit's loopback proxy) |
| App | Chrome right-panel tab + window (`SharedChromeSurface.swift`), Browser menu items, Settings ▸ Browser ▸ Shared Chrome, approval card |

On the Mac only BelloCode, Rancher's `docker` CLI (image builds) and a WKWebView running noVNC. browse, its relay and
MCP server and Chromium run only in the container.

## Image and pinning

Multi-stage, built locally with `docker buildx build --load` (images are built locally by policy). Base:
digest-pinned `node:22-bookworm-slim` (Docker Hub pulls still time out in this VM; the only cached Debian 12),
**flattened** into one `FROM scratch` layer with Node removed. Debian Chromium, `chromium-common`, `chromium-sandbox`,
noVNC (static files only; the package depends on nodejs) and browse's npm tarball and extension zip are pinned by
version and SHA-256 (`versions.env`). Docs, man pages, non-English message catalogues and Chromium locales outside a
short list are removed; Liberation and Noto Core fonts kept. Non-root (uid 1001), read-only root, `/tmp` tmpfs 512 MB.

**Packing key:** RSA-2048 made once per Mac, Keychain `app.bellocode.browser-extension-key`; passed to BuildKit as
`--secret id=extkey,env=…` (never argv, a file, a layer or a log). BuildKit's cache ignores secret contents, so the pack
step also takes `EXTENSION_ID` and checks it matches the key (found while testing: a cached CRX from another key).
Same key → same extension ID → the profile stays paired across rebuilds. The image is tagged
`bellocode-browser:<16 hex of the input hash>` (every context file + the extension ID); a changed input builds a new
image; one previous image is kept as the fallback.

## Lifecycle and flush

One container `bellocode-browser`, profile volume `bellocode-browser-profile`. **Lazy:** the first agent call or a
visible live view starts it (single flight). Calls, visible viewers, handoffs and human control are counted; at zero an
idle timer (Settings, default 10 min) runs. **Stop, in order:** close admission → drain running calls (≤ 30 s) →
`docker stop -t 30` → the entrypoint sends **SIGINT** to Chromium and waits. Measured: SIGTERM is treated by Chromium as
"session ending" and exits without committing the cookie store (a cookie set just before was lost); SIGINT closes
windows and the profile normally and the same cookie survives (`make browser-verify` step "cookie survives an
immediate orderly stop"; live test). Every stop advances the browser **generation** (tabs do not survive; sign-ins do).
**Crash** (unexpected exit, or Chromium restarting inside): generation +1, in-flight calls fail "outcome unknown",
each thread that used the browser gets a plain `[BelloCode] …` line with its next result, restart with backoff
1/2/5/10/30 s, five failures in five minutes stop retrying. Exit 78 (no sandbox) is never retried. Bounds: 2 GB / 2 CPU /
1024 pids, shm 1 GB, HTTP cache 128 MB in tmpfs (not in the profile); profile size is measured (Docker volumes have no
byte quota) with a warning at 80% of the Settings limit. Quitting BelloCode stops the browser in order. **Stop during a
start** (including one that adopted a browser left running by a previous launch) hands over to the orderly stop,
which checks the container's actual state; a daemon failure shows "Stop not confirmed", never Stopped, and an absent
container counts as stopped (v1.0.1 AF23, `SharedBrowserStopTests`). A start that fails after adopting such a browser
(readiness timeout, viewer password) stops it like one it started, and Stop in Failed stops a container that still
runs instead of only relabelling it.

## Networking and canonical URLs

The browser is the egress proxy's **`browser` scope**: its own gateway (`EgressGateway.ensure`, run from the browser
image, which has python3), the internal network `bellocode-egress-browser` as its only network, Chromium
`--proxy-server=http://bellocode-proxy:3128` (no direct path exists), and `enterprise-roots.pem` (company roots +
BelloCode's egress CA) imported into Chromium's NSS store at every start.

**https vs http decision: canonical names are `https://<project>.bc:<port>/` and `https://<service>.<project>.bc/`.**
The proxy already answers every CONNECT and terminates TLS with a leaf for the exact host from its CA, which the
browser trusts; `EgressDial.terminatesTLS` lets that request continue as plain HTTP on the registered private hop
(proxy → loopback forwarder → container). So pages get a secure context (workers, secure cookies) and the http-only
rule of `.dial` stays for every other route. Dev servers must accept the host (Vite `server.allowedHosts`).

`BrowserRouteTable`: `<label>.bc:<port>` → the project's workspace container, its **own loopback** (an exec relay, so
loopback-only dev servers work); `<service>.<label>.bc` → the service by alias **from the workspace container** (443 →
its first declared port). Unknown `.bc` names are refused, never looked up. Labels are stable, unique, stored.
**Changed from the routing note:** attaching the gateway to a project network at route time changed the gateway's
default route and silently broke the browser's open tunnels (seen live: hung navigations), so nothing joins a project
network at runtime; services need the project's workspace running. **Placeholders:** the browser scope admits the
projects with a bound thread or an approval; substitution obeys the bindings exactly as for workspaces.
**WebKit preview:** a routes-only `preview` scope and `PreviewProxyFront` (127.0.0.1, per-launch Basic credentials,
`*.bc` only, no substitution); each project's `WKWebsiteDataStore` gets a `ProxyConfiguration` with `matchDomains
["bc"]`, no failover, and trusts the egress CA for `*.bc` only. Same URLs in both browsers.

## Multi-agent model (browse 0.1.5)

**One pooled `browse mcp`** for every thread, chosen from the review and browse's Rust source: browse has no
per-caller identity (all clients share one token and inventory), so several MCP processes add processes without
isolation; isolation has to come from BelloCode. `BrowseMCPClient` multiplexes JSON-RPC IDs, passes cancellation and
image blocks, initializes as opencode (plain tools). The app hosts it as the client-MCP server **`chrome`**
(`chrome_navigate`, …) per project location; each call carries opencode's session ID (refused without one).
`BrowserCallPolicy`: each thread gets its own group `bc-<8 hex>` and default tab `<group>-main` (created before use);
calls without `tab` go there (never a stray background tab); `tabs new` lands in the group; `tabs list`/group close
are limited to the group; another thread's tab is refused naming its owner; numeric tabs are translated to string IDs
(browse reserves only string tabs) or refused, as is a number no host integer can hold (never a crash, AV11); `settings` and `recording` are hidden. **Sharing** is the person's act,
recorded with expiry. `BrowserTabGate`: one call per tab at a time in order; a shared tab has one **driver** (lease
renewed per call, released by `chrome_release_tab`, revoked by the person, lapses after 60 s); ≤ 4 running and 16
waiting across threads, 4 per thread, round-robin; overflow, takeover or another driver return a plain **Busy**.
**Approval:** MCP servers always need a person: until the project is approved the only tool is
`chrome_request_access`, which raises a card (Allow Once = this thread; Always = the project; revocable in Settings).
Access is checked again when a call gets its tab (right before dispatch) and before its result is returned: revoking
a project cancels its calls already waiting or running, none is sent afterwards, and a running call's result is
withheld (AV05).
**Guidance** (`bellocode.chrome` instruction entry): WebKit preview vs shared Chrome, canonical URLs, own group, Busy,
handoff, and that sign-ins are shared.
**Done threads:** when a thread is archived or deleted its own tabs close (Settings ▸ Browser, on by default), except
tabs it shares with another thread; this never starts the browser, and nothing closes while the person has control.
Threads that existed before launch count too (the tracker is seeded from the store), and a change-stream overflow is
reconciled against every thread.

## Live view and takeover

Chrome tab and optional window: noVNC (Xvnc `-FrameRate 30 -CompareFB 2`, loopback; websockify) through a
`PortForwarder`, in a WKWebView with a non-persistent store. Connects only while visible and not occluded; per-launch
VNC password set over exec stdin, handed to the page by a call (never a URL); quality 6 / compression 2 (compact preset
1024×640 in Settings restarts the browser). View-only until **Take Over** (whole browser or the thread's tab): waiting
agent calls fail Busy, new ones are refused, the browser counts as active; **Give Back** restores. The overlay names
the thread running a call (and tab), the person's control, or the last user. Tab-group switcher by thread. Clipboard:
Chrome → Mac only while you have control; Mac → Chrome only by Paste. Downloads: `/data/downloads`, copied to
~/Downloads on request. Menu: Browser ▸ Show Shared Chrome (⌥⌃⌘B), Open in Window, Take Over, Give Back, Start, Stop
(also in the Command Palette, NF20). Every viewer (the Chrome tab and the detached window) follows the service's
human-control state, whichever one took over; the menu's Take Over acts in the detached window when it is open, else
the panel (v1.0.1 NF17, `SharedChromeViewerTests`).

## Security

- **Shared sign-ins, plainly:** every thread allowed to use the shared Chrome can use every site you are signed in to
  there, as you. Groups and leases scope *calls*, not sign-ins. The profile volume is a credential store (Chromium's
  basic store uses a fixed public key): anyone with the Docker socket or the VM can read it. Delete Cookies and Site
  Data (confirmed) removes the volume and signs everything out.
- **Sandbox:** Chromium keeps its namespace sandbox; the container drops all capabilities, sets no-new-privileges and
  uses Docker's default seccomp profile plus clone/unshare/setns/chroot (revision `g7-1`). The entrypoint refuses to start
  (exit 78) if user namespaces fail, and `verify-sandbox` checks a renderer is in its own PID namespace under seccomp
  mode 2, else stops.
- **No view input restriction on the transport:** noVNC's view-only is client-side; the VNC password exists only in
  the app and the container.
- Nothing published; relay, VNC and websockify on the container's loopback; the browser's only network is internal.

## Measurements (live test, 2026-11-18, 2 vCPU / 6 GB VM)

| | |
| --- | --- |
| Image | 1,413 MB (spike 1,769 MB, −20%); build from warm apt ~40 s (cached rebuild 2 s) |
| Cold start (new volume, first pairing) | 2.7 s docker run → paired (gate); first agent result 5.2–5.4 s (before the 1 s pairing change) |
| Warm start (after idle stop) → first result | 0.59–0.79 s; orderly stop 0.11–0.15 s |
| Memory / CPU | idle 307–309 MiB, 3%; two agents 288–327 MiB, 2–4%; after restart 273 MiB |
| Viewer CPU visible vs hidden | hidden = no connection (by design). Visible not measurable here: this session shows no windows and WebKit suspends the page (as in G7) |

## Upgrade gate

`make browser-verify [CONTEXT=dir]`: builds with a throwaway key, runs hardened, checks no Node, policy install and
automatic pairing, sandbox, a test CA in NSS, `tools/list` against `Contracts/browse-<version>/tools.json`, an HTTPS
page signed by the test CA, and a cookie surviving an immediate orderly stop. 8/8 pass on the pins above.
Debian security updates replace the pinned Chromium in the archive: the build then fails at the version pin; update
`versions.env` (version + three SHA-256) and run the gate. A browse bump needs a new contract folder and a broker review.

## Verification

Unit: `BrowserImageTests` 9, `SharedBrowserLifecycleTests` 9 (lazy single flight, flush order, drain before stop, viewer
and human keep alive, crash/backoff/notice, in-container restart, sandbox never retried, clear order),
`BrowserTabGateTests` 6, `BrowserCallPolicyTests` 9, `BrowserRoutingTests` 4, `SharedBrowserBrokerTests` 6 (approval,
attribution, groups, sharing + lease, restart notice, takeover), `BrowseMCPClientTests` 2. Live
(`BELLOCODE_CONTAINER_TESTS=1 --filter LiveSharedBrowser`): all steps above pass. Real binary
(`+ BELLOCODE_BROWSER_REAL=1 --filter SharedBrowserRealBinary`): two threads, free default model, 2 prompts, each read
its page in its own group. Snapshots `--snapshot chrome`; copies `docs/snapshots/chrome-{panel-light,panel-dark,
takeover-dark,approval-light,settings-light}.png` (the stream is a drawn stand-in).

UX checklist (§E): context line (project › thread · folder · canonical URL); states stopped/building/starting/running/
stopping/restarting/failed/sandbox unavailable/no containers; status glyph + word; every action in the Browser menu;
destructive clear confirmed; takeover reversible; no animation. Not run: VoiceOver, two windows, 30 sessions.

## Known gaps

Shared-workspace projects share one container, so `a.bc:5173` and `b.bc:5173` reach the same listener. Service routes
need the project's workspace running. Bringing a thread's group to the front needs a click in Chrome (browse has no
focus verb). No corrupt-profile snapshot/restore,
no Memory Saver tuning, no input restriction on the VNC transport. The approval card sits partly under the composer at
short heights (existing request-stack layout). Downloads are not announced to agents.

## Needs a person at the screen

Live-view latency, frame rate, CPU visible vs hidden, keyboard/IME and clipboard in the WKWebView; a real sign-in
(SSO, 2FA handoff) through Take Over; the WebKit preview loading a canonical URL through the proxy front; VoiceOver.
