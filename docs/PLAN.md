# BelloCode: product plan and roadmap

Status: draft 1, 2026-11-16. Owner decisions still open are listed in section 8.

BelloCode is a native macOS app (Swift, AppKit + SwiftUI) that brings T3 Code's UI/UX and orchestration model to a
single backend: opencode v2, shipped inside the app bundle. There is no multi-provider layer. Anything T3 Code built
only to abstract over providers is dropped; in exchange BelloCode integrates directly with opencode's server API,
plugin system and built-in browser bridge.

Research this plan is built on (read these before implementing an area):

| File | Contents |
| --- | --- |
| [research/01-swift-engineering-patterns.md](research/01-swift-engineering-patterns.md) | Why Swift apps feel bad at an engineering level; technical baseline; agent rules |
| [research/02-content-surfaces.md](research/02-content-surfaces.md) | Transcript, highlighting, composer, diff, terminal, browser: options, picks, spikes |
| [research/03-ux-patterns.md](research/03-ux-patterns.md) | UX anti-patterns and patterns, principles, shortcut map, acceptance checklist |
| [research/04-t3code-feature-inventory.md](research/04-t3code-feature-inventory.md) | 281 T3 Code features classified PORT / ADAPT / DROP, and why T3 Code feels smooth |
| [research/05-opencode-integration.md](research/05-opencode-integration.md) | opencode 2.3.0 server, API, events, plugins, browser bridge, packaging |

## 0. Scope constraints from the owner (2026-11-16)

- **One enterprise, internal use.** Not a public product.
- **opencode only.** No other agent backend.
- **GitLab only**, most likely self-managed. No GitHub. No forge CLI on the host (`glab` and `gh` are not allowed):
  BelloCode talks to the GitLab API directly. Authentication is an access token stored in the macOS Keychain, not
  OAuth. Wherever this plan or a feature note says "pull request" or "GitHub", read "merge request" and "GitLab".
- **Containers (decided 2026-11-16).** Rancher Desktop on the developer's Mac. opencode itself stays a native host
  process. Everything the agent or user *runs* (tests, builds, dev servers, scripts, terminals) executes in a
  container, because most runtimes will be banned from the host (no bun, python or npm on the host). BelloCode must
  therefore not depend on any host runtime or CLI either: it talks to Rancher Desktop's Docker-compatible API over
  its socket. Background: [research/06-containers-rancher.md](research/06-containers-rancher.md) (which recommended
  containerising the server too; the owner chose command execution only).
- **Look and feel.** The first builds looked like a stock Swift app. A design pass now defines the target visual
  language from T3 Code's source and a mock ([design/](design/)); a restyle of every surface follows.

### Owner answers (2026-11-18)

- **GitLab:** Free tier; native API only (no `glab`). Instance `https://gitlab.novacoast.com`. Git uses HTTPS, not
  SSH. Personal access tokens last one year.
- **Git features:** parity with T3 Code's git integration, built natively into the app.
- **MCP servers:** global MCP servers are wanted. The owner's existing ones are Docker images or separate compose
  stacks that expose an MCP endpoint; a company-wide MCP gateway will be integrated later.
- **Network:** an internal proxy transparently intercepts dependency traffic on the network; users do not configure it.
- **Images (2026-11-18):** images are not signed, and there is no internal registry used for distribution. For most
  projects the image is built from source locally (a Dockerfile in the repository); base images come from public
  registries through the transparent proxy. So BelloCode must build images natively through the Docker Engine API,
  signature verification stays off, and the registry allowlist applies to base images and pulled service images only.

### Owner direction (2026-11-18, later)
- **Browser (2026-11-18):** spike G7 passed (Chromium + `browse` fully in a container). Production uses ONE shared
  browser container for all sessions (efficiency over per-project isolation), each thread with its own `browse`
  session (tab group). It behaves like a developer's own browser: one persistent profile, sign-ins kept and shared by
  every thread (owner decision; `browse` already supports several agents on one browser). Networking: the browser reaches project dev servers and services only through a BelloCode
  routing proxy addressed by project-qualified host names; internet traffic goes through the same egress path as the
  workspace (company CA, transparent proxy).
