# Execution modes, code roots and the filtered Docker endpoint

Where the agent's and the person's commands run, per project (owner decision 2026-11-18, [PLAN.md](../PLAN.md) §0),
building on [containers.md](containers.md). opencode, its file tools and BelloCode's git always stay on the Mac.
Research: [09 §2 and §4](../research/09-devcontainers-dual-env-chrome.md).

## Execution modes

Per project (Project Settings ▸ Environment), default in Settings ▸ Containers ▸ Execution; shown in the header,
context line, terminal strip and pane; a switch applies at once with Undo ([picker](../snapshots/exec-mode-picker-light.png)).

| Mode | What runs where |
| --- | --- |
| **Shared workspace** (default) | One container per developer (label `app.bellocode.shared`) mounting every code root and BelloCode's and opencode's worktree folders read-write at the same paths; default image, host uid:gid, one home volume. Any working directory inside the roots runs there (cwd = the thread's project; other repositories visible, so multi-repo needs no approval); outside is refused; a shared-mode project outside the roots is blocked with the fix. Idle stop only when no project using it is active. BelloCode's own services are not started (use `docker compose`). |
| **Project container** | Unchanged (own image, services, caches, MCP servers); optionally from a dev container file. |
| **Host shell, docker only** (weaker) | One plain `docker …` line per call (`HostDockerCommand`): quoted words only; shell syntax, line breaks, backslashes, `VAR=`, `-H/--host/--context/--config`, `context`, `login`, `cp`, `save`, `export`, `load`, `push`, buildx builder changes and `-o/--output/--iidfile/--cidfile` are refused, not interpreted. Rancher's `~/.rd/bin/docker` by absolute path via `execve`, `PATH=/usr/bin:/bin`, BelloCode's `DOCKER_CONFIG` (no credential helpers), the endpoint on `127.0.0.1`, binds limited to the project. No terminals. |

**Code roots** ([settings](../snapshots/exec-code-roots-dark.png)): first run suggests the folder holding the projects
(`~/Documents/Repos` for its owner; a project directly in `~` or `~/Documents` suggests itself). `CodeRoots` validation:
existing folder, links replaced by their target, never `/`, home or anything containing it, system locations (temporary
folders allowed), `/Users`/`/Volumes` themselves or credential folders (`~/Library`, `~/.ssh`, `~/.config`, `~/.docker`,
`~/.rd`…); nested roots dropped; a folder Rancher does not share gets instructions (Lima `override.yaml`), and once the
shared workspace runs a marker written on the Mac must be visible in each root. **Trusted roots:**
`EnvironmentService.trustedRoots` (BelloCore `TrustedRoots`) and `policyRoots(for:)` (project roots, then code roots)
are what Auto mode and risk notices treat as in scope; the helper configuration carries `trustedRoots` for the plugin.
**Migration** (once, `containers.executionModesMigrated`): projects whose record shows a container keep Project
container; the rest follow the default. **Administrators:** `ContainerCodeRoots` (array, `~/` allowed),
`ContainerCodeRootsLocked`, `ContainerDefaultExecutionMode` (`shared`/`project`/`host-docker`),
`ContainerAllowedExecutionModes`.

## Docker from the workspace (filtered endpoint)

`DockerFilterProxy` listens on `127.0.0.1`; containers reach it as `host.docker.internal`. Per-scope random token as the
client's base path (`DOCKER_HOST=tcp://host.docker.internal:<port>/<token>` with `DOCKER_BUILDKIT=0`, set per exec,
never in container configuration; the Mac's `DOCKER_*` never reach a command). One checked request per connection
(`Connection: close` upstream; CL+TE refused); upgrades only for allowed attach, exec and build session.
**`DockerFilterPolicy` (default deny, every operation):** objects must carry the scope's label
(`app.bellocode.agent-scope`) to be inspected, changed, attached, exec'd or deleted (then addressed by full ID); lists,
events and prunes get the scope's filter; creation adds labels, refuses `app.bellocode.*` labels and `bellocode-` names.
Binds (`-v`, `--mount`, Compose `volumes`) only inside the scope's roots both as written and with links resolved,
rewritten canonical, private propagation; named volumes the scope's (missing ones created with its labels), no driver
options. Refused: privileged, cap-add, devices/GPUs, host or foreign namespaces and volumes-from, security options but
`no-new-privileges` (always added), sysctls, cgroup parent, runtimes, masked-path changes, remote log drivers, `-P`,
non-loopback ports; limits clamped (4 GiB, 2 CPUs, 2048 PIDs, 32 containers). Images under the image policy unless the
scope built them; delete/tag only its own; classic `/build` only (labels added; no remote context, host network,
outputs, foreign tags); `/grpc` (buildx), push, load, import, swarm, plugins, secrets, auth refused. Refusals are
Docker-style 403s ("BelloCode refused this Docker request: …") listed per workspace in the pane. They appear in the
Containers view and Prune. The image needs the CLI and Compose plugin (`docs/features/workspace-image.Dockerfile`, from
`docker:29-cli`). **Hostile matrix:** 89 requests through the proxy to an in-process fake daemon (`DockerFilterTests`,
every case named in its source) all refused, none reached the daemon; bad tokens, smuggling and CL/TE conflicts refused.
Live: 24 hostile CLI commands from inside the shared workspace refused by the real daemon path; compose
up/exec/run/logs/ps/build and classic build work. **Residual risk:** a symlink swapped inside a root between check and
mount (TOCTOU) is followed in the Rancher VM; Dockerfile `FROM` images are not checked; the agent sees its token.

## Environment contract

The plugin's instruction (`Plugin/src/container.ts`, rewritten each run from the helper configuration, no secrets;
research 09 §2): mode, roots and working directory, image/OS/arch/user, file tools on the Mac vs commands on Linux,
Linux outputs stay inside, the filtered endpoint, localhost and forwarded ports, git on the Mac (hooks off, no container
credentials), company CA (keep TLS verification), never fall back to the host, host docker-only's one-command rule.

