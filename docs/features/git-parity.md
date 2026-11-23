# Git parity with T3 Code

Status: done 2026-11-18 (Git parity package) on opencode 2.3.0, MockOpenCode, the fake GitLab and throwaway
repositories; nobody has checked it at the screen. Sources: T3 Code `main` (docs/user/source-control.md,
project-settings.md, composer.md; `GitActionsControl.logic.ts`, `BranchToolbar*`, `orchestration-v2/Checkpoint*`,
`ProjectCloneTracker.ts`), research 04 §5, §11–13, §23. Plan: **build**, **adapt** (GitLab / container / opencode), **drop**.

## Parity table

| # | T3 Code behaviour | BelloCode before → now (files) | Plan | Status |
|---|---|---|---|---|
| 1 | Workspace mode per thread (local / new / existing worktree), per-project default | `WorkspaceDraft`, `WorkspacePickers` | keep | done (M2-C) |
| 2 | Branch picker: paging, search, create & switch, remote branches | ≤ 300 rows → pages of 100 + "Show More", "Create branch … and switch to it" (`BranchPickerView`) | build | done |
| 3 | Base branch, start from origin | `WorkspaceDraft`; the fetch now authenticates (row 15) | keep | done |
| 4 | Worktree location; submodules recursive / top / skip | folder: `WorkspacePreferences.worktreeParent`; submodules never fetched | adapt: always skip (submodule URLs come from the repository and would make host git fetch any host) | adapted |
| 5 | Setup script on creation, setup card | runs in the project container (`setupRunner`) | keep | done (M6) |
| 6 | APFS copy-on-write checkout | `WorktreeService.cloneCheckout` (main checkout is the cache) | keep | done |
| 7 | Worktree handoff (local work → new worktree/branch) | `WorktreeService.handoff` (stash by hash, rolled back on failure); Git ▸ Move Changes to New Worktree… opens a thread there | build | done |
| 8 | Cleanup after settle / archive / merge, keep local changes | `WorktreeLifecycle.swift` `cleanupVerdict`; Git ▸ Remove Clean Worktrees When Settled/Archived; Undo toast | build | done (no "inactive days" timer) |
| 9 | Checkpoint per turn (hidden ref, untracked included) | `GitCheckpoints`: `refs/bellocode/checkpoints/<session>/<message>` via a temporary index, captured before each turn | build | done |
| 10 | Edit from here; "Revert files too" only when isolated | `Engine.planRewind/rewind`: files by compare-and-swap with Undo, then opencode `revert.stage files:false` + `revert.commit`; refused when another thread shares the folder | adapt | partial: Git ▸ Edit Last Prompt from Here… (no per-message button in the transcript) |
| 11 | Generated branch names | slug at once, then `Engine.renameGeneratedBranch` (session.generate) if unpushed and unused | adapt | done |
| 12 | Generated commit messages (repo conventions) | `GitTextGeneration.commitPrompt` + Generate in the commit form | adapt | done |
| 13 | Generated MR title/description | GitLab 1 create form | verify | done (GitLab 1) |
| 14 | Git actions control: quick action + menu with reasons | `GitActionPlanner` (port of `resolveQuickAction`), header button + ⌄ popover, Git menu, palette | build | done |
| 15 | HTTPS auth with the host's credentials | app-owned credential helper (below) | build | done |
| 16 | Confirm pushing to the default branch; force push | `GitActionsModel.push` alerts; force only with its own confirmation, `--force-with-lease` on the remote head the plan showed (`GitPushPlan.remoteHead`, v1.0.1 AF21) | build | done |
| 17 | Auto-pull default branch (ff-only, clean) | `GitRepositoryModel.backgroundFetch`; Git ▸ Automatically Pull Default Branch (off by default) | build | done (app-wide switch, saved; not per project) |
| 18 | Behind/ahead | fetch every 5 min while watched (ContinuousClock, backoff to 60 min), header crumb ↑↓, popover status line | build | done |
| 19 | Publish repository | `GitProjectService.publish`: `POST /projects` (private), HTTPS origin, `push -u` | adapt | done |
| 20 | Clone; project opens at once; send waits; retry | `GitProjectService.clone` + `GitCloneJob`; picker `GET /projects?membership=true`; `DraftComposerHost.send` waits | adapt | partial: no progress percentage (indeterminate); Retry is API-only, failure shown as a toast |
| 21 | SSH → HTTPS | owner chose HTTPS: SSH remote on a configured instance → "Switch Remote to HTTPS" (explicit) | adapt | done |
| 22 | New project from scratch | `GitRepository.initialise`, `GitProjectService.createProject` (Git ▸ New Project…, `~/BelloCode/Projects`) | build | done |
| 23 | Stash when switching with local changes | picker offers Stash and Switch; Git ▸ Restore Stashed Changes (by hash; index and working files restored and verified against the stash before it is dropped, else kept with a recovery ref, v1.0.1 AF05) | build | done |
| 24 | Conflict and detached-HEAD states | `GitStatus.operation`, conflicted files; planner disables with reasons; Abort Merge/Rebase… | build | done |
| 25 | MR auto-discovery, several links per thread | GitLab 1 | verify | done (GitLab 1) |
| 26 | Git status in header, sidebar, composer line | header + composer (M2-C); sidebar rows add `↑2 ↓1` / `⚠ Conflict` for loaded checkouts | build | done |
| 27 | Diff panel, review comments, open in editor | DiffKit | keep | done (M2-C) |
| 28 | Agent pushes with the host's credentials | `bellocode_app_git_push` (ExtrasHub+GitPush): card with remote, branch, commits; protected/default warning; separate force card | adapt | done |
| 29 | Remove agent credits on merge | — | drop: niche | dropped |
| 30 | Stacks, PR page, review guides, other forges, PR sharing | — | drop: GitLab-only; the review UI is another package's | dropped |
| 31 | Sparse worktrees | — | drop: no `t3.json` equivalent yet | dropped |
| 32 | ghq-style clone layout | default `~/BelloCode/<host>/<group>/<project>`, editable | adapt | done |

