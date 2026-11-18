# BelloCode deep review

Reviewed develop at `6db276a` on 18 November 2026. References are relative to that revision.
Scope includes the shipping Swift targets, their test seams, the bundled TypeScript plugin, build inputs and packaging. S/M/L denote a local fix, a cross-component change and a staged refactor respectively.

## Executive summary

Keep the native rendering and single-server architecture. Hold enterprise rollout until the production entry points enforce the execution context the user selected.
Three paths let work start after an essential precondition failed. They cross the shell, Engine and bundled plugin, so testing each module in isolation misses them.

## 1. Architecture and dependencies inside the app

**A1 · suggestion · Divide EngineCore by invariant (L).**
`Sources/Engine/EngineCore.swift:69` owns the server epoch, event exclusion, command admission, persistence retry, attention, organisation and presentation reads.
A session can be created during a snapshot, acquire a queue edit, generate a write and change a window. The rules that decide what survives are spread between commands, reconcile and StoreBatch.
Keep one actor as the ordered writer. First extract snapshot completeness/merge and command state machines into value types. Give the durable writer a narrow, acknowledged interface.
Keep the main-actor facade as the sole composition root for UI services. Moving every method to an independent actor would create more ordering obligations.

**A2 · minor · The release app links its scenario driver (M).**
`Package.swift:119`, `Sources/BelloCodeApp/Launch/AppRuntime.swift:52` and `Launch/LaunchOptions.swift:7` put mock transport, fake forge, scenario scripts, snapshots and end-to-end drivers on the app's dependency path.
The separate demo executables are useful and do stay separate. The app itself still imports MockOpenCode and implements mock-only operations down to issuing browser commands at AppRuntime.swift:182.
Extract the real window composition to an importable shell target, make a fixture executable depend on that and MockOpenCode, and ship a minimal production main. Retain socket/runtime injection for tests.

**A3 · suggestion · Narrow the useful shared interfaces (M).**
`Package.swift:74` makes DiffKit depend on TranscriptKit for highlighting. `Sources/Engine/Store/ChangeBus.swift`, `Sources/OpenCodeKit/Events/EventHub.swift:11` and `Sources/Engine/Terminal/TerminalStream.swift:86` have different delivery contracts.
A dropped paint snapshot can be recomputed. An SSE gap requires a list read. A terminal byte stream needs ordered delivery and its own offset. A single generic event bus would conceal these differences.
Extract highlighting and immutable syntax spans as a leaf. Keep Docker's Unix HTTP/hijack transport, opencode's authenticated URLSession transport and GitLab's redirect-aware transport distinct. Share cancellation, size-budget and failure-contract tests where semantics coincide.
Use domain commands returning acknowledged results below presentation. Services currently mix throwing calls, mutable lastError and void setters, which leaks across boundaries in S2.

## 2. Core correctness and durable state

**C1 · major · Delegation can run in the wrong checkout (S).**
`Plugin/server.ts:277` creates a worktree, records the intended workspace in metadata, then ignores a failed session move at line 299 and prompts at line 302.
The progress and result can describe isolation while the child is still in the original checkout. The top-level batch at line 397 also falls back when a directory is missing.
Require a valid returned directory, verify the child's effective location before prompting, and report the IDs of any created resources for recovery.

**C2 · major · Incomplete resync can advertise live state (M).**
`Sources/Engine/EngineCore.swift:718` reads permissions and forms as one result per directory. A failed list becomes incomplete, and inbox failures at line 744 disappear behind optional values.
After reconcile, line 676 sets the whole connection live. An approval that first arrived during a gap can consequently be missing from Needs you with no retry scheduled by that failure.
Track completeness per list and directory, retain last-known rows, publish partial/stale status and retry failed partitions without waiting for another disconnect.

