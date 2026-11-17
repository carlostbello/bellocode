# Diff panel, git and worktrees (M2-C)

Status: done 2026-11-16 against opencode 2.3.0, MockOpenCode and throwaway git repositories. Nobody has checked it at the screen yet.

## Architecture
- **OpenCodeKit** `HTTP/OpenCodeClient+VCS.swift`, `DTO/VCS.swift`: `/api/vcs`, `/vcs/base|status|branch|diff`, `/api/worktree` (list, create, remove, refresh), `/api/session/{id}/diff`, `…/revert/stage|commit`, `DELETE …/revert`, plus `OpenCodeError.worktreeError`. **MockOpenCode** `VCSRoutes.swift` serves the same shapes (scripted repositories, turn diffs, reverts, worktrees).
- **Engine** `Git/`: `GitRunner` runs git off the main actor. Both pipes are drained, output is bounded, there is a timeout, cancellation kills the process, and git runs with `GIT_TERMINAL_PROMPT=0` and `GIT_OPTIONAL_LOCKS=0`. The other pieces:
  - `GitStatusParser`: porcelain v2 and numstat.
  - `UnifiedPatchParser` and `HunkApplier`: a hunk applies only on an exact match at its line, or at the nearest unique match within 300 lines. A stale or ambiguous hunk throws.
  - `WorkingCopy`: all-or-nothing writes with Undo snapshots. Each file is replaced by a compare-and-swap
    (`renamex_np` with `RENAME_SWAP`/`RENAME_EXCL`, then a comparison of the bytes swapped out), so an edit saved after
    the preflight check is never overwritten: the revert fails with the file left as the other writer saved it. Rollback
    and Undo use the same check and restore exact bytes and permissions or refuse. Limit: a writer that keeps the old
    file open and writes into it in the microseconds between the swap and the comparison cannot be serialized without
    its cooperation.
  - `GitRepository`: status, branches, commits, diffs, stage, commit, push, worktree list and the GitHub compare URL.
  - `WorktreeService`: create, with APFS `clonefile` copies and a setup script; remove; restore.
  - `GitService` (`engine.git`): bounded per-directory `GitRepositoryModel`s with FSEvents watching (250 ms debounce, coalesced refreshes, generation checks), workspace preferences (`app_preference`, so no migration) and turn revert.
- **DiffKit**:
  - `Model/`: `LineDiff` is linear-space Myers that first discards lines unique to one side (GNU diff's step), with a cost budget; past the budget the region is shown as replaced. `IntraLine` gives word ranges (bounded: ≤2,000 UTF-16 units, ≤600 tokens, ≤60 % changed). `DiffRowBuilder` builds one row model for unified and split (aligned pairs, expandable gaps, stable `DiffRowID`s). `DiffSyntax` reuses TranscriptKit's public `HighlightService`, one side at a time, capped at 1.5 MB.
  - `View/`: `DiffContentView` is a CoreText row view drawing only dirty rows, with a bounded CTLine cache, a horizontal offset shared by both sides, wrap by columns, selection within one side, find highlights and accessibility rows. `DiffViewController` builds rows off the main actor, keeps the first visible row anchored, and owns the find bar, hunk/file navigation and the comment popover.
  - `Changes/`: `ChangesModel` (scope, loading, revert, stage, commit, push), `ChangesPanelController`, `FileTree`, `EditorLauncher`.
  - `Workspace/`: `WorkspaceDraft` and the workspace and branch pickers (SwiftUI popovers with search, arrow keys, Return and Escape).
- **App**:
  - `Content/ChangesSurface.swift`: one panel per window; a model per thread (16 kept); reloads when a turn ends.
  - `Shell/MainWindowController+Changes.swift`: the commands.
  - The draft composer gets the two pickers; the header and composer context line show branch, workspace and dirty/↑/↓ state.

## What goes through opencode, what goes through git, and why
- **opencode**: the comparison base (`vcs.base`: reflog or default branch), branch diffs (`vcs.diff mode=branch`), per-turn diffs (`session.diff`; without `context` each patch is the whole file, so both texts are rebuilt and re-diffed locally to allow context expansion), turn revert (`revert.stage files:true`, Undo through `DELETE …/revert`), and adopting worktrees (`worktree.refresh`).
- **git directly**:
  - Status: opencode's status mixes staged, unstaged and untracked and has no upstream or ahead/behind.
  - Stage, commit and push: no opencode endpoints.
  - Per-commit diffs and the branch list (opencode returns names only and no remote branches).
  - **Worktree creation**: verified on the binary, `POST /api/worktree` always checks out a *detached* HEAD in a randomly named folder. It cannot create a branch, start from a chosen base or from origin, or clone copy-on-write. BelloCode runs `git worktree add -b` itself, then `refresh`, which opencode adopts (tested). The setup hook runs the project preference, otherwise opencode's `commands.start`.
- **Measured on 2.3.0**: `revert.stage files:true` and `DELETE …/revert` both overwrite whole files and lose edits made after the turn. So turn revert first compares each file with the turn's end state. Files edited since then bring up a choice: "Revert Agent Changes" (reverse the turn's own hunks, keeping later edits; a stale hunk fails with nothing written) or "Restore Files". Undo always writes back the exact earlier bytes.

