# Secret manager

Status: built 2026-11-18 on opencode 2.3.0 and Rancher Desktop 1.25. Research: [08 §4](../research/08-auto-mode-risk-secrets.md#4-a-value-the-agent-cannot-see).

> **Database migration `v12-secret-manager`** (named distinctly; registered after develop's `v11-auto-audit`;
> `currentVersion` 12): `app_managed_secret` (mode, scope,
> bindings, use counts: never a value), `app_secret_placeholder` (per-thread placeholders: capabilities, not secrets),
> `app_secret_audit` (≤ 200 rows per secret, ≤ 2,000 in all). Another branch adding a migration only needs
> `currentVersion` reconciled.

## Modes

Settings ▸ Secrets (Window ▸ Secrets…) lists secrets by label with handle (`NAME`), mode, scope (project, code roots,
all projects), destinations, claim and last use. Values live only in the Keychain (`app.bellocode.agent-secrets`,
`WhenUnlockedThisDeviceOnly`; the default legacy-keychain ACL lets only BelloCode read without asking: any other
program, `security` included, prompts the person). Never in the store, a log, process arguments or a file.

| Mode | The agent gets | Claim shown |
| --- | --- | --- |
| **Brokered** | a handle, `{{secret:NAME}}` for `bellocode_app_http_request`; BelloCode performs the request | The agent cannot see this value |
| **Placeholder** | `$NAME=bcsec_…` (46 chars, 238 random bits) in its thread's commands; the proxy substitutes it | The agent cannot see this value |
| **Visible** | the value in `$NAME` (confirmed once: "I understand the agent can see…") | The agent can see this value |
| Command only (legacy, `secret_exec`, host pipe) | a one-use reference; an approved command receives the value | The command can reveal this value |

`request_secret` now takes a proposed `mode`, `name`, `destination`, `header`, `prefix`, `query`, `path`; the card
offers Placeholder / Brokered / Visible / Approved command with the binding fields, "This project only", the claim and
its popover; the agent is woken with a handle or placeholder, never the value (unless Visible). Placeholder mode is
shown only while the proxy runs (never silently downgraded). Values shorter than 8 bytes can only be Visible (too short
to detect in responses). Secrets saved before modes appear as "Commands only". `bellocode_app_list_secrets` lists
handles and this thread's placeholders. Rotate replaces the value and keeps placeholders; Revoke stops every use at
once (placeholders become unknown to the proxy); Delete removes the Keychain item and every record (confirmed).

**Built-in brokered uses (unchanged guarantees).** The GitLab token and git's HTTPS credentials already never reach the
agent: GitLab REST from the app, git through `bellocode-exec --git-credential` answering only BelloCode's git. They are
listed read-only under "Used only by BelloCode" with the same claim; they stay managed in Settings ▸ GitLab.

## Egress architecture and enforcement

```
workspace (internal network only) ──▶ gateway "bellocode-proxy:3128" ──▶ host.docker.internal:<port> ──▶ EgressProxy (Mac)
  no route, no external DNS,           BelloCode relay image bound to the      "BCEGRESS <token>" first     ──▶ destination (system trust;
  IPv6 off, HTTP(S)_PROXY set          internal address only; joined to        on every connection              company proxy via CONNECT)
                                       the bridge after it listens
```

- `WorkspaceSpec.egress` (`EgressAttachment`) makes any workspace container (a project's, or a shared one across code
  roots: the attachment is part of the spec) join only `bellocode-egress-<scope>` (internal, IPv6 off, no masquerade),
  with `HTTP(S)_PROXY`/`npm_config_*` set and `net.ipv6.conf.all.disable_ipv6=1`. `WorkspaceManager.ensureRunning`
  creates the network if missing, so a container started by `bellocode-exec` without its gateway has **no** way out
  (fail closed). `EnvironmentService` ensures the gateway right after the container starts; services join the
  internal network under their names.
- The gateway also answers `bellocode-proxy:2375` for the workspace's `docker` (execution modes): those bytes go through
  the proxy front (`BCEGRESS <token> docker`) to the filtered Docker endpoint, which authenticates and filters them;
  `DOCKER_HOST` points there when egress is enforced.
- The gateway (`EgressGateway`): BelloCode's own image `bellocode-egress-gateway:<inputs hash>` (`EgressGatewayImage`),
  built locally from source compiled into the app (a Dockerfile with no `RUN` step and the Python relay) on
  `node:22-bookworm-slim` pinned by digest (the shared browser's base, so no extra pull); never the project's image, so no project-controlled code holds the token or
  joins the bridge (release review R08), in every execution mode with a workspace. Read-only root, user 65534, no
  capabilities; created per launch with a fresh token (only in its environment; the proxy refuses connections without a
  registered token), removed at quit. The first build needs the pinned base from Docker Hub once.
- The proxy (`SecretKit.EgressProxy`, Network.framework, Mac loopback): answers every `CONNECT` itself and terminates
  TLS with a per-host leaf from BelloCode's CA (P-256; key in the Keychain `app.bellocode.egress-ca`, certificate in
  `<data>/egress/`); ALPN `http/1.1` only. The CA reaches containers through the Containers 3 bundle (`ca-bundle.pem`,
  `enterprise-roots.pem`, trust-store update), combined with the enterprise roots in use. Upstream: system trust
  (admin-installed enterprise roots included), and an explicit company proxy (`NetworkHTTPSProxy`) through CONNECT;
  a transparent proxy needs nothing. Destinations resolving to the Mac or link-local are refused.
- **Non-HTTP egress: blocked by default.** Per project, `host:port` pairs may be reached by a raw CONNECT tunnel
  (Settings ▸ Secrets ▸ Container network, labelled **no secret protection**: never inspected, never substituted).
- **Agent-created containers** (filtered Docker endpoint, `DockerScope.egress`): put on the scope's egress network
  (instead of default/bridge, or beside the agent's own networks, which are created `Internal`), given the proxy
  variables, the CA bundle and IPv6 off; leaving the egress network, host networking and foreign networks are refused.
- Switch: Settings ▸ Secrets ▸ Container network (next launch); administrators force it with `EgressEnforced`.

## Routing (for the shared browser package)

Routing is a step of its own, after the request checks and any substitution: `EgressProxyConfiguration.router`
(`EgressRouter`: `.internet`, `.dial(EgressDial)` to a Mac-loopback endpoint, `.refuse`). `SuffixRouter` sends `*.bc`
names through a table and refuses unknown ones; everything else goes to the internet path (company CA, proxy).
Substitution never looks at the route or the client: a scope (`EgressScope`: token, which projects it serves) is all
the proxy knows of a client, so a browser container is one more scope (`admitsProject` = every project it serves) with
the same snapshot. **The browser package plugs in by:** (1) making its gateway with `EgressGateway.ensure` (scope
key e.g. `browser`) and registering the scope; (2) `EgressGateway.attach(scopeKey:network:)` to each project's service
or workspace network when it is in use (`detach` after); (3) per route, a ContainerKit `PortForwarder` on
`EgressGateway.containerName(scope)` with `containerHost` = the service alias or workspace container name, and a
`SuffixRouter` table mapping `web.<project>.bc` / `<project>.bc:5173` to `.dial(EgressDial(endpoint: 127.0.0.1:<forwarder>))`;
(4) Chromium's proxy = `bellocode-proxy:3128` and its trust = the egress CA bundle. Routed names are plain http
(`.dial` refuses https). Tested: `RoutingTests` (in-process, two client scopes) and `LiveEgressRoutingTests`.

## Binding rules

A placeholder is replaced only when **all** hold: the request's scheme, host and port (from the CONNECT target; the
`Host` header must agree, else 421; SNI must agree, else the connection closes) equal a binding's (exact host, no
wildcards, https only); the method is allowed; the path, normalised, is under an allowed prefix on segment boundaries
(dot segments, encoded `/` `\` `.` `%`, NUL or `//` are refused as ambiguous); every occurrence of the placeholder sits
in an allowed place: a header whose whole value is `prefix + placeholder`, a query parameter's exact value, a JSON field
(dotted path) or form field exactly equal, or Basic-auth password; the grant's project is served by this gateway; not
revoked, expired or over its use limit. Otherwise the request is **refused** (403, `X-BelloCode-Refused: <rule>`, body
names the rule; chosen over pass-through so the agent gets a clear error and nothing reaches an unbound host). Split,
truncated, re-cased or encoded placeholders (base64 at any alignment, hex, percent, JSON escapes) are refused.
Upgrades (WebSocket, h2c) to a destination that receives secrets are refused; elsewhere they pass. Redirects go back to
the client; its next request is judged on its own (a placeholder sent on to another host is refused).

**Responses** from any destination a hidden secret is bound to are read whole (≤ 16 MB, ≤ 60 s), decoded
(gzip, deflate, brotli; others refused) and scanned in headers and body for the value as is, JSON-escaped,
percent-encoded, hex, base64 (every alignment, URL-safe, line-wrapped) and in percent-decoded and JSON-unescaped views
(partial or nested escaping). Raw, JSON- and URL-encoded copies are replaced with the thread's placeholder; any other
form blocks the response (502). Streaming responses from such destinations are cut at the bound (502, stated). Other
destinations stream through unbuffered. The brokered tool applies the same request rules on the Mac, follows a
redirect only if the new URL passes them, returns status, allowlisted headers and ≤ 64 KB, and withholds the whole
response if any form of the value appears.

## Adversarial results

`BELLOCODE_SECRET_LIVE=1 swift test --filter LiveEgress`: real proxy, gateway and an egress-enforced workspace built
from `WorkspaceSpec` on Rancher Desktop, run as a **project container and as a shared workspace**; loopback "bound" and
"attacker" servers. Every output, a `docker export` of the workspace, `docker inspect` of workspace and gateway and
everything the attackers received are scanned for the canary in every encoding. **57 attempts per workspace kind,
canary absent in all; every claimed path held.** Agent containers (default and agent-created networks, through the
real filtered endpoint): proxy forced, CA trusted, no DNS or direct route, substitution only for the binding, attacker
403, canary absent; host and egress networks refused.

| Attempt | Outcome |
| --- | --- |
| Bound host, allowed path and header (curl; node through CONNECT) | 200; value substituted; echo shows the placeholder |
| Placeholder to an unbound host; path outside the binding; `..` and `%2f` escapes; wrong method | 403 refused |
| Redirect to the attacker with `--location-trusted` | follow-up refused; attacker received 0 bytes |
| Bound server echoes the value into `Location` (partly percent-encoded) | 502 blocked |
| `Host` header ≠ tunnel host; SNI ≠ CONNECT host | 421; TLS refused (leaf names the CONNECT host) |
| Echo of headers and body: raw, gzip, deflate, br, chunked, split across 3-byte chunks, JSON, header, close-delimited | 200, placeholder only |
| Echo as base64, hex, zstd, partly percent-encoded | 502 blocked |
| Value in an allowed JSON field, echoed back; streaming response from a bound host | placeholder only; 502 at the bound |
| Placeholder in query, another header, text body, split across headers, base64, hex, `%5F`, upper-cased | 403 refused |
| DNS (getent, UDP and TCP to public resolvers), raw UDP (QUIC-style), IPv6 | no answer / unreachable / disabled |
| Direct IP with `--noproxy`, direct to the Mac (plain TCP, proxy port), `https_proxy` and SOCKS overrides | unreachable |
| Raw CONNECT carrying plaintext; CONNECT to a plain TCP port; forged gateway preamble | no upstream bytes; 400 |
| HTTP/2 offered, HTTP/2 prior knowledge | served as HTTP/1.1 |
| WebSocket upgrade to a bound host, or to an unbound host with the placeholder | 403 refused |
| Environment, all processes' environments, `ps`; filesystem export; `docker inspect` | no value |
| Everything the attacker TLS and plain-TCP servers received | 0 requests |

In-process suites (no Docker): bindings 14, scanner 9, proxy 7, broker 4 (`swift test --filter SecretKitTests`).
Found and fixed while testing: a partly percent-encoded echo (`sk%5Flive…`) slipped past exact-pattern scanning and
reached the attacker on redirect (now decoded views); a line-reading race let the gateway preamble swallow the CONNECT.

## The claim

**"The agent cannot see this value"**: BelloCode never supplies the value to the model or to any process the agent
controls; it sends it only to the secret's bound destinations over TLS and checks what comes back. This holds provided
BelloCode, macOS and the container VM, the Keychain and the bound destination are trusted, and the destination's
responses do not encode the value in a way the scanner cannot detect. Not covered: a malicious or compromised bound
destination (it can transform the value, or store and reflect it later; reflection through permitted fields is the
residual risk of the brokered tool), a compromised Mac, VM, proxy or network administrator, copies made before saving,
other local users of the Docker API (they can read the gateway token: substitution still obeys the bindings), and
timing or size side channels. Visible secrets, approved commands and the host pipe say "can see / can reveal".

## End to end and performance

`BELLOCODE_SMOKE_SECRETS=1 BELLOCODE_SMOKE_IMAGE=bellocode-secrets-test:1 BelloCode --smoke-test`: real opencode,
placeholder bound to a loopback test API. Without a model (session shell, the session environment set by
`PUT /api/session/{id}/environment`): the script's call reached the API with the real key, `printf $ANSWER_API_KEY`
showed the placeholder, the audit recorded destination and thread, opencode's data held no form of the key: **pass**.
With a model (`opencode/glm-5.3-flash-free`, 2 prompts): asked to script the call, then to print and recover the key,
the agent never showed it; the transcript (9 KB, tool inputs and outputs), opencode's data, the project, the
workspace's environments and the audit held no form of it: **pass**. It shared its thread with the shell leg, so the
agent's *own* substitution is unproven; the fixed harness's rerun was refused by the free tier. Installs
(`LiveEgressPerf`, fresh caches): npm 3.7 s direct, 3.6 s proxied; pip 4.5 s direct, 3.3 s proxied.

**Administrators:** `EgressEnforced` (forced in `com.bellocode.app`) fixes the switch; `NetworkHTTP(S)Proxy` and
`NetworkTrust…` apply upstream as in Containers 3.

**Needs the company network:** transparent-proxy chaining (its root in the Mac's admin trust); authenticating or
PAC-only proxies (unsupported); CONNECT to internal hosts; pinning clients; the gateway base image from Docker Hub (first build only).

**UX checklist (§E).** Cards and rows name label, handle, mode, destination, project; claims are glyph + words with a
popover; every state (proxy off/failed, unavailable, revoked, refusals naming the rule, audit gap) is shown. Keyboard:
Window ▸ Secrets…, ⌘N. Delete confirmed; Revoke reversible. Not run: VoiceOver, two windows, 30 sessions.

**Known gaps.** Project services see
the internal network but keep their own egress (they could relay unsubstituted traffic). Clients that only speak
HTTP/2 or QUIC fail. The gateway token is visible to Docker API clients. The CA is per Mac. Bodies
over 16 MB from secret-bound destinations are refused.