**C3 · major · App requests cross the cache deletion boundary (M).**
`Sources/Engine/EngineCore.swift:1946` stores secret and app approvals through the ordinary pending projection. `Sources/Engine/Store/ProjectionStore.swift:103` preserves only registry and thread UI rows on repeated write failure.
`Sources/Engine/Store/Schema.swift:191` includes the entire pending table in a cache rebuild. opencode cannot reconstruct a request created solely in the app.
Give app requests their own durable table or an ownership discriminator honored by rebuild, write retry and deletion. Test write failure, relaunch and rebuild with a pending app card.

**C4 · major · Closing one window can freeze another window's thread (S).**
`Sources/Engine/Presentation/Engine.swift:291` returns the same model without acquiring another reference. Each workspace owns a separate eight-entry LRU and calls close on eviction or teardown at `Sources/BelloCodeApp/Shell/WorkspaceController.swift:115,416`.
`Sources/Engine/Presentation/ThreadModel.swift:374` cancels the sole subscription. Open A in two windows, close one, and the surviving workspace still returns its cancelled model from its own cache.
Give each window a lease and tear down on last release. Keep view-local scroll/focus separate from shared messages. Test close and ninth-thread eviction while a second window displays A.

**C5 · major · An authoritative short history can leave deleted messages searchable (M).**
`Sources/Engine/EngineCore.swift:913,941,961` reads disk IDs only between the first and last returned messages. For a short or empty page it also scans the bounded in-memory message cache.
If a server-side rewind removes the tail while disconnected, newer on-disk rows outside that interval can outlive reconcile. With an empty page and a cold message cache there are no candidates at all. The session is nevertheless marked historyComplete.
Reconcile a proven whole history by session and retained IDs in one SQLite transaction, including parts and FTS. Protect optimistic admissions newer than the read. Test an empty list and a shortened tail after process relaunch.

**C6 · major · Delivery-unknown recovery ends at process exit (M).**
`Sources/Engine/EngineCore.swift:119,1299,1316` holds the ID and retryable PromptRequest in memory. `Sources/Engine/Presentation/ThreadModel.swift:221` treats unknown delivery differently from a definite rejection.
The previous same-ID retry fix holds during the process lifetime. Quit after a lost response and the next launch has neither the retry payload nor the delivery-unknown card. A user reconstructing the instruction can give it a different ID.
Persist a bounded outbox before first dispatch, including attachment references and admission state. Restore by checking the original ID, retain attachment files until settlement and provide an explicit discard for an unsent entry.

**C7 · major · Launch catch-up consumes due work before the server starts (S).**
`Sources/Engine/Presentation/Engine.swift:237` awaits extras before core.start. `Sources/Engine/Extras/ExtrasHub.swift:113` awaits scheduler.start, which awaits tick at `Extras/SchedulerService.swift:71`.
A due new-thread task calls the runner during that tick. The supervised client's endpoint is still nil (`EngineCore.swift:190,265`). Failure is recorded and finish advances nextRun or disables a one-off (`SchedulerService.swift:288,301`).
Load task definitions for display immediately. Arm dispatch after the first successful reconcile, distinguish deferrable offline from permanent rejection and retain the original due occurrence. Exercise launch with a gated supervisor and an overdue one-off.

**C8 · major · Unwatch does not fence a fetch already in progress (S).**
`Sources/Engine/Extras/MergeRequestService.swift:290,420,432,462,482` removes the watch on unwatch, but poll resumes using `watches[key] ?? start`. The pause decision also predates the fetch.
Unwatch or settle while a GitLab request is outstanding. Completion can restore the old record, schedule another poll or post a synthetic wake after the user withdrew consent.
Use a watch generation checked after fetch and before waking/persisting. Re-evaluate pause then. Test a delayed 200, delayed failure, and remove/re-add of the same URL.

**C9 · minor · Read-modify-write loses metadata updates (M).**
`Sources/Engine/EngineCore.swift:1977` awaits GET, applies a transform, then awaits PATCH with the reconstructed metadata. `Extras/ExtrasHub.swift:681` uses it for MR links and `Plugin/server.ts:668` separately updates session metadata on settlement.
Two link actions may read the same list before either PATCH. Even when the backend combines unrelated top-level fields, the last write to the same link array wins.
Serialize mutations per session and field, use a version precondition or server merge primitive across writers where available, then reconcile from the response. Test concurrent link/link and link/settle.

