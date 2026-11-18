# BelloCode deep review

Reviewed develop at `6db276a` on 18 November 2026. References are relative to that revision.
This checkpoint records source traces. The verification ledger and module assessment are in progress.

## Executive summary

Keep the native rendering and single-server architecture. Hold enterprise rollout until the production entry points enforce the execution context the user selected.
Three paths let work start after an essential precondition failed. They cross the shell, Engine and bundled plugin, so testing each module in isolation misses them.

## Findings

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
