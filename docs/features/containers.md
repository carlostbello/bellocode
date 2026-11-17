# Containerised execution (M6-A)

Everything the agent or the user **runs** executes in a Linux container on Rancher Desktop (dockerd); opencode stays a
native host process; nothing falls back to the Mac. Spike and raw measurements: [G6-containers.md](../spikes/G6-containers.md).

## Architecture

- **ContainerKit**: Docker Engine API over `~/.rd/docker.sock` (no CLI), runtime discovery (`RuntimeState` with the fix
  to show), `WorkspaceManager` (create on first use, recreate on change, reaper, probes, touch), `PortForwarder`.
- **bellocode-exec** (`Contents/Helpers`, signed): opencode's `SHELL`, `config.shell` and BelloCode's PTY command. It reads
  `<data>/opencode/bellocode-exec.json` (written atomically by the app, mode 0600), finds the project for the working
  directory (mapping `/private/var/…` back to the mounted spelling), starts the container if needed (never pulls) and
  relays the command, stdin, window size and signals. Blocked: exit 125 and one `BelloCode: … The command was not run.`
  line the agent sees as a tool failure.
- **Server launch** (`ContainerExecution`, always on for the bundled server): `SHELL`/`config.shell` = helper,
  `OPENCODE_DISABLE_PROJECT_CONFIG=1`, `formatter: false`, `lsp: false`, host git without hooks (`GIT_CONFIG_*`
  `core.hooksPath=/dev/null`, also in `GitRunner`), no `BUN_*` variable ever passed, the bundled plugin's
  `shell.create.before` guard forcing the helper, and a per-session guidance entry (Linux container, same paths, host
  tools unavailable, image and tools).
- **EnvironmentService** (Engine, `@MainActor`, tasks owned and cancelled with it): runtime polling and events, one
  `ProjectEnvironment` per project, helper configuration, idle stop, reaper, Ports and forwards, file-watch bridge,
  secrets and setup scripts in the container, the isolation self-check. Generation-checked async results.

## Coverage as shipped

| Path | Where it runs | Proof |
| --- | --- | --- |
| Agent shell tool, `/api/shell` | container | self-check (smoke) + e2e prompt on `opencode/big-pickle` |
| PTY with `$SHELL`; BelloCode terminals | container | self-check; smoke terminal round trip in the container |
| `!`cmd`` command templates | container | self-check (internal command, model that does not exist: never prompts) |
| opencode schedule conditions | off (opencode schedules disabled) | self-check reports Off; same shell when enabled |
| Worktree setup scripts | container, in the worktree | unit test; refused outside the mounted roots |
| Worktree `commands.start` (opencode) | never set; flagged HOST if present | self-check configuration scan |
| Formatters, LSP | off | configuration scan |
| Local MCP servers | none configured; repo config ignored; flagged HOST if present | configuration scan |
| Repository plugins/agents/commands, `"shell"` | ignored (`OPENCODE_DISABLE_PROJECT_CONFIG`) | spike e2e |
| Host git (status, diffs, worktrees, snapshots) | host, hooks never run | unit test |
| File tools, ripgrep | host (no project code runs) | n/a |

The self-check runs once the server is live (quick: configuration, shell job, PTY) and on demand ("Verify Isolation",
Window menu and Settings; full adds a command template, schedule condition and terminal in a scratch thread). Each
probe writes a marker under `/tmp`: found in the container proves the path, found on the Mac proves an escape.
`make smoke` runs the full check when Rancher Desktop and the test image are present and prints `SKIP …` otherwise.

## Failure behaviour

