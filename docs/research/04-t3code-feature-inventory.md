# BelloCode: T3 Code feature inventory (UI/UX and orchestration)

Research date: 2026-11-16. Subject: T3 Code (https://t3.codes, MIT, github.com/pingdotgg/t3code). Purpose: decide what BelloCode (native macOS, Swift, exactly one backend: the bundled opencode v2 binary) should **PORT**, **ADAPT** or **DROP**.

## 0. Sources, versions and evidence legend

| Code | Source | Notes |
| --- | --- | --- |
| **B** | Installed app `/Applications/T3 Code (Nightly).app`, version `0.1.10-nightly.20261116.4787`, commit `b5554ac8114f` (from `app.asar/package.json`). Extracted to scratch and read only: Electron main/preload (`apps/desktop/dist-electron`), bundled server (`apps/server/dist/*.mjs`), bundled web client (`apps/server/dist/client`, 1,197 chunks; chunk and route names reveal features). | Treated as untrusted data; nothing executed. |
| **M** | The MCP tool schemas the running nightly server served to this research session (`mcp__t3-code__*`). This is the live, authoritative agent tool surface of the installed build. | |
| **D** | Public repo docs, shallow clone of `main` at `1d1489d` (2026-11-16 10:43 PST): `docs/user/*`, `docs/internals/*`, `docs/orchestration-v2/*`. | Very detailed, current user docs. |
| **S** | Public repo source at the same commit (`apps/web/src`, `apps/server/src`, `apps/desktop/src`, `packages/*`). | |
| **L** | Structure of local state under `~/.t3` (file names, SQLite table/column names, aggregate counts only). No conversation content, secrets or tokens were read or copied. | |
| **P** | Live process inspection (`ps`, `lsof`) of the running nightly. | |

The nightly and public `main` were built on the same day, and every feature checked in the bundle had a public-source counterpart; differences are noted where found (for example, the nightly bundle has a `settings.storage` route and the public tree has `settings.beta`/`integrations` pages). "Nightly-only" behaviour could not be isolated beyond that. **No screenshots were taken and the UI was not driven**; layout statements come from component, route and doc names.

Classification: **PORT** = bring as is (behaviour and UX), **ADAPT** = bring but redesign around one opencode backend and/or native macOS, **DROP** = multi-provider-only, cloud/remote/mobile-only, or out of scope for v1 ("defer" marks things worth revisiting later).

Important nuance for every "provider" row: opencode is itself multi-*model-provider* (Anthropic, OpenAI, OpenRouter, local, ...). So anything T3 does to pick among *agent runtimes* (Codex vs Claude vs Cursor vs opencode) is DROP, but anything about picking *models and options* survives as ADAPT, driven by opencode's own catalog.

---

## 1. Architecture and data model (what the code reveals)

### 1.1 Processes (P, B, S)

```
T3 Code (Nightly)            Electron main: window, menus, native integrations, IPC "desktop:*",
  |                          preview <webview>s, auto-update, SnapShot helpers
  |-- Renderer               React SPA (apps/web), served by the local server; talks to it over
  |                          WebSocket RPC exactly like a remote client would
  |-- server child           the SAME Electron binary run as Node: `--require compileCache.cjs
  |     |                    app.asar/apps/server/dist/bin.mjs --bootstrap-fd 3`, listening on
  |     |                    127.0.0.1:3773 (HTTP + WebSocket RPC + /mcp endpoint)
  |     |-- provider processes   codex app-server, claude (stream-json), opencode serve, ...
  |     |-- t3-resource-monitor  native helper bundled in Resources/
  |     |-- cloudflared          T3 Connect tunnel (remote access)
  |     `-- headless Chrome      (~/.t3/tools) for html_preview screenshots / server-side browser
```

* **Server/client split is hard**: "Provider processes, terminals, Git, and project files belong to the server." The desktop renderer obeys the same boundary as web and mobile (D `internals/overview.md`). A shared `packages/client-runtime` owns connection retries, auth renewal and projections for all clients.
* **IPC**: `contextBridge.exposeInMainWorld("desktopBridge")` with ~130 `desktop:*` channels (B `preload.cjs`): folder picking, context menus, notification badge, theme, updates (`update-check/download/install/set-channel`), SSH environments, WSL, Tailscale serve, server exposure, ~45 `preview-*` channels (webview tabs, zoom, find, devtools, cookie import, element pick, recording, PiP), SnapShot capture, quit-shortcut, trackpad scroll begin/end.
* **RPC**: Effect RPC over WebSocket (`packages/contracts/src/rpc.ts`), subscriptions deliver "snapshot + cursor" then deltas; HTTP for bounded history pages, attachments and diffs (D `internals/performance-regressions.md`).
* **MCP**: the server exposes an authenticated HTTP MCP endpoint `http://127.0.0.1:<port>/mcp`, injected into every provider session under the key `t3-code` with a per-provider-session bearer token (scoped to environment, parent thread, provider instance, session; idle/max expiry; revoked on release) (D `orchestration-v2/orchestrator-mcp-server.md`).

### 1.2 Orchestration core (D `internals/overview.md`, `orchestration-v2/*`; S `apps/server/src/orchestration-v2`)

* **Event-sourced with transactional projections**: an `Orchestrator` serializes commands per thread and decides events *without I/O*; `EventSink` commits events + projections + command receipt + **outbox effects** in one SQLite transaction; an `EffectWorker` performs side effects (start provider turn, interrupt, steer, checkpoint capture, title generation, detach session, stop delegated tasks) after commit and feeds results back as commands. Ack = "intent committed", not "work done".
* **Idempotency**: command receipts dedupe retries (`clientRequestId` on MCP tools).
* **Graph model**: `AppThread → Run (counted user turn) → RunAttempt → ExecutionNode tree (root turn, tool, approval, subagent) → ProviderThread/ProviderTurn`. Only the root node completes a run; child completion never closes the parent; app IDs are primary and provider IDs are refs.
* **Event log pruning**: events older than ~a day are deleted once projections cover them; projections are the source of truth. Locally the `orchestration_v2_events` table is empty while projections hold 181 threads, 472 runs, 17,394 turn items (L).
* **Turn-item types observed locally** (L, counts): command_execution, reasoning, assistant_message, dynamic_tool, web_search, file_change, checkpoint, user_message, subagent, notification, user_input_request, todo_list, secret_request, run_interrupt_request/result, error, compaction, file_search, system_notice, handoff.
* **Outbox effect types observed** (L): `provider-turn.start`, `provider-turn.steer`, `provider-turn.interrupt`, `checkpoint.capture`, `thread-title.generate`, `provider-session.apply-thread-title`, `provider-session.detach`, `delegated-tasks.stop`.
* **Checkpoints** are hidden Git refs (no commits on the user's branch); revert coordinates files with provider conversation rollback.
* **Settlement, PR sync, PR watch, usage-limit resume, scheduled tasks, idle compaction** are server-owned reactors that run with no client connected.

### 1.3 Persistence layout (L, D)

| Path | Contents |
| --- | --- |
| `~/.t3/userdata/statev2.sqlite` (+WAL) | v2 event store, projections (threads, runs, run_attempts, nodes, turn_items, messages, plans, subagents, runtime_requests, checkpoints, checkpoint_scopes, context_transfers, context_handoffs, provider_sessions/threads/turns), command receipts, effect outbox, FTS5 message search, thread launch workflows, `projection_projects` (title, workspace_root, scripts_json, default_model_selection, default_thread_env_mode, favicon_path, auto_pull, project_icon_json, pinned_at, archived_at), `projection_thread_pull_requests`, `pull_request_files_viewed`, `pull_request_review_guides`, `scheduled_tasks` (+ webhook deliveries/pending/replay keys), auth sessions/pairing links, peer environment links, MCP app model context. |
| `~/.t3/userdata/settings.json` | Server/environment settings: provider instances, model preferences (hidden models, order), default model selection, idle compaction, prompt suggestions. |
| `~/.t3/userdata/client-settings.json` | Per-device UI prefs (~80 keys): notification mode, fonts and sizes per surface, chat width, panel animation duration, diff layout/whitespace, send shortcut, follow-up behaviour, tool-call visibility, sidebar grouping/sort, working shelf, timestamp format, browser defaults and profiles, confirmations, voice, SnapShot, math rendering, word wrap. |
| `~/.t3/userdata/desktop-settings.json` | Window bounds/maximized, update channel. |
| `~/.t3/userdata/keybindings.json` | User-editable keybinding rules (88 defaults). |
| `~/.t3/userdata/attachments/` | Uploaded files named `<threadId>-<attachmentId>.<ext>` (images, pasted text, HTML renders). |
| `~/.t3/userdata/browser-artifacts/` | Browser screenshots/recordings. |
| `~/.t3/userdata/secrets/` | Encrypted secret blobs (`*.bin`). |
| `~/.t3/userdata/themes/`, `logs/`, `model-manifest.json`, `usage-*.json` | Custom themes, rotating logs, model classification, usage caches. |
| `~/.t3/projects/` | Projects created from scratch ("New project"). |
| `~/.t3/worktrees/<repo>-<suffix>` | T3-managed git worktrees. |
| `~/.t3/scratch/<date>-<slug>-<id>` | Folders for threads without a project. |
| `~/.t3/caches/` | Provider catalog caches (one JSON per driver), PR cache, fast-checkout APFS clone cache. |
| `~/.t3/tools/` | Managed binaries (codex, cloudflared, headless Chrome, ACP agents). |
| `~/.t3/runtime/versions/` | Versioned server runtimes for the background service. |
| `~/.t3/bin/t3` | CLI (`t3 service`, `t3 update`, `t3 triage`, `t3 connect`). |

**BelloCode take**: the *pattern* (command → events + projection + outbox in one transaction, effect worker, receipts, server-owned reactors) is the root of T3's reliability and is worth ADAPTing in-process (Swift actor + SQLite/GRDB), without the network split, multi-client sync, or provider-agnostic graph generality.

### 1.4 Architecture rows

| Feature | Behaviour | Evidence | Class | Reason |
| --- | --- | --- | --- | --- |
| Local server + web renderer | UI is a client of a localhost server over WS RPC | P, S | ADAPT | Native app can keep an in-process "engine" actor; keep the client/engine boundary as a Swift API, not a socket. |
| Event store + projections + outbox | Durable intent, idempotent retries, crash recovery | D, S, L | ADAPT | Keep the pattern, simplify schema to one backend. |
| Execution graph (runs, attempts, nodes) | Separates user turns, retries/steer attempts, tools, subagents | D | ADAPT | Map 1:1 onto opencode sessions/executions/steps; drop provider-normalisation layers. |
| Snapshot + cursor subscriptions, bounded windows | Thread view loads ~1 MiB / 10 turns window; older pages on scroll | D | ADAPT | Same idea for SQLite paging into a virtualised list. |
| Separate command-output channel | Live command output never goes through the event log; one bounded tail per command, throttled | D, S `CommandOutputHub.ts` | PORT | Prevents a chatty command from blocking every other thread. |
| Provider runtime recovery | Reattach/resume provider session after crash, idle reap or app restart | D | ADAPT | Single recovery path for the bundled opencode server. |
| Multi-provider adapter registry, capability flags | Normalises Codex/Claude/Cursor/Grok/ACP/Pi/... | D, S | DROP | One backend. |
| Background service (`t3 service`) | Server runs as a user service so agents keep working with UI closed | D `background-service.md`, L `runtime/` | ADAPT | Consider a login item/helper that owns opencode so scheduled tasks and long turns survive window close; v2 candidate. |
| Resource monitor helper | Native helper sampling resource use | B, P | DROP | Optional; can use native APIs later. |

---

## 2. App shell and layout

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Three-region layout | Left thread sidebar, central chat (timeline + docked composer), right panel with tabs; bottom terminal drawer | Main window | S `AppSidebarLayout.tsx`, `ChatView.tsx`, `ChatRightPanel.tsx`, `ThreadTerminalDrawer.tsx` | PORT | Core of the feel. NavigationSplitView/NSSplitView + inspector. |
| Right panel tabbed surfaces | Tab kinds: browser preview, diff, files explorer, single file, terminal, pull request, pull-requests list, device, side chat, plan | Right panel; `mod+t` opens "new tab" menu | S `rightPanelStore.ts`, `RightPanelTabs.tsx` | ADAPT | Keep tabs; drop device; PR tabs GitHub-only. |
| Panel state per thread | Each thread remembers its open panel/tabs; switching threads snaps without replaying transitions | Global | D `appearance.md` (Motion), S `panelAnimations.ts` | PORT | Big part of "smooth". |
| Panel animations off by default | Sidebar/right panel/terminal open instantly; slider 0-400 ms; respects reduced motion | Settings → Appearance | D, L (`panelAnimationDurationMs`) | PORT | Snappiness by default. |
| Resizable panels | Drag handles; sidebar width persisted | Sidebar edge, right panel edge | S `useResizableWidth.ts`, `RightPanelResizeHandle.tsx` | PORT | Native split views. |
| Floating mini-player | Preview/device can float over chat as a draggable, resizable PiP window | Preview toolbar | S `ThreadPreviewMiniPlayer.tsx`, B `preview-pip-*` | ADAPT | NSPanel; v2 candidate. |
| Thread header | Title (rename inline), project/branch breadcrumb, Open-in-editor picker, git actions, panel layout controls | Top of chat | S `ChatHeader.tsx`, `WorkspaceBreadcrumb`, `OpenInPicker.tsx`, `PanelLayoutControls` | PORT | |
| Thread details card/panel | Configurable rows: environment & worktree, branch & PR, changes, context window, usage limits, project scripts, servers (ports started by thread), side chats, lineage, automations, open in editor, git actions | Chat side card; right-click to customise | S `threadDetailsItems.ts`, D `thread-sidebar.md` | PORT | Great at-a-glance status. |
| Draft hero → docked composer | New thread shows a centered "hero" composer with project heading; after first send it docks to the bottom and branch/worktree controls retreat | New thread | S `DraftHeroHeadline.tsx`, `draftHeroTransition.ts`, D `appearance.md` | PORT | Signature transition. |
| Empty states | No projects hero, no active thread state | Main area | S `NoProjectsHero.tsx`, `NoActiveThreadState.tsx` | PORT | |
| Toasts with Undo | Unpin/settle/snooze/archive/discard draft show 5 s Undo; `mod+z` triggers it | Bottom of sidebar | D `thread-sidebar.md`, S `SidebarThreadUndoNotice.tsx` | PORT | Undo instead of confirmations. |
| Quit hold | `Cmd+Q` must be held 1.2 s or double-pressed (configurable) | Global | D `keybindings.md`, S `QuitHoldOverlay.tsx` | PORT | Prevents killing running agents. |
| Reopen closed view | `mod+shift+t` reopens last closed tab (file, diff, PR, browser, device) | Global | D, S `reopenClosedView.ts` | PORT | |
| Back/forward navigation | `mod+[` / `mod+]` through visited pages; swipe navigation | Global | D, S `navigationHistory.ts`, `HistorySwipeNavigation.tsx` | PORT | Native trackpad swipe. |
| Workspace focus cycling | `F6`/`shift+F6` cycle focus regions | Global | L keybindings, D `keyboard-focus.md` | PORT | Accessibility. |
| Glass/opacity, contrast | Adjustable glass opacity and contrast | Appearance | L (`glassOpacity`, `appearanceContrast`) | ADAPT | Use native materials/vibrancy. |
| Mobile layouts | iPad/phone navigation and layers | Mobile app | D `internals/mobile-*` | DROP | macOS only. |

## 3. Command palette, search and keyboard

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Command palette | `mod+k`: actions, projects, threads, themes, settings; `>` prefix = actions only; frecency ranking; remembered pick per query for 3 weeks | Overlay | D `thread-sidebar.md`, S `CommandPalette*.tsx` | PORT | Central to keyboard flow. |
| Message search in palette | Threads whose messages contain all words appear under "In messages" and open at the match (FTS5) | Palette | D, L (`orchestration_v2_message_search*`) | PORT | SQLite FTS5. |
| File picker | `mod+p` fuzzy file open in project | Overlay | L keybindings, S `projectFilesQueryState` | PORT | |
| Project search | `mod+shift+f` content search across project | Overlay | L keybindings, B chunk names | PORT | ripgrep/fff (bundle ships `@ff-labs/fff`). |
| Find in thread | `mod+f` searches whole thread incl. older unloaded messages (server-side) and proposed plans | Chat find bar | D `keybindings.md`, S `ThreadFindBar.tsx`, `ThreadFind.ts` | PORT | |
| Find in diff | `mod+f` inside diff searches all files incl. folded | Diff | D | PORT | |
| Configurable keybindings | JSON rules `{key, command, when}` with context keys (`terminalFocus`, `previewFocus`, `composerFocus`, `turnRunning`, `draftThreadRoute`, `modelPickerOpen`, ...), last-match-wins, `!`, `&&`, `||` | Settings → Keybindings; file | D `keybindings.md`, L | ADAPT | Keep the command-ID model; map to NSMenu key equivalents plus a when-clause dispatcher. |
| Default shortcuts (selection) | `mod+n` new thread, `mod+shift+n` new local, `mod+alt+n` no-project thread, `mod+1..9` jump to thread, `mod+shift+[ ]` prev/next thread, `mod+b` sidebar, `mod+alt+b` right panel, `mod+j` terminal, `mod+d` diff, `mod+shift+j` preview, `mod+shift+m` model, `mod+shift+e` effort, `mod+shift+a` permissions, `mod+shift+x` workspace, `mod+shift+g` branch, `mod+shift+l` previous worktree, `mod+shift+s` settle, `mod+shift+p` pin, `mod+shift+c` copy thread ref, `mod+s` stash prompt, `mod+u` usage, `mod+alt+a` theme | Global | L `keybindings.json` (88 rules) | PORT | Start from this table. |
| Hover cards | Thread hover card previews | Sidebar | S `ThreadHoverCard.tsx` | PORT | |

## 4. Settings and theming

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Settings pages | General, Appearance, Chat, Threads, Projects, Worktrees, Source control, Diffs, Browser, Providers, Keybindings, Voice, SnapShots, Devices, Scheduled tasks, Secrets, Connections/Access, Usage, Diagnostics, Maintenance/Storage, Labs, Archived, About, Licenses | Settings route | B route chunks `_chat.settings.*`, S routes | ADAPT | Native Settings window; drop remote/devices/providers-list pages. |
| Settings search | Search across settings | Settings | B `settingsSearch` chunk | PORT | |
| Scope chain (environment / project override) | "Applying settings for …" crumb; layers icon shows default → environment → project override; reset to inherit; "Mixed" across environments | Settings header | D `project-settings.md` | ADAPT | Keep app default → project override; drop multi-environment bulk edit. |
| `t3.json` repo config | Repo-declared scripts, icon path, worktree submodule policy; resolution order project override > environment > t3.json > built-in | Repo root | D, S `t3.json` | ADAPT | Support a `bellocode.json` and optionally read `t3.json` for compatibility. |
| Themes | Built-in themes; separate light/dark selection; system/light/dark; palette `mod+alt+a`, cycle appearance `mod+alt+shift+a` | Appearance, palette | D `appearance.md`, B (many Shiki theme chunks) | ADAPT | Native appearance + theme tokens. |
| Theme editor + import | Create theme, pick area to find colour, import T3 or VS Code / Open VSX theme | Appearance, `mod+alt+shift+t` | D, S `ThemeEditorPanel`, `vscodeThemeImport.ts`, `openVsxThemes.ts` | ADAPT | VS Code theme import is valuable; editor is v2. |
| Agent-settable theme | Agent can read/publish/switch themes via MCP | MCP | M `t3_theme_read`, `t3_theme_set` | ADAPT | Keep only if theming is token-based. |
| Fonts and sizes per surface | Interface, prompt, code, terminal font family and size; font smoothing | Appearance | L | PORT | |
| Chat width, timestamp format, word wrap | Readability prefs | Appearance/Chat | L | PORT | |
| Math rendering toggle | LaTeX in messages | Appearance | D | PORT | |
| Confirmations | Archive/delete/unpin confirms, quit mode | General | L | PORT | |
| Labs flags | Boring sidebar, fast worktree checkout, suggest next prompt, linked environments | Settings → Labs | D | ADAPT | Keep a Labs page for staged features. |
| Managed policy | Admin caps on permission modes, telemetry etc. | — | D `managed-policy.md` | DROP | Enterprise. |
| i18n | 9 UI languages | — | S `i18n/translations` | DROP | English first (defer). |

## 5. Project management

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Add existing folder | Register a folder as project | Palette "Add project", sidebar | D, M `t3_project_create` | PORT | |
| New project from scratch | Name → git repo in `~/.t3/projects/<slug>` with README, icon, first commit, opens a thread; optional "Create private repository on GitHub" | Palette "New project" | D `source-control.md`, M | PORT | |
| Clone repository | Pick host or paste URL (also accepts branch/file page URLs); project opens immediately, clone runs in background, first prompt can be written and send waits; toast with progress/cancel/retry; SSH→HTTPS fallback; optional ghq-style `<host>/<owner>/<repo>` layout | Palette "Add project" | D, M `t3_project_clone`, S `ProjectCloneToastCoordinator.tsx` | PORT | Optimistic: no waiting. GitHub first. |
| Publish repository | Create hosted repo, add origin, push | Git actions | D | ADAPT | GitHub only. |
| Delete project | Removes record; folder on disk stays; non-empty needs force | Settings → Projects | M `t3_project_delete` | PORT | |
| Archive / unarchive project | Leaves pickers; threads/settings/files kept | Settings → Projects | D, M `t3_project_update{archived}` | PORT | |
| Pin project | Pinned projects first in all pickers and boring-sidebar folders | Pickers, palette | D, L (`pinned_at`) | PORT | |
| Project icons | Automatic favicon/icon detection, Lucide icon, emoji, monogram (two letters + colour from 18-colour palette), image | Project settings, icon picker | D, M, S `ProjectIconPickerDialog`, `ProjectMonogram` | PORT | Strong visual identity in sidebar. |
| Project actions (scripts) | Named commands with icon (play/test/lint/configure/build/debug); options: run on worktree create (setup), run on settle, stop on settle, async, preview URL + auto-open preview; keybinding `script.{id}.run` | Header scripts control, thread details | D, M `scripts[]`, S `ProjectScriptsControl.tsx` | PORT | Setup scripts for worktrees are essential. |
| Per-project defaults | Default model selection, default thread workspace mode (local/worktree), auto-pull, permission default, text-generation instructions, worktree naming, cleanup policy, merge credit stripping | Settings scoped to project | D, M, L | PORT | |
| Auto-pull default branch | Fast-forward only when clean | Source control | D | PORT | |
| Turn scratch thread into project | Folder becomes project in place; "Initialize Git" later | Thread menu | D | PORT | |
| Project-scoped provider enable | Turn providers on/off per project | Settings → Providers | D | DROP | Single backend. |
| Multiple checkouts / environments per project | Project group across machines, choose checkout in scope line | Settings | D | DROP | Local only. |
| Sidebar project filter / grouping | Filter sidebar by project; optional group-by-project folders | Sidebar | D | PORT | Owner likes projects → threads; see 6. |

## 6. Threads: creation, list and organisation

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| New thread | Opens project picker when >1 project (shift-click = current project); carries model/mode selection unless project default; branch/workspace mode from defaults | Sidebar button, `mod+n` | D `thread-sidebar.md` | PORT | |
| New thread in this worktree | Continue in an existing worktree | Branch toolbar | D | PORT | |
| Thread without a project | Own folder in `~/.t3/scratch/<date>-<words>-<id>`; no git controls; `mod+alt+n` | Hero heading, palette | D, L | PORT | Great for quick tasks. |
| Start in background | `mod+enter` in a draft starts the thread and opens a fresh draft with same workspace mode/base branch; each gets its own worktree | Composer | D, L `composer.sendBackground` | PORT | Fan-out without leaving composer. |
| Send to several models | Shift-click models in a new thread's picker; each model gets its own thread + worktree | Model picker | D, S `useMultipleModelSend.ts` | ADAPT | Several opencode models. |
| Drafts persisted | Unsent drafts (text, attachments, chips) survive reload; appear in sidebar; discard with Undo | Sidebar draft block | S `composerDraftStore.ts`, `SidebarDraftBlock.tsx` | PORT | |
| Sidebar sections | Pinned → Active → Working (beta, default on) → Snoozed shelf → Settled shelf (older settled shelf paged) | Sidebar | D, S `Sidebar.tsx`, `olderSettledShelf` | PORT | This "inbox" model is the core of thread management. |
| Pin / reorder | Drag within/between pinned and active; server-saved order; rows slide aside to show insertion gap; drop badge shows Pin/Unpin/Settle/Un-settle/Wake | Sidebar | D, S `Sidebar.drag.ts`, `Sidebar.motion.ts` | PORT | |
| Settle | Move finished work out of active list; closes idle-prompt terminals; runs "run on settle" scripts; un-settle returns to top | Thread menu, `mod+shift+s`, drag | D, M `t3_thread_organize` | PORT | |
| Drag-to-settle range | Press Settle and drag to settle a range; same for Un-settle/Wake; Esc cancels | Sidebar | D | PORT | |
| Auto-settle | Server settles after 7 days inactivity and on PR merge/close; blocked by live work, pending questions, background work, watched PRs; per-thread "Never" | Settings → Threads, thread menu | D | PORT | |
| Snooze | Presets (configurable list), custom date/duration, multi-select snooze; wakes early on approval, question, failure, or user message | Thread menu | D, M | PORT | |
| Archive / unarchive | Hidden from lists; Archived settings page | Thread menu | D, M | PORT | |
| Delete thread | Deletes thread and side chats; keeps scratch folder/worktree (cleanup policy may delete) | Thread menu | D | PORT | |
| Mark unread / visit watermark | Unread indicator; watermark of last visit in timeline | Thread menu, timeline | M `mark_unread`, S `ThreadVisitWatermark.tsx` | PORT | |
| Status indicators | Working, Waiting, Pending Approval, Awaiting Input, Plan Ready, Completed/Done, Failed, Limited, Goal, Woke, Connecting, Preparing worktree, terminal process running, remote | Sidebar rows | S `Sidebar.logic.ts`, `ThreadStatusIndicators.tsx` | PORT | Drop "remote"/guest states. |
| Working shelf ordering | Working threads collapse into a section; return to top when they need you; list ordered by "came back to you" | Sidebar | D | PORT | |
| Boring sidebar (group by project) | Folder per project, pinned projects first, counts and attention dot on closed folders, pen button to start thread | Labs | D, L | PORT | Matches owner's "sessions per project". Consider making it a first-class mode. |
| Titles | Auto-generated title, placeholder title, rename inline, regenerate (menu/`thread.regenerateTitle`), title instructions per project | Header, menu | D, M `t3_thread_update` | ADAPT | Generate via opencode (empty title asks opencode to generate). |
| Copy references | Copy thread link (pastes as chip), thread ID, branch, path | Menu, `mod+shift+c` | D | PORT | |
| Thread links | `t3-thread://v2/<env>/<thread>` links rendered as live-title chips | Messages | D, S `MarkdownThreadLink.tsx` | ADAPT | `bellocode://thread/<id>`. |
| Drop files on a thread row | Opens thread with files attached in composer | Sidebar | D | PORT | |
| Thread search (agent/API) | Search by title, branch, PR, project, then message text | MCP | M `t3_thread_search` | PORT | |
| Multi-environment rows, environment badges, load balancing | Threads across machines | Sidebar | D, L `loadBalancingEnabled` | DROP | Local only. |
| Thread migration / legacy import | Import Claude/Codex/Pi history, v1→v2 migration | Welcome, toasts | D `thread-migration.md` | DROP | No legacy. (Could import opencode sessions: ADAPT later.) |

## 7. Thread lifecycle: runs, queueing, interrupt, modes, approvals

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Follow-up behaviour Queue vs Steer | Setting decides default while agent runs; `mod+enter` does the opposite; send button icon shows the action (queue icon vs steer arrow); holding Cmd flips it | Composer | D `composer.md`, L | PORT | opencode v2 has an inbox (`session.inbox.enqueued/delivered/cancelled`) and steering (S adapter). |
| Queued messages UI | Dashed unsent messages at end of timeline; Send now, edit (pencil → composer, checkmark saves), remove, reorder; server-saved; `alt+up` edits last queued; `mod+shift+enter` sends first queued as steer | Timeline end | D, M `t3_queue` (list/read/edit/cancel/reorder/promote_to_steer), S `QueuedRunsControl.tsx` | PORT | |
| Steer via restart fallback | If backend can't steer natively, interrupt and restart same run with new attempt | Orchestrator | D `feature-lifecycles.md` | ADAPT | opencode v2 supports steering; keep fallback. |
| Interrupt / Stop | Composer shows Interrupt when draft empty; Stop holds the queue, ends PR watches, stops delegated tasks depth-first; terminal state comes from provider, not the request | Composer, `thread.stop` | D, M `t3_thread_interrupt` | PORT | |
| Resume | Empty composer shows Resume after stop/limit/restart; uses native continuation or resends unsent request; held queue continues | Composer | D | ADAPT | Depends on opencode continuation semantics. |
| Usage-limit handling | "Limited" status; Resume at reset (scheduled), Snooze until reset, settings defaults | Thread banner | D, S `UsageLimitRecoveryBanner.tsx` | ADAPT | opencode reports quota/429 (S adapter comments). |
| Permission (runtime) modes | Supervised, Auto-accept edits, Auto, Full access; default Full access; project override; shown next to model; `mod+shift+a` | Model picker bottom, composer | D `permission-modes.md`, M enums | ADAPT | opencode has no AI reviewer, so "Auto" = Supervised: drop Auto; keep 3 modes mapped to opencode permission rules. |
| Interaction mode Plan vs Default | "Plan" option in the mode/effort menu; plan turns produce a Proposed plan card (collapse, copy, save to workspace path); status "Plan Ready" | Composer picker, timeline | S `ProposedPlanCard.tsx`, `ComposerModelEffort`, M `interactionMode` | ADAPT | Map to opencode's plan agent. |
| Approvals | Inline approval rows in timeline and composer approval actions; subagent approvals bubble up to parent with subagent name; opencode: Allow once / Allow for workspace / Deny (deny doesn't stop the turn); `.env` reads need approval in restricted modes | Timeline, composer | D, S `TimelinePendingApprovalRow.tsx`, `ComposerPendingApprovalActions.tsx`, `ChildThreadApprovals.tsx` | PORT | Directly maps to opencode `permission.asked/replied`. |
| Questions (user input requests) | Agent asks structured questions; multi-question panel above composer with options and custom answers; attachments in answers; can be answered from parent for children; snooze keeps question open | Composer panel | D `question-attachments.md`, S `ComposerPendingUserInputPanel.tsx`, M `t3_pending_request` | PORT | opencode question tool. |
| Goals (`/goal`) | Agent keeps working across turns until done; Goal status and progress line; `/goal clear|pause|resume` | Composer, timeline | D `composer.md` (OpenCode ≥2.2.5) | PORT | Supported by opencode v2. |
| `/clear` fresh session | New provider session in same thread; "New session" divider; earlier messages stay | Composer | D, S `ComposerFreshSession.tsx` | PORT | |
| `/compact` | Compact context when supported | Composer | D | PORT | opencode `session.compaction.*`. |
| Idle compaction | Claude instances compact idle threads | Settings | D | DROP | Claude-specific; opencode auto-compacts itself. |
| Edit from here (rewind) | Rewind conversation to before a message; "Revert and keep changes" or "Revert files too" (worktree threads only, refused if directory shared); prompt returns to composer | Under sent message | D, S `useTimelineRewind.ts` | PORT | Checkpoints + opencode revert. |
| Restart agent session | Reload skills/MCP config; conversation continues | Palette | D | PORT | |
| Context window display | Context usage in thread details | Thread details | D | PORT | |
| Elapsed/"now" indicators | Agent elapsed timer, live status line | Timeline | S `AgentElapsed.tsx`, `ThreadStatusLine.tsx`, `ThreadNow.tsx` | PORT | |
| Provider switching mid-thread with context handoff | Switch Codex↔Claude with budgeted portable handoff | Model picker | D `portable-handoffs.md`, `provider-switching-and-context.md` | DROP | Single backend (model switch within opencode is native). |
| Suggested next prompt | Predicted next message, Tab to accept | Labs | D (Claude/Codex only) | ADAPT | Possible via small opencode call; low priority. |

## 8. Model and option pickers

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Model picker | Provider list sidebar + model search; Left/Right to move between providers, search, effort; `mod+1..9` jump; `mod+shift+up/down` switch provider; favourites, hidden models, custom order | Composer, `mod+shift+m` | D `keybindings.md`, S `ModelPickerContent.tsx`, `ModelPickerSidebar.tsx`, L | ADAPT | Group by opencode's model providers; drop agent-runtime list. |
| Effort / traits picker | Reasoning effort with glyph; speed/service tier; `mod+shift+e`; increase/decrease commands | Composer | S `TraitsPicker.tsx`, `EffortGlyph.tsx`, `TraitsSpeed.tsx` | ADAPT | Map to opencode variants. |
| Project model catalog | Models from project `opencode.json` appear only in that project | Picker | D `providers-opencode.md` | PORT | |
| Refresh catalog | Refresh provider status/models/commands/skills | Settings | D | PORT | |
| Custom models | Add unlisted model with name/options | Settings → Providers → Models | D | ADAPT | opencode config owns this; expose read-only or edit opencode.json. |
| `@model` mentions | `@opus` names a model for the agent (e.g. delegation) without switching | Composer | D | ADAPT | Useful for delegation prompts. |
| Provider instances, add-instance dialog, provider auth terminal, update provider CLIs | Manage many agent runtimes | Settings → Providers | B `AddProviderInstanceDialog`, `ProviderAuthTerminal` | ADAPT | Becomes "opencode accounts/auth" page for the bundled binary (`opencode auth`). |
| Text generators | Separate fast model APIs for titles/commits | Settings → Providers | D `text-generation.md` | ADAPT | Use an opencode small model instead of separate API keys. |

## 9. Transcript (timeline) rendering

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Virtualised timeline | LegendList virtualization; per-visit scroll position restore; follow-tail mode in a store so scroll does not re-render ChatView; new turn anchored near top; debounced "scroll to bottom" pill | Chat | S `useTimelineFollow.ts`, `timelineScrollAnchoring.ts`, `useTimelinePositionRestore.ts` | PORT | Native NSTableView/List with anchoring. |
| Timeline minimap | Minimap of the thread with wheel navigation | Chat edge | S `TimelineMinimap.tsx`, `timelineMinimapItems.ts` | PORT | |
| Markdown | GFM, tables (exportable), GitHub alerts, details, code blocks with Shiki highlighting and copy, Mermaid, KaTeX math, RTL text direction | Messages | S `ChatMarkdown.tsx`, `MarkdownTable.tsx`, `MarkdownMermaidCodeBlock.tsx`, `MarkdownMath.tsx` | PORT | |
| Streaming markdown stability | Server emits only terminated lines and holds headings until content follows; client caches completed blocks and re-parses only the tail | Messages | S `assistantStreaming.ts`, `markdown-incremental.ts`, `markdownStreamBlocks.ts` | PORT | Key to no-jitter streaming. |
| Work groups (activity log) | Consecutive tool calls collapse into a summary ("Ran 2 commands and sent messages to 3 threads"); expand for inputs, status, exit codes; live command output tail; Open diff on file changes | Timeline | D `activity-log.md`, S `TimelineWorkGroupRows.tsx`, `CommandOutputPanel.tsx` | PORT | |
| Tool-call visibility | Show all / Hide successful / Hide all ("Thinking") / Zen (only user msg + final reply) | Settings → Chat | D, L `toolCallVisibility` | PORT | |
| Reasoning | Reasoning items rendered collapsible; never read by screen reader | Timeline | L item types, D | PORT | |
| Todo lists, plans | Todo list items and proposed plan cards | Timeline | L, S | PORT | |
| Subagent cards | Child task cards with status; open child thread; tooltip | Timeline | S `ProviderSubagentBar.tsx`, `SubagentTooltipContent.tsx`, `NativeChildWorkDialog.tsx` | PORT | |
| Checkpoint / lifecycle rows | System dividers (New session, compaction, interrupt results, handoff) | Timeline | S `TimelineSystemDivider.tsx`, `V2LifecycleRow.tsx` | PORT | |
| Item inspector | Inspect raw v2 item | Timeline | S `V2ItemInspector.tsx` | ADAPT | Debug-only. |
| Images and media | Image gallery/zoom, video/audio playback, save/copy path, right-click media actions | Messages | D `composer.md`, S `ChatMarkdownMedia.tsx`, `ZoomableImage.tsx` | PORT | |
| File links | Agent file links open in file viewer (read-only outside workspace), line-anchored links open source view | Messages | D, S `MarkdownFileLink.tsx` | PORT | |
| Commit / PR links | Open in Diff pane / PR view when local | Messages | D `source-control.md` | ADAPT | GitHub. |
| Assistant citations | Select text in an answer → "Cite in composer" with comment; chip navigates back to source with highlight | Assistant selection toolbar | D `composer.md`, `internals/assistant-citations.md` | PORT | |
| Copy message | Copy as Markdown with chip links | Message | D | PORT | |
| Error banners | Thread error banner, provider status banner | Chat | S | PORT | |
| Screen reader announcements | Status only / status + messages / everything; window title prefixed with status | Settings → Chat | D `activity-log.md` | PORT | VoiceOver. |
| Guest sharing | Share thread with a guest link | Thread menu | D `guest-links.md` | DROP | Cloud. |

## 10. Composer

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Rich-text Markdown editor | Live-styled Markdown (Tiptap) showing markers under the caret; lists, task lists, quotes, headings, rules, code blocks with language picker; Tab/Shift-Tab nesting; toggle to plain | Composer | D `composer.md`, S `ComposerPromptEditorTiptap.tsx`, `composer-rich-text*.ts` | ADAPT | Native NSTextView/TextKit 2 with Markdown styling. |
| Send shortcut | Enter sends / mod+Enter for multiline / always mod+Enter | Settings → Chat | D | PORT | |
| 120,000 char limit with validation | Over-limit stays in composer | Composer | D, S `ComposerPromptLengthValidation.tsx` | PORT | |
| Large paste → attachment | ≥32 KiB paste becomes a text-file attachment; `mod+shift+v` keeps it inline | Composer | D | PORT | |
| Attachments | Up to 100 files; images ≤10 MiB (80 MiB total), others ≤50 MiB; upload begins immediately; HEIC→JPEG; drag/paste; retry/remove failed | Composer strip | D, S `ComposerAttachmentStrip.tsx` | PORT | |
| Context chips | Inline chips at caret: file, image, terminal excerpt, diff review comment, preview annotation/picked element, PR (`#123` search), thread (`@title`), skill (`$`), model (`@opus`); copy/paste carries chips; dashed outline when unresolved | Composer | D `composer.md`, `internals/composer-context-references.md` | PORT | `[label](t3-context://v1/<kind>/<id>)` model is portable. |
| Slash commands | Built-ins `/model`, `/side`, `/btw`, `/clear`; provider commands (`/compact`, `/goal`, custom) listed from backend; skills in slash menu optional | Composer menu | S `useComposerMenuItems.ts`, D | ADAPT | List opencode commands. |
| Skills | `$` adds a skill from backend's enabled skills | Composer | D, B `providerSkills` | ADAPT | opencode skills. |
| Thread references | `@` thread or drag thread from sidebar; agent reads history on demand via tool | Composer | D | PORT | |
| Prompt recall | ArrowUp/Down in empty composer walks sent prompts | Composer | D | PORT | |
| Prompt stash | `mod+s` saves draft (with attachments/chips); restore or stash menu | Composer badge/menu | D, S `ComposerStashMenu.tsx` | PORT | |
| Voice dictation | `mod+shift+d`; transcribe on chosen environment (bundled `transcribe-cpp`) or cloud; custom words, filler removal, post-processing | Composer mic | D `voice-input.md`, B deps | ADAPT | Apple Speech on-device; v2 candidate. |
| Composer banners | Stack of banners (clone progress, fresh session, update, usage limits) with priority, collapse, dismiss | Above composer | D `internals/web-ui.md`, S `ComposerBannerStack.tsx` | PORT | |
| Composer controls bar | Model/effort, permissions, host, workspace (local/worktree/previous), branch; compact menu when narrow | Under composer | S `ComposerControlsBar.tsx`, `CompactComposerControlsMenu.tsx` | PORT | Drop host picker. |
| Paste-to-focus | Typing/pasting anywhere focuses composer | Global | S `usePasteToFocusComposer.ts` | PORT | |
| Typing guard | Prevents accidental sends during IME/typing races | Composer | S `composerTypingGuard.ts` | PORT | |
| Undo grouping | Composer undo groups and context undo | Composer | S `composer-undo-grouping.ts` | PORT | NSUndoManager. |

## 11. Git and worktrees

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Workspace mode per thread | Local checkout vs New worktree vs existing/previous worktree; default per project | Branch toolbar under composer | D, S `BranchToolbarEnvModeSelector.tsx` | PORT | Core of parallel agents. |
| Branch picker | Paginated branches, create & switch ref, base branch for new worktree, start from origin | Branch toolbar | S `BranchPicker.tsx`, `WorktreeBaseBranchPicker.tsx` | PORT | |
| Worktree creation | In `~/.t3/worktrees` or custom location; submodules recursive/top-level/skip; setup script runs; "Preparing worktree" status and setup card | New thread send | D `project-settings.md`, S `WorktreeSetupCard.tsx` | PORT | |
| Worktree branch naming | Static prefix (`t3/`), model-selected semantic prefix, or custom instructions; temp name until generated | Settings → Worktrees | D | ADAPT | Generate via opencode. |
| Fast worktree checkout (macOS) | APFS copy-on-write clones from a cache of recent checkouts (~2x faster, fast first `git status`) | Labs | D | PORT | Perfect native-Mac fit. |
| Worktree handoff | Move a running local thread into a new worktree/branch; ends live session; optional continuation prompt | MCP; thread UI | M `t3_worktree_handoff`, `t3_worktree_status`, `t3_worktree_list` | PORT | |
| Worktree cleanup policies | Inactive days, after settle, after merge, unchanged worktrees; protection levels for local changes; delete with thread; "Delete now" with report | Settings → Worktrees → Cleanup | D | PORT | |
| Git actions | Commit, Commit & push, Push, Pull, Push & create PR, Open PR, Sync ref, Publish repository; generated commit messages/PR text using repo conventions or custom instructions | Header git actions control | S `GitActionsControl.tsx`, D | ADAPT | Text via opencode; GitHub only. |
| Checkpoints | Hidden-ref snapshot per turn for diffs and restore | Background | D | PORT | |
| Remove agent credits on merge | Strip agent co-author lines | Settings | D | DROP | Niche. |

## 12. Pull requests

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| PR auto-discovery & linking | Server finds PR for thread branch; multiple PRs per thread incl. other repos; stacks; badges; link/unlink from palette, panel, right-click; agent `gh pr create` auto-links | Thread badge, Linked PRs panel | D `source-control.md`, M `link_pull_request(s)`, `unlink_*`, `list_thread_pull_requests` | ADAPT | GitHub only. |
| PR watch ("babysit") | Agent calls watch; server polls every 2 min and wakes agent on failed checks, required checks passed, new comments/reviews, conflicts, merge queue drop; stops on merge/close/10 comment-only wakes/8 failures/Stop; thread stays in Working while checks run | Thread, eye icon | D, M `watch_pull_request`, `unwatch_pull_request` | ADAPT | High-value orchestration; GitHub via `gh`/token. |
| Pull requests page | List, review details, activity, commits, changed files, request reviewers, checkout, merge (auto-merge), edit title/description, tick checkboxes, line comments as review drafts | Route `/pull-requests`, right panel | D, B `_chat.pull-requests` | ADAPT | Big surface; v2 candidate, GitHub only. |
| Mark files viewed | Synced with GitHub viewed marks | PR Code tab | D, L table | ADAPT | With PR page. |
| Review guides | Model writes a guided tour of a PR (stops, "Look closely"), Ask about this stop, Finish review | PR Guide tab | D, M `write_pull_request_guides`, `read_pull_request_guide` | ADAPT | Defer; uses opencode in temp checkout. |
| GitHub stacks | Merge stack, rebase stack | PR page | D | DROP | Defer. |
| Other forges (GitLab, Forgejo/Gitea, Bitbucket, Azure DevOps, GitCafe, Cursor Origin) | Integrations | Settings → Source control | D, S packages | DROP | Scope. |
| PR sharing across environments | Route PR reads through another machine's credentials | Settings | D | DROP | Remote. |

## 13. Diffs, review, files

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Diff panel | Turn diff (only the turn's own work), branch comparison vs base, per-commit view (newest 100); unified/split; ignore whitespace; collapsed files; hide test files; file tree; worker-pool diffing | Right panel (`mod+d`) | D, S `DiffPanel.tsx`, `DiffWorkerPoolProvider.tsx`, `@pierre/diffs` | PORT | |
| Changed files tree | Per-turn changed files with stats | Timeline/details | S `ChangedFilesTree.tsx`, `DiffStatLabel.tsx` | PORT | |
| Inline review comments | Select lines in a diff → comment becomes composer chip | Diff | S `DiffCommentAnnotation.tsx`, `reviewCommentContext.ts` | PORT | Great feedback loop. |
| Open in editor | Open file/diff in external editor (VS Code, JetBrains, Cursor, Zed...), favourite editor `mod+o` | Header, context menus | S `OpenInPicker.tsx`, `JetBrainsIcons.tsx` | PORT | |
| File explorer | Project tree pane | Right panel "files" | B `FileExplorerPane` | PORT | |
| File viewers | Code (Shiki), Markdown/HTML/CSV/TSV rendered vs raw, PDF, images, audio/video, Office docs (docx/xlsx/pptx via WASM), notebooks, fonts, Mermaid, binary, large text, ZIP as folder | Right panel "file" | B chunks `PdfViewer`, `OfficeViewer`, `NotebookPreview`, `FontViewer`, `Spreadsheet`, D | ADAPT | QuickLook/PDFKit/AVKit cover most natively. |

## 14. Terminal

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Per-thread terminals | Drawer (`mod+j`) and right-panel terminals; new (`mod+n` when focused), split (`mod+d`, `mod+shift+d`), close (`mod+w`); persistent across thread switches | Bottom drawer / tab | L keybindings, S `ThreadTerminalDrawer.tsx`, `PersistentThreadTerminals.tsx` | PORT | SwiftTerm or libghostty (bundle ships `ghostty-vt.wasm`). |
| Server-side scrollback | 5,000 lines / 8 MiB kept by server; restored on reconnect | Terminal | D `terminal.md` | PORT | |
| Terminal context to composer | Select output → terminal excerpt chip | Terminal | D, S `TerminalContextInlineChip.tsx` | PORT | |
| Terminal links | Links/ports open in preview | Terminal | S `terminal-links.ts`, `openTerminalLinkInPreview.ts` | PORT | |
| Servers panel | Lists local servers (ports) the thread's terminals or agent started; open in browser panel; Stop | Thread details | D, S `ThreadServersPanel.tsx` | PORT | |
| Close idle terminals on settle | Keeps output | Settle | D | PORT | |
| fish/no-query-term quirks | Startup tweaks | — | D | PORT | Small. |

## 15. Built-in browser / preview and devices

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Preview browser tabs | Per-thread tabs with URL bar (`mod+l`), back/forward, reload/hard reload, zoom (`mod+=/-/0`), find (`mod+f`), devtools, favicon/history, search engine, incognito, recent URLs, local server cards for discovered ports | Right panel (`mod+shift+j`) | B `preview-*` IPC, S `components/preview/*` | ADAPT | WKWebView. |
| Browser profiles & cookie import | Profiles; import cookies from another browser | Settings → Browser | D `browser-import.md`, B IPC | DROP | Defer. |
| Agent automation tools | Agent opens tabs, navigates (URL or environment port), snapshots accessibility tree with `aria-ref`, acts (click/type/hover/select/drag/upload/press/scroll), evaluates JS, waits for conditions, handles dialogs; ownership (agent vs user-driven tab); visible agent cursor | MCP; preview | M `preview_*`, S `AgentBrowserCursor.tsx`, `PreviewAutomationBroker.ts` | ADAPT | Implement over WKWebView + injected JS; high value for opencode. |
| Responsive presets & appearance | Resize to 17 device presets/freeform/fill; force prefers-color-scheme | Preview toolbar, MCP | M `preview_resize`, `preview_set_appearance`, B 3D device models (`iphone-*.glb`) | PORT | |
| Recording | Record tab to video (frame rate, show key/mouse presses), max 50 MiB | Preview menu, MCP | M `preview_recording_*`, L settings | ADAPT | WKWebView snapshots or ScreenCaptureKit. |
| Pick element / annotate | Pick DOM element or draw/voice annotation → composer chip | Preview | B `preview-pick-element`, `preview-annotation-*`, S `PreviewAnnotationSpeech.tsx` | PORT | Strong feedback loop. |
| Proactive panels | Auto-open preview when agent opens one / dev server starts; floating preview | Settings | L `proactivePanelsEnabled`, `browserAutoShowFloatingPreview` | PORT | |
| Server-side browser runtime | Headless browser tabs for remote environments | Server | D `remote-access.md` | DROP | Local only. |
| Default system browser | T3 as macOS default browser | System | D `default-browser.md` | DROP | Niche. |
| Devices (iOS Simulator / Android Emulator) | Live device stream in panel, float, agents drive via `agent-device` CLI | Right panel "device" | D `devices.md`, M `device_*` | DROP | Defer (v2 candidate for iOS devs). |

## 16. Orchestration (agents working with agents)

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Delegated child tasks | `delegate_task`: app-owned child thread with only the task prompt (no parent history), optional role (implementation/research/review/design/test/general), isolation shared or worktree (from parent commit), async (default) or wait ≤45 s; inherits model/modes, cannot exceed parent's runtime mode | Agent tool; Agents view | M, D `orchestrator-mcp-server.md` | ADAPT | Keep; target is always opencode (choose model/variant). |
| Completion wakes parent | When a child finishes, parent is woken with the result (no polling); `task_status` workState working / waiting_for_children / result_available; reading marks delivered | Server | M `task_status`, D | PORT | The key orchestration quality. |
| Cancel task | `task_cancel` stops child, its delegates, queued turns, PR watches | Agent tool | M | PORT | |
| Follow-ups to child | `t3_thread_send` to child thread starts fresh task in same child conversation | Agent tool | M, D | PORT | |
| Native vs app-owned subagents | Both tracked: provider-native subagents (e.g. opencode task tool, `subagent.updated`) and app-owned delegated threads (local DB: 73 app-owned, 46 native) | Timeline cards, Agents | L, S opencode adapter | ADAPT | Decide whether to use opencode native subagents, app-owned child sessions, or both. |
| Child approvals/questions in parent | Child's pending approval/question surfaces in parent thread; wait ends on pending question | Parent timeline/composer | D, S `ChildThreadApprovals.tsx` | PORT | |
| Stop cascades | Stop on parent stops all delegated tasks depth first; archive parent waits/cancels children | Thread | D | PORT | |
| Agents panel | Follow work delegated to subagents; subagent threads read-only (message the parent instead) | Thread UI "Agents" | D `thread-sidebar.md`, S `ProviderSubagentBar.tsx` | PORT | |
| Create top-level threads | `create_threads` (1-20, same checkout, optional prompts) and `t3_thread_launch` (one, with workspace strategy root/worktree/existing_worktree, base ref, startFromOrigin, scratch, attachments) | Agent tool | M | PORT | Fan-out into the sidebar. |
| Thread-to-thread messaging | `t3_thread_send` modes auto/queue/steer/restart, `freshContext`; target cannot have broader modes than sender; `t3_thread_wait` (optionally until delegated work settles); `t3_thread_read` messages/activity views with paging | Agent tool | M | PORT | |
| Thread management by agents | list/search/read/rename/regenerate title/organize (pin, snooze, settle, archive, unread)/configure model | Agent tool | M `t3_thread_*` | PORT | |
| Fork / merge-back | Fork thread from a stable point (latest stable run, run, checkpoint) with lazy native fork or portable context; merge-back delta into source | Agent tool; thread UI | M `t3_thread_transfer`, D lineage doc | ADAPT | opencode has native session fork; keep lineage UI. |
| Side chats | `/side` or `/btw`: ask about a thread without adding to it; starts with thread's knowledge, same folder/permissions/model; Bring back into thread; deleted with thread | Right panel tab | D `thread-sidebar.md`, S `SideChatPane.tsx` | ADAPT | Implement as opencode fork. |
| Lineage view | Relationships (fork, side chat, delegated child, workflow) | Thread details "Lineage" | S `ThreadRelationshipsControl.tsx`, `ThreadLineageWorkflowRow.tsx` | PORT | |
| Background work waiting | `t3_background_wait` keeps thread in Working while background shell/monitor tasks run (Claude/OpenCode only) | Agent tool, Working shelf | M | PORT | Supported for opencode. |
| Workflows | Claude Code workflow coordinators; `t3_workflow_stop` | Agent tool | M ("Claude workflow") | DROP | Claude-only. |
| Cross-provider delegation | Delegate to a different agent runtime | Agent tool | D | DROP | Single backend. Cross-*model* delegation stays (ADAPT above). |
| Cross-environment delegation | `target.environmentId` to linked machines | Agent tool | D | DROP | Local only. |
| Orchestrator capabilities | `orchestrator_capabilities` lists models, options, runtime modes (short list + search) | Agent tool | M | ADAPT | Lists opencode models/variants. |
| Scheduled tasks | See section 20 | | | | |
| Orchestration summaries | Activity log summarises orchestration actions | Timeline | D `activity-log.md` | PORT | |

## 17. MCP tool surface exposed to the agent (server key `t3-code`)

All rows: evidence **M** (live schema) unless noted; S = `apps/server/src/mcp/toolkits/*`.

| Tool | What it does | Class |
| --- | --- | --- |
| `orchestrator_capabilities` | List providers, models, options, runtime modes for delegation | ADAPT |
| `delegate_task` | Start a child agent with only `task`; isolation shared/worktree; async/wait | ADAPT |
| `task_status` | Read a delegated task's state/result (marks delivered) | PORT |
| `task_cancel` | Stop a delegated task and everything under it | PORT |
| `create_threads` | Create 1-20 top-level threads in this checkout | PORT |
| `t3_thread_launch` | Create one thread with workspace strategy, model, modes, attachments, scratch | PORT |
| `t3_thread_list` | List threads (filters: status, settled, snoozed, subagents, title) | PORT |
| `t3_thread_search` | Search active threads by title/branch/PR/project/text | PORT |
| `t3_thread_read` | Read any thread (messages or activity view, paging, bounded text) | PORT |
| `t3_thread_send` | Message any thread: auto/queue/steer/restart, freshContext | PORT |
| `t3_thread_send_attachments` | Send uploaded attachments to a thread | PORT |
| `t3_thread_wait` | Wait for a run, optionally until delegated work settles | PORT |
| `t3_thread_interrupt` | Interrupt a running top-level turn | PORT |
| `t3_thread_update` | Rename / regenerate title | PORT |
| `t3_thread_organize` | Pin, snooze, settle, archive, mark unread | PORT |
| `t3_thread_configure` | Read/set thread provider, model, options | ADAPT |
| `t3_thread_transfer` | Fork / merge_back / status of context transfers | ADAPT |
| `t3_queue` | List/read/edit/cancel/reorder queued messages, promote to steer | PORT |
| `t3_pending_request` | List/read/respond to pending questions (not approvals) | PORT |
| `t3_background_wait` | Keep thread Working while background tasks run | PORT |
| `t3_workflow_stop` | Stop a Claude workflow | DROP |
| `t3_attachment_prepare_upload` / `t3_attachment_discard` | Upload URL for files, discard pending upload | PORT |
| `t3_project_list` / `_read` / `_create` / `_update` / `_delete` / `_clone` | Project CRUD, clone, scripts, icon, defaults, pin/archive | PORT |
| `t3_worktree_status` / `_list` / `_handoff` | Inspect worktree, list refs, move thread into new worktree | PORT |
| `t3_environment_read` / `t3_environment_preferences_update` | Read identity/prefs; update env prefs (background profile, default env mode, origin start, writing style) | ADAPT |
| `t3_environment_link(s)` / `_unlink` (S only, Labs) | Link other machines | DROP |
| `link_pull_request(s)` / `unlink_pull_request(s)` / `list_thread_pull_requests` | PR linking | ADAPT |
| `watch_pull_request` / `unwatch_pull_request` | PR babysitting wakes | ADAPT |
| `write_pull_request_guides` / `read_pull_request_guide` | PR review guides | ADAPT |
| `schedule_task` / `list_scheduled_tasks` / `delete_scheduled_task` / `run_scheduled_task_now` | Scheduled and webhook automations | ADAPT |
| `preview_open` / `_navigate` / `_snapshot` / `_act` / `_evaluate` / `_wait_for` / `_dialog` / `_status` / `_resize` / `_set_appearance` / `_recording_start` / `_recording_stop`, `t3_preview_list` / `t3_preview_close` | Browser automation in the thread's preview | ADAPT |
| `html_preview` / `html_render` | Screenshot-check then publish an inline themed HTML page (chart/diagram/mockup) | PORT |
| `device_list` / `_open` / `_screenshot` / `_close` | Simulators/emulators | DROP |
| `t3_theme_read` / `t3_theme_set` | Restyle the app | ADAPT |
| `request_secret` | Private secret card; returns one-use `secretRef` or a file path | PORT |
| `send_to_user` | Show Markdown verbatim mid-turn | PORT |
| `tool_search` (S, deferred exposure) | Lets agents discover deferred tools to keep tool lists short | PORT |

Implementation notes from the opencode adapter (S `packages/provider-opencode/src/server/v2/adapter.ts`): T3 registers its MCP server into the shared `opencode serve` at runtime per thread (tool-name hashing because opencode hides tools with names over 64 chars; "deny all threads' T3 servers, then allow only this thread's" permission rules), re-adds MCP servers after an opencode restart, and waits for tools to load before prompting on old opencode versions. Events consumed include `session.execution.*`, `session.step.*`, `session.text.*`, `session.reasoning.*`, `session.tool.*`, `session.inbox.*`, `session.compaction.*`, `session.retry.scheduled`, `session.model.selected`, `permission.asked/replied`, `message.updated`, `subagent.updated`. This is directly reusable knowledge for BelloCode's opencode client.

## 18. HTML renders and MCP apps

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Visual replies (`html_render`) | Agent publishes a self-contained page shown above its reply; uses theme CSS variables (`--background`, `--chart-1..6`, ...), follows light/dark live, sandboxed, links open externally, expand to full screen, zoom; local images inlined at publish; deleted with thread | Timeline | D `html-renders.md`, M | PORT | WKWebView with injected theme vars. |
| `html_preview` check | Headless screenshot + console + contentHeight before publishing; blocks private-network hosts | Agent tool | D, M | ADAPT | WKWebView offscreen snapshot instead of downloaded Chrome. |
| MCP Apps | Interactive apps from MCP tool results (ext-apps standard), Codex/Claude only | Timeline | D | DROP | Not supported for opencode in T3; revisit. |

## 19. Notifications and attention

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Notification mode | off / notifications / sound / notifications-and-sound; input vs completion kinds; sounds pre-decoded on a gesture; same-sound bursts coalesced; snoozed threads suppressed | Settings → General | S `contracts/settings.ts`, `threadNotifications.ts` | PORT | UNUserNotificationCenter + NSSound. |
| Dock badge | Badge count of threads needing attention | Dock | B `desktop:set-notification-badge` | PORT | |
| In-app notifications / background announcer | Announce background thread outcomes | App | L `inAppNotificationsEnabled`, S `BackgroundThreadAnnouncer.tsx` | PORT | |
| Window title status | Optional status prefix (Working / Needs approval / Needs your input) | Window title | D | PORT | |
| Mobile push | Push to phone | Mobile | D `mobile-notifications.md` | DROP | |

## 20. Secrets, scheduled tasks and automations

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Secret request card | Agent asks for one secret in a private card ("Save securely" / Decline), never in chat; one-use `secretRef` consumed by another tool, or file delivery for CLI use | Timeline card | D `secrets.md`, M `request_secret`, S `SecretRequestCard.tsx`, L item type `secret_request` | PORT | Store in Keychain. |
| Secret providers (1Password `op://` refs) | Credential fields accept secret references | Settings → Secrets | D | DROP | Defer. |
| Scheduled tasks | Interval (≥1 min), fixed time + weekdays, once; destination new thread per run or one thread (continue or fresh session per run); pause, run now, edit, delete; agent-created | Settings → Scheduled tasks, thread "Automations" | D `project-settings.md`, M `schedule_task`, L table `scheduled_tasks` | PORT | Needs a process alive at the scheduled time (see background service). |
| Webhook triggers | Public URL via T3 Connect tunnel, placeholders `{{body.x}}`, signatures, filters, dedupe/coalesce, delivery log | Settings | D, M | DROP | Cloud tunnel; defer. |
| Prompt links | URL opens a draft with a prompt (repo, model, PR params) | `app.t3.codes/new?...` | D `prompt-links.md` | ADAPT | `bellocode://new?prompt=` URL scheme. |

## 21. Usage, updates, telemetry, diagnostics

| Feature | Behaviour | Where | Evidence | Class | Reason |
| --- | --- | --- | --- | --- | --- |
| Usage page | Tokens, cache savings, model breakdown, estimated API cost, periods day/week/month/quarter; keyboard `c/t/l` | Sidebar, `mod+u` | D `usage.md`, L | ADAPT | opencode history only (T3 reads opencode SQLite). |
| Usage limits panel | Plan limits with reset times in composer/thread details | Composer, details | S `ComposerUsageLimits.tsx`, `ThreadDetailsUsage.tsx` | ADAPT | opencode quota info. |
| App updates | Channels (stable/nightly), check/download/install, "Update everything" (providers → servers → desktop) with progress, release notes | Sidebar capsule | D `updating.md`, B `desktop:update-*`, S `UpdateEverythingDialog.tsx` | ADAPT | Sparkle; bundled opencode updates with app. |
| Provider CLI updates | Update managed agent CLIs | Sidebar pill | S `SidebarProviderUpdatePill.tsx` | DROP | Bundled binary versioned with app. |
| Telemetry | Product events to ingest.t3.codes/PostHog; relay traces to Axiom; env opt-out | — | D `telemetry.md` | DROP | Not needed. |
| Diagnostics/maintenance | Diagnostics page, storage cleanup, logs retention, slow RPC/host freeze toasts | Settings | B routes, S `SlowRpcRequestToastCoordinator.tsx` | ADAPT | Keep logs + storage cleanup. |
| Triage | Agent investigates T3 issues | Palette | D | DROP | |
| Welcome / onboarding | Detects agents, imports projects from agent histories | First run | D `welcome-page.md` | ADAPT | Check bundled opencode auth; import opencode projects. |
| CLI (`t3`) | Service, update, triage, connect, install to PATH | Terminal | D, B IPC `cli-command-*` | DROP | Defer. |

## 22. Remote access, mobile, other drops

| Feature | Evidence | Class | Reason |
| --- | --- | --- | --- |
| T3 Connect (account, relay, tunnel via cloudflared), pairing codes, device approval | D `remote-access.md`, P | DROP | Cloud/remote. |
| LAN/Tailscale/SSH environments, WSL backends, desktop-as-remote-only | D, B IPC | DROP | Local only. |
| Linked environments, peer links, cross-machine threads | D, S | DROP | |
| Outside agents (OAuth MCP for Claude/ChatGPT/Poke) | D `outside-agents.md` | DROP | Could later expose BelloCode's MCP to local agents. |
| Guest links | D | DROP | |
| Mobile apps (iOS/Android) and offline queue | D | DROP | |
| ChatGPT sharing control, Clerk auth, passkeys | B, S | DROP | |
| SnapShots (capture another window + accessibility tree into draft) | D `snap-shot.md`, B | DROP | Defer; native ScreenCaptureKit makes it easy later. |

---

## 23. Why T3 Code feels smooth (from the code)

1. **Optimistic sends with preview handoff.** User messages render before the server echoes them; an acknowledged message leaves the optimistic list in the same render the ack arrives so it never flickers or duplicates; image blob previews are kept until the server copies have loaded, then revoked (S `chat/optimisticUserMessages.ts`, `useAttachmentPreviewHandoff`).
2. **Durable intent, fast acknowledgement.** A command is acknowledged once intent commits (event + projection + outbox in one transaction); slow work happens in the effect worker. The UI never waits on the provider to show state (D `internals/overview.md`).
3. **Line-buffered streaming.** The server emits assistant text by completed lines, holds headings until content follows, and avoids emitting half list markers (S `orchestration-v2/assistantStreaming.ts`); the client caches completed Markdown blocks and re-parses only the tail (S `markdown-incremental.ts`, `markdownStreamBlocks.ts`). Result: no reflow jitter during streaming.
4. **Server-side event coalescing and backpressure.** Whole-entity updates are coalesced before delivery; subscriptions are ACK-paced with byte budgets (S `ThreadLiveEventCoalescer.ts`, `LiveStreamBudget.ts`). Command output has its own throttled channel, opened only while a command row is expanded (D `performance-regressions.md`).
5. **Bounded windows and lazy detail.** Opening a thread loads a ~1 MiB / 10-turn window; tool bodies are omitted on the wire and fetched when a work group expands; older history pages merge without disturbing the scroll window; resume sends deltas, never re-downloads a snapshot the client already holds (D `performance-regressions.md`).
6. **Virtualised timeline with careful scroll physics.** LegendList virtualization; follow-tail state lives in an external store so scrolling does not re-render the chat view; a new turn anchors near the top; scroll-to-bottom pill is debounced on show and immediate on hide; scroll position is remembered per visit (S `useTimelineFollow.ts`, `timelineScrollAnchoring.ts`).
7. **Instant panels by default.** Panel animations default to 0 ms (opt-in up to 400 ms), and switching threads snaps to the destination's panel state without replaying transitions (D `appearance.md`, S `panelAnimations.ts`). Smoothness here comes from *not* animating layout.
8. **Animate only list changes, FLIP-style.** Sidebar section changes (pin, settle, snooze) animate with FLIP clones; drag shows an insertion gap and rows slide aside; reduced motion respected; no second transition after drop (S `Sidebar.motion.ts`, D `thread-sidebar.md`).
9. **Undo instead of confirm.** Reversible actions apply instantly with a 5 s Undo (and `mod+z`), so the user is never blocked by dialogs (D).
10. **Nothing waits that does not have to.** Clone runs while the first prompt is typed (send waits only at the end); uploads start on attach; worktree creation shows a setup card; background sends open the next draft immediately (D `source-control.md`, `composer.md`).
11. **Off-main-thread heavy work.** Diff computation in a worker pool, separate workers for large text, spreadsheets, Office, images (B chunk names `*.worker`, S `DiffWorkerPoolProvider.tsx`).
12. **Render discipline.** Every web file must compile under React Compiler (lint + test enforced); long-lived components use `useStableCallback` to avoid retaining old renders (D `internals/web-ui.md`).
13. **Resilient connection.** One connection supervisor per environment, jittered backoff, probe-before-reconnect, cached data retained through disconnects, "Still connecting" instead of a broken UI (D `internals/connection-runtime.md`).
14. **Server-owned state machines.** Settlement, PR watch, usage-limit resume and schedules run server-side, so the UI just renders persisted results and never derives state from local clocks (D `internals/overview.md`).
15. **Fast worktrees.** APFS copy-on-write clone cache makes "new worktree" about twice as fast (D `project-settings.md`).

For BelloCode, items 1, 3, 6, 7, 8, 9, 10 and 15 are UI choices that translate directly to SwiftUI/AppKit; items 2, 4, 5, 14 argue for an engine actor with a SQLite projection store and incremental change streams instead of re-fetching.

---

## 24. Consolidated PORT/ADAPT feature list (seed for the BelloCode product list)

### Shell and navigation
- PORT: three-region layout (sidebar, chat with docked composer, tabbed right panel, bottom terminal drawer); per-thread panel state; instant panels with optional animation slider; draft hero composer that docks after first send; thread header with breadcrumb, open-in-editor, git actions; configurable thread details card; undo toasts; quit hold; reopen closed tab; back/forward with swipe; focus-region cycling; empty states.
- ADAPT: right-panel tab kinds (browser, diff, files, file, terminal, PR, side chat, plan); floating mini-player as NSPanel; native materials instead of glass/opacity.

### Command palette, search, keyboard
- PORT: command palette with frecency and `>` actions; message full-text search; file picker; project content search; find in thread and in diff; hover cards; default shortcut table.
- ADAPT: JSON keybindings with when-clauses mapped onto macOS menus.

### Settings and theming
- PORT: settings search; fonts and sizes per surface; chat width, timestamps, word wrap; math toggle; confirmations.
- ADAPT: native Settings window with app → project override chain; repo config file (`bellocode.json`, optional `t3.json` read); themes with separate light/dark, VS Code theme import, token-based agent theming; Labs page.

### Projects
- PORT: add folder; new project from scratch (git init, README, icon, first commit); background clone with optimistic first prompt; delete; archive; pin; project icons (auto, Lucide, emoji, monogram, image); project actions with setup/run-on-settle/stop-on-settle/preview URL; per-project defaults; auto-pull; turn scratch thread into project; sidebar project filter and group-by-project folders.
- ADAPT: publish repository (GitHub only).

### Threads and sidebar
- PORT: new thread with project picker; new thread in existing worktree; scratch threads without project; start-in-background fan-out; persisted drafts; sections Pinned/Active/Working/Snoozed/Settled; drag reorder and drag-to-change-state; range settle; auto-settle rules with per-thread Never; snooze presets/custom/multi; archive, delete, mark unread, visit watermark; full status indicator set; Working shelf ordering; copy references; drop files on rows; thread search.
- ADAPT: send one prompt to several models (opencode models); titles generated via opencode with project instructions; thread links via `bellocode://`.

### Running agents
- PORT: queue vs steer with opposite-action modifier; queued-message timeline UI with edit/reorder/send-now/promote; interrupt with queue hold and cascade; approvals inline and in composer (Allow once / for workspace / Deny) with child approvals bubbling to parent; structured questions with attachments; `/goal`; `/clear` fresh session; `/compact`; edit-from-here rewind with optional file revert; restart agent session; context-window display; elapsed/status line.
- ADAPT: steer-by-restart fallback; Resume and usage-limit recovery (resume at reset, snooze until reset) on opencode semantics; three permission modes mapped to opencode rules (no "Auto"); Plan mode via opencode plan agent with proposed-plan card; suggested next prompt (later).

### Model selection
- PORT: project-local model catalog; refresh catalog.
- ADAPT: model picker grouped by opencode model providers with favourites/hidden/order and keyboard navigation; effort/variant picker; `@model` mentions; opencode auth/accounts page instead of provider instances; text generation through an opencode small model.

### Transcript
- PORT: virtualised timeline with follow/anchor/restore; minimap; Markdown with tables, alerts, Shiki code, Mermaid, KaTeX, RTL; line-buffered streaming plus incremental parse; collapsible work groups with live command output; tool-call visibility modes incl. Zen; reasoning; todo lists and plan cards; subagent cards; lifecycle dividers; media viewer; file links; assistant citations; copy as Markdown; error banners; VoiceOver announcements.
- ADAPT: commit/PR links (GitHub); item inspector as debug tool.

### Composer
- PORT: send-shortcut options; length limit; large paste to attachment; attachments with immediate upload; inline context chips (file, image, terminal, review comment, preview annotation, PR, thread, skill, model); thread references; prompt recall; prompt stash; banner stack; controls bar (model, effort, permissions, workspace, branch); paste-to-focus; typing guard; undo grouping.
- ADAPT: native rich-text Markdown editor; slash menu from opencode commands; `$` skills from opencode; voice dictation with Apple Speech (later).

### Git, worktrees, PRs, diffs, files
- PORT: workspace mode local/worktree/previous; branch picker with base branch and start-from-origin; worktree creation with submodule policy and setup script; APFS fast checkout; worktree handoff; cleanup policies; checkpoints as hidden refs; diff panel (turn, branch, per-commit, split/unified, whitespace, tree, worker diffing); changed-files tree; inline review comments to composer; open in external editor; file explorer.
- ADAPT: generated branch names and commit/PR text via opencode; git actions (GitHub only); PR auto-link, multi-link and stacks display; PR watch/babysit wakes; PR page, viewed marks and review guides (later); file viewers via QuickLook/PDFKit/AVKit.

### Terminal
- PORT: per-thread persistent terminals in drawer and tabs with split; retained scrollback; terminal excerpt chips; links to preview; servers panel with Stop; close idle terminals on settle.

### Browser preview
- PORT: responsive presets and appearance override; pick element and annotations to composer; proactive auto-open.
- ADAPT: WKWebView tabs with URL bar, zoom, find, devtools; agent automation tool set (snapshot/act/evaluate/wait/dialog/status, tab ownership, agent cursor); recording.

### Orchestration and MCP
- PORT: completion wakes parent; task status/cancel; follow-ups to child; child approvals/questions in parent; stop cascade; Agents panel; create_threads and thread_launch fan-out; thread-to-thread send/wait/read/interrupt; agent thread management tools; lineage view; background-wait; orchestration summaries; MCP tools listed as PORT in section 17 (thread, queue, pending request, attachment, project, worktree, html, request_secret, send_to_user, tool_search).
- ADAPT: `delegate_task` and `orchestrator_capabilities` targeting opencode models/variants; native vs app-owned subagent policy; fork/merge-back and side chats on opencode session fork; thread configure; environment prefs; PR, schedule, preview and theme tools; per-thread MCP registration into the bundled `opencode serve`.

### HTML, notifications, secrets, automation
- PORT: inline HTML visual replies with theme variables; notification modes with sounds; dock badge; background announcer; status in window title; secret request card (Keychain); scheduled tasks (interval, fixed time, once; destination modes).
- ADAPT: html_preview via offscreen WKWebView; prompt links via `bellocode://` URL scheme.

### Platform
- ADAPT: in-process engine with event store + projections + outbox + receipts; snapshot/paged loading; separate command-output stream (PORT); single runtime recovery path for opencode; optional background helper so schedules and turns survive window close; usage and limits from opencode data; Sparkle updates with bundled opencode; diagnostics, logs and storage cleanup; onboarding that checks opencode auth.

---

## 25. Open questions

1. **opencode v2 queue/steer semantics.** The T3 adapter consumes `session.inbox.enqueued/delivered/cancelled` and steers running executions; confirm against opencode's own API docs whether BelloCode can rely on native queueing, or must hold the queue itself like T3 does (T3 keeps its own durable queue and holds it on Stop).
2. **Native vs app-owned subagents.** T3 tracks both (locally 46 provider-native vs 73 app-owned). Should BelloCode delegate through opencode's own task/subagent mechanism, through its own child sessions via an MCP `delegate_task`, or both? The "completion wakes parent" quality depends on owning the child lifecycle.
3. **Checkpoints and rewind.** T3 uses hidden git refs and coordinates with provider rollback (opencode revert). Decide whether to use opencode's own snapshots, git hidden refs, or both; scratch folders are not git repos.
4. **MCP injection mechanics.** T3 adds per-thread MCP servers to a single shared `opencode serve` at runtime and hashes long names. Confirm the v2 API for runtime MCP registration and per-session tool permission scoping in the bundled version.
5. **Permission modes.** opencode has no AI approval reviewer, so "Auto" collapses to Supervised. Which three modes, and how they map to opencode permission rules (including `.env` handling and "Allow for workspace" scope across sessions)?
6. **Plan mode.** Exact UI for toggling plan mode and implementing a plan was not observed (only the "Plan" mode option and Proposed-plan card). Confirm the opencode plan-agent flow.
7. **Background survival.** Should agents, scheduled tasks and PR watches keep running when the window is closed or the app quits (login-item helper owning opencode), as T3's background service allows?
8. **Scope of GitHub features.** PR page, review guides and stacks are large. Which are v1?
9. **Remote/mobile.** All remote, T3 Connect, mobile and linked-environment features are classified DROP; confirm the owner does not want phone access.
10. **Visual and interaction fidelity.** This inventory is from code and docs; no screenshots or hands-on timing were captured. A recorded walkthrough of the nightly (sidebar drag, draft-hero transition, streaming, panel switching) would pin down the "feel" targets.
11. **Nightly-only features.** The nightly (`b5554ac`) and public `main` (`1d1489d`) were built the same day; no feature was found exclusively in the nightly, but per-feature diffs were not exhaustive.
12. **Licensing.** T3 Code is MIT; reusing design, copy or algorithms (for example the streaming line buffer) needs attribution in BelloCode.
