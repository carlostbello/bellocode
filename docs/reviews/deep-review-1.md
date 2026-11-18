# BelloCode deep review

Reviewed develop at `6db276a` on 18 November 2026. References are relative to that revision.
Scope includes the shipping Swift targets, their test seams, the bundled TypeScript plugin, build inputs and packaging. S/M/L denote a local fix, a cross-component change and a staged refactor respectively.

## Executive summary

**Hold enterprise rollout.** The app can archive a project by deleting its persistent container home, and a warm launch can replace saved execution restrictions with defaults. Both behaviors were observed at the service boundary using in-memory fixtures. These are release blockers even for a single internal user.
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

File and type columns are independent rankings. Primary declaration spans include comments/nested members through the closing top-level brace, exclude extensions and are a lower bound on total responsibility. The long mock catalog is fixture data. The same line count in EngineCore has very different maintenance costs.
Swift normally imports modules. Counting import statements gives BelloCore 133, Engine 83, DesignSystem 78 and OpenCodeKit 37. For type fan-in, counting distinct *other* files mentioning a uniquely named top-level type/alias outside imports and line comments gives DS 86, SessionID 76, Engine 33, MessageID 32, Timestamp 28, DSButton/DSDraw 24 each, Message/Session 23 each, ProjectionStore 22, OpenCodeClient/MainWindowController 20 each. This is a lexical proxy, not compiler symbol resolution.

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

## 4. Security and execution isolation

**S1 · major · Production can select an unconfined backend (S).**
`Sources/BelloCodeApp/Launch/AppRuntime.swift:57` accepts an environment-selected endpoint before building the supervised configuration.
`Sources/Engine/EngineConfiguration.swift:15` accepts any URL with a scheme. The attached branch uses the ordinary projection database, default vaults and no container configuration.
A developer's inherited override therefore changes where normal app work executes and which server reconciles the user's existing cache.
In that branch, the missing setup runner falls through to host zsh (Sources/Engine/Presentation/Engine.swift:172 and Sources/Engine/Git/WorktreeService.swift:299). Compile attachment into a development harness with a separate data namespace. Require the bundled supervisor and helper in the distributed executable.

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
`Scripts/opencode-checksums:7` records an Intel archive hash but no Intel executable hash. The binary_ok test in `Scripts/fetch-opencode.sh:52` accepts executability alone when that second hash is absent. This also affects an already-populated Vendor directory.
The verified archive route is stronger. The ripgrep fallback at `Scripts/fetch-opencode.sh:168` permits a local executable or missing helper, and `Scripts/make-app.sh:58` will still package/sign. A signature authenticates what this build packaged.
Require verified executable digests and portable dependencies for every shipping architecture, verify any cached helper just before signing, and keep the permissive fallback solely in a clearly marked developer build. Test an unrecognized cached helper without executing it.

**D3 · minor · Acknowledgements omit bundled notices (S).**
`Scripts/make-app.sh:67` copies one license per Swift package. The generated bundle contains seven such texts. The resolved h, swift-png and swift-markdown checkouts also contain NOTICE files. opencode and ripgrep appear in `Sources/BelloCodeApp/Settings/Acknowledgements.swift:40` but have no corresponding text in the assembled bundle.
T3 Code's embedded MIT notice is present. Include required notices and binary release attributions from the exact shipped artifacts, track transitive components and validate bundle contents as a packaging test.

**D4 · suggestion · Isolate Rancher discovery from the Docker capability decision (S).**
`Sources/ContainerKit/Runtime/RuntimeDiscovery.swift:117,135,158` relies on the 1.25 product layout, a home-relative socket, app plist and containerEngine.name. A config value can reject access before the supported Linux Engine API is probed.
A settings rename or stale value can misclassify an otherwise supported engine. Prefer version/ping/API compatibility on the selected socket as authority and use product configuration for remediation hints. Retain API 1.44 floor and fail closed on unsupported capabilities.
