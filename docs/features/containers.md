# Containerised execution (M6-A, Containers 2)

Everything the agent or the user **runs** executes in a Linux container on Rancher Desktop (dockerd); opencode stays a
native host process; nothing falls back to the Mac. Spike: [G6-containers.md](../spikes/G6-containers.md).

> **Database: no migration.** Containers 2 adds no table: new project fields (MCP servers, services, caches) live in
> the `app_environment` JSON (`v6`, decoded with defaults), the image policy and pulled-image list in `app_preference`,
> the restart grant in `app_grant` (kind `serviceRestart`). The schema stays at `v8-app-outbox`.

## Architecture

- **ContainerKit**: Docker Engine API over `~/.rd/docker.sock` (no CLI), `RuntimeState`, `WorkspaceManager` (create,
  recreate on change, reaper, probes, caches, prune), `ServiceManager`, `PortForwarder`, `StdioRelay`, `ImagePolicy`.
- **bellocode-exec** (`Contents/Helpers`): opencode's `SHELL`/`config.shell` and the PTY command. It reads
  `<data>/opencode/bellocode-exec.json` (atomic, 0600), finds the project, starts the container if needed (never
  pulls) and relays command, stdin, window size and signals. Modes: `-c cmd`, interactive, `--stdio [--project DIR] --
  argv…` (local MCP servers), `--stdio --refuse NAME`, `--service NAME` (a shell in a service). Blocked: exit 125 and
  one `BelloCode: … The command was not run.` line. **Policy currency (S4):** each write puts `bellocode-exec.required`
  (launch epoch, generation) first; the helper runs only a configuration of this launch at least that generation
  (re-reads ~2 s), else refuses; a failed write shows "Commands refused" in Settings and is retried.
- **Server launch** (`ContainerExecution`): helper as shell, `OPENCODE_DISABLE_PROJECT_CONFIG=1`, formatter and LSP
  off, opencode's git through the `git` shim, no `BUN_*`, the plugin's `shell.create.before` guard, and refusals for
  local MCP servers in the isolated configuration files (`MCPRouting`).
- **EnvironmentService** (Engine, `@MainActor`, owned tasks, generation-checked): runtime polling and events, one
  `ProjectEnvironment` per project, helper configuration, idle stop, reaper, ports, file-watch bridge, secrets, setup
  scripts, MCP registration, services, caches, policy, prune, the isolation self-check.

## Coverage

| Path | Where it runs | Proof |
| --- | --- | --- |
| Agent shell tool, `/api/shell`; PTY with `$SHELL`; BelloCode terminals | container | self-check (smoke); terminal round trip |
| `!`cmd`` command templates | container | self-check (full) |
| opencode schedule conditions | off (schedules disabled) | self-check reports Off |
| Worktree setup scripts | container, in the worktree | unit test; refused outside the mounts |
| Worktree `commands.start`, formatters, LSP | never set / off; flagged HOST if present | configuration scan |
| **Local MCP servers, per project** | **container** (`bellocode-exec --stdio`) | scan + scratch-server probe (smoke); live test; e2e tool call |
| **Local MCP servers configured for all projects** | **refused** (helper prints why) | unit test; scan reports "refused" |
| MCP servers added at runtime by another client | flagged (command unknown) | self-check "MCP servers added at runtime" |
| **Project services** | sibling containers, project network | live test (two services, health gate) |
| Repository plugins/agents/commands, `"shell"` | ignored (`OPENCODE_DISABLE_PROJECT_CONFIG`) | spike e2e |
| BelloCode's and opencode's host git | host, sandboxed (`HostGit`, shim) | hostile-repository matrix + "Host git" check |
| Commands receiving a secret (`secret_exec`) | one-shot sibling container, no network | fake-runtime e2e + live test |
| File tools, ripgrep | host (no project code runs) | n/a |

The self-check runs at launch (quick: host git, configuration, shell job, PTY, a scratch MCP server) and on demand
("Verify Isolation", full adds a command template, schedule condition and terminal). Each probe writes a marker under
`/tmp`: found in the container proves the path, found on the Mac proves an escape. **Isolated** only when every
applicable check ran and held; a skipped check gives **Not verified**, an escape or failure **Problem**. `make smoke`
fails unless Isolated.

## MCP servers

