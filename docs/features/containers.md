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
  `OPENCODE_DISABLE_PROJECT_CONFIG=1`, `formatter: false`, `lsp: false`, opencode's own git through the `git` shim
  (`<data>/git-shim/git` → `bellocode-exec`, first on PATH; see "Host git"), no `BUN_*` variable ever passed, the bundled plugin's
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
| BelloCode's host git (status, diffs, add, commit, worktrees, fetch/push) | host, sandboxed (`HostGit`): runs no program a repository configures | hostile-repository matrix (unit) + self-check "Host git" (smoke) |
| opencode's host git (snapshots, VCS diffs, revert, worktrees, fetch) | host, sandboxed through the `git` shim | same matrix through the shim; real-binary VCS test through the shim |
| Commands that receive a secret (`secret_exec`) | one-shot sibling container, no network, project read-only (unless approved) | fake-runtime end to end + live Rancher test |
| File tools, ripgrep | host (no project code runs) | n/a |

The self-check runs once the server is live (quick: host git, configuration, shell job, PTY) and on demand ("Verify
Isolation", Window menu and Settings; full adds a command template, schedule condition and terminal in a scratch
thread). Each probe writes a marker under `/tmp`: found in the container proves the path, found on the Mac proves an
escape. The **Host git** probe builds a scratch repository whose configuration names a marker-writing program at every
git extension point and runs BelloCode's and opencode's (shim) git against it: "Confined" when nothing ran. The verdict
(M6-B) is **Isolated** only when every applicable check ran and held; any skipped check (no project with an image,
server offline, runtime refusing commands, plugin silent) gives **Not verified** (amber, never shown as a pass); an
escape or failure gives **Problem**. `make smoke` fails unless the verdict is Isolated, and prints `SKIP …` when Rancher
Desktop or the test image is missing.

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

## Host git

Git runs on the Mac for BelloCode (Changes panel, worktrees, push) and for opencode (snapshots in its own git dir,
VCS diffs, revert, worktrees). The project folder is mounted read-write into the container, so anything the agent runs
there can rewrite `.git/config`, `.gitattributes`, `.git/info/attributes`, hooks or a worktree's `.git` link, and git
turns configuration into program execution in many places: `core.fsmonitor`, clean/smudge/process filters, textconv and
`diff.<driver>.command`, `diff.external`, merge drivers, hooks and `core.hooksPath`, pagers (`core.pager`, `pager.*`),
editors, `core.askPass`, `core.sshCommand`, credential helpers (also URL-scoped), `url.*.insteadOf` to `ext::`,
`remote.*.vcs`, `remote.*.uploadpack/receivepack`, `core.gitProxy`, `core.alternateRefsCommand`, `gpg.program` with
signing or `log.showSignature`, `include`/`includeIf`, submodules with their own configuration, `core.worktree`
(checkout writes elsewhere).

**Decision (M6-B):** keep git on the host and confine every invocation at one choke point (`ContainerKit/HostGit`),
rather than move working-tree git into the container: opencode's own git is on the host regardless (its snapshot git
dir is outside the mounts, and it resolves `git` on PATH), so a container route would leave its calls exposed, while the
shim confines both the same way; and the Changes panel keeps working without depending on git in every image. A scan
of the repository's configuration was rejected: driver names come from the repository, so keys cannot be listed in
advance, and any scan races the container.

1. **Sandbox** (`/usr/bin/sandbox-exec`, profile parameters by `-D`, inherited by children): local operations may
   execute only the real git binary (Command Line Tools or Xcode, never the `/usr/bin/git` stub or a PATH entry) and
   its `libexec/git-core`; no network; writes only under the working directory, its discovered `.git` directories
   (only paths with a `.git` component), `TMPDIR`, `/dev` and roots the caller names. fetch/push/pull/clone/ls-remote may
   also execute `/usr/bin/ssh` and the system shells (credential helpers run through `sh`), reach the network and write
   `~/.ssh`; `git-remote-ext` and `git-remote-fd` stay blocked.
2. **Overrides** (`GIT_CONFIG_COUNT`, read after every file): `core.hooksPath=/dev/null`, `core.fsmonitor=false`,
   pagers `cat`, editors `true`, empty `core.askPass`, signing and `log.showSignature` off, `gc.auto=0`,
   `maintenance.auto=false`, `safe.bareRepository=explicit`, no submodule recursion, `protocol.allow=never` with only
   `https` and `ssh` allowed, `core.sshCommand` and credential helpers only from the user's own (system, global, Apple
   default) configuration: the helper list is reset (repository and URL-scoped ones included) and the user's re-added.
3. **Environment**: allowlist (HOME, identity, `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE`, `GIT_CONFIG_GLOBAL`…),
   fixed PATH, `GIT_EXEC_PATH` pinned, `GIT_ASKPASS` empty, `GIT_NO_LAZY_FETCH=1`; `SSH_AUTH_SOCK` only for network
   operations; inherited `GIT_SSH*`, `GIT_EXTERNAL_DIFF`, pager and editor variables dropped.

Without the sandbox or git, BelloCode refuses (git errors say so; the shim exits 126); nothing runs unconfined.
Effects: repository-defined filters do not run on the host (files are read unfiltered; git-lfs content appears as
pointers there; run LFS in the container), textconv/external diffs are not used, local-path remotes are refused for
fetch/push, a user's custom `core.sshCommand`/credential helper still works only if it is in their global or system
configuration.

