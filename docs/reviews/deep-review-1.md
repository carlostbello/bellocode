# BelloCode deep review

Reviewed develop at `6db276a` on 18 November 2026. References are relative to that revision.
Scope includes the shipping Swift targets, their test seams, the bundled TypeScript plugin, build inputs and packaging. S/M/L denote a local fix, a cross-component change and a staged refactor respectively.

## Executive summary

**Hold enterprise rollout.** The app can archive a project by deleting its persistent container home, and a warm launch can replace saved execution restrictions with defaults. Both behaviors were observed at the service boundary using in-memory fixtures. These are release blockers even for a single internal user. The 41 findings comprise **2 critical, 18 major, 16 minor and 5 suggestions**.
Keep the single backend, stable server IDs, native editors, virtualized renderers and one ordered projection. The most valuable changes are small corrections to lifetime, ownership and acknowledgement at the places those components meet.

### Recommendations ranked by value for effort

1. Make Archive Project visibility-only. Introduce an explicit purge with named volumes if needed (U1, S).
2. Restore the saved project execution policy before creating or publishing executable defaults (S3, S).
3. Make the selected permission mode an acknowledged precondition of the first interactive or scheduled prompt (S2, Q1, M).
4. Acquire thread-model leases per window. Close the subscription after the last release (C4, S).
5. Require a confirmed worktree location before starting a delegated child (C1, S).
6. Remove optional host mounts from a secret command unless its approval includes them (S5, S).
7. Ship only the supervised runtime. Move attachment and host setup fallback behind a test-only composition root (S1, A2, M).
8. Start schedule catch-up after the server and session projection are ready (C7, S).
9. Serialize helper-config writes and require the installed policy generation before allowing commands (S4, M).
10. Separate app-owned requests/outbox from disposable projection rows, and track completeness per resync partition (C2, C3, C5, C6, L in stages).

### Module health at this revision

| Module | Assessment |
| --- | --- |
| BelloCore | Healthy. Typed IDs and immutable domain values travel well across actors. Persisted Codable values need explicit compatibility fixtures. |
| OpenCodeKit | Generally strong. Verified real supervised restart and authentication, bounded SSE parsing and typed transport. Contract failures need better semantic classification. |
| Engine | Needs repair. Coalescing, cached reads and atomic status publication work. Startup ordering, shared-model lifetime and durable ownership drive the highest risks. |
| ContainerKit | Capable Docker protocol implementation. Check the *effective* one-shot mounts and the scope of destructive lifecycle operations. |
| bellocode-exec | Focused. Reads the helper contract, routes argv/TTY/signals to Docker and reports blocked work. Its authority is only as current as the producer's file. |
| DesignSystem | Good semantic tokens, contrast variants and AX control tests. One SwiftUI style hook generated an actor-isolation warning. |
| TranscriptKit | Strong rendering foundation. Tail-only updates and per-row text access have regression tests. Input-byte limits and open-thread lifetime still matter. |
| ComposerKit | Sound marked-text handling and draft model. First-send configuration and lifecycle errors occur in its shell adapter. |
| AgentUI | Pinned cards and explicit grant scope are good. A card is reliable only when its backing request and the effective policy survive. |
| OrchestrationUI | Sensible presentation split. Tree status, MR state and schedule controls depend on service acknowledgement and correct refresh after cancellation. |
| DiffKit | Good visible-range drawing, asynchronous search and virtual accessibility rows. Review SDK/AX assumptions on an unlocked machine. |
| TerminalKit | Good emulator/PTY separation, bounded replay and focus routing. Reconnect input overflow needs user-visible recovery. |
| BrowserKit | Strong session attachment and document generation checks, separate visual sandbox. Input file authorization and grant revocation belong at its service boundary. |
| BelloCodeApp | Substantial native shell with real menus, undo and restoration. Window sharing, archive semantics and release-only composition need work. |
| MockOpenCode | Valuable deterministic fault injection. Already-ready endpoints and simulated tools hide cold-launch and deployment faults. |
| Plugin | Small deployment footprint and explicit attribution. Worktree moves, fan-out and stop acknowledgement need failure-path tests. |
| Scripts | Verified arm64 archives and ad-hoc bundle assembly here. Provenance of fallback helpers and missing notices block a reproducible enterprise release. |
| Development targets | DesignGallery and the seven surface/runtime demos are useful harnesses. Isolate the mock/snapshot features that are also compiled into the shipping app. |

## 1. Architecture and dependencies inside the app

### Measured shape

The SwiftPM app and helper dependency closure contains **370 Swift files and 93,477 physical lines**, including MockOpenCode and harness sources compiled into BelloCodeApp. Excludes standalone demo/gallery executables, Tests, dependencies and Plugin. Engine has 20,058 lines, the app 15,899 and TranscriptKit 10,159. The bundled plugin entry alone has 727 TypeScript lines.

| Largest Swift files | Lines | Largest primary type declarations | Lines |
| --- | ---: | --- | ---: |
| Engine/EngineCore.swift | 1,990 | EngineCore (line 69) | 1,871 |
| BelloCodeApp/Sidebar/SidebarViewController.swift | 1,367 | SidebarViewController (37) | 1,211 |
| ComposerKit/View/ComposerViewController.swift | 1,072 | ComposerViewController (15) | 870 |
| DiffKit/Changes/ChangesPanelController.swift | 987 | LayoutEngine (46) | 844 |
| Engine/Containers/EnvironmentService.swift | 929 | TranscriptController (38) | 807 |
| DiffKit/View/DiffContentView.swift | 896 | EnvironmentService (91) | 803 |
| TranscriptKit/Transcript/Layout/LayoutEngine.swift | 889 | DiffContentView (51) | 801 |
| DiffKit/View/DiffViewController.swift | 884 | ChangesPanelController (25) | 798 |
| Engine/Store/ProjectionStore.swift | 870 | MainWindowController (17) | 729 |
| TranscriptKit/Transcript/Controller/TranscriptController.swift | 857 | DefaultCatalogJSON (MockOpenCode, line 5) | 722 |

Including same-module extensions gives a different ranking: MockOpenCodeServer 3,548 lines, TranscriptController 3,381, EngineCore 1,919, SidebarViewController 1,211, SnapshotRunner 1,182, ComposerViewController 1,049 and DiffContentView 1,043. SnapshotRunner alone is larger than most production view controllers.
File and type columns are independent rankings. Primary declaration spans include comments/nested members through the closing top-level brace, exclude extensions and are a lower bound on total responsibility. The long mock catalog is fixture data. The same line count in EngineCore has very different maintenance costs.
Swift normally imports modules. Counting import statements gives BelloCore 133, Engine 83, DesignSystem 78 and OpenCodeKit 37. For type fan-in, counting distinct *other* files mentioning a uniquely named top-level type/alias outside imports and line comments gives DS 86, SessionID 76, Engine 33, MessageID 32, Timestamp 28, DSButton/DSDraw 24 each, Message/Session 23 each, ProjectionStore 22, OpenCodeClient/MainWindowController 20 each. These counts approximate fan-in because equally spelled references can resolve differently.

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
A startup repair reconstructs pending schedule cards (Extras/ExtrasHub.swift:115). It cannot reconstruct an arbitrary app-only request. Give app requests their own durable table or an ownership discriminator honored by rebuild, write retry and deletion. Test write failure, relaunch and rebuild with a pending app card.

