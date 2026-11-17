# G6: containerised execution

Status: run 2026-11-17 on an M5 Max (18 CPUs, macOS 27.0.1) with Rancher Desktop 1.25 (dockerd 29.9.2, Engine API 1.56,
linux/arm64, vz + virtiofs, 2 vCPU / 6 GB VM, no admin), opencode 2.3.0 (source at tag `v2.3.0`, `a6b15d3`).
Code: `Sources/{ContainerKit,bellocode-exec,ContainerSpike}`, `Tests/ContainerKitTests`. Reports: [G6/](G6/) (e2e,
measurements, observations, and the control run with project config allowed).

**Gate: PASS, with four conditions** (all cheap, listed in "Production design"): disable project config, disable
formatters and local MCP unless routed through the helper, turn off git hooks for host git, and never set a worktree
start command. With those, every enabled path that runs commands ran in the container; nothing fell back to the host.

## 1. Interception: how opencode 2.3.0 executes, and where to redirect it

Source facts. The agent's `shell` tool, `POST /api/shell`, `!`cmd`` in commands and schedule conditions all go through
`core/src/shell.ts`: the shell is `config.shell`, else `$SHELL`, else `/bin/zsh` (`shell/select.ts`); argv is
`<shell> -c <command>` for any shell name it does not know (no `-l`); cwd is made absolute; env is the session environment
(`PUT /session/{id}/environment`) or the server's own, plus `TERM`/`OPENCODE_TERMINAL`, then the `shell.create.before`
plugin hook may edit command, cwd, timeout, shell and env. The command runs in the `opencode-pty` process daemon
(`create_pipe`; falls back to an in-process spawn), stdin from /dev/null, its own process group, output combined to a file;
timeout or cancel = SIGTERM, then SIGKILL after 3 s; on exit, what is left in the group is killed. Persistent PTYs
(BelloCode's terminal) run the client's `command`, else `$SHELL` (not `config.shell`) through `opencode-pty create_pty`.
The workspace-driver registry (the only "remote execution" hook) is empty in the CLI; only SDK embedders can fill it.

Chosen mechanism: **(a) `bellocode-exec` as opencode's shell** (`config.shell` and `$SHELL`), plus **(b) a guard plugin**
whose `shell.create.before` hook forces `event.shell` back to the helper, plus `OPENCODE_DISABLE_PROJECT_CONFIG=1`.
(c) replacing the shell tool with a plugin tool would lose opencode's background jobs, timeouts and restart hand-off for no
gain. The helper (Swift, no dependencies beyond ContainerKit) reads `BELLOCODE_EXEC_CONFIG` (socket, project roots →
container; no secrets), refuses any cwd outside a containerised project (exit 126) or when the runtime is down (exit 125),
forwards the environment minus host-only names (PATH, HOME, TMPDIR, XDG_*, OPENCODE_*, SSH_AUTH_SOCK, GIT_CONFIG_*, ...) as
exec `Env` (in memory, never in container config), relays stdout/stderr/exit code, and in TTY mode raw-relays the terminal,
`SIGWINCH` → exec resize and hang-up → kill the in-container session. In-container wrapper (POSIX `sh`): the command runs in
the exec's own session; a watcher holds the exec's stdin, so closing it (cancel, timeout) or losing the connection (helper
SIGKILLed) sends TERM then KILL to the whole group.

| Path | Runs on | Mechanism | Coverage | Escape risk |
| --- | --- | --- | --- | --- |
| Agent shell tool, `/api/shell`, `/session/{id}/shell` | container | (a) + (b) | covered (e2e) | none seen; repo `opencode.json` `"shell"` ignored |
| `!`cmd`` in commands, schedule conditions | container | (a) (same resolver) | covered by source | as above |
| Persistent PTY / drawer; legacy `/api/pty` | container | helper as `TerminalLaunch.command`, `$SHELL`; `config.shell` | covered (e2e; legacy by source) | a client passing another `command` (BelloCode only) |
| Formatters after edits | host | `"formatter": false` | covered (off) | prettier/biome/oxfmt run project `node_modules` on the host via embedded Bun if enabled |
| LSP | none | no LSP runtime in 2.3.0 (TODOs in `edit.ts`) | n/a | returns with a future opencode |
| MCP `local` servers | host | define none; repo config disabled | not covered | needs a helper `--stdio` mode (not built) |
| Worktree `commands.start` | host | hard-coded `bash -lc` (`worktree.ts`) | not covered | BelloCode must never set it; check at startup |
| Repository plugins / agents / commands | host, in opencode | `OPENCODE_DISABLE_PROJECT_CONFIG=1` | covered (e2e) | control run: a repo plugin **ran on the host** without it |
| Providers `az`, Claude Code, integration auth commands | host | not configured; `OPENCODE_DISABLE_CLAUDE_CODE=1` | covered (off) | enabling them spawns host CLIs |
| Git (project id, snapshots, diffs, worktrees) | host | stays on host; hooks off | partially | hooks (e.g. husky `core.hooksPath`) run on host unless disabled |
| File tools, ripgrep | host | none needed (no project code runs) | n/a | none |

## 2. Engine API client (ContainerKit)

POSIX unix socket (`FileStream`: blocking I/O on per-direction serial queues, cancellation shuts the socket down) and a
small HTTP/1.1 layer (`HTTPHeadParser`, incremental `ChunkedDecoder`, Content-Length/until-close/101 framing, pull-driven
body chunks, raw hijacked stream after upgrade). `StreamDemuxer` decodes Docker's 8-byte frame headers at any byte boundary,
streaming payload (bounded by one read). `EngineClient` covers `_ping`, version, info, events (label filters), image
inspect/pull with progress (`X-Registry-Auth` in memory only)/build from an in-memory tar/remove, container
create/start/stop/kill/remove/inspect/list-by-label/wait/logs/attach/archive, exec create/start (TTY and multiplexed)/
resize/inspect, volumes and networks. `RuntimeDiscovery` → `RuntimeState`: `.notInstalled`, `.notRunning` (socket missing,
refused, or Lima accepting and closing while the VM boots), `.wrongEngine("containerd")` (from Rancher's settings
`containerEngine.name`; never reads `rd-engine.json`), `.unsupported` (non-Linux or API < 1.44), `.ready`.
**containerd claim verified from source, not by switching** (forbidden here): Rancher 1.25 `lima.ts` starts dockerd only
for moby; with containerd the forwarded `~/.rd/docker.sock` has no daemon and containerd's socket
(`/run/k3s/containerd/containerd.sock`) stays inside the VM; `nerdctl` reaches it only through Lima's shell. No Docker API
without dockerd. The image for the e2e was built through `POST /build`; no CLI was used anywhere.
Tests: 30 unit tests (fake in-process unix-socket daemon, every-boundary chunked and frame parsing, hijack with stdin echo,
state model) plus 2 opt-in live tests (`BELLOCODE_CONTAINER_TESTS=1`).

## 3. Workspace container model

- **One container per project**, not per worktree: worktrees share the repo's object store and the threads already share a
  trust boundary; one container keeps caches warm and cold start is cheap anyway. The project root and opencode's worktree
  directory for it (`$XDG_DATA_HOME/opencode/worktree/<project-id-6>`) are bind-mounted **at the same absolute paths**, so
  paths in output, diffs and the transcript are host paths. A host `git worktree add` there works in the container (the
  absolute `gitdir:` resolves); `git status` needs `safe.directory=*` because host-created directories can appear as uid 0.
- File sharing: Rancher shares `~`, `/Volumes`, `/private/tmp`, `/var/folders`, `/tmp/rancher-desktop`. Other paths fail at
  create (`bind source path does not exist`); validate before creating. Files created in the container (as the user or as
  root) are owned by the host user on the Mac; host files with mode 600 are readable inside.
- `User` = host `uid:gid`, no privilege, `CapDrop: ALL` (CHOWN/DAC_OVERRIDE/FOWNER kept only for BelloCode's root
  `$HOME` preparation), `no-new-privileges`, `Init` (tini), CPU/memory/pids limits, `$HOME` and caches in named volumes.
  The create body is hashed (with the image ID) into a label; **the mounted directories' device:inode is a second label**:
  a re-cloned or re-created project folder leaves a running container on the old, empty directory (hit in this spike), so
  a mismatch recreates it. Secrets go per exec in `Env` over the socket, never into the container config.
- Network: bridge (egress) or `none`. Published ports must use `HostIp 127.0.0.1` (Rancher forwards `0.0.0.0` bindings to
  every interface of the Mac). **Unpublished ports: in-app forwarder** (`PortForwarder`): a host loopback listener where
  each connection is one exec running a relay to `127.0.0.1:<port>` inside the container. It needs no recreate or sidecar
  and reaches dev servers bound to the container's loopback, which published ports cannot (e2e: 19–71 ms per request).
  The spike's relay uses bash `/dev/tcp`; production uploads a static relay via `PUT /archive`.
- Lifecycle: create on first use, `start` when stopped (helper does it on a 409), stop when idle, recreate when the hash or
  mount identity changes, remove container and labelled volumes with the project. Everything is found by label.

## 4. Measurements ([G6/measurements.json](G6/measurements.json); container vs host)

| Measure | Container | Host |
| --- | --- | --- |
| Cold start, image present (create, start, prepare $HOME, first exec) / start a stopped one, n=5 | p50 70 / 52 ms, p95 82 / 71 ms | n/a |
| `true` round trip, n=200: raw exec / wrapped exec / `bellocode-exec -c true` process | 10.8/13.5, 15.5/26.5, 20.3/23.7 ms (p50/p95) | `/bin/sh -c true` 3.9/5.6 ms |
| Keystroke → echo: exec TTY (`cat`), n=200 | p50 0.49 ms, p95 0.84 ms | PTY via `script` 0.04/0.05 ms |
| Keystroke → echo through opencode PTY + WebSocket + helper (e2e, one sample) | 21 ms | n/a |
| `seq 1 2000000` (14.9 MB): exec non-TTY / TTY / via helper | 62 / 172 / 52 ms | 176 ms (BSD seq) |
| Local clone of opencode 2.3.0 (11.4k files) over the bind mount | 5.58 s | 1.41 s (4.0×) |
| `git status` first / again | 0.38 / 0.21 s | 0.48 / 0.12 s |
| `grep -r` over the `.ts` files | 0.73 s | 0.21 s (3.5×) |
| Create / delete 10,000 small files | 1.63 / 0.96 s | 0.46 / 0.36 s (3.5× / 2.7×) |
| Write visibility host→container / container→host (p50, incl. exec) | 1.3 / 10 ms | n/a |
| inotify in container for host / container writes; FSEvents on host for container writes | **none** / yes; yes (95 ms) | n/a |
| Cancel (stdin closed): plain / TERM-ignoring parent / `setsid` child (`&` and double-fork included) | 20 ms exit 143 / 2.0 s / **1 left** | n/a |
| 20 concurrent execs (`sleep 0.5`) / 20 concurrent helper processes | 623 / 704 ms wall, all correct | n/a |

## 5. End-to-end result ([G6/e2e.json](G6/e2e.json): 30/30)

Pinned opencode on the host, isolated XDG dirs, `basePath /usr/bin:/bin`, shell = helper, 3 prompts on
`opencode/big-pickle` (9 prompts in the whole spike). Proven: shell jobs run in Linux, in the host path, as the host uid,
with `python3` and `node` from the image; stderr and exit 7 surface; the repo's `"shell": "/bin/zsh"` and repo plugin are
ignored; cwd outside the project is refused (126); a timed-out job is stopped. The agent ran Python and Node (`Linux
<project>`, `linux v22.23.5`) and a failing command (stderr `boom`, exit 3) reported as failure; it fixed `calc.py` with its
edit tool on the host and `python3 -m unittest` in the container passed; its background `python3 -m http.server` (never
published) was fetched from the host through the forwarder and deleting the job killed it. A terminal through opencode's
persistent PTY API and BelloCode's `TerminalService` ran `uname -a` (Linux), resized to 27×91 (`stty size`), Ctrl-C
interrupted `sleep 100`, `vi` used the alternate screen and saved, the agent read the screen, `exit 5` reached opencode.
Server exited; no process left in the container. Not covered: local MCP, formatters via the container, PTY re-attach
after an app restart (the helper lives in opencode-pty, so it should work), IME.

## 6. Host-binary audit

| Executable | Needed by | Verdict |
| --- | --- | --- |
| BelloCode, `bellocode-exec` | app, every command | bundle and sign (helper: 20 ms per command) |
| `opencode` | server | bundle. **It is a full Bun 1.4.4**: `BUN_BE_BUN=1 opencode t.js` runs any script on the host (verified). Policy must accept that, or ask for a build without it |
| `opencode-pty` | shell jobs, PTYs | bundle, `OPENCODE_PTY_BIN` (today extracted ad hoc into the cache) |
| `rg` | search tools | bundle a portable static build (the current fetch copies Homebrew's, linked to pcre2) |
| `git` | opencode (snapshots in its own data dir, diffs, worktrees), Engine GitService | stays on host: snapshots use a git dir outside the mounts. Apple's `/usr/bin/git` needs Command Line Tools: require them or bundle a pinned git. Set `core.hooksPath=/dev/null` via `GIT_CONFIG_*` for both; run hook-bearing commits in the container if a team needs hooks |
| `bun` (plugin tests), Node, Python, Docker/nerdctl/rdctl CLIs, `/bin/sh`, `/bin/zsh` | none at run time | eliminated (shells: once `shell` and `$SHELL` are the helper). Plugin tests: run `bun test` in an `oven/bun` container through ContainerKit (a `ContainerSpike plugin-test` command would be a few lines; not built), or via the bundled opencode's Bun if policy allows |
| `swift`, `codesign`, `notarytool` | build only | Command Line Tools on the build machine |

## Risks

- **Rancher drift:** socket path, settings schema (`containerEngine.name`), virtiofs ownership quirks and the
  0.0.0.0 forwarding behaviour are Rancher internals; pin supported versions and keep the live tests in CI.
- **Bind-mount cost:** 2.6–4× slower metadata-heavy work, no inotify for host edits (hot reload breaks unless watchers poll
  or BelloCode bridges FSEvents → in-container `touch -c`, which does raise inotify ATTRIB: verified). Heavy dependency
  trees (`node_modules`) belong in named volumes.
- **Experimental opencode surfaces:** persistent PTY API, `shell.create.before`, `OPENCODE_DISABLE_PROJECT_CONFIG`
  (an env flag read in `server-process.ts`) and the empty workspace-driver registry can change in any release: contract
  tests must assert each.
- **Escapes left:** `setsid`/daemonising commands survive a cancel (needs an idle reaper exec); a killed helper in TTY mode
  leaves its shell running until reaped; plugins run with server authority; enabling formatters, local MCP, worktree
  start commands or provider CLIs reopens host execution.
- **Policy:** image provenance (internal registry, digest pin, scan), egress (bridge allows all), secrets visible to every
  process in the container, the Docker socket is root-equivalent on the VM (never mount it).

## Production design

- **Modules.** `ContainerKit` (this prototype, hardened): transport, `EngineClient`, `RuntimeDiscovery`, `WorkspaceSpec`/
  `WorkspaceManager`, `ExecSession`, `PortForwarder`. `Engine` gains `EnvironmentService` (`@MainActor` models over an
  actor): per-project runtime state, lifecycle, events subscription, idle stop, reaper, forwards, FSEvents bridge, writes
  the helper config. `OpenCodeKit.ServerConfiguration` sets `SHELL`, `BELLOCODE_EXEC_CONFIG`,
  `OPENCODE_DISABLE_PROJECT_CONFIG=1`, `GIT_CONFIG_*` (hooks off) and adds `"shell"`, `"formatter": false` and the guard
  hook (in the bundled `Plugin/`) to `OPENCODE_CONFIG_CONTENT`. `TerminalLaunch` becomes the helper.
- **Environment setting (per project, SwiftUI, Project Settings ▸ Environment).** Runtime status row (text + symbol for every
  `RuntimeState`), image (reference, resolved digest, pull/rebuild with progress), resources, network (bridge / none),
  ports and active forwards (open in the built-in browser), caches (clear), container logs, "Open terminal in container",
  Restart, Rebuild. Thread header shows project, branch, worktree and "Container: <image>".
- **What the agent is told** (session instruction entry from the plugin, plus a tool-description transform): commands run
  in Linux (image, distribution, available runtimes) at the same paths; file tools edit the Mac copy directly; servers
  should bind 127.0.0.1 or 0.0.0.0 and are opened through BelloCode's forwarder; no Docker access.
- **Failure behaviour.** Never fall back to the host. Rancher stopped: the helper exits 125 with "Rancher Desktop is not
  running …; the command was not run", the tool result shows it, the composer shows a pinned banner with the state's
  sentence and "Open Rancher Desktop", the terminal drawer shows the same in place of a shell. containerd: the banner
  tells the user to switch to dockerd. Missing image: progress in the banner; nothing runs until it exists.
- **Build order.** 1) ContainerKit hardening (timeouts, API negotiation, fixtures), static relay; 2) EnvironmentService,
  server config, guard plugin, signed helper; 3) settings UI and failure states; 4) forwards in the browser; 5) FSEvents
  bridge, reaper; 6) helper `--stdio` (local MCP), formatters via helper; 7) plugin tests in a container; 8) contract tests.

## Left on this machine

Spike containers, volumes and image `bellocode-spike-workspace:g6` removed (`ContainerSpike cleanup --images`), scratch
`~/.bellocode-g6-spike` deleted; kept: public base `node:22-bookworm-slim` (349 MB) and Rancher's `rdx-proxy`. One incident: while reading Rancher's
`rd-engine.json` to look for engine settings, its management-API password was printed into this session's tool output (a
redaction pattern failed); it was not written to any file or commit. Whether Rancher rotates it on restart was not
checked; restarting Rancher Desktop or treating it as exposed is advised.