Runtime not installed / not running / containerd / too old, no image, pull failed (sign-in needed), folder not shared,
container failed: each is a phase with a message and a fix ("Install/Start Rancher Desktop", "Switch the container
engine to dockerd", "Choose an image", "Sign in to the registry", Retry). It is written into the helper configuration
(the agent gets it as a tool failure), shown as a banner above the composer and over the terminals, in the toolbar
status item and the thread context line. Retry and fixes take effect without restarting a thread: the helper reads the
configuration on every command. Setup scripts and secret commands throw the same message (`EnvironmentBlockedError`).

## Workspace model

Per project setting (`app_environment`, migration `v6-container-environments`, kept by `rebuild()`): image (else the
app default; **no public default**), variables (reserved names refused), limits (CPU, memory, pids), user mounts (off;
read-only by default), network (bridge / none), file-watch bridge, idle minutes. Registry passwords: Keychain
(`app.bellocode.registry`), sent only in the pull's `X-Registry-Auth` header. One container per project
(`bellocode-ws-<key>`), project folder, BelloCode's and opencode's worktree folders mounted at the same absolute paths,
host uid:gid, no capabilities, `no-new-privileges`, `init`. Recreated when the image, the setting or the folder identity
(device:inode) changes; an outdated container keeps running until the next activation. Stopped when idle; removed with
the project; stray processes (`setsid` leftovers) reaped after cancelled commands and on demand.

## Dev servers

No ports published. A listener in the container is forwarded on demand to `127.0.0.1` on the Mac (same port when free)
through an exec relay; per project; stopped with the project, the runtime or from the Ports list (Settings ▸
Environment: port, process, address, Open in the built-in browser, Stop). Links and dev-server offers in a
containerised project's thread are mapped to the forward. A server bound to `0.0.0.0` in the container is still only
reachable from the Mac's loopback: the relay connects inside the container and nothing is published (live test).

## File-watch bridge

Rancher's file sharing does not raise inotify for host edits. FSEvents (file-level, off the main actor) → debounced
150 ms, bounded batches (2 000 paths, overflow collapses to folders) → `touch -c -m -r f f` in the container (mtime
unchanged; metadata-only events never loop). Excludes `.git`, dependency and build folders. Measured: a Node `fs.watch`
in the container fires **61 ms** after a host edit; a batch costs 15–28 ms (one exec).

## Secrets

The host pipe (`SecretService`, unchanged) cannot reach a container. For containerised projects a saved secret is
delivered as a container reference (`bcsecretc_…`, one use, one thread, one hour, 64 outstanding) and
`bellocode_app_secret_exec` runs one command with the value in that exec's environment only (Engine API, in memory);
output redacted (`<secret>`). Tests: present in exactly one exec, absent from other execs, the helper file and the
container's configuration (`inspect`, live test); never in transcript or logs (only a redacted result is returned).

## Host requirements

Only `git`, `/bin/sh` and the bundled `opencode`, `bellocode-exec` and `rg` (ripgrep 15.1.0, pinned SHA-256 in
`Scripts/ripgrep-checksums`, system libraries only). Settings ▸ Containers lists them. `make plugin-test` runs the
plugin's `bun test` in a throwaway container. **Policy point:** the opencode binary embeds Bun; `BUN_BE_BUN` would make
it a JavaScript runtime on the host. The server's environment drops every `BUN_*` variable and the helper never sets one.

## Measured (this arm64 Mac, Rancher Desktop 1.25, `node:22-bookworm-slim`)

Container ready (create + start) 115–196 ms; terminal round trip in the container 133–144 ms; host edit to a green
test in the container 105–112 ms; helper `-c true` p50 20 ms (spike); watch bridge 61 ms; `make plugin-test` 69 ms.

## Enterprise policy points

Image provenance: set the default image to the internal registry, pin by digest, scan and sign there (BelloCode shows
the resolved digest; signature verification is not enforced yet). Registry: credentials per host in the Keychain.
Egress: bridge allows all outbound traffic; `none` per project; organisation egress belongs in the network. Limits:
per project. Audit: signposts only; command content is never logged.

## UX checklist (03-ux-patterns.md §E)

Purpose/context: thread line shows project, branch, worktree and `Container: image (state)`. States: ready, checking,
starting, pulling, failed, runtime down, no image, folder not shared, all with a next step (snapshots). Keyboard: Window
▸ Containers…, Project Environment…, Verify Container Isolation; panes are plain SwiftUI controls. Accessibility: glyph
+ word everywhere, combined labels on banner and status item. Not exercised: VoiceOver walk-through, two windows,
Reduce Motion (nothing animates).

## Known gaps, unverified

- A helper `--stdio` mode for local MCP servers (they are flagged, not routed). Image signature verification.
- Snapshot glass drawn opaque; terminal working-directory (OSC 7) inside the container depends on the image's shell.
- Not driven on screen: Ports "Open" into the built-in browser (the e2e fetches the forward URL directly).
- Later "Rancher workloads" package: compose-style service containers per project, shared caches, remote runtimes.

Snapshots: `docs/snapshots/containers-*.png`. Commands: `make smoke`, `make e2e-containers`, `make plugin-test`,
`BELLOCODE_CONTAINER_TESTS=1 swift test --filter Live`, `--snapshot containers`.