**C4 · major · Closing one window can freeze another window's thread (S).**
`Sources/Engine/Presentation/Engine.swift:291` returns the same model without acquiring another reference. Each workspace owns a separate eight-entry LRU and calls close on eviction or teardown at `Sources/BelloCodeApp/Shell/WorkspaceController.swift:115,416`.
`Sources/Engine/Presentation/ThreadModel.swift:374` cancels the sole subscription. Open A in two windows, close one, and the surviving workspace still returns its cancelled model from its own cache.
Give each window a lease and tear down on last release. Keep view-local scroll/focus separate from shared messages. Test close and ninth-thread eviction while a second window displays A.

**C5 · major · An authoritative short history can leave deleted messages searchable (M).**
`Sources/Engine/EngineCore.swift:913,941,961` reads disk IDs only between the first and last returned messages. For a short or empty page it also scans the bounded in-memory message cache.
If a server-side change removes the tail while disconnected, newer on-disk rows outside that interval can outlive reconcile. With an empty page and a cold message cache there are no candidates at all. The session is nevertheless marked historyComplete.
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
With 2,000 fixture threads this review measured 28.6 ms median for a one-thread change and 122.2 ms for a filter rebuild. A busy group of agents can consume much of a main-thread frame budget. An isolated repeat exceeded its timeout and sampled stale or unexpected edit counts, so these are observations from the combined run. No per-token sidebar invalidation was established.
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

**P5 · minor · File-watch overflow loses coverage of the changed tree (M).**
`Sources/Engine/Containers/FileEventBridge.swift:157,180` caps pending paths while continuing to insert parent folders. Flush clears both sets and sends only the first maxBatch entries. More distinct changed folders than the limit can leave the container watcher unaware of part of a change.
A large checkout or generated tree is a realistic trigger. Counters record overflow, but the truncated names have no retry path. The backing folder set can grow until flush.
Represent overflow as one dirty workspace with a bounded rescan/refresh obligation. Expose the degraded state and avoid repeated debounce wakeups while a prior sink call is outstanding. Test more changed directories than fit in a batch.

**P6 · minor · Virtual rows do not bound paged message bodies (M).**
`Sources/Engine/Presentation/ThreadModel.swift:350` keeps a full MessageModel and sort key for every older message loaded. The core's 2,048-message cache (`EngineConfiguration.swift:40`) and the window's eight-thread LRU bound different objects.
Paging through long tool-heavy histories in several recently visited threads can therefore retain their bodies even after cells and layouts are recycled. This is a source-derived memory slope. Earlier transcript layout/cache repairs addressed different storage.
Measure resident bytes after paging 1k/10k messages in eight threads and after closing one window. Keep lightweight IDs/sort keys, evict bodies outside a costed window and rehydrate from SQLite while preserving selection ranges and the visible anchor.

## 4. Security and execution isolation

**S1 · major · Production can select an unconfined backend (S).**
`Sources/BelloCodeApp/Launch/AppRuntime.swift:57` accepts an environment-selected endpoint before building the supervised configuration.
`Sources/Engine/EngineConfiguration.swift:15` accepts any URL with a scheme. The attached branch uses the ordinary projection database, default vaults and no container configuration.
A developer's inherited override therefore changes where normal app work executes and which server reconciles the user's existing cache.
In that branch, the missing setup runner falls through to host zsh (`Sources/Engine/Presentation/Engine.swift:172` and `Sources/Engine/Git/WorktreeService.swift:299`). Compile attachment into a development harness with a separate data namespace. Require the bundled supervisor and helper in the distributed executable.

**S2 · major · A selected permission mode can fail while the first turn proceeds (M).**
`Sources/BelloCodeApp/Shell/Seams.swift:215` creates a thread and calls the nonthrowing setter in `Sources/Engine/Presentation/ThreadModel.swift:322`.
The draft host then sends at `Sources/BelloCodeApp/Content/ComposerSurface.swift:377`. The scheduled runner explicitly uses `try?` at `Sources/Engine/Extras/ExtrasHub.swift:664`.
If the server accepts creation and rejects the rules update, the first instruction still runs under the effective defaults. The built-in build agent normally allows most actions before session rules are applied (Sources/Engine/Sync/Mapping.swift:340). A schedule card may have promised different rules.
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

**S7 · major · Revocation can succeed on screen and fail in durable storage (S).**
`Sources/Engine/Extras/VisualService.swift:229` ignores a rejected grant deletion, removes the host in memory and repaints. The old grant is reloaded at line 85 on next launch.
Likewise, `Sources/Engine/Extras/MergeRequestService.swift:173` hides the instance even if Keychain deletion failed. Adding the same URL later can expose an old stored token to the normal provider path.
Make revocation fail closed in memory, report “removal pending” until durable deletion succeeds and retry. Scope the acknowledgement to both stores where applicable. Test a denied Keychain deletion and a failed SQLite write followed by restart.

**S8 · minor · Routine account refresh downloads a secret-bearing representation (M).**
`Sources/BelloCodeApp/Launch/AppDelegate.swift:58`, `Sources/Engine/Auth/AuthService.swift:217,263` and `Sources/OpenCodeKit/HTTP/OpenCodeClient+Integrations.swift:104` refresh credentials on launch/catalog changes to derive non-secret account summaries.
The DTO drops secret fields, but the entire HTTP response first exists as Data in the desktop process. This is broader than the data the provider list and onboarding need. No leak to logs was established.
Use integration connection metadata for routine views and seek an upstream summary-only endpoint for account management. Until available, narrow the bulk read to the explicit account operation that requires it.

The production supervisor uses isolated HOME/XDG, a new password and loopback readiness verification. Pipe draining and redaction remain valuable. Keep the child output buffer support-only and avoid collecting raw server responses in diagnostics.
The host Git shim is still shared by BelloCode and opencode in supervised mode. Local and network Git have deliberately different privileges. Pin smoke coverage to both with each macOS/CLT upgrade because sandbox-exec profiles and the installed git-core layout are OS dependencies.
The plugin obtains the caller from the tool context, asserts cross-project access for targeted thread operations and allows denial of a child's request. Same-project reads/sends and metadata enumeration have broader scope than a single checkout (`Plugin/server.ts:144,429,466,511,575`). Treat the project as the collaboration boundary in owner policy.

