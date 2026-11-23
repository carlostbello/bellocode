# Containerised execution (M6-A, Containers 2 and 3, execution modes)

Everything the agent or the user **runs** executes in a Linux container on Rancher Desktop (dockerd), or, in host
docker-only mode, as one filtered `docker` command; opencode stays a native host process; nothing else falls back to the Mac. Spike: [G6-containers.md](../spikes/G6-containers.md).

> **Database: no migration (Containers 2 and 3).** No table is added: project fields (MCP servers, services, caches,
> `useGlobalMCP`, `globalMCPOptOut`) live in the `app_environment` JSON (decoded with defaults); the image policy,
> pulled images, global MCP list (`mcp.global`) and network settings (`network.settings`) in `app_preference`; the
> restart grant in `app_grant`; execution modes add optional fields to both (`executionMode`, `useDevContainer`,
> `approvedDevLifecycle`; `containers.defaults` code roots and default mode). Secrets are Keychain items only. The schema is unchanged (latest on develop: `v9-gitlab`).

## Architecture

- **ContainerKit**: Docker Engine API over `~/.rd/docker.sock` (no CLI), `WorkspaceManager`, `ServiceManager`,
  `PortForwarder`, `StdioRelay`, `ImagePolicy`, `ImageMCPRunner`, `CorporateNetwork`, `ImageBuildNetwork`, `NetworkProbe`.
- **bellocode-exec** (`Contents/Helpers`): opencode's shell and PTY command. Reads `<data>/opencode/bellocode-exec.json`
  (atomic, 0600), starts the container if needed (never pulls), relays command, stdin, window size and signals. Modes:
  `-c cmd`, interactive, `--stdio [--project DIR] -- argv…`, `--stdio --mcp ID [--project DIR]` (global image servers),
  `--stdio --refuse NAME`, `--service NAME`. Blocked: exit 125 and one `BelloCode: … The command was not run.` line.
  **Policy currency (S4):** each write puts `bellocode-exec.required` (launch epoch, generation) first; the helper runs
  only a configuration of this launch at least that generation (re-reads ~2 s), else refuses ("Commands refused").
- **Server launch** (`ContainerExecution`): helper as shell, `OPENCODE_DISABLE_PROJECT_CONFIG=1` (by default; see
  [opencode-config.md](opencode-config.md)), no formatter, LSP or
  `BUN_*`, git through the shim, the plugin's shell guard, routes or refusals for the isolated files' local MCP servers
  (`MCPRouting`), `NODE_EXTRA_CA_CERTS` and proxies computed at each launch.
- **EnvironmentService** (Engine, `@MainActor`, owned tasks, generation-checked): runtime polling and events, one
  `ProjectEnvironment` per project, helper configuration, idle stop, reaper, ports, file-watch bridge, secrets, setup
  scripts, MCP registration (project and global), stacks, services, caches, policy, network, prune, the self-check.

## Execution modes ([execution-modes.md](execution-modes.md))

Default **Shared workspace** (one container per developer, every code root at the same path: multi-repo without
approvals); **Project container** (as above); **Host shell, docker only** (one parsed `docker` command on the Mac).
`docker` in a workspace uses BelloCode's filtered endpoint; code roots are the policy layer's trusted roots.

## Coverage

