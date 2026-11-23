# Orchestration (M3-A)

Status: done 2026-11-16 against opencode 2.3.0 (real binary) and MockOpenCode. Agents delegate to child agents, fan work
out into threads, message other threads; the person sees a lineage tree with attention bubbling up.

## Architecture: three channels, as used
| Channel | What runs there | With the app closed |
| --- | --- | --- |
| opencode native | Child sessions (`parentID`); the `<subagent>` report + parent wake after **every** child round (durable outbox, `session/execution/subagent-report.ts`); native `subagent` tool; permissions/approvals; instruction entries | Works |
| Server plugin `Plugin/` (TS, in the server) | 14 agent tools; cascade stop; child summaries in `metadata.bellocode`; guidance entry per session; RPC `bellocode.info` | Works (durable state lives in opencode: links, metadata, entries) |
| Client MCP `bellocode_app` (Swift, `OpenCodeKit/ClientMCP`) | UI tools: `open_thread`, `queue` (more since: orchestration-extras.md) | Gone: opencode drops the tools when the socket closes |

Loading: `OPENCODE_CONFIG_CONTENT={"plugins":[{package:<Contents/Resources/opencode-plugin>, options:{limits}}],
"experimental":{"subagent_depth":2}}` (`ServerConfiguration.pluginDirectory`). A local directory with a root `server.ts`
loads by path: no npm, no network, no build step (Bun transpiles TS; `make-app.sh` copies `server.ts` + `src/`). The
plugin imports nothing from opencode (plain JSON Schema inputs). Engine: `OrchestrationService` (`engine.orchestration`)
builds a `TaskGraph` from every session + status on a new `.lineage` change topic (session/status changes only, never
tokens): node state machine, aggregates, per-node `TaskNodeModel` and per-tree `LineageModel` for narrow invalidation.
No migration: the graph is rebuilt from cached sessions at launch (children survive restarts; tested on a file store).
UI: new `OrchestrationUI` module (kept apart from AgentUI, which is approvals and pickers; testable without the app):
Agents panel; the app mounts it as the "Agents" right-panel tab and adds the header strip and sidebar nesting.

## Tools (plugin unless noted) and native equivalents
- `delegate_task` child agent on a self-contained task: agent, model/variant, `workspace: shared|worktree`, `wait` ≤ 45 s.
  Native `subagent` is kept: it lacks worktree, wait and limits. Both render as sub-agent cards (`Mapping.toolContent`).
  `worktree` (deep review 1, C1): the child is prompted only after `worktree.create` returned an absolute directory and
  the child's session reads back as located there (moved if needed; real 2.3.0 reports the moved directory verbatim,
  `WorktreeMoveRealBinaryTests`). Otherwise the call fails and names the thread(s) and worktree(s) it created, so they
  can be reused or removed; nothing runs in the original checkout. `create_threads` with `worktree` does the same per
  thread and never falls back to the shared checkout.
- `task_status` working / waiting_for_children / result_available / failed / cancelled + latest result.
- `task_cancel` stops a child and everything below. Follow-ups: `thread_send` to the child (native: `subagent` + sessionID).
  Stops (here and `thread_interrupt`, deep review 1, C10) report what was observed: interrupts requested, acknowledged
  and failed, sessions read back as settled within 5 s, still stopping, and threads left unexamined. Children are listed
  page by page (200 per page, ≤ 25 pages per parent, ≤ 2,000 per tree); a walk cut by a limit or a failed list is
  reported incomplete, and `thread_wait` never reports such a tree as settled.
- `create_threads` 1–8 top-level threads (optional worktree each, optional first prompt), one fan-out group. Each
  `agent` is checked before anything is created: unknown agents and sub-agents are refused (v1.0.1 GF14).
- `thread_list`, `thread_search` (titles), `project_list`, `thread_read` (bounded: 20 messages, 12,000 chars).
- `thread_send` (queue|steer, prefixed "[Message from …]"), `thread_wait` (≤ 45 s), `thread_interrupt` (cascades).
  To a thread another agent interrupted (held), `thread_send` queues without waking it (`resume: false`; GF02), and a
  send during an interrupt still in flight waits for it and is held too (GV08).