## 5. Code quality, failure handling and test architecture

**Q1 · major · The two-stage agent change can leave the wrong effective rules (M).**
`Sources/Engine/EngineCore.swift:1674` first switches the session's agent, then fetches restrictions and updates the permissions. An error during the second step leaves the first step committed. A concurrent agent/mode change may also interleave while those calls await.
Rollback for a failed optimistic model/agent/mode call at line 1720 compares the entire session. An unrelated SSE rename can make that comparison fail and leave a rejected field displayed. The title-only guard at line 1216 provides a narrower precedent.
Serialize policy transitions per session. Represent configuring/failed/confirmed explicitly, reconcile the actual server state, and block dispatch while rules are uncertain. Use per-field revisions for independent optimistic edits.

**Q2 · minor · File migration success does not validate stored JSON compatibility (M).**
`Sources/Engine/Store/Schema.swift:15,178` declares currentVersion 5 but registers six migrations, v1–v6. GRDB tracks their names, so this constant does not itself prevent v6 opening.
`Store/ProjectionStore+Environment.swift:15` skips undecodable environments. `Store/ProjectionStore.swift:814,836` treats invalid preference/terminal blobs as absent. An added required Codable field can turn valid historical settings into defaults even when every SQL migration succeeds.
Keep named forward migrations, the WAL pool and the existing quarantine distinction. Derive the diagnostic version. Add populated historical databases and JSON blobs, round-trip drafts, grants, schedules and policy, and fail visibly on an unreadable app-owned row. A pre-upgrade backup and a compatible reader are more useful on downgrade than destructive down-migrations.

**Q3 · minor · Strict language mode still leaves concrete isolation warnings and fragile lifetimes (S).**
`Package.swift:13,22` enables Swift 6 and limits the hardcoded CLT Testing macro path to test settings. The build emitted an actor-isolation warning at `Sources/DesignSystem/Controls/DSSwiftUI.swift:103` for constructing a main-actor ViewModifier from the synchronous style hook.
In `Sources/BelloCodeApp/Shell/WorkspaceController.swift:149`, the fallback from weak self force-unwraps that same self. If the draft creation callback outlives the window it can trap instead of ending the operation.
Make the missing owner a normal optional/cancelled result and scope UI callbacks to window lifetime. Replace the underscored style hook with a supported modifier/wrapper if it cannot satisfy the SDK isolation contract. Track warnings by source and toolchain.

**Q4 · minor · Concurrent UI suites make timing failures hard to attribute (M).**
`Tests/BelloCodeAppTests/TerminalShellTests.swift:18,73` tears down in an unawaited Task and waits up to five seconds for another drawer record. Suite serialization does not isolate it from other suites sharing NSApp/MainActor.
The combined run missed that condition. The isolated three-test suite passed. This establishes inconsistent results under different workloads. The cause remains open. `Tests/BelloCodeAppTests/SwitchTimeTests.swift:42,75` gates warm timings more strictly than cold ones.
Await teardown, expose terminal admission/attachment gates and run AppKit throughput budgets in their own process. Keep the concurrent run as a separate stress lane, and capture a bounded diagnostic when a gate fails.

A source scan of the app dependency closure found **zero** non-comment lines with `Task.detached` or `@unchecked Sendable`, 32 with `Mutex(`, 59 with `MainActor.assumeIsolated` and three with `nonisolated(unsafe)`. These are literal-line counts.
All three unsafe declarations occur in the Objective-C accessibility adapter (`Sources/DiffKit/View/DiffContentView+Accessibility.swift:17,49,109`). It checks the thread at access points. Audit callback queue contracts and keep such adapters small. Replacing locks in synchronous OS callbacks with casual unowned tasks would weaken ordering.
The mock is particularly effective for forced write failures, dropped answers and ordered events. A fixed mock already has an endpoint, a separately constructed EnvironmentService loads before any UI, and scripted tools return predictable locations. These strengths also explain why C1, C7 and S3 need composition tests.

## 6. UX, presentation and restoration

**U1 · critical · Archive Project can permanently delete the workspace home (S).**
`Sources/BelloCodeApp/Shell/WorkspaceController.swift:286` offers “Archive Project” with Undo. Undo calls addProject. `Sources/Engine/Presentation/Engine.swift:460` passes the entire hidden-project list to `Containers/EnvironmentService.swift:191`, which immediately requests removal with volumes.
`Sources/ContainerKit/Workspace/WorkspaceManager.swift:194` forcibly removes labeled containers and volumes, including persistent container HOME. A file saved only in that home disappears. Restoring the sidebar entry cannot recover it. The hidden list is a snapshot, so subsequent unrelated project updates can request the cleanup again.
Make archive visibility-only. Reserve container/volume destruction for an explicit purge that lists affected storage. Test archive, undo, another project's update and relaunch with a fake runtime asserting zero destructive calls.

**U2 · minor · Existing queue items lack matching menu actions and honest intermediate states (S).**
`Sources/BelloCodeApp/Content/QueuedPromptsView.swift:65,82,111` exposes Steer Now and Remove on a particular item. The shell commands at `Shell/ShellCommand.swift:239,557` queue/steer the *current draft* and require composer content.
`Sources/Engine/EngineCore.swift:1529,1555` sets delivery to steer or removes the row before the PATCH/DELETE returns. A transport error can restore the row after it appeared withdrawn.
Expose actions for the focused queued ID through menu validation and accessibility. Display “Steer requested” or “Withdrawing” until acknowledged. Document the pinned API's supported edits before promising general reorder/edit.

**U3 · major · Disconnected terminal input can disappear without feedback (S).**
`Sources/Engine/Terminal/TerminalStream.swift:145` accepts bytes during connecting/reconnecting/detached only if the entire input fits the remaining 64 KiB. Overflow is silently ignored. A subsequent small Return can still fit.
This matters for a paste followed by Return: the user cannot tell which input the remote PTY will eventually receive. The existing resize debounce, cursor-based replay and explicit controller/observer ownership should remain.
Return a queued/refused result to the pane. Show a persistent overflow notice, require the user to review or clear queued input before submitting and never auto-replay a possibly executed command. Test the boundary with injected transport, independent of frame timing.