opencode spawns a local server's `command` on the Mac, so BelloCode never gives it one that runs there. **Project
servers** (Project Settings ▸ Environment ▸ MCP servers: name, command run *in the container*, non-secret variables)
are registered per location with `PUT /api/experimental/mcp/{name}?location[directory]=…` (2.3.0: scoped to that
location, connects at once, spawn cwd = the location) as `bellocode-exec --stdio --project <dir> -- <command>`; the
helper runs it in a non-TTY exec under a wrapper that gives it the exec's real stdin, records its process group, passes
TERM/INT/HUP on and stops leftovers on exit. Bytes pass unchanged; one 64 KiB input chunk in flight; end of input is
passed on; the exit code is kept. Registration happens when the project's container is ready, after a reconnect and on
every change (removed servers are removed); relayed execs do not keep a container from idling (an idle stop ends them
and the next activation reconnects them). **Rule for servers configured for all projects** (a `mcp.servers` entry in
BelloCode's isolated configuration files): **refused**. They have no project, so no container, mounts or image, and a
shared "tools" container would be a cross-project sandbox with its own policy surface; `OPENCODE_CONFIG_CONTENT`
replaces each such entry (it wins and replaces whole entries on 2.3.0) with `bellocode-exec --stdio --refuse <name>`,
whose message opencode shows as the server's failure. Interception of runtime adds is not possible (BelloCode is the
API's only client); the self-check flags any server it cannot account for.

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
volumes and asks once. UI: Environment ▸ Services (state glyph + word with health, Open per port into the built-in
browser, Terminal = `bellocode-exec --service` tab, Logs, Restart, Delete Data, refused/ignored keys, editor or Reload)
and the Containers view. Agent tools: `list_services`, `service_logs` (≤ 500 lines, 16 KB, cut marked),
`restart_service` (approval card the first time per project, "Always in This Project" grant). No tool removes data.

## Image policy (workspace and services)

Allowlist of registries (`registry.acme.internal`) or repository prefixes (`registry.acme.internal/dev/`,
`docker.io/library/postgres`; Docker normalisation, boundary matching), optional digest pins (`@sha256:` + 64 hex), pull
policy (`missing` default, `always` = pull before every create/recreate, `never`). A refused image is never pulled or
run: phase "Image not allowed" with the specific message in the banner, the helper's refusal, the Services section.
**For administrators** (managed preferences win over Settings, shown read-only): keys forced by a configuration profile
in domain `com.bellocode.app`, or a root-owned, non-writable `/Library/Preferences/app.bellocode.policy.plist`:
`ContainerImageAllowlist` (array), `ContainerImageRequireDigest` (bool), `ContainerImagePullPolicy` (string),
`ContainerImageRequireSignature` (bool), `ContainerImageSignaturePublicKey` (PEM), `ContainerDefaultImage` (string).
Images BelloCode pulled that were absent before are recorded (for Prune).

**Image signatures: not verified (seam).** Key-based cosign verification is feasible natively (registry v2 API with
the Keychain credentials and Bearer token flow, the `sha256-<digest>.sig` tag or OCI referrers, ECDSA P-256 over the
simple-signing payload with CryptoKit, payload digest = the pinned digest = the daemon's `RepoDigests`). It was not
shipped because it could not be validated soundly here: no cosign-signed test image, no way to create real signatures
without a host CLI, and cosign 2.4+ bundles, keyless (Fulcio, Rekor, TUF roots) and Notary v2 (X.509 trust policies)
each need their own verifier. `ImageSignatureVerifier` is the seam; `ContainerImageRequireSignature` without a
verifier **refuses every image** (never "unverified").

## Caches

npm `~/.npm`, pnpm `~/.local/share/pnpm/store`, pip `~/.cache/pip`, Cargo `~/.cargo/registry`, Go `~/go/pkg/mod`,
Gradle `~/.gradle/caches`, Maven `~/.m2/repository` (home = `/home/bellocode`), or the path an image declares
(`app.bellocode.caches=npm,pip`, `app.bellocode.cache.<kind>=/path`). Each is a named volume nested in the home
volume, owned by the user; the project's own (`bellocode-<key>-cache-<kind>`, deleted with the project) unless the
person shares that cache (`bellocode-shared-cache-<kind>`, no project label). Project Settings ▸ Environment ▸ Caches
turns caches on or off and shares them; Settings ▸ Containers ▸ Caches lists sizes and empties one after confirming
(refused while a running container uses it; stopped users are recreated on next use).

## Housekeeping

**Prune BelloCode Resources…** (Settings ▸ Containers, Window menu) lists exactly: stopped BelloCode containers
(workspaces, services, one-shot secret commands), unused BelloCode volumes of projects BelloCode no longer has (never a
known project's home or data, never a shared cache), BelloCode networks with nothing attached, unused images BelloCode
pulled. One confirmation; then it removes only items that still qualify (anything started or used since is kept and
named). Anything without BelloCode's labels is never listed.

## Workspace, failures, ports, file watching

One container per project (`bellocode-ws-<key>`), project and worktree folders at the same paths, host uid:gid, no
capabilities, `no-new-privileges`, `init`; saved policy in force before anything runs (S3). Recreated when image,
setting or folder identity changes; stopped when idle; archiving only hides. Volumes are deleted only by **Delete
Container and Data…** (lists containers, volumes and networks; asks once). Every blocked state (runtime down,
containerd, no image, image not allowed, pull failed, folder not shared, settings unavailable) is a phase with message
and fix, written to the helper configuration and shown as a banner, status item and context line. Ports: a listener is
forwarded on demand to `127.0.0.1` through an exec relay; nothing is published. File-watch bridge: FSEvents →
`touch -c -m -r` in the container (61 ms to a Node watcher).

## Host git, secrets, host requirements

Host git stays on the Mac for BelloCode and opencode (shim), confined at one choke point (`HostGit`): `sandbox-exec`
(only the real git, no network except fetch/push, writes only in the repository), `GIT_CONFIG_COUNT` overrides (hooks,
fsmonitor, pagers, editors, signing, helpers, `protocol.allow`), an allowlisted environment; 28 configuration vectors
and 15 hooks fire nothing (`HostGitIsolationTests`). Git run outside BelloCode is unconfined; `sandbox-exec` is
deprecated (removal makes host git fail closed). Secrets: delivered to containers by one-use reference; `secret_exec`
runs the approved exact command in a one-shot sibling (no network, project read-only, value on stdin); see
[orchestration-extras.md](orchestration-extras.md#3-secrets). Host executables: `git`, `/bin/sh`, bundled `opencode`,
`bellocode-exec`, `rg` (pinned SHA-256, re-checked before signing); licences in `Resources/Acknowledgements/`.

## For the security team (decisions code cannot make)

1. **Image provenance and signing.** Which registries and prefixes to allow, whether digest pins are required, and
   which signature scheme to adopt (key-based cosign, keyless with Fulcio/Rekor, or Notary v2) with which keys or
   roots; until a verifier exists, requiring signatures refuses everything.
2. **Registries and credentials** (per-host Keychain items today). 3. **Egress**: containers and services default to
   outbound access; offline per project; organisation egress belongs in the network.
4. **Mounts**: project and worktrees read-write by design; user mounts read-only by default.
5. **Host git at all** (confined, but on the Mac with the user's credentials and a deprecated sandbox).
6. **Secrets and grants**: agent-proposed secret commands, "Always" approvals, service-restart grants, schedule and
   HTML-visual grants, plain-HTTP GitLab.
7. **Services**: whether agent-edited compose files may start services without review (today: they run inside the
   same container boundary, under the image policy, never privileged or published).
8. **MCP servers**: whether project MCP servers are allowed, and whether a shared "tools" container should replace
   the refusal for servers configured for all projects.
9. **Threat model**: the Rancher VM, other Docker API clients and other local processes can influence containers.

## UX checklist (03-ux-patterns.md §E)

Context: every row names project, service or container; thread line shows `Container: image (state)`. States:
not started, pulling, starting, running, healthy/unhealthy, stopped (exit code), waiting (blocked dependency, reason),
refused (keys or policy), failed; MCP connected/starting/failed/sign-in/off; empty and unusable definitions say why.
Keyboard: Window ▸ Containers…, Project Environment…, Verify Container Isolation, Prune BelloCode Resources…; panes are
standard controls. Accessibility: glyph + word everywhere, labelled toggles and editors. Destructive actions (Delete
Service Data, Clean cache, Prune, Delete Container and Data) list exactly what goes and confirm once; MCP removal has
Undo. Not exercised: VoiceOver walk-through, two windows, Reduce Motion (nothing animates), 30-session parallelism.

## Known gaps

Signature verification (seam). MCP servers are registered for project roots (as app tools are), not for worktree
locations. Edits to the isolated global configuration while running apply at the next launch (the scan flags them).
Service images run as their own user with default capabilities. The thread header lets a long container crumb
overlap the Agents chip at narrow widths (pre-existing). Remote runtimes. Snapshot glass drawn opaque.

Measured (Rancher Desktop 1.25, arm64): container ready 115–196 ms; terminal round trip 133–144 ms; watch bridge
61 ms. Live tests end to end: workspace plus two redis services healthy and reachable by name 2.3 s; project MCP server
registered, connected through the relay and proven in the container 4.7 s (both include container creation).
Snapshots: `docs/snapshots/containers-*.png`, `containers2-*.png`. Commands: `make smoke`, `make e2e-containers`,
`BELLOCODE_CONTAINER_TESTS=1 swift test --filter Live`, `--snapshot containers`.
