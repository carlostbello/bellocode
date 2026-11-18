# Git parity with T3 Code

Status: in progress (Git parity work package, 2026-11-18). Source: T3 Code `main` (docs/user/source-control.md,
project-settings.md, composer.md; `GitActionsControl.logic.ts`, `BranchToolbar*`, `WorktreeBaseBranchPicker`,
`orchestration-v2/Checkpoint*`, `project/ProjectCloneTracker.ts`), research 04 §5, §11–13, §23.
Plan column: **build**, **adapt** (GitLab / container / opencode instead of T3's mechanism), **drop** (reason).
Status column: **done**, **partial** (what is missing in the cell), **not done**.

## Parity table

| # | T3 Code behaviour | BelloCode before this package | Gap | Plan | Status |
|---|---|---|---|---|---|
| 1 | Workspace mode per thread: local / new worktree / existing worktree, per-project default | `WorkspaceDraft`, `WorkspacePickers` (DiffKit), `WorkspacePreferences` | none | keep | done (M2-C) |
| 2 | Branch picker: paginated list, search, create & switch, remote branches | `BranchPicker` lists ≤ 300, creates in local mode | no paging; create only from the draft | build: "Show more" paging, create-and-switch from the git actions menu too | |
| 3 | Base branch + start from origin for new worktrees | `WorkspaceDraft.baseBranch`, `startFromOrigin` (fetch is now authenticated, row 15) | none | keep | done (M2-C) |
| 4 | Worktree location (custom folder), submodules recursive / top level / skip | `WorkspacePreferences.worktreeParent`; submodules never initialised (`submodule.recurse=false`) | no submodule policy | adapt: policy `skip` (default) / `topLevel`; `recursive` dropped: submodule URLs come from the repository and would make host git fetch arbitrary hosts | |
| 5 | Setup script on worktree creation, "Preparing worktree" card | runs in the project container (`setupRunner`), failure shown in the picker | none | keep (container only, never host) | done (M6) |
| 6 | APFS copy-on-write fast checkout | `WorktreeService.cloneCheckout` (`clonefile`) | T3 keeps a cache of checkouts; we clone the main checkout when HEAD = base | keep; no cache (the main checkout is the cache) | done (M2-C) |
| 7 | Worktree handoff: move a local thread into a new worktree/branch, carrying uncommitted work | none | missing | build: `WorktreeHandoff` (stash-free: patch + untracked copy, source left clean only on success) | |
| 8 | Worktree cleanup: after settle / archive / merge / unchanged, keep-with-local-changes, report | manual "Remove Worktree…" with Trash + Undo | no policies | build: `WorktreeCleanupPolicy` evaluated on settle/archive; never removes dirty or unpushed worktrees | |
| 9 | Checkpoints: hidden ref per turn (working tree incl. untracked) | opencode snapshots only (whole-file restore, loses later edits) | missing | build: `refs/bellocode/checkpoints/<session>/<message>` via a temporary index | |
| 10 | Edit from here: rewind conversation; "Revert and keep changes" / "Revert files too" (isolated worktree only) | none (turn revert of files exists, not conversation rewind) | missing | adapt: opencode `revert.stage files:false` + `revert.commit`; files restored from our checkpoint with compare-and-swap writes; refused when another thread shares the directory | |
| 11 | Generated branch names from the first prompt (static prefix / semantic prefix / instructions) | `WorktreeService.slug(prompt)` with `bellocode/` prefix | no model naming | adapt: temp slug at once, then `session.generate` proposes a name; rename only if still unused | |
| 12 | Generated commit messages (repo conventions or custom instructions) | "Update a, b" from file names | no model text | adapt: `session.generate` with staged diff stat + recent subjects | |
| 13 | Generated PR/MR title and description (uses the thread's work) | GitLab 1 `CreateMergeRequestModel` uses `session.generate` | none | verify parity | done (GitLab 1) |
| 14 | Git actions control: quick action + menu (Commit, Commit & push, Push, Pull, Push & create PR, Sync, Publish) with disabled reasons | Changes footer: Commit, Push, Create MR (no Pull/Fetch/Sync, no quick action) | menu, quick action, reasons, pull, fetch, sync | build: `GitActionPlanner` (port of `resolveQuickAction`), header button + Git menu + palette | |
| 15 | HTTPS auth from the host's credentials | git used the person's own helpers; push needing auth failed | no token-based HTTPS | build: app-owned credential helper (Step 2 below) | |
| 16 | Confirm before committing/pushing to the default branch | none | missing | build: confirmation names branch + remote | |
| 17 | Auto-pull default branch (fast-forward only, clean checkout) | none | missing | build: `GitSyncScheduler` fetch on ContinuousClock with backoff; ff-only pull when clean and opted in | |
| 18 | Behind/ahead indicators | header/composer show ↑/↓ from status (no fetch, so ↓ stale) | stale behind count | build: periodic authenticated fetch (row 17) | |
| 19 | Publish repository (create hosted repo, add origin, push) | none | missing | adapt: GitLab `POST /projects` (private by default, namespace picker), `origin` = HTTPS URL, push | |
| 20 | Clone: pick host or paste URL; project opens at once, clone in background, first prompt typed while cloning, send waits; progress, cancel, retry | none | missing | adapt: GitLab project picker (`GET /projects?membership=true`), HTTPS clone with credential helper, `CloneTracker` gates send | |
| 21 | SSH → HTTPS fallback | none | missing | adapt: owner chose HTTPS: detect SSH remote on a configured instance, explicit "Switch Remote to HTTPS" | |
| 22 | New project from scratch (git init, README, first commit, optional publish) | none (Add Project picks a folder) | missing | build: `ProjectScaffold` + optional publish (row 19) | |
| 23 | Stash handling when switching branches with local changes | `git switch` refuses; message shown | no choice offered | build: prompt "Stash and Switch" / "Bring Changes" / Cancel; named stash `bellocode: <branch>`, applied by SHA | |
| 24 | Conflict and detached-HEAD states shown honestly | header shows short SHA for detached; conflicts not distinguished | conflict state missing | build: status reports merge/rebase in progress + unmerged files; actions disabled with reasons; Abort Merge/Rebase | |
| 25 | PR/MR auto-discovery and several links per thread | GitLab 1: branch MR discovery, multi-link, chips | none | verify parity | done (GitLab 1) |
| 26 | Git status in header, sidebar and composer context line | header + composer (branch, kind, dirty ↑↓) | sidebar row has no git state; no conflict/behind wording | build: sidebar shows branch + ↑↓/conflict glyph+word for worktree threads | |
| 27 | Diff panel: turn / branch / commit, file tree, inline comments, open in editor | DiffKit (M2-C) | none | keep (another package adds GitLab review threads) | done (M2-C) |
| 28 | Agent git through the host's credentials (`gh pr create`, `git push` in the agent's shell) | agent shell runs in the container with no credentials | push path for agents | adapt: `bellocode_app_git_push` tool, host push behind an approval card (remote, branch, commits, force; protected branch warning) | |
| 29 | Remove agent credits on merge | — | — | drop: niche (research 04) | dropped |
| 30 | GitHub stacks, PR page, review guides, other forges, PR sharing across environments | — | — | drop: GitLab-only scope; PR page is the GitLab review package's | dropped |
| 31 | Sparse worktrees (`worktreeSparsePatternsPath`) | — | — | drop: no `t3.json`; reconsider on request | dropped |
| 32 | ghq-style clone layout | — | — | adapt: clone destination defaults to `~/BelloCode/<host>/<group>/<project>`, editable | |

## Credential design (Step 2)

See "HTTPS credentials" below; summary of the guarantees is kept with the implementation (`GitCredentialBroker`).