**U4 · suggestion · Keep surface themes as renderer adapters, centralize scaling (S).**
`Sources/BelloCodeApp/Content/AppStyle.swift:14,27` adjusts ComposerStyle and AgentUIStyle at construction. TranscriptTheme, DiffTheme and TerminalTheme must also translate semantic roles to CoreText, CGColor or SwiftTerm values. Several “standard” constructors remain public.
This produces multiple refresh paths for the same appearance/text-size change, even where the restyle uses the same DS colors. Native field, terminal and diff metrics genuinely differ.
Keep the renderer types and feed them one versioned appearance/text-scale input. Check live changes in an already-open picker, composer, diff, terminal and transcript with the same contrast/font-size matrix.

**U5 · minor · An unavailable search index is presented as a successful empty search (S).**
`Sources/BelloCodeApp/Palette/PaletteController.swift:346` turns a thrown message search into an empty array, marks the query complete and displays “No messages match”. The file-search path at line 331 already distinguishes failure.
A store read failure with cached sessions visible is indistinguishable from an absent message. Preserve prior results, show the index error with Retry, and commit messageQuery only after a successful result.

The section E checklist was applied as a code and test audit. Cached snapshots, native split autosave, per-window selection/drafts and stable IDs give warm navigation a sound base. `AppDelegate.swift:53` shows the window before cache hydration. Slow store open still precedes the first window, and `Presentation/Engine.swift:232` suppresses cache-load errors. Measure time to usable cached rows on a populated store, separately from server-ready time.
Purpose/context, states and artifacts have specific exceptions in C1, C2, U1 and U2. Parallelism and restoration need C4 and S3. Ask for the effective branch/worktree at action time and preserve focus on a failed confirmation.
Keyboard evidence includes marked-text checks in `Sources/ComposerKit/View/ComposerTextView.swift:50,64` and terminal key routing in `Sources/TerminalKit/Terminal/TerminalPaneView.swift:22,137`. AgentUI has pinned requests and menu responders. Status glyphs and labels, per-row text accessibility and on-demand accessibility elements for large diff row lists are substantial work.
Physical IME composition, VoiceOver rotor/actions, Full Keyboard Access, live approval announcements, large text, RTL, non-US shortcuts, contrast, Reduce Motion/Transparency, drag/Undo, multiple monitors and keyboard interaction inside WKWebView still require an unlocked session. A passing AX method call alone cannot verify these interactions. Onboarding/provider failure and notification privacy were read only.

## 7. Dependencies, contracts and packaging

**D1 · minor · A fresh CLT build can stall in a dependency's build plugin (S).**
`Package.swift:40` pins SwiftTerm 1.99.3. Its build-info generator consults Git when build metadata is absent (`SwiftTerm/Sources/SwiftTermBuildInfoGenerator/BuildInfoGenerator.swift:19,279` in that checkout).
The first build was still waiting after 32 minutes. A process sample located the wait in GitCommand.output → NSConcreteTask.waitUntilExit. Rebuilding with the four supported SWIFTTERM_BUILD_* metadata variables from the verified checkout completed. This run does not establish why the child wait stalled.
Pass verified dependency revision/tag/dirty metadata in the reproducible release build, add a build timeout with diagnostics, and raise the observed hang upstream. Keep the CLT macro-path workaround test-scoped and verify it on each toolchain, including the minimum supported OS.

**D2 · major · The release script can sign a helper whose provenance it cannot establish (S).**
`Scripts/opencode-checksums:7` records an Intel archive hash but no Intel executable hash. The binary_ok test in `Scripts/fetch-opencode.sh:48` accepts executability alone when that second hash is absent. This also affects an already-populated Vendor directory.
The verified archive route is stronger. The ripgrep fallback at `Scripts/fetch-opencode.sh:155` permits a local executable or missing helper, and `Scripts/make-app.sh:58` will still package/sign. A signature authenticates what this build packaged.
Require verified executable digests and portable dependencies for every shipping architecture, verify any cached helper just before signing, and keep the permissive fallback solely in a clearly marked developer build. Test an unrecognized cached helper without executing it.

**D3 · minor · Acknowledgements omit bundled notices (S).**
`Scripts/make-app.sh:67` copies one license per Swift package. The generated bundle contains seven such texts. The resolved h, swift-png and swift-markdown checkouts also contain NOTICE files. opencode and ripgrep appear in `Sources/BelloCodeApp/Settings/Acknowledgements.swift:40` but have no corresponding text in the assembled bundle.
T3 Code's embedded MIT notice is present. Include required notices and binary release attributions from the exact shipped artifacts, track transitive components and validate bundle contents as a packaging test.

**D4 · suggestion · Isolate Rancher discovery from the Docker capability decision (S).**
`Sources/ContainerKit/Runtime/RuntimeDiscovery.swift:117,135,158` relies on the 1.25 product layout, a home-relative socket, app plist and containerEngine.name. A config value can reject access before the supported Linux Engine API is probed.
A settings rename or stale value can misclassify an otherwise supported engine. Prefer version/ping/API compatibility on the selected socket as authority and use product configuration for remediation hints. Retain API 1.44 floor and fail closed on unsupported capabilities.

**D5 · minor · Unknown new events and broken known events look identical (M).**
`Sources/OpenCodeKit/Events/OpenCodeEvent.swift:160` catches a decoding failure and emits the same unknown envelope used for genuinely new event types. `Sources/Engine/Sync/EventReducer.swift:552` then decodes seven additional known event types manually out of raw frames.
A changed field on a known semantic event can therefore increment an unknown counter while the connection stays healthy and the relevant state goes stale. Conversely, an intentionally supported extra event can count as unknown.
Move the seven typed payloads into OpenCodeKit. Distinguish unsupported event, malformed known event and irrelevant event. Trigger a bounded targeted refresh for malformed semantic events. Log only type/category and count.

### External contracts to carry through upgrades

| Dependency or boundary | Pinned assumption and how drift appears |
| --- | --- |
| GRDB.swift 7.12.0 (MIT) | DatabasePool with WAL on disk, DatabaseQueue in memory, FTS5, foreign keys, transactional named migrations. Test a populated old file on the oldest supported macOS SQLite as well as this SDK. |
| swift-markdown/swift-cmark 0.9.0 (Apache-2.0 / bundled cmark notices) | Parsing and source spans feed layout and selection caches. Replay the Markdown corpus, including partial fences, tables, UTF-16 selection and finished revisions. |
| SwiftTerm 1.99.3 (MIT) | Rendering, input routing and terminal replay depend on the pre-2.0 surface and its build plugin. Retest resize/input ordering, alternate screen, clipboard controls and reconnect. |
| swift-argument-parser 1.8.2, swift-png 4.5.2, h 1.0.1 | Transitive pins in Package.resolved, Apache-2.0. Build the complete app/helper closure under Swift 6.4. Check license notices with the shipped inventory. |
| opencode 2.3.0 | Bundled host binary, MIT. Supervisor checks version and PID. HTTP 404/decoding failure, missing events and changed tool behavior are three different failure modes. Keep the source archive checksum and contract fixtures as an upgrade unit. |
| GitLab REST v4 | Same-origin redirect guard, Keychain token, conditional pagination, rate-limit handling. Revalidate against the supported self-managed versions and editions, including a path prefix and missing approval capability. |
| Rancher Desktop / Docker Engine | Product layout and file-sharing assumptions, labeled mounts/volumes, Linux Engine v1.44, exec hijack and port forwarding. The fake daemon protects protocol shape. VM behavior, file events and network policy need a controlled live matrix. |