| Path | Where it runs | Proof |
| --- | --- | --- |
| Agent shell tool, `/api/shell`; PTY with `$SHELL`; BelloCode terminals | container | self-check (smoke); terminal round trip |
| `!`cmd`` command templates | container | self-check (full) |
| opencode automations (2.3.1+; schedule conditions before) | off (disabled in config) | self-check reports Off |
| Worktree setup scripts | container, in the worktree | unit test; refused outside the mounts |
| Worktree `commands.start`, formatters, LSP | never set / off; flagged HOST if present | configuration scan |
| **Local MCP servers, per project** | **container** (`bellocode-exec --stdio`) | scan + scratch-server probe (smoke); live test; e2e tool call |
| **Global image MCP servers** (Settings, or `docker run` in the isolated config) | **own container**, no project mount | self-check "Global MCP server (image)" (smoke); live test; e2e tool call |
| Other local commands configured for all projects | **refused** (helper prints why) | unit test; scan reports "refused" |
| Remote MCP servers; compose stacks (Rancher's `docker compose`) | nothing on the Mac but the loopback forward | unit + live test |
| MCP servers added at runtime by another client | flagged (command unknown) | self-check "MCP servers added at runtime" |
| **Project services** | sibling containers, project network | live test (two services, health gate) |
| Repository plugins/agents/commands, `"shell"` | ignored by default (`OPENCODE_DISABLE_PROJECT_CONFIG`); trusted projects' text config via the plugin; a repository `"shell"` never wins over the inline one ([opencode-config.md](opencode-config.md)) | spike e2e; `OpenCodeConfigRealBinaryTests` |
| BelloCode's and opencode's host git | host, sandboxed (`HostGit`, shim) | hostile-repository matrix + "Host git" check |
| Shared workspace (any folder in the code roots); `docker` inside; host docker-only | shared container; filtered endpoint; Mac, one `docker` argv | unit, live, `make e2e-exec`; hostile matrix; `HostDockerCommandTests` |
| Commands receiving a secret (`secret_exec`; "the command can reveal this value") | one-shot sibling container, no network | fake-runtime e2e + live test |
| Workspace network with enforced egress ([secrets.md](secrets.md)) | internal network; HTTP(S) only via BelloCode's proxy | smoke "egress" line; `LiveEgress` |
| File tools, ripgrep | host (no project code runs) | n/a |

The self-check runs at launch (quick: host git, configuration, shell job, PTY, scratch stdio and image MCP servers) and on
demand ("Verify Isolation", full adds a command template, the automations probe (schedules on servers before 2.3.1) and
terminal). Probes leave markers: in the container proves the path, on the Mac an escape. **Isolated** only when every
applicable check ran and held (skipped: **Not verified**; escape or failure: **Problem**). `make smoke` fails unless
Isolated.

## MCP servers

opencode spawns a local server's `command` on the Mac, so BelloCode never gives it one that runs there. **Project
servers** (Project Settings ▸ Environment ▸ MCP servers: a command run *in the container*, non-secret variables) are
registered per location (`PUT /api/experimental/mcp/{name}?location[directory]=…`; 2.3.0: that location only, connects
at once) as `bellocode-exec --stdio --project <dir> -- <command>`: a non-TTY exec whose wrapper gives it the real stdin,
records its process group, passes TERM/INT/HUP on; bytes unchanged, one 64 KiB chunk in flight, EOF and exit code kept.
One sync per location at a time (requests coalesce; each registration is recorded as made, so removals are never
lost; a removal counts only once opencode's list no longer has the server: until then the row shows Removing…, it stays
recorded and the sync is retried with backoff): when the container is ready, after a reconnect, on every change. Relayed execs do not keep a container awake.

## Global MCP servers (Settings ▸ MCP Servers, Window ▸ MCP Servers…)

Registered for each project in use (a thread or new-thread draft of it is shown: the window marks the project in use
when it builds the view's context, v1.0.1 NF03), per location; Project Settings ▸ Environment turns all
or single ones off; a project server of the same name wins. List in `mcp.global`; secret values only in the Keychain
(`app.bellocode.mcp`, `<id>/header|env/<name>`), read at registration, sent only in opencode's runtime registration (never
a file, the store, the helper configuration or a log; the editor shows "Saved in Keychain"; missing: not registered).

- **Remote endpoint**: `{type: remote, url, headers}` (OAuth discovery off with headers); https (plain http only to
  loopback); TLS checked by opencode with its roots plus the enterprise bundle. **Gateway readiness:** the company MCP
  gateway is one such entry, its URL plus an `Authorization` header; nothing else is needed.
- **Container image** (`docker run -i --rm IMAGE ARGS`): `bellocode-exec --stdio --mcp <id> --project <dir>`. The helper
  (never pulling) creates `bellocode-mcp-<id>-<projectKey>`, attaches before start (stdin open once, no TTY), relays,
  removes it when the connection ends; entrypoint/CMD semantics kept. **No project folder is mounted**; explicit mounts
  are listed with their access (off by default); `capDrop ALL`, `no-new-privileges`, 1 CPU, 1 GiB, 512 pids; network
  outbound or none; image policy applied. Secrets reach the create (`-e`, so `inspect` shows them while it runs) via
  the helper's environment. **Shared** (opt-in): one `bellocode-mcp-<id>` keep-alive (needs `/bin/sh`), secrets per
  exec only, stopped when idle. Connections end when the project's container idles out. Pull, Restart, Logs (stderr,
  256 KiB); leftovers of killed helpers are removed after a removal and at runtime start.
