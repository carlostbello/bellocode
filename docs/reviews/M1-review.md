# M1 independent review

Reviewed `develop`, 2026-11-16. Verdict: **not ready for a reliable daily-driver experience**: draft restoration, recovery after failed sync or disk writes, and attachment cleanup need work. Findings are static code review, not reproduced failures. TranscriptKit and spike/demo targets were excluded as requested; the shell's currently mounted temporary transcript is in scope. Counts: 0 critical, 10 major, 3 minor.

## Module verdicts

- **OpenCodeKit:** sound foundations in loopback authentication, child identity checks, SSE framing and bounded subscriber mailboxes; supervisor observers accumulate (M9). Same-ID prompt retry still needs a real-server lost-response test before its at-most-once claim can be relied on.
- **Engine:** narrow message models, coalescing and reconnect snapshots are good design; recovery, storage and queue bounds have serious gaps (M1–M5, M8).
- **BelloCore:** stable typed identities and value models are appropriate; no separate high-confidence defect found in this review.
- **BelloCodeApp:** standard menus and cached models are useful, but the mounted transcript and restored composer have visible gaps (M1, M6, M7). Several feature-note limitations are real, not merely documentation issues.
- **DesignSystem:** semantic palette and typography tokens are a good basis; actual contrast and accessibility require screen checks.
- **ComposerKit:** IME-aware editing, bounded thumbnails and server-acknowledged outcomes are promising; attachment files and uncertain sends need attention (M1, M4, M7, m1).
- **AgentUI:** pending cards stay until acknowledgment and have labelled actions; real keyboard routing, VoiceOver and provider flows remain unverified.
- **MockOpenCode:** useful deterministic scripts and fault controls, but an unbounded listener stream and mock-only assertions limit confidence (m2, m3).

## Findings

### Major

**M1 — Restored thread drafts can open blank and be overwritten.** UX 1, 9; engineering 8. `Sources/Engine/Presentation/ThreadModel.swift:103` initializes `draft` empty and loads it asynchronously at :282–292 and :319–322. `Sources/BelloCodeApp/Content/ComposerSurface.swift:71` attaches a host immediately; `Sources/ComposerKit/Host/ComposerController.swift:63` reads the draft once, while `Sources/ComposerKit/Host/ThreadModelComposerHost.swift:208` observes status/errors, not draft readiness. On relaunch or after model eviction, the composer can mount before the cached draft arrives, display empty text, and a new edit can save over the recovered draft. Fix by explicitly waiting for initial draft hydration before attaching, or reconcile it into an untouched editor with a generation/dirty check; test delayed cache load and typing during it.

**M2 — A failed reconnect resync can remain stale indefinitely.** Engineering 5, 12; UX 8. `Sources/Engine/EngineCore.swift:440` retries snapshot fetch only three times; :453–456 marks offline and returns, while `Sources/OpenCodeKit/Events/EventHub.swift:128` emits the next resync only on another connection. If HTTP list endpoints are temporarily unavailable while SSE stays connected, later events continue without a successful rebuild and no retry is scheduled: missed approvals, messages or status can remain missing. Keep a cancellable, bounded-backoff resync retry while connected, visibly stale until success, preserving event ordering and handling overflow; test recovery without disconnecting SSE.

**M3 — Database write failure silently discards locally owned state.** Engineering 5, 19; UX 8, 9. `Sources/Engine/EngineCore.swift:296` removes the pending batch before writing; :307–313 merely logs a failure and does not retry, restore the batch or publish an error. A full disk or transient SQLite error can lose an unsent draft, local preferences or cached state on quit despite apparently successful editing. Retain/coalesce failed writes within a bounded budget, expose a persistent save failure, and retry in order; test a failing writer followed by recovery and quit.

**M4 — Ambiguous sends are restored as if definitely unsent.** UX 5, 8; engineering 12. `Sources/Engine/EngineCore.swift:1057` retries transport failures with the same ID, but after the last lost response :1070–1074 removes the optimistic row and throws; `Sources/ComposerKit/Host/ComposerController.swift:151` restores the draft and announces “Not sent.” If the server accepted the prompt but every response was lost, the user can send it again with a new ID and run the instruction twice. Reconcile the original ID against authoritative state; otherwise show “delivery unknown,” retain the ID and offer an explicit check/retry using that ID. Test accepted request plus lost replies against the actual server.

**M5 — A transient database-open error can delete drafts and preferences.** Engineering 19; UX 9. `Sources/Engine/Store/ProjectionStore.swift:169` catches every error from opening, reading or migrating and :181–185 removes the database and WAL before recreating it. For example, a temporary lock, storage I/O error or failed migration can erase app-owned drafts and model preferences that the server cannot rebuild. Distinguish verified corruption/schema incompatibility from transient failures; preserve or quarantine the original and surface recovery, never delete it on generic errors. Test locked and migration-failure cases with a draft present.