The checked-in OpenAPI includes many operations the app never invokes. The following are the experimental routes used by the first-party clients, plus the plugin contracts they require.

| Route or protocol | Consumer, failure signal and upgrade check |
| --- | --- |
| GET /api/experimental/client-mcp (WebSocket) | ClientMCPHost.swift:167 builds Basic-auth upgrade plus location/name. Check MCP initialize, tools/list, attributed calls, cancellation and disconnect removing tools. |
| GET /api/experimental/session/{id}/instructions/entries, PUT/DELETE …/entries/{key} | OpenCodeClient+Browser.swift:118 supplies browser and plugin guidance. Check stored entry text/identity after attach and removal. Missing guidance can otherwise look like a functioning bridge. |
| GET/POST /api/experimental/session/{id}/terminal and GET …/terminal/read | OpenCodeClient+PTY.swift:9,15,49. Check persistent list/create shape and readable terminal output per session. |
| GET/PUT/DELETE /api/experimental/persistent-pty/{id}, GET …/snapshot, GET …/connect (WebSocket) | OpenCodeClient+PTY.swift:22,29,36,41,60. Verify cursor/role/takeover/input_protocol=1, replay/reset boundaries and exit. A successful upgrade alone does not verify byte offsets. |
| POST /api/experimental/schedule, GET/DELETE …/schedule/{id} | OpenCodeClient+Isolation.swift:65. Exercised by isolation diagnostics. BelloCode's recurring scheduler executes its stored definitions locally. A broken probe must remain “Not verified”/“Problem”. |
| POST /api/rpc/{rpcID}/{method} carrying experimental.browser v4 | BrowserContract.swift:8, BrowserAttachment.swift:113,246,325,380 implement attach, command, result, state and SSE rpc.experimental.browser.control. Explicit version mismatch, long-lived attach and request deadline. Replay navigation, cancellation, ownership transfer and stale generations. |
| Same RPC with bellocode/info, plugin contract v1 | OrchestrationContract.swift:14,114 and Plugin/server.ts:629. Compare tool set and version after location activation. Verify SDK ctx.session, worktree, permission, instructions, event subscription, tool transformation and shell hook behavior in addition to the names. |

Session list/message/inbox, interrupt, pending permission/form, synthetic wakes, VCS and worktree calls also need semantic upgrade coverage even though their URLs lack the experimental prefix. A wire-compatible change to prompt-ID admission or worktree move ordering can invalidate UI guarantees.

## Refactoring roadmap

| Order | Change and size | Primary risk | Protection and exit criterion |
| --- | --- | --- | --- |
| Quick 1 | Remove purge from archive, restore saved policy before helper publication (S each). | Existing cleanup and cold-start ordering. | Fake-runtime archive/undo/quit and populated-cache relaunch. Observe zero volume deletes and the exact saved policy. |
| Quick 2 | Gate first send on permission confirmation and child location (S–M). | Orphaned empty sessions/worktrees. | Reject the second step after successful creation. Keep the ID for retry, report cleanup, observe zero dispatched prompts. |
| Quick 3 | Lease shared thread models, fence MR completions, defer schedule catch-up (S each). | Leaks, duplicate reminders, delayed sidebar state. | Two windows plus eviction, unwatch while fetching, one overdue occurrence with a gated-ready supervisor. |
| Quick 4 | Remove optional secret mounts, fix visual file authorization and revocation errors (S–M). | Existing projects expecting optional assets. | Inspect effective mounts and card scopes, exercise failed deletion/relaunch, verify authorized visual attachments still render. |
| Quick 5 | Enforce verified release inputs and notices, stabilize SwiftTerm build metadata (S). | Developer bootstrap friction. | Fresh arm64/Intel inputs, stale cached input refusal, strict codesign verification and notice inventory. |
| Structural 1 | Extract a production composition root and fixture executable. Require a container runner in the shipped Git/PTY setup (M). | Broken shell snapshots or missing test hooks. | Build both graphs. The release dependency graph excludes MockOpenCode, fixture graph still drives all panes. |
| Structural 2 | Split durable app state from rebuildable projection, moving requests/outbox via an additive migration (M–L). | Losing pending cards, attachments or drafts during upgrade. | Seed historical DB/WAL, interrupt migration, restart, rebuild and recover. Preserve explicit unknown delivery and deduplicate by ID. |
| Structural 3 | Extract the per-project execution-policy writer and per-session command/resync state machines (L). | Reordering events or admitting stale work across awaits. | Deterministic barriers around install/configure/fetch/commit, snapshot completeness tests, full reducer fixtures, real supervisor disconnect lane. |
| Structural 4 | Optimize measured sidebar, FTS and resource work and isolate shared highlighting (M). | Search freshness, anchor drift, lost live context. | Compare row work, WAL bytes, resident memory and p95 under a fixed multi-window fixture. Preserve replay, selection and find behavior. |
| Release gate | Run hardware UX and enterprise integration acceptance on a signed build (M). | Debug/mock behavior differs on the managed image. | Unlocked 60/120 Hz, VoiceOver/IME, real approved image, self-managed GitLab and production Keychain signing identity. |

The target graph keeps BelloCore and rendering tokens at the bottom, external protocol adapters independent, a single projection writer above them, and a main-actor window layer consuming scoped models. Split files along these ownership boundaries after the regression tests exist. A separate process or a generic provider abstraction adds no value to this single-backend deployment.

## Verification and limits

**Environment.** Apple M5 Max, arm64, macOS 27.0.1 (26A434), Apple Swift 6.4, CLT 6.4 driver 1.168.6. Source revision `6db276a`. Counts use physical lines and file-level identifiers in the checked-in tree. No on-screen frame measurements were available.

### Commands and observed results