- **Compose stack** (full compose spec): Rancher's `~/.rd/bin/docker-compose` by explicit path (never `PATH` or Docker
  Desktop's plugin), Rancher's socket, BelloCode's own `DOCKER_CONFIG` (Rancher's buildx linked in), project
  `bellocode-mcp-<key>`; an existing file (its folder is the project: `build`, `env_file` work) or one written here.
  `config --format json` first: privileged, caps, devices, host namespaces, bind mounts need **Run as written**; the
  engine socket is always refused; image-only services follow the policy. The override labels containers, adds
  certificates and proxies (builds: proxy args, `bellocode-ca` context) and `!reset`s published ports; the endpoint is
  forwarded to a stable loopback port, registered as remote. `up --wait` on first use, `stop` idle, `down` on removal.

Local servers in BelloCode's isolated opencode files: a mount-free `docker run` runs its image the same way (`--mcp
cfg-<name>`); any other command stays refused. Runtime adds by other clients are flagged by the self-check.

**Import…** reads only when asked, read-only: opencode (`~/.config/opencode/opencode.json(c)`, `config.json`; 2.x
`mcp.servers`, 1.x `mcp`), Claude Desktop (`claude_desktop_config.json`), Claude Code (`~/.claude.json`), Cursor
(`~/.cursor/mcp.json`), VS Code (`Code/User/mcp.json`). `docker run` entries become image servers (`-e`, `-e NAME` from
the entry's env, `--network bridge|none`, `--entrypoint`; `-v` listed, left out unless included; `-t`, `--name`, `--pull`,
`-p`, limits dropped with a note; `--privileged`, `--env-file`, `--mount`, `--network host`, named volumes, the engine
socket refused); URLs become remote; host programs (`npx`, `uvx` …) and `docker compose` are listed with why.
Secret-looking values go to the Keychain on Add; placeholders (`${input:…}`, `{env:…}`) ask for one.

## Services ("Rancher workloads")

Source: the project's checked-in `compose.yaml` / `compose.yml` / `docker-compose.y(a)ml`, else services defined in
the Environment pane (same format). YAML is read by BelloCode's own subset parser (**no dependency**; block maps and
lists, quoted and plain scalars, flow lists/maps, `|`/`>` blocks; anchors, merge keys, tags and multiple documents are
refused with the line). **Supported per service:** `image`, `environment` (map or list), `ports` (container ports),
`volumes` (named only), `depends_on` (list, or `condition: service_started | service_healthy |
service_completed_successfully`), `healthcheck` (`test`, `interval`, `timeout`, `start_period`, `retries`, `disable`),
`command`. **Refused** (service not started, listed): `build`, bind mounts/host paths, `privileged`, `cap_add`,
`devices`, `network_mode`, `pid`, `ipc`, `security_opt`, `userns_mode`, `volumes_from`, `sysctls`, `runtime`,
`extra_hosts`, `cgroup_parent`. **Ignored** (listed): everything else, `KEY` without a value, `${…}` (no interpolation).

Each service is `bellocode-svc-<key>-<name>` on the project network `bellocode-net-<key>` (internal `-offline` when the
project is offline), DNS alias = its name; the workspace joins that network. Image user and default capabilities,
`no-new-privileges`, no extra capabilities or devices, limits (1 CPU, 1 GiB, 1024 pids), **nothing published**: a port
opens on demand through a relay in the workspace container to `127.0.0.1` on the Mac. Lifecycle: start with the
workspace in dependency order, a dependant waits for `service_healthy` (bounded by the healthcheck's own timing, at
most 5 min; unhealthy, exited or no healthcheck blocks it with the reason); stop on idle with the workspace; recreated
when the definition changes; removed when no longer defined (volumes kept); logs; **Delete Service Data…** lists the
volumes and asks once. UI: Environment ▸ Services (state with health, Open per port, Terminal, Logs, Restart, Delete
Data, refused/ignored keys, editor or Reload) and the Containers view. Agent tools: `list_services`, `service_logs`
(≤ 500 lines, 16 KB, cut marked), `restart_service` (approval first time per project, "Always" grant); none removes data.

## Image policy (base images and pulled images)

Images are unsigned and no internal registry distributes them (owner, 2026-11-18): most projects build from a
Dockerfile on public base images. The policy covers what BelloCode pulls (base images, pulled workspace and service
images): an allowlist (empty: any) of registries or repository prefixes (`docker.io/library/`; Docker normalisation,
boundary matching), optional digest pins, pull policy (`missing`, `always`, `never`). A dev container built here is checked by its
Dockerfile's base images (`FROM`, `COPY --from`, `RUN --mount=from=`, before each build), never by the local tag it gets. A refused image is never pulled or
run ("Image not allowed", with the reason in the banner, the helper and Services). Builds an agent starts through the
filtered Docker endpoint are checked the same way: the Dockerfile is read from the context as it streams, plain tar or
gzip (Compose's classic builder and `docker build --compress` send gzip; bzip2/xz contexts are refused).
**For administrators** (managed preferences win over Settings, shown read-only): keys forced by a configuration profile
in domain `com.bellocode.app`, or a root-owned, non-writable `/Library/Preferences/app.bellocode.policy.plist`:
`ContainerImageAllowlist` (array), `ContainerImageRequireDigest` (bool), `ContainerImagePullPolicy` (string),
`ContainerImageRequireSignature` (bool), `ContainerImageSignaturePublicKey` (PEM), `ContainerDefaultImage` (string);
**Containers 3:** `NetworkTrustEnterpriseCertificates` (bool), `NetworkTrustedCertificates` (array of SHA-256
fingerprints), `NetworkHTTPProxy`, `NetworkHTTPSProxy` (URLs), `NetworkNoProxy` (array or comma list),
`NetworkDiagnosticsURLs` (array). Pulled images that were absent before are recorded (for Prune).

**Signatures: off** (seam `ImageSignatureVerifier`; no switch; an administrator's key still **refuses every image**).

## Corporate network (transparent proxy, TLS interception)

Nothing to configure in the common case. **Trust enterprise certificates in containers** (Settings ▸ Containers;
automatic: on when the Mac trusts root CAs of the admin domain, i.e. a profile or an administrator installed them)
exports the chosen roots natively (`SecTrustSettingsCopyCertificates`; certificates only, never keys or identities;
non-CA certificates never offered; default: admin-domain self-signed CAs) to `<data>/network/certs/`
(`enterprise-roots.pem`; `ca-bundle.pem` = the Mac's built-in roots plus them). Every BelloCode container mounts it
read-only at `/etc/bellocode/certs` (roots also in `/usr/local/share/ca-certificates/`, `/etc/pki/ca-trust/source/`)
with `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`, `GIT_SSL_CAINFO`, `CURL_CA_BUNDLE` (bundle), `NODE_EXTRA_CA_CERTS`
(roots); a workspace also gets the bundle read-only at each distribution's default bundle file (Debian, Ubuntu, Alpine,
Arch `/etc/ssl/certs/ca-certificates.crt`; Alpine `/etc/ssl/cert.pem`; the RHEL family `/etc/pki/tls/certs/ca-bundle.crt`,
`/etc/pki/tls/cert.pem`, `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`; openSUSE `/etc/ssl/ca-bundle.pem`,
`/var/lib/ca-certificates/ca-bundle.pem`; a link in the image is resolved by the daemon; GV09), so nothing of its image
runs as root for it (a program that reads only a hashed certificate folder, or Java's `cacerts`, does not see the
enterprise roots); opencode gets `NODE_EXTRA_CA_CERTS`
at each launch (Bun reads neither the Keychain nor macOS proxies). **Proxies:** `HTTP(S)_PROXY`/`NO_PROXY` from an
administrator, else the Mac (environment, then System Settings; no PAC), to containers and opencode; `NO_PROXY` always
adds loopback and service names; a Mac-loopback proxy becomes `host.docker.internal`. **Network diagnostics** fetches
configurable URLs (default `https://gitlab.novacoast.com`, `https://registry.npmjs.org`, `https://pypi.org/simple/`) in a
running workspace (curl, node, python3 or wget) and from the Mac with opencode's trust: status, issuer, proxy headers,
"TLS intercepted by …". **Verified here** with a local test CA and HTTPS server on a container network (trusted with the
bundle, refused without). **Needs the corporate network:** the proxy's signing root and its trust domain, which hosts it
intercepts, PAC-only proxies, images without a trust-store tool, Bun accepting the real chain.