## Behaviour
- **Scopes**: This Turn (pick any turn), Branch vs base, Uncommitted (HEAD → working tree, with per-file staged and unstaged checkboxes), Commit (newest 100).
- **Revert**: menu titles state the scope ("Discard Uncommitted Changes to X", "Revert This Turn’s Changes to X"). Revert hunk, file or turn apply at once with Undo (toast and ⌘Z). The only confirmations are removing a worktree that holds files of its own, and turn revert when files changed after the turn.
- **Removing a worktree**: "clean" means no uncommitted, untracked *or ignored* files (`WorktreeService.contents`; ignored folders count once). A clean worktree is removed at once with Undo. Otherwise the confirmation names the counts and up to five paths (`.env`, `build/`); on confirmation those files are moved to the Trash in a folder named after the worktree (`RemovedWorktree.heldContents`), and Undo re-checks out the branch and moves them back byte for byte (staged changes come back unstaged). If the Trash was emptied meanwhile, Undo restores the checkout and says the files are gone. Redo repeats the confirmed removal.
- **Commands** (Changes menu): Show Changes ⇧⌘D, Next/Previous Change ⌃⌘↓/↑, Next/Previous File ⌃⌘→/←, Add Review Comment ⇧⌘K, Open in Editor ⌘O, Choose Workspace ⇧⌘E, Choose Branch ⇧⌘B. Revert Hunk/File/Turn, Commit, Push, Open Pull Request, Side-by-Side, Ignore Whitespace, Wrap Lines and Remove Worktree have no shortcut.
- **Keys in a focused diff**: n/j and p/k move between hunks, ]/[ between files, c comments, ←/→ scroll long lines, ⌘F/⌘G/⌘E find, ⌘C copies, Escape closes find.
- **Review comments**: ComposerKit has no review-comment chip, so a comment becomes a named text attachment chip ("Review path:12–14.md") with the quoted lines.
- **Shared shell files**: additive, grouped edits only:
  - Seams: the Changes tab and `DraftThreadOptions.directory`.
  - ShellCommand: one block of cases plus `ChangesCommandState`.
  - MainMenu: the Changes menu.
  - MainWindowController: six hooks.

## Measured
Release build on an M5 Max at 165 Hz (6.06 ms frames), window 1200×900, `.build/release/DiffDemo --bench`. Each scenario scrolls the whole document down and back at 60 pt per frame. Reports are in `docs/features/diff-bench/`.

| Scenario | Rows | Build | Frames p50/p99 | >33 ms run 1 / run 2 | Worst draw |
|---|---|---|---|---|---|
| 10,000 changed lines, unified | 29,898 | 16–29 ms | 6.1 / 6.1–16.7 ms | 2 / 0 | 5.1 ms |
| 10,000 changed lines, split | 20,002 | 33 ms | 6.1 / 6.1 ms | 0 / 0 | 3.3 ms |
| 10,000 changed lines, wrapped | 29,898 | 26 ms | 6.1 / 6.1–8.3 ms | 1 / 0 | 5.2 ms |
| 100,000-line file, unified | 100,003 | 43–48 ms | 6.1 / 6.1 ms | 0 / 1 | 3.3 ms |
| 100,000-line file, split | 100,003 | 48–51 ms | 6.1 / 6.1–16.7 ms | 0 / 14 | 2.8 ms |

The >33 ms frames move between scenarios from run to run, and our draw time never exceeded 5.2 ms. They include display-link gaps of 24 s and 35 s, which means the display stopped delivering frames. They are not explained by the diff view, but they are not ruled out either: they need a run with the screen unlocked.

Other measurements:
- Line diff of 20,000 lines with 10,000 changed: 48 ms in a debug build (6.7 s before discarding).
- Corpus check against git: 120 seeded pairs give the same counts as `git diff --minimal`, every one of our patches applies with `git apply`, and hunk headers match git exactly.
- Worktree with copy-on-write: 300 files cloned, clean status, about 0.9 s for the whole test in debug.

## Verification
`swift test` passes for all suites. New tests:
- OpenCodeKit `VCSClientTests`.
- Engine `GitParsingTests`, `GitRepositoryTests`, `GitServiceTests`, and `GitRealBinaryTests` (real 2.3.0: VCS endpoints, worktree adoption, a session in a worktree, `WorktreeError.forceRequired`, turn diff and revert shapes).
- DiffKit `LineDiffTests`, `DiffRowTests`, `ChangesModelTests`.
- App `ChangesShellTests`.

`make app` and `make smoke` pass. `.build/debug/DiffDemo --snapshots` writes 20 PNGs; six are in
`docs/snapshots/diff-*.png`. App states: `BELLOCODE_SNAPSHOT_STATES=draft,changes,changes-split .build/debug/BelloCode --snapshot app` (`docs/snapshots/diff-app-changes-dark-1280x800.png`).

## Section E checklist (agent, no human at the screen)
- **Purpose and context**: pass. The header and composer show project, branch, Local checkout or Worktree, and dirty/↑/↓; the status line names the scope and base; revert titles name the scope.
- **States**: pass by test or snapshot for empty (per scope), loading, stale ("Updating…", content kept), offline or failed (message plus last content), not a repository, binary, image, large file, preparing a worktree, and failure.
- **Speed**: rows are built off the main actor (16–51 ms); a cached model shows at once when switching threads.
- **Keyboard**: every action has a menu item; the pickers work by keyboard; driven programmatically only.
- **Accessibility**: statuses are a letter plus a word (+/− markers, "Added", "Staged"). Every row of the diff is a
  virtual accessibility element (`DiffContentView+Accessibility.swift`), not only the drawn ones: the list reports all
  rows through the ranged children API (count, index range, index of child), lists every row directly for documents up
  to 2,048 rows and the rows around the viewport beyond that, and makes elements on demand (bounded cache of 4,096,
  dropped on each rebuild). Labels give file headers (path, status, counts), change headers ("Change 3: @@ …"), and
  lines (added/removed/unchanged, line number, text; old and new in split). Focusing an element scrolls it into view.
  Drawn controls are actions: file header press toggles it; gap press shows 20 more lines, with a "Show All Lines"
  action; "Revert Hunk" on change headers of revertable files; "Add Comment" on lines. After an action, the new state
  is announced once and focus moves to the element for the acted-on row. Tested through the accessibility API in
  process; VoiceOver itself (rotor, VO-arrow traversal through the ranged API, speech) is unverified.
- **Artifacts and safety**: pass. Hunk revert after a manual edit fails explicitly (test); turn revert keeps or explicitly replaces later edits; Undo restores exact bytes.
- **Persistence**: diff options and workspace defaults persist. The panel's scope is not restored after relaunch.

## Known gaps
- Branch-scope and commit-scope diffs show only hunks (no full texts, so no context expansion).
- Wrapping assumes one column per character, so CJK text wraps late.
- The setup script and worktree folder have no settings UI (preferences API only).
- "Generate message" is a plain default (the file names).
- Comment marks are not saved.
- Push uses the user's git credentials without prompting; a push that needs authentication fails with git's message.
- The image placeholder has no preview.

## Needs a human at the screen
- Scroll feel and frame pacing with the display unlocked (the >33 ms gaps above).
- Trackpad horizontal scrolling and drag selection with autoscroll.
- Popovers' focus.
- VoiceOver.
- Opening files in real editors.
- Push and Open Pull Request against a real GitHub remote.
- Copy-on-write speed on a large repository.