**M6 — The mounted transcript cannot reach older messages or preserve reading position.** Engineering 6; UX 1, 9. `Sources/Engine/Presentation/ThreadModel.swift:248` exposes pagination, but `Sources/BelloCodeApp/Content/TemporarySurfaces.swift:89` renders only `messageIDs` and never calls `loadOlder`; :114–116 initially jumps to bottom and has no saved anchor. A conversation exceeding the initial window has inaccessible history; switching/relaunching loses the reader's place. The shell notes acknowledge a placeholder, but this is current app behavior. Wire the replacement transcript to paging and persist visible ID plus offset; restore around inserts and height changes, bottom-follow only when already at bottom.

**M7 — Attachment storage is neither continuously bounded nor fully cleaned.** Engineering 5; privacy. `Sources/ComposerKit/Host/AttachmentFileStore.swift:42` writes pasted content and its 512 MB/age policy runs only via launch cleanup (`Sources/BelloCodeApp/Launch/AppDelegate.swift:40`). A long-running app can exceed the cap indefinitely. Separately, Quick Look writes pasted data to `Sources/ComposerKit/View/AttachmentStripView.swift:46` under `BelloCodeComposer`, with no deletion path anywhere in the reviewed sources; even unsent private text/images can remain after removal or quit. Enforce the budget on writes without evicting active attachments; own and delete preview files on dismissal/removal/teardown and clean abandoned files at launch. Test long sessions and crash recovery.

**M8 — Write-behind and streamed delta limits are not hard bounds.** Engineering 3, 5, 10. `Sources/Engine/EngineCore.swift:290` clears `writeTask` before awaiting a write; subsequent ticks can build an unbounded chain of tasks and batches (:295–315) when SQLite is slower than events. `Sources/Engine/Sync/StreamCoalescer.swift:59` appends without a cap; crossing the threshold only affects `isDue` (:76–82), while `scheduleDeltaFlush` in `EngineCore.swift:263` does not reschedule an already pending timer. A sustained burst or stalled disk can grow memory despite the documented bounds. Use a single bounded writer with coalescing and a visible recovery path; enforce a byte ceiling on delta admission and flush immediately or resync on overflow. Test a blocked writer and oversized burst.

**M9 — Supervisor state subscriptions accumulate while state is stable.** Engineering 5, 9. `Sources/OpenCodeKit/Server/ServerSupervisor.swift:124` retains each continuation; `awaitReady()` creates one at :133–141 and returns as soon as ready, but there is no termination removal. Entries are only pruned on a later state publish (:332–337). Repeated SSE reconnects while the child remains healthy repeatedly call `awaitReady` and retain terminated continuations until the next supervisor state transition. Install `onTermination` removal or use a bounded waiter mechanism; test repeated ready waits without a state change.

**M10 — Server-controlled error text is publicly logged.** Privacy and engineering 20. `Sources/Engine/EngineConfiguration.swift:104` carries the server's arbitrary `body.message` into `EngineError.description`; `Sources/Engine/EngineCore.swift:453`, :812 and :894 log that description with `.public`. If an error echoes a project path, prompt fragment or secret, it enters the system log. `Sources/OpenCodeKit/HTTP/OpenCodeError.swift:41` also claims messages never include request bodies, but :65 includes unsanitized server text. Log a bounded operation/status/tag only; keep any user-facing detail private and sanitized. Test with a sentinel secret in an error body and capture logs.

### Minor

**m1 — Cache opening and migration run on the main actor.** Engineering 7. `Sources/Engine/Presentation/Engine.swift:100` and :116–119 synchronously construct `ProjectionStore`; `Sources/Engine/Store/ProjectionStore.swift:146–158` opens and migrates SQLite, including filesystem operations. A slow disk or large migration blocks launch/UI despite the feature claim that SQLite is off-main. Build the store asynchronously off-main before creating the facade; measure a slow open/migration.

**m2 — Mock listener has an unbounded connection queue.** Engineering 5, 10. `Sources/MockOpenCode/Transport.swift:27` uses `.unbounded` for accepted connections. A connection burst faster than the mock's consumer can process it grows memory, undermining stress tests. Bound admission and close/reject overflow connections; add a burst test. This is test infrastructure, not the bundled production server.

**m3 — Timing-based and mock-heavy verification leaves important races unproven.** Engineering 8, 12; research 03 section E. Examples include fixed sleeps at `Tests/EngineTests/ChildBubbleTests.swift:29` and `Tests/EngineTests/IntegrationFixesTests.swift:81`; mock event behavior cannot establish actual opencode idempotency or lost-response handling. Slow CI can be flaky and passing tests do not prove the prompt retry claim. Use explicit barriers/virtual clocks for ordering and a sandboxed real-server test that accepts a prompt while its response is dropped.

## Five changes that would most improve feel

1. Hydrate and preserve drafts before the composer accepts edits (M1).
2. Finish the replacement transcript with paging, stable scroll anchoring and reliable bottom-follow (M6).
3. Keep cached UI visibly stale and recover automatically after an unsuccessful reconnect sync (M2).
4. Make uncertain sends explicit and reconcilable so users can trust Stop, Queue and Send (M4).
5. Make local-save failures visible and recoverable rather than losing drafts at shutdown (M3, M5).

## Human checks and verification limits