## Image builds (API for the image-build feature)

`ImageBuildNetwork` (`EnvironmentService.imageBuildNetwork(for:)` adds service names to `NO_PROXY`): `buildArgs()`
(Docker's predefined proxy args, not in history), `contextEntries()` (bundles at `bellocode-ca/` in a tar context),
`instrument(dockerfile:source:)` (after every `FROM`, heredocs and continuations respected: `COPY` of bundle and roots,
`SSL_CERT_FILE` … `NODE_EXTRA_CA_CERTS`; no `RUN`), `cliArguments()` for `docker buildx` (`--build-context`,
`--build-arg`). `EngineClient.buildImage` takes `buildArgs`, `dockerfile`, `networkMode`. Live: a `RUN` fetching from the
test CA's server passes instrumented, fails without. `FROM` pulls and `ADD <url>` use the daemon's trust (Rancher
Desktop's VM, which imports the Mac's roots): verify on the corporate network.

## Caches

npm `~/.npm`, pnpm `~/.local/share/pnpm/store`, pip `~/.cache/pip`, Cargo `~/.cargo/registry`, Go `~/go/pkg/mod`,
Gradle `~/.gradle/caches`, Maven `~/.m2/repository` (home `/home/bellocode`), or the image's (`app.bellocode.caches`,
`app.bellocode.cache.<kind>=/path`; a label path must be absolute and plain, without `.` or `..`, and not `/`, `$HOME` or
above it, `/etc/bellocode`, `/tmp/.bellocode`, `/proc`, `/sys` or `/dev`, else the default is used; a cache over a mounted
folder or a second cache at one path is not mounted; AF09): named volumes nested in home, the project's own (`bellocode-<key>-cache-<kind>`)
unless shared (`bellocode-shared-cache-<kind>`). Project Settings ▸ Environment ▸ Caches turns them on, off or shared;
Settings ▸ Containers ▸ Caches lists sizes and empties one after confirming (refused while a running container uses one).

