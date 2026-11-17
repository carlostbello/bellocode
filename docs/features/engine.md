# Engine and projection store (M1-A)

Status: done 2026-11-16 against opencode 2.3.0 and MockOpenCode. Gate G2 passed (run 2; see below).

## API map for UI authors (`import Engine`, `import BelloCore`)

- `Engine(configuration:)`, `@MainActor`. `start()` reads the cache into `root` first (no server needed), then connects;
  `stop()` before quitting. Source: `.supervised(ServerSupervisor)`, `.fixed(ServerConnection)` (mock, or
  `ServerSource.fromEnvironment()` for `BELLOCODE_SERVER_URL`/`_PASSWORD`), `.dynamic { … }` (tests).
- `engine.root: EngineRoot`: `connection` (cached/connecting/syncing/live/offline; content stays visible in all),
  `projects: [ProjectItem]` (pinned first), `attention: AttentionSummary` ("Needs you" items + `counts.dockBadge`),
  `catalog: CatalogModel`, `project(id) -> ProjectModel?`.
- `ProjectModel`: `sessionIDs` / `archivedSessionIDs` (top level, newest created first: rows never reshuffle while
  agents work), `row(id) -> SessionRowModel` (`session`, `status` with text `label` and `symbolName`), `children(of:)`.
- `engine.openThread(id) -> ThreadModel` (same instance while open; call `close()`): `phase`, `session`, `status`,
  `messageIDs` (server IDs, oldest first), `message(id) -> MessageModel` (`message`, `revision`: cache rendering by
  `(id, revision)`), `hasOlder` + `loadOlder()`, `pendingRequests` (pin above the composer), `submittingRequestIDs`,
  `queue`, `draft` (persisted), `isRunning`/`isStopping`/`sendMode`, `lastError: EngineError` (`userMessage`).
  Commands: `send(_:delivery:)`, `stop()`, `steer(_:)`, `cancelQueued(_:)`, `reply(to:_:)` (once/always/reject),
  `answer(_:_:)`, `dismiss(_:)`, `setModel/setAgent/setPermissionMode`, `markViewed()`, `updateUIState(_:)`.
- `Engine` commands (throw `EngineError`): `createThread`, `renameThread`, `deleteThread`, `setArchived`, `send(_:to:)`,
  `stop(_:)`, `reply`, `answer`, `markViewed`, `setModel/Agent/PermissionMode`, `addProject`, `removeProject` (hides;
  reversible), `setProjectPinned`, `moveProject`, `search` (FTS), `refreshCatalog`, `flush`.
- Invalidation: each model subscribes to one `ChangeTopic` (`.projects`, `.sessions(p)`, `.thread(s)`, `.attention`,
  `.catalog`, `.connection`). A token re-renders only the tail `MessageModel`; `messageIDs` changes only when a message
  is added, removed or reordered. Follow-tail and scroll position belong to the view.
- Optimistic: a send appears at once with `delivery == .sending` (idle) or as a `.sending` queue item (busy; queue is
  the default, steer on request); `.accepted`/`.queued` only after the server answers; on a definite failure it is
  removed, the text returns to the draft and `lastError` is set. A lost answer is retried under the same prompt ID
  (opencode 2.3.0 answers a repeated ID with the original item and keeps one message: `PromptRetryRealBinaryTests`,
  run 2026-11-16). If any answer was lost, the outcome is decided by asking the server: `GET …/message/{id}`, then the
  inbox, then the message again; found = accepted; absent = one more same-ID send (or not sent after a definite
  refusal); unreachable = `EngineError.deliveryUnknown`: the entry stays `.sending`, the text is not put back in the
  draft, and `ThreadModel.unconfirmedSends` holds it (32 max) for `retryUnconfirmed(_:)` (check, then same-ID resend)
  or, once a retry is refused, `takeUnconfirmed(_:)`. Every successful resync checks unknown sends (never resends).
  In memory only: a relaunch drops them (the resync shows the prompt if it was admitted). Rename/archive/model/agent/mode roll back on failure. Delete hides
  the row and restores it if the server refuses. A reply removes the request only after the server's 204.

## Schema (`Store/Schema.swift`, migration `v1-initial`)