| Check | Result in this worktree |
| --- | --- |
| `Scripts/fetch-opencode.sh` | Used the cached, SHA-256-verified arm64 opencode 2.3.0 archive and the verified ripgrep 15.1.0 archive. |
| `swift build` | First invocation stalled in SwiftTermBuildInfoGenerator. After sampling and ending that generator, the debug build with the dependency's supported metadata overrides completed in 31.94 s. CLT linker search-path and the Q3 warning remain. |
| `make app` with the same build metadata | Assembled a 292 MiB debug bundle with opencode, rg, bellocode-exec and plugin. Inside-out ad-hoc signing and `codesign --verify --deep --strict` passed. Inspected the packaged acknowledgements. |
| Focused `swift test --filter` run, six test targets | 148 tests, 147 passed. The terminal drawer assertion failed at TerminalShellTests.swift:73. The 2,000-thread navigation test passed in this run. |
| `swift test --skip-build --filter TerminalShellTests` | All 3 passed in isolation (32.630 s). Attribution to load or a product race remains open. |
| `swift test --skip-build --filter NavigationPerformanceTests` | Isolated repeat failed. Exceeded its 300 s limit, finished after 442.351 s and reported 3,504 row edits in each of ten samples against a bound of four. |
| Real pinned server, `swift test --skip-build --filter 'lifecycleSessionsEventsCrashRestartAndStop\|stopDuringStartupLeavesNoChild'` | 2 passed in 2.070 s. First readiness 1,381 ms, restart after owned child kill 342 ms, new SSE resync 344 ms after kill, stop 6 ms. CRUD, auth rejection and restart ran without a model turn. |
| Additional `swift test --skip-build --filter` sweep | 49 passed across orchestration text, fake environment/interception, secret approvals, worktree folders, cold-start faults, diff/AX and design controls. |
| Read-only source/contract census | Counted declarations/imports under Sources, inspected all six SQL migrations and compared the used experimental operations with Contracts/opencode-2.3.0/openapi.json and the recorded SSE stream. |

The build override values were `SWIFTTERM_BUILD_BRANCH=detached`, `SWIFTTERM_BUILD_TAG=v1.99.3`, `SWIFTTERM_BUILD_COMMIT=282c3c3a932b55c129628876b70f37d993af1615` and `SWIFTTERM_BUILD_DIRTY=false`. Revision, tag and clean detached state were checked in the resolved SwiftTerm checkout.
The first test invocation used this filter, before fetching the binary. The separate real-server command selected only the two named prompt-free tests.

```sh
swift test --filter 'SSEParserTests|EventHubTests|ServerSupervisorTests|NavigationPerformanceTests|SwitchTimeTests|StreamingCostTests|ProjectionStoreTests|QueueOrderingTests|AttentionTests|GitLabTransportTests|ScheduleApprovalBindingTests|PortForwarderTests|AccessibilityTextTests|DraftHydrationTests|StoreOpenSafetyTests|ResyncRetryTests|WriteBehindSafetyTests|EngineClientTests|ScheduleTests|ChangesShellTests|TerminalShellTests|BrowserShellTests|ClientMCPEngineTests'
swift test --skip-build --filter 'DiffAccessibilityTests|DiffEngineTests|ControlTests|AgentsPanelModelTests|ContainerEnvironmentTests|SecretCommandApprovalTests|FaultAndColdStartTests'
```

**Direct service probes.** Two disposable Swift programs were compiled from stdin against the debug object files. They used in-memory GRDB, synthetic identifiers and a fake runtime. No repository test source or product code was edited.

| Finding | Probe and observation |
| --- | --- |
| S3 | Saved image `approved:1` and network `none`. Replayed the launch order `projectsChanged → EnvironmentService.start → environment(for:)`. Observed image nil and network bridge. Runtime discovery was disabled for this probe. |
| C4 | Acquired the same thread twice through Engine.openThread. Object identity matched. Closing the first handle left the second alive but unregistered (`loadedThread(id) === second` was false). Removal of its subscription is in ThreadModel.close. |
| C3 | Inserted one synthetic app-owned pending request via StoreBatch, then called ProjectionStore.rebuild. Pending count went from 1 to 0. |
| U1 | Sent a visible project followed by the hidden-project list into EnvironmentService with a recording FakeWorkspaceRuntime. Its remove call received `volumes=true`. Actual Docker removal was not exercised. |
| S5 | Inspected secretCommandBody for an offline/read-only approval and a configured writable optional mount. The effective bind mounts had readOnly flags `[true, false]`. No secret value or Docker connection was involved. |

**Performance interpretation.** The combined debug run measured 4,018 sidebar rows, a 2.89 ms median / 5.70 ms p95 palette keystroke and 24.3 ms median palette open. It rebuilt candidate sources ten times for ten opens and zero times during typing. Warm 500-thread switches measured 9.5 ms median / 10.5 ms p95. Cold p95 was 11.3 ms with a **46.4 s maximum**. Record both the tail and the median.
The isolated navigation run produced a contradictory edit count after timeout. A process sample was in NavigationWindowTests.swift:465 → ShellDriver.idle → nested RunLoop.main.run. The test samples lastStructureMilliseconds/lastRowEdits after an idle interval, without awaiting a unique applied revision. Instrument that receipt before treating either run as a production latency guarantee.
Earlier release measurements in `docs/features/transcript.md:120`, `docs/features/diff-git.md:51` and `docs/features/terminal.md:43` belong to their original scenarios. Transcript tail regressions passed here. DiffContentView.swift:265 draws dirty visible rows and DiffViewController.swift:622 performs cancellable find. Earlier 100k-row diff build times of 43–51 ms do not measure today's whole window or interval to first usable content.
Measure three launch milestones in a signed release build with a large, cold and warm store: visible window, first interactive cached thread, first live reconciliation. Correlate SQLite read duration, main-actor projection apply, time until first blocker is visible, idle file watchers and memory per open window. For transcript and diff, sample p95/p99 layout and presentation separately while resizing and streaming.

### Earlier dispositions checked

- **M1.** Store-open quarantine distinguishes corruption from ordinary open failures. Forced write/retry, same-ID command flow and resync tests are meaningful. The new issues concern app-only requests joining an older cache lane, durability after restart and incomplete *successful* resyncs.
- **M2–M4.** Tail-only updates, transcript AX text, virtual diff rows and actual download admission/identity handling remain present. The multi-window model-lifetime issue is independent of the app-wide pending deletion fix. The archive issue affects labeled Docker volumes, distinct from the repaired Git worktree Trash path.
- **M3–M6.** Verified regressions for same-origin GitLab redirects/304 pagination, schedule-definition binding, one-shot command approval, per-project worktree folders and forwarder admission through selected tests or source inspection. Host Git's sandbox and shim remain connected in the bundled launch path. S4/S5 concern configuration delivery and effective mounts around those fixes.

**Reading only and unverified.** Other findings are reasoned control-flow or data-ownership traces unless a probe or measurement is named. No full-suite pass is claimed. No live Rancher API, container lifecycle, provider/model prompt, enterprise GitLab account, user opencode database, real Keychain credential, Finder walkthrough or human accessibility session was used. `make smoke` includes live execution/isolation probes and was outside this review's constraints. Developer ID, notarization, signed Keychain access, Intel behavior and macOS 15 compatibility remain unverified.