## Housekeeping

**Prune BelloCode Resources…** (Settings ▸ Containers, Window menu) lists exactly: stopped BelloCode containers, unused
BelloCode volumes of projects (and stacks) BelloCode no longer has (never a known project's home or data, never a shared
cache), unattached BelloCode networks, unused images BelloCode pulled. One confirmation; items that changed since are kept
and named. Anything without BelloCode's labels is never listed.
**Ownership:** a container, volume or network with one of BelloCode's names but without the labels of its role (shared
browser and profile, egress gateway and network, workspace home and caches, service volumes and networks, image MCP
containers, compose-stack projects) is never stopped, removed, recreated or adopted: the operation fails with "…was not
created by BelloCode…", naming it (`ForeignResourceError`, `ResourceOwnershipTests`, `BrowserOwnershipTests`).

## Workspace, failures, ports, file watching

One container per project (`bellocode-ws-<key>`), project and worktrees at the same paths, host uid:gid, no capabilities,
`no-new-privileges`, `init`; saved policy in force first (S3). A dev container's named `remoteUser` is resolved to its
uid:gid from the image's `/etc/passwd` (read from a never-started container) and refused if root or undefined (a bare
uid gets its group the same way, so the group is always recorded); `$HOME` and nested caches are given to the user by
BelloCode's own image (the egress gateway's), never the project's, and nothing runs as root in the workspace. That
helper mounts the home and cache volumes at fixed folders of its own (never at a path the image names, never nested in
a volume), chowns only their root folders as root with `CAP_CHOWN` alone, and makes the cache folders nested in `$HOME`
in a second run as the user with no capabilities, so nothing a workspace left in a volume (a link, a program in a
populated or shared cache) is followed or run by it (v1.0.1 AF09). Every
exec into it (helper commands, terminals, relayed MCP servers, probes, diagnostics, port relays, the shared browser's
routes) runs as the container's recorded numeric uid:gid against its inspected ID, never as a name Docker would
resolve from the container's own (writable) `/etc/passwd`; a container whose user is not a nonzero numeric uid:gid gets
no exec (`WorkspaceManager.execTarget`, `WorkspaceError.unverifiedUser`). A container recorded with a name, root or no group (one
created before v1.0.1's AF09/AF10 fixes) counts as outdated ("user not verified"): it is never reused or adopted and is
replaced by one created with the verified user. The workspace keeps no capabilities (no CHOWN/DAC_OVERRIDE/FOWNER for home preparation) and `/tmp/.bellocode`
is a 1777 tmpfs. Recreated when image, setting, folder identity or the
certificate selection changes; stopped when idle; archiving only hides; volumes go only by **Delete Container and
Data…** (lists, asks once). Every blocked state is a phase with message and fix (helper configuration, banner, status
item, context line). Ports forward on demand to `127.0.0.1` through an exec relay. File-watch bridge: FSEvents → `touch`.

## Host git, secrets, host requirements

Host git stays on the Mac for BelloCode and opencode (shim), confined at one choke point (`HostGit`): `sandbox-exec`
(only the real git, no network except fetch/push, writes only in the repository and its own metadata: a linked
worktree's gitdir only as `<commondir>/worktrees/<name>` whose `gitdir` points back at this checkout, a submodule's only
under an enclosing superproject's `.git/modules`, a `commondir` only for such a worktree; `HostGitWritableRootsTests`), `GIT_CONFIG_COUNT` overrides (hooks,
fsmonitor, pagers, editors, signing, helpers, `protocol.allow`), an allowlisted environment; 28 configuration vectors
and 15 hooks fire nothing (`HostGitIsolationTests`, also with BelloCode's credential helper present). HTTPS remotes on a
configured GitLab instance authenticate through `bellocode-exec --git-credential`, the only program the network profile
adds, answering only git processes the app launched ([git-parity.md](git-parity.md) "HTTPS credentials"). Git run outside BelloCode is unconfined; `sandbox-exec` is
deprecated (removal makes host git fail closed). Secrets: delivered to containers by one-use reference; `secret_exec`
runs the approved exact command in a one-shot sibling (no network, project read-only, value on stdin), created and
exec'd as the image's verified numeric uid:gid (root or an undefined user refused before it exists; v1.0.1 AF10); see
[orchestration-extras.md](orchestration-extras.md#3-secrets). Host executables: `git`, `/bin/sh`, bundled `opencode`,
`bellocode-exec`, `rg` (pinned SHA-256, re-checked before signing); licences in `Resources/Acknowledgements/`.
Host git stays on the Mac for BelloCode and opencode (shim), confined by `HostGit`: `sandbox-exec` (only the real git, no
network except fetch/push, writes only in the repository), `GIT_CONFIG_COUNT` overrides (hooks, fsmonitor, pagers,
editors, signing, helpers, `protocol.allow`), an allowlisted environment; 28 vectors and 15 hooks fire nothing.
`sandbox-exec` is deprecated (removal makes host git fail closed). Secrets reach containers by one-use reference;
`secret_exec` runs in a one-shot sibling ([orchestration-extras.md](orchestration-extras.md#3-secrets)). Host executables:
`git`, `/bin/sh`, bundled `opencode`, `bellocode-exec`, `rg` (pinned SHA-256); licences in `Resources/Acknowledgements/`.

## For the security team (decisions code cannot make)

1. **Image provenance and signing**: allowed registries and prefixes, digest pins, which signature scheme (key-based
   cosign, keyless Fulcio/Rekor, Notary v2) with which keys or roots; until a verifier exists, requiring signatures
   refuses everything (today: unsigned, public base images). 2. **Registries and credentials** (per-host Keychain items).
3. **Egress**: containers default to outbound access; offline per project; organisation egress belongs in the network.
4. **Mounts**: project and worktrees read-write by design; user and MCP mounts read-only by default, listed.
5. **Host git at all** (confined, but on the Mac with the user's credentials and a deprecated sandbox).
6. **Secrets and grants**: agent-proposed secret commands, "Always" approvals, service-restart, schedule and HTML-visual
   grants, plain-HTTP GitLab. 7. **Services**: agent-edited compose files start services without review (same
   boundary, image policy, never privileged or published).
8. **MCP servers**: whether project and global servers are allowed, which images, shared containers, mounts, and the
   gateway's authentication (one header today). 9. **Threat model**: the Rancher VM, other Docker API clients and local
   processes can influence containers. 10. **Enterprise roots**: which roots containers and opencode trust
   (`NetworkTrustedCertificates`) and whether user-domain roots may be chosen.

## UX checklist (03-ux-patterns.md §E)

Context: every row names project, service or container; thread line shows `Container: image (state)`. States:
not started, pulling, starting, running, healthy/unhealthy, stopped (exit code), waiting (blocked dependency, reason),
refused (keys or policy), failed; MCP connected/starting/failed/sign-in/off; empty and unusable definitions say why.
Global MCP rows: Off, Ready, Starting, Connected, Failed, Sign-in needed, Needs attention, Refused, Pulling n%;
diagnostics Reached/Failed. Keyboard: Window ▸ Containers…, Project Environment…, MCP Servers…, Verify Container
Isolation, Prune BelloCode Resources…; standard controls; the MCP editor and Import review are inline (no sheets).
Accessibility: glyph + word everywhere, labelled toggles and editors. Destructive actions (Delete Service Data, Clean
cache, Prune, Delete Container and Data) list exactly what goes and confirm once; MCP removal (project and global) has
Undo. Not exercised: VoiceOver walk-through, two windows, Reduce Motion (nothing animates), 30-session parallelism.

## Known gaps

MCP servers register for project roots, not worktrees. Isolated-config edits apply at the next launch. Service images
keep their user and default capabilities. Shared image containers need `/bin/sh`; stack relays need a relay tool in the
endpoint image; stack builds get certificates only where the Dockerfile copies `bellocode-ca`; PAC proxies are not
read; a selection change reaches opencode at its next start. Narrow thread headers can overlap (pre-existing).

Measured (Rancher Desktop 1.25, arm64): container ready 115–196 ms; terminal round trip 133–144 ms; watch bridge 61 ms;
two redis services healthy 2.3 s; project MCP server connected in the container 4.7 s; global image server through
opencode 4.5 s; compose stack (built) connected 4.4 s; test CA trusted, diagnosed and built 9.9 s. Snapshots:
`docs/snapshots/containers{,2,3}-*.png`, `exec-*.png`. Commands: `make smoke`, `make e2e-containers`, `make e2e-exec`,
`--snapshot containers3`, Live.