- `pending_requests` list approvals in self + descendants; deny a child's request. Agents can never approve.
- `send_to_user` Markdown the person must read now: a titled quoted card in the transcript (input persists).
- `orchestrator_capabilities` sub-agents, chat models with variants, limits.
- App (client MCP): `bellocode_app_open_thread`, `bellocode_app_queue` (list / cancel / steer).
  The engine hosts the app (and shared Chrome) client-MCP servers for every project on connect and on every
  project-list change while live, and replaces the hosts when the server connection changes (a supervised restart has
  a new port and password); v1.0.1 NF01, `ClientMCPEngineTests`, `OrchestrationRealBinaryTests`.

## Lifecycle, verified on 2.3.0 (10 prompts on `opencode/big-pickle`)
- Wake once: a child created via `parentID` (plugin or API) posts exactly one `<subagent … state="completed">` report and
  the parent replies once ("GOT HELLO-CHILD"). `delegate_task` → child → summary `HELLO-CHILD` in metadata.
- Stopping a child wakes its parent with a "cancelled" report (seen). So cascade = plugin on `execution.interrupted
  {reason:user}`: stop running descendants deepest first, then cut any restart of those sessions for 15 s
  (`execution.started` → interrupt). Real test: one interrupt of the parent → child stopped, parent restart cut in 9 ms,
  parent outcome `interrupted`. The Engine's `stopTree` does the same order (idempotent).
- Parent finished while children run → `waitingOnChildren` (header "Waiting on 2 children", hourglass), not done.
- Child approvals bubble through the existing attention model (`blockingChildID`) to the parent's pending list, the
  "Needs You" list and the aggregate ("1 needs you"); not duplicated. Real test: shell approval in a child → parent list.
- Limits: depth 2 below a top-level thread (aligned with `subagent_depth`), 6 running children, 8 threads per call,
  waits ≤ 45 s; refusals say which limit and what to do instead. No orphans: deleting a parent deletes children (opencode).
- 2.3.0 facts found here: plugin results must not carry `output` without an output schema; a location's RPC answers
  `rpc.unavailable` until it activates (client retries); `session.created` carries `metadata` (now mapped).

## Scoping and safety
**Permission rules of created threads (S2).** Verified on 2.3.0 (`PolicyRealBinaryTests`, no prompts): a session
created with `permissions` reports them at once; a child created with `parentID` inherits its parent's session rules;
switching the agent alone leaves session rules untouched; an unknown agent is rejected with nothing changed.
`delegate_task` checks that the child carries the caller's rules and `create_threads` passes the caller's rules to
each new top-level thread and checks them; neither sends a first prompt otherwise. In the app, the draft's mode and a
schedule's mode are part of the create request; agent and mode changes are serialised per thread (new rules computed
first, agent switched back if the rules are refused, result read back), and a thread whose rules the server did not
confirm refuses to send until the mode is chosen again.
Attribution: plugin tools get `sessionID` from the tool context; client-MCP calls from `_meta["ai.opencode/sessionID"]`
(unattributed calls are refused). Own descendants: free. Same project: free, including `thread_interrupt` since
Auto mode (docs/features/auto-mode.md): attributed, with a reason, rate-limited, shown in both threads, target held
until Resume. Another project: every read/send/wait/interrupt asks (`bellocode_other_project`,
"always" saves per project). `delegate_task` asserts the native `subagent` permission. App tools: same project only.

## Guidance
Instruction entry `bellocode.orchestration` (~900 chars) written by the plugin at `session.created` and at the first run
of older sessions: which tools exist, "don't poll", depth-aware ("you cannot delegate further"), child-task wording.