Counts (32 rows): 26 done (6 of them adapted to GitLab/opencode: 11, 12, 19, 21, 28, 32), 1 adapted with less scope (4),
2 partial (10, 20), 3 dropped (29–31). Shortcuts: ⌃⌘↩ suggested action, ⌃⌘G actions, ⌃⌘P push, ⌃⌘L pull, ⌃⌘R fetch.

## Final-check fixes (v1.0.1, `FinalCheckGitTests`, `FinalCheckRewindTests`, `GitShellFinalCheckTests`)

- **Commit-message context (AF01):** untracked files are read beneath the checkout without following links
  (`ConfinedDirectory`): a link is quoted as its text, as git commits it, and a file's size is checked on the open
  descriptor before any byte is read.
- **Pushes bound to their plan (AF06, AF21):** `GitPushPlan` carries the local commit and the remote head it showed.
  `push(_:force:)` re-checks branch, HEAD and the remote's push URL, then pushes the plan's commit to the remote by
  name with its push URL pinned for that one git process to the URL the plan showed (`GitRepository.pinnedPush`: the
  remote's URLs are reset and replaced by an unguessable placeholder that BelloCode's own `insteadOf` rule maps to the
  approved URL). The destination and the credentials git asks for are the approved ones even if the remote or an
  `insteadOf` rule changes meanwhile, and the URL is rewritten once, as `git remote get-url --push` showed it (v1.0.1
  AF06: re-passing the shown URL as a repository argument let a second rule redirect it). Settings scoped to the remote
  name (`remote.<name>.sslVerify`, `.proxy`, `.receivepack`) apply as in a terminal (GV10); for a GitLab remote the
  app's credential overrides still reset its proxy. Only the shown branch is updated: no tags (`--no-follow-tags`,
  `push.followTags` ignored), no configured push options, no mirror (AV08). A force push leases on the plan's remote
  head. A remote with several push URLs is refused. The agent's `git_push` card and the GUI confirmation both use it;
  there is no unbound force push.
- **Commit & Push (NF05):** a push failure after a successful commit is the action's error and a notice, not only in
  the closed form.
- **Rewind (AF19, AF20, NF12):** the shared-worktree guard compares canonical git working-tree roots (a thread in a
  sibling directory of the same checkout blocks a file restore), re-checked just before files are written; worktree
  cleanup uses the same check. Rollback and Undo act at the recorded restore root, not the session directory; a failed
  rewind Undo is shown with the affected path.
