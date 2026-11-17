# Navigation: sidebar organisation, palette, search, notifications (M2-D)

Status: done 2026-11-16 against MockOpenCode (bundled 2.3.0 for `make smoke`). Not yet checked by a person.

## Sections and wake rules (`Engine/Organisation/ThreadSections.swift`, pure, injected clock)
- Every top-level, unarchived thread is in one section: **Pinned** (wins over everything) → **Snoozed** (until its
  time) → **Settled** → **Working** (running, stopping or status unknown) → **Active** (everything else). "Needs You"
  stays at the top across projects (engine attention list; snoozed/settled hide only non-blockers).
- Order never reshuffles while agents work: Pinned and Active by a manual key (default creation time, newest first;
  drags write a key between the neighbours, renumbering only when no room is left); Working by run start, oldest
  first (new runs join at the end); Snoozed by wake time; Settled by settle time, newest first.
- Wake: a snooze ends at its time, or early when the thread is blocked (approval, question), fails, or starts a run
  after it was snoozed. A settled thread un-settles when blocked, failed, a new run starts or a run finishes after it
  was settled. Wakes are persisted (the thread returns to the top of Active), so a resolved blocker never re-hides it.
- Auto-settle (Settings ▸ Threads, default 7 days; 1 h … 7 d or Never; per-thread "Never Auto-Settle"): only a thread
  whose last turn finished, seen, not pinned, unread, snoozed or blocked, after N hours since both the run ended and
  the last view. The engine runs the rules on every attention change and on a timer armed for the next deadline
  (at least hourly).
- State: `ThreadOrganisation` in `app_thread` (pinned, sort key, snoozed until/at, settled/at, never auto-settle,
  marked unread). **Migration `v4-thread-organisation`** adds five columns (tested from a v3 database). Published on a
  new `.organisation` topic (`engine.root.organisation`); `ShellState` gained grouping, section expansion, sidebar
  scroll anchor and per-thread panel state (bounded; M1 state still decodes).

## Sidebar (`Sidebar/`)
Projects → sections → threads (or "All Threads by State"); filter field (⌥⌘F; titles fuzzy, project name keeps all
its threads); ⇧/⌘-click and ⇧-arrows multi-select, and every organisation command acts on the selection. Pin, settle,
snooze (Later Today / Tomorrow / Next Week / Custom… popover), wake, archive, delete, mark unread, never auto-settle:
immediate, 5-second Undo toast and ⌘Z/⇧⌘Z. **Delete is deferred** and app-wide (`PendingThreadDeletions`, one per
engine): hidden at once in every window (a window showing the thread moves to a neighbour), Undo offered in every
window (toast and ⌘Z; Undo in any of them restores it everywhere and retires the others), sent to opencode exactly
once when the Undo window ends, when the last window closes, or at quit, which waits for the results before stopping
the engine (a failure shows the row again with a notice, or a quit alert when no window is left); after sending it
leaves the undo stacks. Drag and drop: rows within a section
reorder, between sections change state (badge says Pin / Unpin / Settle / Un-settle / Wake / Snooze until …), Working
refuses ("follows the agent"), another project refuses ("Threads stay in their project's folder"), projects reorder
(pinned stay above). Insertion gap with rows sliding aside (`.gap`; plain line under Reduce Motion); structure changes
apply as remove/insert of only the moved rows, animated only after a menu action, never after a drop, an engine
update or under Reduce Motion. Settled and Snoozed are collapsed by default; expansion and scroll restore.

## Palette (`Palette/`)
One borderless key `NSPanel` per window, built with the window (no animation). ⌘K actions first; ⌘P threads,
projects and files of the current project; ⇧⌘F message search. Prefixes `>` actions, `@` threads, `#` projects,
`/` files. Every `ShellCommand` is listed with its shortcut, or "Unavailable" and the reason in the footer. Ranking:
fuzzy (word starts, runs, prefixes, synonyms) + frecency (persisted, 1,000 keys) + the pick remembered per query for
3 weeks; fixed group order and deterministic tie-breaks, selection kept while typing; server results (files,
messages) replace earlier ones only when they arrive, filtered locally meanwhile (no flicker, no spinner). Return
opens; ⌘↩ opens in the background (thread/project/hit: a new window behind; file: without switching apps; action:
runs and stays open); Escape returns focus where it was.

Search: `Engine.searchMessages` (FTS5) grouped by top-level thread, ≤3 hits with "N matches", project and date; a hit
opens its thread, `TranscriptController.restore(anchor:)` brings the message up and find highlights the term (existing
public API; no TranscriptKit change).