- Run the complete research 03 section E checklist at the screen, including cached navigation, scrolling while streaming and reading above the tail, resizing and relaunch restoration.
- Exercise real IMEs, undo grouping, first-responder menus and shortcuts in composer, terminal and browser; verify requests never steal typing focus.
- Check VoiceOver order/announcements, Full Keyboard Access, large text, contrast, appearance, Reduce Motion/Transparency and multi-display/window behavior.
- Test paste, Finder drag/drop and Quick Look, including removal, shutdown and crash cleanup; inspect privacy implications with representative sensitive files.
- Exercise real provider OAuth, real approvals/questions, network gaps and a running turn at quit with a sandboxed server.
- Verification here: static source and feature-note review; no build, tests, UI automation or live server were run. The brief forbids writes outside `build`, and running the existing suite may create temporary files, preferences or other data outside it. No claims of screen acceptance, performance measurement or actual reproduction are made. Follow up with isolated, instrumented tests for the scenarios above.

## Disposition

M1-G review fixes, 2026-11-16 (branch `t3/m1-review-fixes`). Every finding was checked against the code and found
real; each fix has a regression test that forces the scenario deterministically (injected write hooks, mock faults,
barriers), and each test was seen failing on the old behaviour where noted.

- **M1 fixed** (`adcd692`). Reproduced: closing before hydration wrote `""` over a stored draft, and an early edit
  was dropped. `ThreadModel.isDraftLoaded`; edits before it merge with the stored draft (stored first) on hydration
  or close; `ComposerController` saves nothing over an unloaded draft and reconciles typing into it; tokens and
  selection survive model eviction. Tests: `ReviewFixesTests` (M1), `DraftHydrationTests`.
- **M4 fixed** (`50313e6`, `19cbd65`, race fix in `e28516c`). Real 2.3.0 (`PromptRetryRealBinaryTests`, opt-in,
  `opencode/big-pickle`, isolated XDG/HOME, one ID sent twice): the repeated ID answers 200 with the same item and
  the server keeps one user message; `GET …/message/{id}` is 404 `MessageNotFoundError` before and 200 after. A lost
  answer is now reconciled by ID (message, inbox, message); found = accepted, absent = one more same-ID send,
  unreachable = "Delivery unknown" (`UnconfirmedSend`, composer stays clear, Retry reuses the ID, Thread menu item).
  Tests: `AmbiguousSendTests` (mock `HTTPFault.dropResponse` serves the prompt and drops the answer).
- **M2 fixed** (`e28516c`). Reproduced by design (three failed attempts left `.offline` with no retry). Cancellable
  bounded-backoff retry while connected; out-of-loop resyncs serialized with event handling. `ResyncRetryTests`.
- **M3 fixed** (`6eb04fb`). Failed writes keep app-owned rows (retried until success) and retry cache rows three
  times before a resync; `EngineRoot.storage` / toolbar "Not saving"; `stop()` retries; preferences retry
  (`saveFailed`). `WriteBehindSafetyTests`, `PreferenceWriteSafetyTests`.
- **M5 fixed** (`4a87e94`). Reproduced: a permission failure deleted the database. Only `SQLITE_CORRUPT`/`NOTADB`
  and newer schemas are quarantined (moved aside with WAL, newest three kept); anything else throws `OpenError`
  with the file untouched and the app offers Try Again. `StoreOpenSafetyTests`. No migration added.
- **M6 deferred**: the transcript is being replaced by another work package (TranscriptKit); not touched here.
- **M7 fixed** (`938a3e4`). Budget enforced on every write without evicting files younger than one hour (a queued
  send is read on delivery); over budget fails visibly. Quick Look copies are per process and deleted on dismissal,
  removal, deinit and quit; dead processes' folders are removed at launch. `AttachmentStorageTests`.
- **M8 fixed** (`6eb04fb`, `cc0b323`). One writer, no task chain, pending writes coalesced to one entry per row
  (a 200-update stall makes at most 3 write attempts, 1 pending row); deltas flush inside `ingest` at the byte
  ceiling. `blockedWriterCoalescesInsteadOfChaining`, `StreamDeltaCeilingTests`. A livelock in the first writer
  version (polling a finished task under actor priorities) was found by the full suite and replaced by continuations.
- **M9 fixed** (`7378657`). `onTermination` removes observers; `awaitReady` does not subscribe when ready.
- **M10 fixed** (`cace8e1`; log lines in `6eb04fb`). `logSummary` (operation, status, validated tag) in every public
  log; misleading comment corrected; user-facing server text sanitized. `LogPrivacyTests` reads this process's
  OSLogStore for a sentinel and fails with the old log line.
- **m1 fixed** (`6eb04fb`). `Engine.make` / `ProjectionStore.open` open and migrate off the main actor; launch order
  unchanged (the window still shows cached content first). `StoreOpenOffMainTests` (a migration that needs the main
  actor to proceed). Not measured on a slow disk.
- **m2 fixed** (`cd0e8e7`). Accept queue bounded (256), overflow cancelled and counted. `ListenerBoundTests`.
- **m3 fixed for the cited sleeps** (`22dc69b`) with `threadBarrier`; other fixed sleeps in older tests remain. The
  real-server lost-response half is covered by the M4 probe plus the mock fault.