- **Stash restore (AF05):** a failed restore keeps the stash with a recovery ref and shows the recovery alert.

## HTTPS credentials

- **Helper:** `bellocode-exec --git-credential` (bundled). `HostGit` adds, for each exact HTTPS remote URL on a
  configured instance, `credential.<url>.helper=""` then the helper, and pins `http.<url>.sslVerify=true`, `proxy=""`,
  `curloptResolve=""`, `extraHeader=""`, `remote.<name>.proxy=""`. The overrides come last with maximal URL
  specificity, so a repository (writable from the container) cannot add its own helper for that URL (it would get the
  password on `store`), route it through a proxy, map the host or turn TLS checks off. The sandbox lets git execute
  the helper only for network operations.
- **Broker** (`GitCredentialBroker`, app process): Unix socket in a 0700 per-launch folder; a 32-byte one-shot grant
  per git launch, bound to the git process ID after launch, revoked at exit (≤ 10 min, ≤ 8 answers). It answers only a
  peer that descends from the granted process, only `https`, and only for the installation the request's host, port and
  repository path resolve to (most specific path prefix; git sends the path via `credential.<url>.useHttpPath`) when the
  grant was made for it; no path or an ambiguous match gets no answer. The token is read from the Keychain per request. `erase` (GitLab refused the token) becomes "GitLab rejected your token…".
- **Never** in arguments, environment (only the grant ID and socket path, in that git's own environment), `.git/config`,
  remote URLs, logs, the store, transcripts, opencode's shim or containers. Tested: `GitCredentialTests` (9, against
  `git http-backend` behind an in-process TLS server with a throwaway CA), `HostGitIsolationTests` (matrix with the
  helper present), `GitPushToolTests`.
- **Scopes** (docs.gitlab.com/user/profile/personal_access_tokens: "To clone, fetch, and pull, use a token with the
  read_repository scope. To push, use a token with the write_repository scope. The api scope also grants these
  permissions."): `read_repository` + `write_repository`, or `api`. `read_api` is not enough; known scopes are checked
  before a fetch or push (`GitTokenScopes`). Settings ▸ GitLab suggests `https://gitlab.novacoast.com`.

## Verification

`make test` three times; new suites: `GitCredentialTests`, `GitActionPlannerTests`, `GitWorkflowTests`,
`GitCheckpointTests` (concurrent edit before and during a restore), `GitProjectTests` (clone-while-typing, retry,
publish, handoff, cleanup), `GitPushToolTests`, `GitActionsModelTests`, hostile matrix + helper. Opt-in real binary:
`BELLOCODE_GIT_REAL=1 swift test --filter GitParityRealBinary` (checkpoint before the turn, generated commit message
"add launch checklist", branch "bellocode/add-launch-checklist-docs", conversation rewind with file restore and Undo;
5 short runs on the free default model). Snapshots: `.build/debug/BelloCode --snapshot git` (14);
`docs/snapshots/git-{actions-menu-dark,branch-create-light,commit-push-dark,behind-ahead-light,rewind-dark,clone-light}.png`.

## UX checklist (03 §E, agent, no human at the screen)

Context: every surface names the branch; header shows project / branch ↑↓ · worktree; push cards name remote and
branch. States: clean, dirty, ahead, behind, diverged, no upstream, no remote (Publish), detached, merge/rebase stopped,
fetch failed (kept status + reason), cloning / failed / cancelled, generating. Keyboard: every action is a Git menu
item; popovers move with arrows, Return, Escape; ⌘↩ commits. Accessibility: glyph + word everywhere ("↑1 to push",
"Merge in progress"), disabled rows say why; VoiceOver not run. Safety: default-branch and force pushes confirmed;
rewind confirmed (permanent in opencode), file restore with Undo and compare-and-swap; worktree cleanup only clean and
pushed/merged with Undo. Not exercised: two windows, 30 sessions, Reduce Motion (nothing animates), real trackpad.

## Needs the real gitlab.novacoast.com

TLS chain and proxy behaviour for git (`http.sslVerify` stays on; an enterprise CA must be in the system trust
store), token introspection of the scopes, `can_push`/`protected` on branches for the actual roles, `POST /projects`
in the person's namespace, clone speed of large repositories, and Keychain prompts on a signed build.