**C10 · major · A stop count can include children still running (S).**
`Plugin/server.ts:120,127,178` limits the child query/traversal and ignores individual interrupt errors, then returns the number it attempted. The wait loop checks the same limited traversal at line 197.
Even a two-child tree can report both interrupted after one call fails. A broad tree with many historical children can also hide an active descendant beyond a page.
Report requested, acknowledged, failed and unexamined separately. Page to completion or return incomplete at the limit, then verify settled states through events. Apply the same contract to wait.

## 3. Performance and resource use

**P1 · minor · Small sidebar edits still rebuild large intermediate structures (M).**
`Sources/Engine/EngineCore.swift:425,559,1752` computes attention for all sessions on a dirty status and scans organisation inputs twice. `Sources/BelloCodeApp/Sidebar/SidebarViewController.swift:252,319` rebuilds tree inputs, parent map and materialized node maps even when AppKit receives two row edits.
With 2,000 fixture threads this review measured 28.6 ms median for a one-thread change and 122.2 ms for a filter rebuild. A busy group of agents can consume much of a main-thread frame budget. No per-token sidebar invalidation was established.
Maintain per-project section membership, recalculate dirty ancestors, and batch simultaneous status changes. Keep the existing palette candidate snapshot per opening. Measure p95 with 30 active threads and a second window before adding another cache.

**P2 · minor · Streaming write batching still rewrites whole messages (M).**
`Sources/Engine/Store/ProjectionStore.swift:523` replaces the header, deletes all parts, inserts all parts, deletes FTS and tokenizes the whole searchable text for each persisted revision. The default write cadence is 100 ms (`EngineConfiguration.swift:29`).
A reply with many completed tool parts rewrites those unchanged parts whenever its last text part grows. This cost is independent of TranscriptKit's fixed tail rendering. Indexed keyset paging and GRDB's on-disk WAL pool are sound choices (`Store/Schema.swift:44,52`, `ProjectionStore.swift:338,634`).
Dirty-track parts, move FTS updates to completion or a slower checkpoint and keep an in-memory search path for the live tail if required. Compare logical bytes appended, WAL bytes, transaction duration and search freshness on a long reply.

**P3 · minor · Image input and visual artifact I/O exceed the intended bounds (M).**
`Sources/TranscriptKit/Transcript/Source/ImageLoading.swift:35` decodes data URLs without a decoded-byte cap and checks HTTPS size after URLSession has materialized the response.
`Sources/Engine/Extras/VisualService.swift:92,119,153,262` reads JSON/PNG and writes preview output on the main actor. The document-count prune walks HTML records. Preview PNGs use separate UUIDs and a separate directory.
Bound bytes while streaming and before base64 decoding, cap concurrent loads and move file work to a storage actor. Give temporary previews a byte/age budget. Measure peak resident size and main-actor time separately from thumbnail cache size.

**P4 · suggestion · Budget background wakeups per app, especially with no visible windows (S).**
`Sources/Engine/Containers/EnvironmentService.swift:21,255,572` probes every four seconds while down, every 30 seconds while up and checks idle every minute. The sidebar has a 30-second timer per window (`SidebarViewController.swift:224`).
MR polling already backs off, schedule timing uses the earliest due task, and `Sources/Engine/Extras/WallClock.swift:21` wakes at most a minute apart to follow clock changes. Plugin waits check every 750 ms and may walk a task tree (`Plugin/server.ts:193`).
Back off an unavailable runtime when no project needs it, pause invisible row clocks, and use event-driven waits plus deadlines where possible. Count wakeups and requests over ten idle minutes with zero, one and ten watches before tuning.

## 4. Security and execution isolation