- **Execution model (2026-11-18):** configurable per developer and per project. Default: a shared workspace container
  that mounts one or more code roots (for this owner `~/Documents/Repos`, but configurable per developer) at the same
  paths, so multi-repo work needs no per-request approval inside those roots. Options: a per-project container (dev
  container or image) and a host-shell docker-only mode. Configured code roots count as "inside the project" for risk
  and Auto policy.
- **Secrets:** a built-in Keychain secret manager with brokered use, placeholder substitution (an egress proxy swaps
  the real value in only for bound destinations) and an explicitly labelled visible use. The goal is to state
  confidently that the agent cannot see a brokered or placeholder secret.
- **Browser:** `browse` on the host is not acceptable; only Chrome running in a container with `browse` installed in
  it (spike G7).
- **Docker CLI (2026-11-18):** the `docker` CLI is allowed on the host (it is Rancher Desktop's, in `~/.rd/bin`). This
  replaces the earlier "no container CLI on the host" assumption. BelloCode may use `docker`, `docker compose` and
  `docker buildx` where that is simpler or more complete than the Engine API; agent commands still run in the container.

- **Dev containers:** move to dev-container infrastructure like VS Code's (`.devcontainer` where a project has one,
  a default otherwise), opencode still on the host writing files. Handle the dual-environment edge cases (git in/out,
  company certificates, secrets, ports, file ownership) and give the agent an environment contract so it navigates
  them without trial and error. Git stays on the host. Research: research/09.
- **Permissions:** the owner will run with full access but wants risky things surfaced (secrets entering the context,
  anything outside the project). Implement T3 Code's **Auto** mode. Agents may interrupt other threads without
  approval. MCP servers always need human approval. Research: research/08.