## Open questions for the owner

1. Should archived project environments stay running, stop while retaining volumes, or expire under a separate retention rule? Which volume contents need backup?
2. Can the enterprise build remove external-server attachment, host setup scripts and host-secret delivery entirely? Which release architectures and minimum CLT/macOS combinations must CI support?
3. Is optional mount access ever required by commands receiving secrets? Should approval also bind an image digest and an exact worktree rather than a project-wide command grant?
4. Which app-owned records must survive a downgrade, cache reset and server replacement? What retention/encryption policy applies to undelivered prompts, attachments and recoverable old databases?
5. Should grants for visual network hosts and cross-thread read/send span every project? Should remote transcript images load automatically from host networking in an otherwise offline workspace?
6. What delivery semantics should schedules and MR wakes promise when a crash occurs between server admission and local bookkeeping? Which synthetic operations support a stable client-supplied ID on the pinned backend?

## Disposition: isolation, policy and secrets (U1, S1–S7, Q1, D2/D3)

Branch `t3/security-policy-isolation`. Every finding below was confirmed against the code before fixing; none was
found wrong. No database migration was added (new state uses the existing `app_preference` table and files).
Other findings (C1–C10, U3) are dispositioned separately.

| Finding | Disposition | Commit | Evidence |
| --- | --- | --- | --- |
| U1 | Fixed. Archive only hides the project; the environment service ignores hidden projects. The runtime's `remove` no longer takes a volumes flag; the only volume deletion is Settings ▸ Environment ▸ **Delete Container and Data…**, which lists the exact containers and volumes and asks once, then deletes only those still labelled for the project. | `9ed1cd9` | `ProjectEnvironmentLifetimeTests.archiveUndoUnrelatedUpdatesAndRelaunchNeverRemoveContainersOrVolumes`: archive, unrelated pin/move, undo, re-archive and a relaunch on a file store make zero remove/volume calls on a recording runtime; container-only removal keeps volumes; purge deletes exactly the listed volume and refuses another project's list. |
| S3 | Fixed. `Engine.start` loads environments before the cached project list; `EnvironmentService.start` overwrites placeholder models with the saved setting, and nothing creates, publishes (helper file) or runs until settings are loaded. An unreadable row or table read blocks the project (`policyUnavailable`) instead of applying defaults. No project gets a default beyond the app-wide one (which defines only the image). | `5a9f547` | Warm and cold launch tests with a saved offline policy + approved image + app default image assert the model, the helper file spec and every Docker spec. The warm test fails on the previous order (5 failed expectations, reproduced by reverting the two changes). Unreadable-row test: helper spec withheld, no container created. |
| S4 | Fixed. One chained writer; each write puts `bellocode-exec.required` (launch epoch + generation) first, then the configuration; success is recorded after both land; failures are shown ("Commands refused") and retried; a failed requirement write removes the configuration. `bellocode-exec` runs a command only if the epoch matches and the generation is at least the required one (re-reads up to ~2 s), else exit 125 with the blocked-message style. | `3d5734c`, `e6d4d52` | `HelperConfigWriterTests`: held/reordered writes land in generation order with the newest policy; failed config write leaves a refused file and recovers on retry; failed requirement write removes the file; an earlier launch's file is refused; the real helper binary refuses an older configuration (exit 125, nothing run). `make smoke` passes through the new check. |
| S1 | Fixed. Decision: no target split (A2 left for a later structural change). `BELLOCODE_SERVER_URL` attach and `--mock`/`--snapshot` exist only in debug builds (`BELLOCODE_DEVELOPMENT` on the BelloCodeApp target, `.when(configuration: .debug)`), so `make smoke`, snapshots and demos are unchanged; attach uses its own store, defaults suite and in-memory secrets. The bundled path refuses to start without `Helpers/opencode` and `Helpers/bellocode-exec`. `WorktreeService` no longer falls back to host zsh: a setup script without a container runner is refused before anything is created. | `a5db721`, `7b39925` | `swift build -c release --product BelloCode` compiles with those modes excluded; LaunchOptions/bundle tests; `GitTests` asserts refusal with no folder created and no marker written. |
| S2, Q1 | Fixed. Threads are created with the mode's rules in the create request (draft composer and scheduler; no non-throwing setter afterwards), and the server's copy is checked. Agent and mode changes are serialised per thread: new rules computed before any change, agent switched back if the rules are refused, result read back; an unconfirmed state blocks sends until the mode is chosen again. Optimistic edits roll back only their own field. Plugin: `create_threads` passes the caller's rules and both it and `delegate_task` check them before the first prompt (`Plugin/server.ts`, small additive edit near C1's lines). | `c414209` | `PermissionPolicyTests` (6, mock): no PATCH needed after create; rejected creation sends zero scheduled prompts; an accepted-but-unapplied update blocks sending until re-chosen; failed rules update rolls the agent back on the server; agent+mode+send are ordered with a held request; a failed model change keeps a concurrent rename. Plugin `bun test` 19 pass (container). |
| S5 | Fixed. Secret-command containers get no optional mounts unless the agent asks (`includeMounts`); the card then lists each folder with its access, the digest binds them (unchanged digest when none), the create request carries exactly that access, and a setting that no longer allows it refuses. | `17ad90d` | `SecretCommandMountTests` inspect the create request sent to a fake daemon (writable optional mount absent; listed mount read-only as approved; network none; container removed). Engine test: card text, passed policy, Always re-asks when access changes. |
| S6 | Fixed. Visual `path` inputs must resolve (symlinks, `..`) inside the calling thread's project or worktree folders, are opened once with `O_NOFOLLOW`, re-checked via `F_GETPATH` on the descriptor, must be regular files and are read with the cap applied while reading. | `d1da577` | `VisualFileAuthorisationTests`: symlinked file and folder, `..`, absolute outside and `/etc/hosts` refused; `/dev/zero`, a FIFO and a folder refused; cap enforced on bytes read. |
| S7 | Fixed. Visual host revocation blocks at once and succeeds only when the grant row is deleted; otherwise "Removal pending" (persisted beside the visuals, so a restart does not restore it) and retried. GitLab instance removal succeeds only when the Keychain token is deleted; otherwise the instance stays listed with the problem. Removed addresses are remembered (`gitlab.removedInstances`); re-adding one without a new token deletes a leftover token rather than reusing it. | `294feec` | `RevocationDurabilityTests` with a failing store write hook (including a restart) and a refusing vault. Limit: a token orphaned by a pre-fix build for an address never removed through this version is not tracked. |
| D2, D3 | Fixed. `make-app.sh` bundles opencode and rg only when their executable SHA-256 equals the pin for the build architecture (Intel opencode and both rg digests now pinned, taken from the verified archives; rg required), bellocode-exec only as built by the run; bundled copies re-checked before signing; any other helper refused. Notices: NOTICE files of swift-markdown, swift-png and h, opencode's LICENSE at `v2.3.0` (`Scripts/notices/`), ripgrep's COPYING/LICENSE-MIT/UNLICENSE; a missing text fails the build. | `c4f9f88` | `make app` (9 texts bundled, strict codesign verify); an unpinned `Vendor/ripgrep/rg` is refused before building. D1 (SwiftTerm generator stall) recurred once under `make app` and was not addressed here. |