## Contract change detection
`OrchestrationContract` (OpenCodeKit) mirrors tool names and `CONTRACT_VERSION`; `bellocode.info` returns both; the
Agents panel footer, `make smoke` and the real tests fail on a mismatch or missing tool. Experimental surfaces relied on:
`/api/experimental/client-mcp`, plugin RPC `/api/rpc/{id}/{method}`, `experimental.session.instructions`, the
`execution.*` events, `ctx.session.*` promise API. Bumping opencode reruns `BELLOCODE_ORCH_REAL=1 swift test --filter
OrchestrationRealBinary` and `make smoke`.

## UI
Agents tab: tree (depth indent + guide line), glyph + state words, kind badge, last update (plugin summary), elapsed
(live for running) or age, model, agent; Open / Follow Up (inline field) / Stop; "Created N threads" section; Back to
Parent; plugin status footer. Header strip "Agents · 2 running · 1 needs you · 1 failed" or "Child of “…”". Sidebar:
children and fan-out threads nest (collapsible) under their parent; order never changes; nested rows don't drag.
Transcript: cards show the child's live state; child reports are one-line notes; `send_to_user` is a card.
Thread ▸ Agents: Show Agents ⌃⌘A, Select Next/Previous Agent ⌃⌥⌘↓/↑, Open Selected Agent ⌃⌘O, Follow Up Selected
Agent…, Stop Selected Agent and Its Tasks ⌃⌘., Go to Parent Thread ⌃⌘U (uniqueness tests pass).

Appearance (restyle 3): summary pills, outline status glyphs or the drawn spinner, `bodyEmph` titles, @agent pills,
`meta text3` state lines (blocked/failed words in their tone), report boxes on `fillSubtle`, 1 pt guides, `rowActive`
selection, ghost row actions on hover or selection (always in the accessibility tree), per docs/design/mock/agents-dark.png.


## Verification
`swift test` (OpenCodeKit `ClientMCPTests` 7; Engine `TaskGraphTests` 5 + `OrchestrationServiceTests` 6; TranscriptKit
`OrchestrationCardTests` 3; OrchestrationUI 1; app shortcut tests), `cd Plugin && bun test` (13), real suite 5/5,
`make app`, `make smoke` ("bellocode plugin loaded from opencode-plugin: contract 1, 14 tools"; the contract is 2
since, `Plugin/src/logic.ts`, still 14 tools). Snapshots
`.build/debug/BelloCode --snapshot orch` (16); `docs/snapshots/orch-{agents-tree-light,agents-tree-dark,
transcript-cards-light,waiting-reports-dark,child-view-light,fanout-sidebar-dark}.png`.

## Section E checklist (agent, no human at the screen)
Purpose/context: every row names title, kind, state, model; header names project/directory/branch. States: empty (no
thread / no children), running, waiting, blocked, failed, stopped, done, plugin unavailable/incompatible, offline (cached
tree). Speed: local (graph updates per change). Keyboard: every action is a menu item; row buttons are SwiftUI (Tab order
not driven). Accessibility: rows are labelled elements, status never colour-only; VoiceOver unverified. Parallelism: tree
+ aggregate + nested sidebar. Approvals: existing cards, child labelled. Persistence: tree from cache; collapse state of
nested sidebar rows is not saved. Not run: VoiceOver, real pointer, two windows.

## Known gaps
App tools are not shown in the transcript any differently; `open_thread` changes the key window's selection; mock lacks
the client-MCP route (the host retries with backoff in mock mode); `thread_read` uses the model context (compacted
history); no per-thread "allow other project" setting beyond opencode's saved rules. Two existing tests
(`queueSteerAndStopWhileRunning`, `sendStreamApproveQueueStopAndSwitch`) failed once under full-suite load, passed alone.

## Extension points (the next packages, since built: orchestration-extras.md, secrets.md, gitlab.md)
Scheduled tasks, merge-request link/watch, secrets, HTML previews plug in as: a plugin tool (durable work, e.g. schedules, MR watch
waking via `ctx.session.synthetic`) and/or an entry in `AppTools.definitions` + a case in `handleAppTool` (UI work:
secret card backed by Keychain returning a reference, `html_preview` via WKWebView). Transport, attribution and scoping
are already in place.