- **Secrets:** a value the agent can never see is a key feature (stronger than today's "approve the exact command").
- **opencode upgrades:** a repeatable upgrade and regression gate; move to 2.3.2 (needed for a new GPT model).
- **Browser:** find a way to use real Chrome and the actual `browse` functionality (research/09).

## 1. Facts that shape the plan

1. "opencode2" is opencode major version 2 (2.3.0 locally, MIT). One 224 MB arm64 binary, Bun compiled in.
2. `opencode serve --stdio --port 0` starts in about 0.1 s, prints its URL as one JSON line, and exits when the
   parent closes stdin. One server serves every project; each request names its directory.
3. opencode already has most orchestration primitives: child sessions, background sub-agents that wake the parent,
   session-to-session messaging, queued and steering follow-ups, forks, revert, worktrees, per-turn diffs, PTYs,
   permission and question requests, provider login over the API, unread basis (`time.idle` vs `time.viewed`).
4. The event stream is volatile: events missed while disconnected are gone. The app needs its own projection cache
   and must re-fetch on every reconnect.
5. The browse tool (`anomalyco/browse`) is an MCP server that tunnels Chrome's debugging protocol through a Chrome
   extension. It cannot drive a WebKit view. But opencode 2.3.0 ships a built-in browser plugin
   (`experimental.browser`, contract version 4) whose `browser.*` tools appear only when a desktop app attaches a
   browser it owns. That is the integration point for the built-in browser.
6. The useful plugin surfaces (client-hosted MCP, plugin RPC, browser bridge, schedules) are all under
   `/api/experimental`. The embedded binary must be pinned and guarded by contract tests.
7. This machine has Command Line Tools only (Swift 6.4), no Xcode and no code-signing identity. `swift build`,
   `codesign` and `notarytool` are available; `xcodebuild`, XCUITest and Instruments are not.

## 2. Feature list

Tags: **M1** to **M5** are the milestones in section 6. "Later" means after first release.

### Shell and navigation
- M1: three-region window: sidebar, chat with docked composer, tabbed right panel, bottom terminal drawer.
- M1: draft "hero" composer that docks after the first send; thread header with project / session / branch.
- M2: per-thread panel state, instant panels (0 ms default, optional animation), back/forward, reopen closed tab.
- M2: window and workspace restoration: windows, selected thread, pane sizes, scroll anchors, drafts.
- M2: undo toasts (5 s) in place of confirmation dialogs; empty states for every surface.
- M5: multiple windows and native tabs; floating mini-player panel; focus-region cycling.

### Command palette, search, keyboard
- M2: command palette with frecency and `>` actions; quick open for projects, sessions and files.
- M2: every action is a menu item with a shortcut; default shortcut table (research 03, section D).
- M2: find in thread; thread title search. M3: full-text message search (local FTS index).
- M5: user keybindings file with when-clauses; find in diff; project content search.

### Projects
- M1: add folder, list, select, remove; per-project session list; project icon and name.
- M2: new project from scratch (git init, first commit); background clone while the first prompt is typed.
- M2: pin, archive, reorder; per-project defaults (model, agent, permission mode, workspace mode).
- M3: project actions (setup script, run on settle, stop on settle, preview URL); scratch threads without a project.

### Threads and sidebar
- M1: create, rename, delete; generated titles; live status indicator per row; persisted drafts.
- M2: sections Pinned / Active / Working / Snoozed / Settled; drag reorder and drag to change state; settle,
  snooze, archive, mark unread; auto-settle rules.
- M2: attention model: needs approval, needs answer, failed, finished unread, running, idle. "Needs you" group at
  the top; "next needs attention" command.
- M3: start in background; send one prompt to several models; thread links via `bellocode://`.

### Running agents
- M1: send, stream, interrupt; inline approvals (allow once / always for scope / deny); structured questions.
- M1: permission modes mapped to opencode session rules (ask, auto-edit, full access) and plan / build agents.
- M2: queue vs steer with a visible queued-message list (edit, reorder, send now); `/compact`, `/clear`, `/goal`.
- M2: edit-from-here rewind with optional file revert; fork; context-window and cost display; elapsed line.
- M3: usage-limit recovery (resume at reset); proposed-plan card with "implement plan".

### Models and accounts
- M1: onboarding that works with opencode's free models before any login; provider login (API key and OAuth)
  through the server API; import credentials from an existing opencode install with consent.
- M1: model picker grouped by provider with favourites and keyboard navigation; variant / effort picker.
- M2: accounts page (multiple credentials per provider); hidden models and ordering; `@model` mention.

### Transcript
- M1: virtualised streaming timeline; stick-to-bottom with release; stable anchoring; Markdown with tables and
  highlighted code; per-message copy; error banners.
- M1: tool-call rows with status; reasoning blocks; todo lists.
- M2: collapsible work groups ("Read 4 files, 3 s") with lazy tool bodies and live command output; sub-agent cards;
  lifecycle dividers; file links; images and media viewer; tool visibility modes.
- M2: cross-message selection and copy as Markdown (subject to the transcript spike, section 5).
- M5: Mermaid, KaTeX, minimap, VoiceOver announcements, RTL.

### Composer
- M1: auto-growing native text view; correct IME, undo, paste; send-key option; attachments and image paste.
- M2: `@` file mentions, `/` commands and skills from opencode, context chips (file, image, terminal excerpt,
  review comment, thread), large paste to attachment, prompt history recall, prompt stash.
- M2: controls bar: model, variant, permission mode, agent, workspace, branch.
- Later: voice dictation.

### Git, worktrees, diffs, files
- M2: workspace mode (local / new worktree / existing worktree); branch picker with base branch; worktree
  creation with setup script; APFS copy-on-write fast checkout.
- M2: diff panel: per turn, whole branch, per commit; unified and split; changed-files tree; open in editor.
- M3: inline review comments sent to the composer; per-hunk revert; worktree handoff and cleanup policies.
- M3: generated branch names, commit messages and PR text through an opencode small model; commit / push / open PR.
- M5: file explorer and file viewers (Quick Look, PDF, media).

### Terminal
- M2: per-thread persistent terminals in the drawer and as tabs, with split; retained scrollback.
- M3: terminal excerpt chips; agent-readable terminals (opencode PTYs); servers panel with Stop; link detection
  that opens the built-in browser.

### Built-in browser
- M4: WKWebView tabs with URL bar, history, zoom, find, Web Inspector; per-project storage profiles.
- M4: agent control through opencode's `experimental.browser` bridge: `browser.*` tools appear when a thread has a
  browser attached; agent cursor and tab ownership shown to the user.
- M4: pick element and annotate, sent to the composer; responsive presets; appearance override; auto-open on a
  dev-server URL.
- M4: "Your Chrome" status for the separate browse tool (pairing, doctor) for tasks that need real logins.
- Later: recording; optional Chromium (CEF) backend behind the same interface for full debugging-protocol fidelity.

### Orchestration
- M3: delegated child tasks on opencode child sessions: completion wakes the parent; status, cancel, follow-up;
  child approvals and questions bubble to the parent; stop cascades.
- M3: Agents panel and lineage tree ("2 running, 1 needs you"); jump to child and back.
- M3: agent-facing tools: create threads, send / wait / read / interrupt another thread, list and manage projects
  and worktrees, queue, pending requests, send-to-user, request secret, HTML preview, link pull request.
- M3: scheduled tasks (interval, fixed time, once); PR auto-link and PR watch that wakes the thread.
- Later: review guides, PR page, stacks; workflows.

### Notifications, secrets, platform
- M2: notifications (only for blockers and completions, when not foreground); dock badge; status in window title.
- M3: secret request card backed by Keychain; inline HTML visual replies.
- M5: themes (separate light and dark, VS Code theme import), fonts per surface, settings search, Labs page.
- M5: Sparkle updates carrying the pinned opencode; diagnostics, logs, storage cleanup.

### Dropped from T3 Code
Provider instances and cross-provider delegation, Claude-only workflows, remote and linked environments, T3
Connect, mobile, device previews, non-GitHub hosts, telemetry and admin policy.

## 3. Architecture

```
BelloCode.app  (Developer ID, hardened runtime, not sandboxed)
 ├─ Contents/MacOS/BelloCode                 Swift app
 ├─ Contents/Helpers/opencode                pinned 2.x, re-signed with JIT entitlements
 ├─ Contents/Helpers/rg                      bundled ripgrep
 └─ Contents/Resources/opencode-plugin/      "bellocode" server plugin (TypeScript, local path)

App process
  UI (AppKit + SwiftUI, main actor)
    └─ view models (@Observable, per window / thread / message)
  Engine (actors)
    ├─ ProjectionStore   GRDB/SQLite cache: projects, sessions, messages, parts, pending requests, queue, FTS
    ├─ Reducers          events -> projections; attention model; optimistic sends
    ├─ StreamCoalescer   token deltas -> at most ~30 UI commits per second per message
    └─ Services          Session, Approval, Auth, Worktree, Terminal, Git, Scheduler, PRWatch
  OpenCodeKit (actors)
    ├─ ServerSupervisor  spawn `opencode serve --stdio --port 0`, isolated XDG dirs, random password, restart
    ├─ HTTP client       generated DTOs + hand-written transport, typed errors
    ├─ EventHub          one SSE connection, spec-correct parser, reconnect -> resync
    ├─ ClientMCPHost     app-hosted "bellocode-ui" MCP over WebSocket (UI tools)
    └─ BrowserBridge     `experimental.browser` v4 contract over WKWebView
```

Choices and their reasons:

- **AppKit where feel is decided, SwiftUI elsewhere.** Window, split view, transcript, composer, diff, terminal and
  browser hosts are AppKit. Settings, pickers, palette rows, cards and onboarding are SwiftUI. The usual cause of
  bad-feeling Swift apps is using SwiftUI for exactly the surfaces it handles worst.
- **opencode is the source of truth; SQLite is a rebuildable cache.** Threads open from cache with no spinner, then
  reconcile. This is what makes navigation feel instant and survives the volatile event stream.
- **One ordered ingestion path.** SSE parser, then reducer, then coalescer, then per-message state. A token never
  invalidates the whole transcript.
- **Deep opencode integration in three channels.** (1) a thin bundled server plugin for hooks, orchestration tools
  and events; (2) UI tools hosted by the app over client MCP, which vanish when the app is closed; (3) the built-in
  browser bridge. Session metadata stores app state such as linked PRs and pins so it travels with the session.
- **Isolated data by default.** BelloCode's opencode uses its own config, data and cache directories, so it never
  shares a database with a user's own opencode install. Credentials can be imported.
- **Pinned binary with contract tests.** The OpenAPI document and recorded event fixtures for the pinned version
  live in the repo; upgrading opencode is a deliberate change that must pass them.

## 4. Repository layout

```
Package.swift
Sources/
  BelloCore/        domain types, IDs, no dependencies
  OpenCodeKit/      supervisor, HTTP, SSE, DTOs, client MCP host
  Engine/           projection store, reducers, coalescer, services
  DesignSystem/     tokens, typography, icons, motion, shared controls
  TranscriptKit/    transcript view, Markdown pipeline, highlighting
  ComposerKit/      composer text view, mentions, attachments
  DiffKit/          diff model and views
  TerminalKit/      terminal host
  BrowserKit/       web tabs and the browser bridge
  BelloCodeApp/     app delegate, windows, menus, feature wiring
  MockOpenCode/     scriptable fake server for tests and UI fixtures
Tests/<Module>Tests/
Plugin/             bellocode opencode plugin (TypeScript)
Contracts/opencode-<version>/   openapi.json, recorded event streams
Scripts/            fetch-opencode, make-app, sign, notarize, run-fixture
docs/
```

## 5. Decision gates (M0 spikes)

Each spike is a small prototype with a pass/fail measurement. Results are recorded in `docs/spikes/`.

| Gate | Question | Candidates | Pass condition |
| --- | --- | --- | --- |
| G1 Transcript | Which engine carries the transcript? | (A) one TextKit 2 document with attachments; (B) NSCollectionView of self-sizing rows | 10,000 mixed messages plus a streaming tail: no visible hitch while scrolling, anchor holds within 2 pt when content above changes, follow / release / rejoin works. A wins if it passes, because it gives cross-message selection for free; otherwise B with per-message selection. |
| G2 Server | Can the app own opencode robustly? | Supervisor + SSE + resync | Kill the server mid-stream, sleep/wake, reconnect: no lost or duplicated messages after resync. |
| G3 Browser | Can WKWebView satisfy the browser bridge? | `experimental.browser` v4 over WKWebView | A real opencode session navigates, snapshots, clicks, fills, evaluates and screenshots the visible tab. |
| G4 Packaging | Does a SwiftPM-built, re-signed bundle run? | `swift build` + bundle script + ad-hoc signing | App launches from Finder, starts the bundled opencode, runs a turn on a free model. |
| G5 Terminal | Is SwiftTerm good enough? | SwiftTerm vs opencode PTY WebSocket feed | vim, tmux, fast output, resize all behave; latency acceptable. |

### Gate results (2026-11-16)

| Gate | Result | Decision | Evidence |
| --- | --- | --- | --- |
| G1 Transcript | A failed (57% of frames missed scrolling up, multi-second stalls on long jumps); B passed every measure with 0 pt drift and working cross-message selection | **B: virtualised rows (NSTableView, CoreText-drawn)** | [G1-A](spikes/G1-A-textkit.md), [G1-B](spikes/G1-B-rows.md) |
| G2 Server | Passed on the second run after a resync fix (server copy wins after a restart) | Supervisor + resync as designed | [G2](spikes/G2-server.md), [engine](features/engine.md) |
| G3 Browser | Passed: a real agent drove a WKWebView through `experimental.browser` v4 | WKWebView for v1; Chromium later behind the same interface | [G3](spikes/G3-browser-bridge.md) |
| G4 Packaging | Passed with ad-hoc signing; Developer ID and notarization untested | SwiftPM + bundle script | [G4](spikes/G4-packaging.md) |
| G5 Terminal | Passed with conditions | SwiftTerm as renderer, opencode owns the PTY | [G5](spikes/G5-terminal.md) |

Still to re-measure with the screen unlocked and a person present: on-screen frame pacing for the transcript and
terminal, real trackpad input, input methods, VoiceOver.

## 6. Roadmap

| Milestone | Outcome | Main work packages |
| --- | --- | --- |
| **M0 Foundations** | Repo builds, bundle runs, gates G1 to G5 answered | Scaffold and build scripts; OpenCodeKit core; MockOpenCode; five spikes |
| **M1 Walking skeleton** | Add a project, start a thread, watch it stream, approve a tool call, switch threads instantly | Engine and projection store; window shell and sidebar; transcript v1; composer v1; approvals and questions; onboarding, auth and model picker |
| **M2 Daily driver** | Good enough to replace T3 Code for single-agent work | Queue and steer; work groups and tool cards; diff panel; terminal drawer; worktrees and branches; palette, menus, shortcuts; attention, notifications, restoration; sidebar sections and drag |
| **M3 Orchestration** | Agents managing agents, as in T3 Code | bellocode plugin; client MCP tools; child tasks and Agents panel; thread-to-thread tools; schedules; PR link and watch; secrets; HTML replies; message search |
| **M4 Browser** | Agent and user share one built-in browser | Web tabs; browser bridge; element picker and annotations; presets; browse status |
| **M5 Ship** | Signed, notarized, auto-updating release | Themes and settings; keybindings; accessibility pass; performance gates; signing, notarization, Sparkle; diagnostics |

Status, 2026-11-16: M0 and M1 are merged on `develop` (shell, Engine, composer, approvals, model picker, onboarding,
production transcript), plus the M2 terminal drawer and the fixes from the first independent review
([reviews/M1-review.md](reviews/M1-review.md)). Per-feature notes are in [features/](features/). Nothing has yet been
checked by a person at the screen.

M1 packages depend on M0. Within M1 to M5, packages are cut along module boundaries so several can run at once.
M4 can start as soon as G3 passes and does not block M2 or M3.

## 7. How the work is orchestrated

- **Planner (this thread)** owns the plan, cuts work packages, merges, and keeps this file current.
- **Claude Opus 5.5 agents implement.** One work package per agent, each in its own git worktree and branch. A brief
  names the module, the files it may touch, the research sections to read, and the definition of done.
- **GPT-6.1 Terra agents research and review.** Research before a milestone where the plan has unknowns; after
  each package, an independent review against [AGENTS.md](../AGENTS.md) and the UX checklist in research 03.
- **Definition of done for every package:** `swift build` and `swift test` pass; new logic has tests against
  MockOpenCode or recorded fixtures; no heavy work on the main actor; every action reachable from menu and
  keyboard; states covered (empty, loading, stale, failure); the package's own entry in `docs/spikes/` or
  `docs/features/` says what was verified and what was not.
- **Verification without Xcode:** unit and fixture tests via `swift test`; the app is launched from the bundle
  script and inspected with screenshots; measurements use `os_signpost` and in-app frame timing. Instruments and
  XCUITest become available if Xcode is installed.

## 8. Decisions for the owner

1. **Install Xcode?** Recommended. Without it there is no Instruments, no XCUITest, and SwiftUI previews are
   unavailable. The plan works on Command Line Tools but performance evidence is weaker.
2. **Apple Developer ID.** Needed for a notarized build others can open. Until then builds are ad-hoc signed and
   run only on this Mac.
3. **Keep running when the window is closed?** T3 Code runs agents, schedules and PR watches in a background
   service. Planned default: the app stays alive in the menu bar; a login-item helper is deferred.
4. **Isolated or shared opencode data?** Planned default: isolated, with credential import. Sharing means BelloCode
   threads show up in your terminal opencode, but two servers must never use one database.
5. **Cross-message text selection.** Planned as a goal decided by gate G1, not a hard requirement.
6. **GitHub scope for first release.** Planned: link, watch and open PRs; review guides and stacks later.
7. **Send key.** Planned default: Return sends, Shift-Return inserts a newline (as T3 Code), configurable.