## Dev containers (Project container only)

Opt-in per project ([pane](../snapshots/exec-devcontainer-light.png)), `.devcontainer/devcontainer.json` with comments.
Supported: `image`; `build` (`dockerfile`, `context`, `args`, `target`, inside the project) built by BelloCode with
Rancher's `docker buildx build --load`; same-path workspace; `containerEnv`/`remoteEnv` (plain values); `remoteUser`;
`forwardPorts` (forwarded on start); `postCreateCommand`/`postStartCommand`, run only after the person approves their
digest. Refused with the reason (file unused, project image kept): `initializeCommand`, `features`, `privileged`,
`capAdd`, `securityOpt`, `runArgs`, `mounts`, other workspace folders, Compose, other lifecycle forms, `${localEnv:…}`;
`customizations`, `name`, `hostRequirements` listed as ignored.
## Verification

Unit: `CodeRootsTests`, `TrustedRootsTests`, `ExecutionModeTests` (resolution, migration, helper entries and directory
checks per mode, trusted roots, dev containers), `HostDockerCommandTests`, `DockerFilterTests` (hostile matrix),
`DevContainerTests`; plugin tests for the contract. Live (`BELLOCODE_CONTAINER_TESTS=1`): `LiveDockerFilterTests`
(shared workspace ready 0.1 s; compose stack to PONG 0.3 s). `make e2e-exec`: the shared workspace through the app's
launch path with the real opencode; its agent-prompt step was skipped on 2026-11-18 because the provider refused every
free model (usage limit, deprecations). Snapshots: `--snapshot containers` writes `containers-exec-*`; copies in
`docs/snapshots/exec-*.png`.

## UX checklist (03-ux-patterns.md §E)

Context: header, context line, terminal strip and pane name the mode, image and state; refusals name the request and
the folder rule. States: suggested/configured/managed roots, missing/link/system/home/credential/not-shared roots,
outside-roots, no image, runtime down, refused Docker requests, dev container refused/ignored/needs review; each with
its fix. Keyboard: Settings ▸ Containers and Window ▸ Project Environment… reach every control (standard buttons, radio
rows, toggles); Add Folder… uses the open panel. Reversible: mode switches apply at once with Undo; removing a root says
what changes. Accessibility: glyph + word everywhere, labelled rows. Not exercised: VoiceOver walk-through, two
windows, 30-session parallelism, a person at the screen.