Cache (rebuildable): `project`, `session` (by project, parent), `message` (`seq` rowid, by session/created/id),
`part` (by message/idx), `message_fts` (FTS5, rowid = `message.seq`), `pending_request`, `queued_prompt`, `catalog`
(no secret-bearing fields), `session_sync` (older-page cursor, history complete). App-owned (kept by `rebuild()`):
`app_project` (directory, order, pinned, archived), `app_thread` (draft, visit watermark, pinned, snoozed, settled,
scroll anchor), `app_preference`. Rows hold the domain value as JSON plus query columns. Nothing is ever deleted at
open: a verifiably corrupt (`SQLITE_CORRUPT`/`NOTADB`) or newer-schema file is moved aside with its WAL
(`projection.sqlite.corrupt-<ms>` / `.newer-<ms>`, newest three kept), a new one is created and
`EngineRoot.storage == .recovered(...)`; any other failure (lock, I/O, permission, failed migration) throws
`ProjectionStore.OpenError` with the file untouched (the app offers Try Again). `Engine.make(configuration:)` opens and
migrates off the main actor. Writes are batched transactions; the engine writes behind (100 ms) with one writer: while
a write is slow, newer writes coalesce into one pending batch (one entry per row). A failed write keeps app-owned rows
(retried with `writeRetryBackoff` until they succeed; `storage == .writeFailing`, "Not saving" in the toolbar) and
retries opencode cache rows three times before dropping them for a resync. Streamed text is persisted when a block
ends, on eviction from the 2,048-message memory cache, and at `stop()` (which retries a failing write three times).

## Sync and coalescing rules

- One ordered path: EventHub → `EventPipeline` (drop duplicate event IDs, 8,192 remembered) → `StreamCoalescer` for
  text/reasoning/tool-input deltas → pure `EventReducer` → `ChangeBus` (live) and write-behind.
- Coalescer: per (message, block); a flush is due 33 ms after the first unpublished delta; a message is flushed at once
  before any other event for it (block/step end, tool call, turn end, interrupt); reaching 1 MB pending flushes
  everything inside `ingest`, before the next delta (a hard ceiling, not just "due").
  Nothing is dropped; revision increases once per publish.
- Reducers are monotonic (create-only-if-empty, forward-only tool states, busy/idle only move forward), so duplicates,
  late events and replay over a newer snapshot change nothing (tested on the recorded stream).
- `.resync` (every connect and overflow): `/api/info` (pid), projects, all session pages, pending permissions and
  questions per directory, the inbox of running sessions, and the newest 50 messages of open threads (4 requests in
  parallel). Server copies merge onto local ones; local streamed text ahead of a snapshot is kept unless the pid
  changed (server restart: the server wins). A window that does not connect to the cache truncates older cache and
  resets the thread. Sessions busy across a restart show `unknown` (opencode keeps them busy). A resync that fails all
  three attempts while the stream stays connected shows `.offline("Could not sync with opencode; retrying")` and retries
  with `resyncRetryBackoff` (1 s doubling to 30 s) until one succeeds; a reconnect, disconnect or `stop()` cancels the
  retry. Out-of-loop resyncs (retry, effect-queue overflow) take turns with event handling, so events are applied in
  order around them.
- Attention: approval > answer > stopping > running (unknown offline/orphaned) > failed-unseen > finished-unseen >
  idle; seen = max(opencode `viewed`, local visit watermark). Child blockers bubble to every ancestor
  (`blockingChildID`). List = top-level, unarchived; snoozed/settled hide only non-blockers; urgency, then oldest.

## Measured (debug build, this Mac, `swift test`)

- Cold start (second launch, no server): launch snapshot 0.7 ms; open cached thread 5-6 ms to `phase == .ready`.
- 10,000-message fixture (mock): open with empty cache 21-28 ms (server window); server page 6-30 ms; writing all
  10,000 messages 1.0-1.3 s; store read of the newest 50: 1.1-1.4 ms; open cached thread 6-8 ms; cached page of 50:
  1.5 ms; resident 133 -> 140 MB with 1,050 messages loaded; engine memory cache holds 50.
- Sustained events: 70,000-80,000 events/s through the engine alone (decode, dedupe, coalesce, reduce, publish);
  18,000 events/s end to end from the mock over HTTP/SSE.

## G2 (BELLOCODE_G2=1 swift test --filter G2)

Real 2.3.0, isolated XDG/HOME in a temp dir, `opencode/big-pickle` (free), one prompt per run. Run 1 failed: after
SIGKILL the restarted server lists the killed turn with empty text (deltas never persisted) while the merge kept the
streamed text; fixed by the restart rule above. Run 2 passed: killed 8.2 s into streaming, live again 0.50 s later
(2 resyncs), cache and shown thread equal the list endpoints, one user message, no duplicates, no process left. Seen
then: the session stays `busy` with no `idle` 3 s after restart (hence `unknown`). The orphan rule landed after run 2.

## Changes outside Engine/BelloCore

OpenCodeKit: inbox list/cancel/update, message get, view, switch agent/model, prompt text on `inbox.enqueued`.
MockOpenCode: matching routes and events; fix: following a cursor kept the default order instead of the first page's.

## Unverified

Sleep/wake reconnect; `session.message.content.updated`, `session.permissions`, `inbox.delivery.changed` and
`agent-switched` messages on the real server; whether action `*` rules work for full access; orphaned turns being
failed later by opencode; interrupt and steer timing on a real model; performance in a release build or with the UI
attached; FTS on non-Latin text; the UX acceptance checklist (no UI in this package).