## Shortcut decisions
⌘K is shared, focus-aware: Command Palette is disabled while a terminal has focus, so ⌘K reaches Clear Terminal there
(Terminal.app's key); Clear Terminal is enabled only with terminal focus. The Go menu precedes Terminal, so the menu
resolves ⌘K to the palette elsewhere. The uniqueness test now allows only this pair and checks no context enables
both; a model of NSMenu's key resolution is tested both ways. From a terminal, ⌘P then `>` opens actions. Others:
⌘P Quick Open, ⇧⌘F Search Messages, ⌘[ / ⌘] Back / Forward (free; ⌥⌘[ ] stay with requests), ⇧⌘T Reopen Closed
Thread (archived, deleted within its Undo window, settled or snoozed while shown), ⇧⌘N New Window, ⇧⌘P Pin, ⇧⌘S
Settle, ⌥⌘S Snooze Until…, ⌥⌘F Filter Threads. Delete Thread (⌥⌘⌫) no longer asks.

## Notifications (`Attention/`, `NotificationPolicy` pure)
A notification is a new "Needs you" entry (approval, question, failure, unseen completion), keyed by thread + status +
since, posted once (never per token or tool call; first evaluation at launch only learns). Blockers notify unless that
thread is on screen in the active app; completions only while the app is in the background. Modes all / blockers
only / off, sound for blockers, per-project mute, bursts of more than 3 become one summary, grouped by project
(`threadIdentifier`). Resolved entries are removed from Notification Center. Authorization is requested at the first
agent run, not at launch; Settings shows the state with "Allow…" or "Open System Settings…". Outside an app bundle
(`swift run`, tests) or in mock mode delivery is off and Settings says so. Approvals offer Allow Once / Deny only
when the operation is one resource, one line, ≤120 characters (`NotificationActionSafety`); Allow requires
authentication, is never "always", and replies only if that request is still pending (else the thread opens). Dock
badge = approvals + questions + failures. The window subtitle adds "N need you". Optional menu-bar item lists Needs
You (status in words, project, age).

## Windows and restoration
⇧⌘N opens another window with its own selection, history, undo and layout, sharing the Engine. The first window keeps
the M1 state key; others are listed and reopen after relaunch only when the system "Close windows when quitting" is
off (closed ones are forgotten). The first window always restores its thread, drafts, panes, sidebar expansion and
scroll, per-thread right panel and transcript anchor (UX rule 9). Back/forward history: 50 entries per window.

## Measured (debug build, this Mac; `NavigationPerformanceTests`: 2,000 threads, 4,018 sidebar rows)
Palette open p50 35.8 ms (max 50) incl. sources for 2,000 threads; keystroke-to-results p50 2.9 ms, p95 5.9 ms.
Sidebar: one thread changing section p50 18.8 ms; full rebuild after a filter 100 ms; scroll step p95 4.8 ms.

## Verification
`swift test` passes: Engine `OrganisationTests` (sections, wakes and auto-settle on an injected clock, presets,
relaunch, timer wake, migration v3→v4, frecency, fuzzy, search mapping, policy); `NavigationLogicTests` (tree diff,
drops, ranking, ⌘K resolution, restoration, window restore) and `NavigationWindowTests` (real sidebar, palette, search
reveal, deferred delete, history, filter, panels, notifier with Allow Once) on the mock. `make app`, `make smoke` pass.
Snapshots: `.build/debug/BelloCode --snapshot nav` (48 images); eight in `docs/snapshots/nav-*.png`.

## Section E checklist
Pass: purpose/context, states (empty, no match, offline files, searching, failure toasts), speed, keyboard (menus,
palette keys, ⇧-arrows; drag has menu equivalents), parallelism (2,000 threads), approvals (safe inline), persistence,
two windows. Not run: VoiceOver (labels and announcements exist), separate displays, localisation.

## Known gaps / needs a human at the screen
Real drag and drop (gap animation, badge position, project reorder); notification delivery, actions and grouping in a
signed build (ad-hoc builds may be refused: the Settings state shows it); VoiceOver and Reduce Motion; menu-bar item.
The flat list cannot reorder across projects; wake compares
server run times with the local clock; Redo of an undone delete lives only in the window that undid it;
`ShellState.manualUnread` is legacy (engine-owned now); full sidebar rebuild (filter cleared) is 100 ms at 2,000.