**S1 · major · Production can select an unconfined backend (S).**
`Sources/BelloCodeApp/Launch/AppRuntime.swift:57` accepts an environment-selected endpoint before building the supervised configuration.
`Sources/Engine/EngineConfiguration.swift:15` accepts any URL with a scheme. The attached branch uses the ordinary projection database, default vaults and no container configuration.
A developer's inherited override therefore changes where normal app work executes and which server reconciles the user's existing cache.
Compile attachment into a development harness with a separate data namespace. Require the bundled supervisor and helper in the distributed executable.

**S2 · major · A selected permission mode can fail while the first turn proceeds (M).**
`Sources/BelloCodeApp/Shell/Seams.swift:215` creates a thread and calls the nonthrowing setter in `Sources/Engine/Presentation/ThreadModel.swift:322`.
The draft host then sends at `Sources/BelloCodeApp/Content/ComposerSurface.swift:377`. The scheduled runner explicitly uses `try?` at `Sources/Engine/Extras/ExtrasHub.swift:664`.
If the server accepts creation and rejects the rules update, the first instruction still runs under the effective defaults. A schedule card may have promised different rules.
Share one throwing create/configure operation, retain the created ID and draft for retry, and permit dispatch only after acknowledgement. Assert zero sends after a rejected policy write.


**S3 · critical · Startup can discard a project's saved isolation policy (S).**
`Sources/Engine/Presentation/Engine.swift:232,388` applies the cached project list before environments.start. `Sources/Engine/Containers/EnvironmentService.swift:178` seeds a default model for each visible project. The subsequent load at line 134 imports persisted settings only for missing keys.
On a normal warm launch the common case is precisely an existing key. A project with network disabled can acquire the default bridge network (`EnvironmentModels.swift:21`) if a default image is configured. Without a default image its explicit image can appear missing. The helper config is written from these models before launch.
Restore persisted environment settings into every matching model before publishing any executable config. Treat a failed policy read as unavailable. Seed SQLite with an offline project and an app default image, relaunch the full Engine on a fake runtime, and assert the resulting Docker spec and helper file.

**S4 · major · Atomic helper files can still contain obsolete policy (M).**
`Sources/Engine/Containers/EnvironmentService.swift:862,876` records lastWrittenConfig before the async write and swallows errors at line 885. Cancelling the coalescing task does not order two writes already in progress.
After a disk error the earlier valid file remains on disk, identical retries are suppressed, and the app may show the new policy. Two successful atomic renames can also finish out of generation order.
Use one serialized writer, acknowledge the installed generation, retry visibly and withhold command authority until policy is current. Include a per-launch epoch so an old file cannot authorize a new server. Test write refusal and reversed completion with a fake file sink.

**S5 · major · A secret-command grant describes less access than the one-shot container receives (S).**
`Sources/Engine/Extras/ExtrasHub.swift:577,605,617` describes and binds the command, variable and network/project-write bits. `Sources/ContainerKit/Workspace/SecretCommand.swift:35` applies the write decision to workspace roots but carries user mounts with their original write access.
With an optional writable mount, an approved command described as offline with a read-only project can still persist data outside the disposable container. Changing an optional mount also changes the meaning of an existing Always grant.
Omit optional mounts from secret commands by default. If required, show and bind the exact canonical paths and access modes and reapprove on change. Preserve stdin delivery, one-shot lifetime and the earlier exact-command approval fix.

**S6 · major · Visual file inputs cross the host/project boundary before WebKit runs (S).**
`Sources/Engine/Extras/ExtrasHub.swift:176` passes the caller's directory to `Extras/VisualService.swift:139`, which also accepts any absolute path and follows ordinary filesystem resolution. It checks size then separately reads UTF-8. The resulting content becomes a preview artifact or persisted visual.
The renderer's nonpersistent store, CSP and content rules in `Sources/BrowserKit/Visuals/HTMLVisualSandbox.swift:50,199` protect a later stage. They cannot establish that the input came from the authorized workspace.
Accept inline content or a bounded regular file beneath approved project/worktree roots, read from a verified descriptor, and require an explicit person-selected attachment for external files. Keep the same resolver for preview and render.