Tests: `HostGitIsolationTests` builds a hostile repository (28 configuration vectors, 15 hooks in `.git/hooks`, the
origin and a `core.hooksPath` folder, `include`, `includeIf`, an `ext::` remote, an `ext` vcs remote, ssh and git://
remotes) and runs BelloCode's status, all diff scopes, show, stage, unstage, commit, log, branches, worktree
list/create (normal and copy-on-write)/remove/restore, start-from-origin fetch, fetch of every remote, push and
`credential fill`, with the production and a permissive runner: no marker; then opencode's commands through the shim
(status, numstat, diff, diff-files, ls-files, log, show, add, commit, checkout, reset --hard, snapshot add/write-tree,
worktree add/list/remove, fetch --all, push): no marker. `core.worktree` pointed outside: nothing written there (the
unconfined control writes). A submodule with its own fsmonitor: nothing ran. Control: plain git fires the vectors.

**Outside BelloCode's control:** git launched by anything other than BelloCode and opencode (the user's terminal, IDE,
GUI clients, Finder previews) is unconfined: a repository the agent modified can still run programs when the user runs
git on it outside BelloCode. `sandbox-exec` is deprecated by Apple (it works on this macOS; a future removal makes host
git fail closed). The sandbox allows reads anywhere and writes inside the repository: a hostile configuration can make
git read or overwrite files in the repository and its `.git` (the agent can do that anyway). A `url.*.insteadOf` can
redirect a push to another https/ssh host (no credentials are sent unless the user's own helper has some for it).
opencode could in principle start git by an absolute path in a future version (2.3.0 resolves it on PATH; the
real-binary test fails if the shim is bypassed).

## Secrets

The host pipe (`SecretService`) cannot reach a container. For containerised projects a saved secret is delivered as a
container reference (`bcsecretc_…`, one use, one thread, one hour, 64 outstanding). `bellocode_app_secret_exec`
(M6-B) asks the person first: a card shows the secret's label, project and folder, the variable, **the command
verbatim**, and its access. Only after Allow does the command run, in a **one-shot sibling container** (same image,
user and limits, no capabilities, project and worktree folders read-only, no caches or persistent home, HOME=/tmp,
network `none`) unless the agent asked for network or write access and the card said so. The value goes on the exec's
stdin into the variable (`NAME=$(cat)`), so it is in no container or exec configuration; the container is removed
afterwards (also on error or timeout). The thread is woken with the bounded output; verbatim occurrences of the value
are replaced by `<secret>` as a courtesy only. "Always for This Command" stores an approval bound to the secret,
project, variable, exact command and access (SHA-256 in `app_grant`); any difference asks again; deleting the secret
revokes it. Guarantee and limits: [orchestration-extras.md](orchestration-extras.md#3-secrets).

## Host requirements

Only `git`, `/bin/sh` and the bundled `opencode`, `bellocode-exec` and `rg` (ripgrep 15.1.0, pinned SHA-256 in
`Scripts/ripgrep-checksums`, system libraries only). Settings ▸ Containers lists them. `make plugin-test` runs the
plugin's `bun test` in a throwaway container. **Policy point:** the opencode binary embeds Bun; `BUN_BE_BUN` would make
it a JavaScript runtime on the host. The server's environment drops every `BUN_*` variable and the helper never sets one.

## Measured (this arm64 Mac, Rancher Desktop 1.25, `node:22-bookworm-slim`)

Container ready (create + start) 115–196 ms; terminal round trip in the container 133–144 ms; host edit to a green
test in the container 105–112 ms; helper `-c true` p50 20 ms (spike); watch bridge 61 ms; `make plugin-test` 69 ms.

## For the security team

The review (docs/reviews/M3-M6-review.md) names decisions code cannot make. BelloCode enforces boundaries; these are
policy, to be decided and written down:

1. **Image provenance and signing.** Which images may run (default image in the internal registry, pinned by digest,
   scanned, signed). BelloCode shows the resolved digest but does not verify signatures.
2. **Registries.** Which registries are allowed and with which credentials (per-host Keychain items today).
3. **Egress.** Containers default to `bridge` (all outbound traffic); `none` per project; secret commands default to
   no network. Organisation egress control belongs in the network (proxy, firewall), not in BelloCode.
4. **What may be mounted.** Project and its worktree folders read-write by design; user mounts read-only by default.
   Whether users may add read-write mounts, and which paths are off limits (home, `~/.ssh`, cloud drives).
5. **Whether host git is acceptable at all.** Host git is confined (see "Host git"), but runs on the Mac with the
   user's credentials for push, reads the user's global configuration, and relies on Apple's deprecated
   `sandbox-exec`. The alternative is git only in containers (credentials in the container, no host Changes panel
   without a running container).
6. **Secrets.** Whether agent-proposed commands may receive secrets at all, and whether "Always for This Command" is
   allowed; a command the user approves can reveal the value.
7. **Grants.** Acceptable scope and lifetime of schedule project grants, HTML-visual host grants, saved secret-command
   approvals, and plain-HTTP GitLab instances (refused unless allowed per instance).
8. **Threat model.** Whether the Rancher VM, other local Docker API clients, other processes of the same user and
   other containers are in scope (any of them can inspect or influence containers through the socket).

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
- Git run outside BelloCode and opencode is not confined. Secret-command containers a crash left behind are removed
  when the runtime is next seen ready.
- Snapshot glass drawn opaque; terminal working-directory (OSC 7) inside the container depends on the image's shell.
- Not driven on screen: Ports "Open" into the built-in browser (the e2e fetches the forward URL directly).
- Later "Rancher workloads" package: compose-style service containers per project, shared caches, remote runtimes.

Snapshots: `docs/snapshots/containers-*.png`. Commands: `make smoke`, `make e2e-containers`, `make plugin-test`,
`BELLOCODE_CONTAINER_TESTS=1 swift test --filter Live`, `--snapshot containers`.