Real binary (2.3.0, isolated temporary XDG/HOME, no prompts, `BELLOCODE_POLICY_REAL=1 swift test --filter PolicyRealBinaryTests`):
a session created with `permissions` reports them at once; `setAgent(plan)` in ask mode reports agent `plan` with the
mode's rules followed by plan's `edit * deny` and its plan-folder exception; a bare `switchAgent(build)` leaves the
session rules unchanged (the two-stage window); an unknown agent is rejected (not found) with nothing changed; a mode
change is reported as sent; a child created with `parentID` and no rules inherits the parent's session rules.

Also changed outside these findings: the `git` shim's trusted-configuration probe waited with `Process.waitUntilExit`
inside `bellocode-exec`'s async top level, which never returned on this machine (macOS 27), so every network git
subcommand through the shim hung and the confined `GitRealBinaryTests` case timed out; reproduced with the unmodified
base `main.swift` (5 of 5) and fixed by waiting on the termination handler (`f3116a8`, 0 of 20). The same
`waitUntilExit` symptom is what stalls SwiftTerm's build-info generator (D1), which remains open.

## Disposition: core-correctness findings (branch `t3/core-correctness-fixes`)

Findings C1–C10 and U3. Every finding was confirmed against the code before it was changed; none was found wrong.
Each fix has a deterministic regression test (gates, held responses, injected clocks and MockOpenCode faults; no
sleeps used as synchronisation). Where noted, the test was first run against the unfixed code and failed.

**Database migrations (additive, named):** `v7-app-requests` (new `app_request`; moves existing `app_…` rows out of
`pending_request`) and `v8-app-outbox` (new `app_outbox`). `ProjectionSchema.currentVersion` is now 8. Another branch
adding a migration must be ordered after these two.

| Finding | Disposition and evidence |
| --- | --- |
| C4 | Fixed. `Engine.openThread` takes a lease and `ThreadModel.close()` releases one. The subscription ends only with the last lease, and `Engine.stop()` ends all. Scroll, focus and follow-tail state already live in each window's views, so the shared model holds none. `ThreadLeaseTests` (two `WorkspaceController`s on one engine, close and ninth-thread eviction while the other window shows the thread) failed before the fix. |
| C7 | Fixed. `SchedulerService.start(armed:)` loads definitions at once. `ExtrasHub` arms dispatch when the connection is live and disarms it otherwise. Offline, connection-refused and 503 failures defer the run and keep the original due occurrence; rejections are still recorded. `ScheduleLaunchTests` covers an overdue one-off with a gated endpoint, which failed before the fix, plus deferral and rejection cases. |
| C1 | Fixed in `Plugin/server.ts`. A worktree child is prompted only after a usable directory came back and its session reads back as located there. Otherwise the call fails and names the created threads and worktrees. `create_threads` no longer falls back to the shared checkout. Plugin tests (`test/delegation.test.ts`, scripted context) failed 6/9 on the old plugin. `WorktreeMoveRealBinaryTests` checks on the pinned binary, with no prompt, that a moved session reports the worktree directory verbatim. |
| C10 | Fixed. Stops report requested, acknowledged, failed, settled, still-stopping and unexamined. Children are paged, a cut walk is reported incomplete, and `thread_wait` does not report a partially listed tree as settled. `test/stop.test.ts` failed 5/6 on the old plugin. |
| C8 | Fixed. A per-watch generation is checked after the GitLab read and after a wake, and the pause is re-evaluated after the read. `MergeRequestFenceTests` covers delayed success, delayed failure, remove/re-add and archive-during-read. The first three failed before the fix. |
| C2 | Fixed. Pending lists are read per directory and inboxes per session. Failed reads become `SyncGaps` partitions: their last-known rows are kept, `EngineRoot.syncGaps` is published ("Partly synced" in the toolbar), and only those partitions are retried while connected. `PartialResyncTests` checks that a missed approval appears after the retry with no reconnect and that an unread inbox keeps queued items. |
| C3 | Fixed with migration `v7-app-requests`. App requests are honoured by write routing, `rebuild()`, `replaceAllPending` (also when batches merge), the cache-write give-up (`StoreBatch.appOwned`) and session deletion. `AppRequestDurabilityTests` covers rebuild, write failure plus relaunch, and migration from a v6 file. |
| C6 | Fixed with migration `v8-app-outbox`. Entries are written before the first dispatch and settled on admission or refusal. They are restored at launch as cards, and the first resync checks the original ID. A not-sent entry stays until Edit in Composer or the new Discard. Launch attachment clean-up keeps referenced files. `OutboxTests` covers admitted-then-quit, never-admitted-then-retry and refused-then-relaunch-then-discard; there is also an attachment clean-up test. |
| C5 | Fixed. A short page reconciles every cached ID of the session up to the read time, and `StoreBatch.reconciledHistory` deletes rows with parts and FTS entries in one transaction. In-flight, admitted-during-read, outbox and newer rows are kept. `HistoryReconcileTests` covers a shortened tail and an emptied thread after relaunch, including search. |
| C9 | Fixed in part. App metadata updates are serialised per session. The plugin's settlement now re-reads metadata just before writing and changes only its own key. opencode 2.3.0 offers no version precondition, so a cross-process race with the plugin is narrowed, not closed. `MetadataSerializationTests` holds the first read and checks that both updates survive. |
| U3 | Fixed. `TerminalStream.send` returns sent/held/refused/ignored. Overflow refuses the whole input and everything after it, and held input is not replayed until the person chooses Send Held Input or Discard. The pane shows a bar, beeps on refusal and says "Input held" while reconnecting. `TerminalHeldInputTests` covers this against the mock PTY. |

**Unverified or left open.** C9 cross-writer atomicity needs a server merge or precondition primitive. During a session, the attachment store's write-time eviction still protects files only for its one-hour grace (launch clean-up honours the outbox). There is no on-screen check of the new "Partly synced", held-input or Discard UI (no screenshot permission). The C1 real-binary check covers the move/read-back contract, not a model-driven delegation.
