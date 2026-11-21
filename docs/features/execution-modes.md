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
| **Host shell, docker only** (weaker) | One plain `docker …` line per call (`HostDockerCommand`): quoted words only; shell syntax, line breaks, backslashes, `VAR=`, `-H/--host/--context/--config`, `context`, `login`, `cp`, `save`, `export`, `load`, `push`, buildx builder changes and `-o/--output/--iidfile/--cidfile` are refused, not interpreted. Rancher's `~/.rd/bin/docker` by absolute path via `execve`, `PATH=/usr/bin:/bin`, BelloCode's `DOCKER_CONFIG` (no credential helpers), the endpoint on `127.0.0.1`, binds limited to the project. **Client confinement (N03/A06):** options naming host files (`--env-file`, `--label-file`, `--env-from-file`, build `-f`/context, compose `-f`/`--env-file`/`--project-directory`) must resolve inside the project's roots; `--secret`, `--ssh`, `--build-context`, `--cache-to`, local `--cache-from`, `--attest`/`--sbom` and remote contexts are refused; and the client runs under `sandbox-exec` (`HostDockerSandbox`): no reads or writes under `/Users`, `/Volumes` or temporary folders except the roots (read-write), docker's installation and BelloCode's `DOCKER_CONFIG` (read-only), no other writes, outbound network only to the endpoint's port (so a Compose file's `env_file`/`build` outside, Rancher's raw socket or a `.env` `DOCKER_HOST` reach nothing). No sandbox, no command. Under enforced egress the scope gets the project's egress network and gateway like the other modes. No terminals. |

**Code roots** ([settings](../snapshots/exec-code-roots-dark.png)): first run suggests the folder holding the projects
(`~/Documents/Repos` for its owner; a project directly in `~` or `~/Documents` suggests itself). `CodeRoots` validation:
existing folder, links replaced by their target, never `/`, home or anything containing it, system locations (temporary
folders allowed), `/Users`/`/Volumes` themselves or credential folders (`~/Library`, `~/.ssh`, `~/.config`, `~/.docker`,
`~/.rd`…); nested roots dropped; a folder Rancher does not share gets instructions (Lima `override.yaml`), and once the
shared workspace runs a marker written on the Mac must be visible in each root. **Trusted roots:**
`EnvironmentService.trustedRoots` (BelloCore `TrustedRoots`) and `policyRoots(for:)` (project roots, then code roots)
are what Auto mode and risk notices treat as in scope; the helper configuration carries `trustedRoots` for the plugin.
**Migration** (once, `containers.executionModesMigrated`): projects whose record shows a container keep Project
container; the rest follow the default. The settings and the marker are one transaction; after a failed write nothing is
marked done (retried next launch, the project keeps its container meanwhile, the pane says why), and an unreadable row
keeps the migration open. **Administrators:** `ContainerCodeRoots` (array, `~/` allowed),
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
up/exec/run/logs/ps/build and classic build work. **Build base images (R14, A08, N04):** a classic `/build` context is read whole and held back in an unlinked temporary file
until it is judged, so the daemon only receives an archive whose effective Dockerfile was checked (`BuildContextScanner`, Go
`archive/tar` semantics: a second entry for the Dockerfile's path in any spelling, a link at or above it, an entry written
through an earlier link, names leaving the context, sparse files, malformed numbers, PAX records or checksums, and data after
the end marker are refused; gzip through zlib, concatenated members decoded, trailing bytes refused; bzip2/xz/zstd refused).
Its `FROM`, `COPY --from`, `RUN --mount=from=` and `# syntax=`/`BUILDKIT_SYNTAX` frontend images (`DockerfileBases`: BuildKit's
directive rules, heredocs only for unquoted `<<WORD` in RUN/COPY/ADD, an unclosed heredoc refused, and a second no-heredoc
reading so a parser disagreement cannot hide a FROM; global `ARG`s and `buildargs` expanded; unresolvable refused) are
checked against the image policy unless the scope built them. BuildKit through the endpoint (`/session`, `/build?version=2` or
`session=`) is refused. Streamed bodies (build, `docker cp`) may be up to 4 GiB; JSON bodies 4 MiB (N07). Under enforced egress,
`RUN` steps get the egress network and the proxy as predefined build arguments. **Residual risk:** a symlink swapped inside a root
between check and mount (TOCTOU) is followed in the Rancher VM; the agent sees its token.

## Environment contract

The plugin's instruction (`Plugin/src/container.ts`, rewritten each run from the helper configuration, no secrets;
research 09 §2): mode, roots and working directory, image/OS/arch/user, file tools on the Mac vs commands on Linux,
Linux outputs stay inside, the filtered endpoint, localhost and forwarded ports, git on the Mac (hooks off, no container
credentials), company CA (keep TLS verification), never fall back to the host, host docker-only's one-command rule.

## Dev containers (Project container only)

Opt-in per project ([pane](../snapshots/exec-devcontainer-light.png)), `.devcontainer/devcontainer.json` with comments.
Supported: `image`; `build` (`dockerfile`, `context`, `args`, `target`, inside the project with links resolved) built by BelloCode with
Rancher's `docker buildx build --load` (right before each build the canonical context and the Dockerfile, opened
without following a link, are verified inside the project again; A18: the kept context is then copied (APFS clones, links as
links) into a private folder, the CLI builds that copy with the Dockerfile on stdin, and the tag is the digest of the copy, so a
save during the build cannot put new bytes under an old tag; under enforced egress `RUN` steps get `--network none`, because
BuildKit's builder cannot join the egress network, N09); the image tag is the content tag of what the build sends (Dockerfile, arguments, target and every
context file `.dockerignore` keeps, links as links; computed in the background, bounded to 200 000 files / 4 GiB), so a
changed input rebuilds; Rebuild runs the build again and replaces the container after it succeeded; a built tag is never
pulled; the build belongs to the project's task: a project or mode change, stopping the service or its 60-minute
deadline stops docker (TERM, KILL after 10 s) and waits until it is gone, and a result is used only for the plan still
in force; same-path workspace; `containerEnv`/`remoteEnv` (plain values); `remoteUser`;
`forwardPorts` (forwarded on start); `remoteUser` that is root (`root`, `0`, `0:…`) is refused, and a named user that is
uid 0 in the image is refused when the container starts (N09); `postCreateCommand`/`postStartCommand`, run only after the person approves their
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
