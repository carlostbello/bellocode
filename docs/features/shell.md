# Window shell, sidebar and app wiring (M1-B)

Status: done 2026-11-16 against MockOpenCode and opencode 2.3.0 (one short prompt per run on `opencode/big-pickle`).

## What exists
- **Launch** (`Launch/`): `AppRuntime` = engine + server. `--mock [demo|large]` runs an in-process MockOpenCode with a
  temp cache and a separate defaults suite; `BELLOCODE_SERVER_URL/_PASSWORD` attach; else the bundled
  `Contents/Helpers/opencode` under `ServerSupervisor` (data in `~/Library/Application Support/BelloCode/opencode`,
  cache `…/BelloCode/projection.sqlite`). Window shows first, `engine.start()` shows cache, then connects. Quit waits for
  `engine.stop()` (child exited). `--smoke-test` (supervisor + engine until live, 401 check, no child left).
  `--snapshot <name>` renders PNGs to `build/snapshots/` (empty, thread with approval, panels, draft; light/dark).
- **DesignSystem**: `DS.Palette` (system dynamic colours, accent, contrast), `DS.Typography(baseSize:)`,
  `DS.Spacing`/`DS.Radius` (24 pt rows), `DS.Motion` (panels 0 ms, Reduce Motion), `StatusGlyph`/`StatusLabel`,
  `CountBadge`, `MonogramView`, `SidebarRowView`, `EmptyStateView`, `UndoToastView`, `ToolbarButton`, `RelativeTime`.
- **Window**: `MainSplitViewController` (sidebar | `ContentSplitViewController` thread over terminal drawer | inspector
  `RightPanelViewController`), unified toolbar (sidebar, New Thread, connection, terminal, inspector). Title and subtitle
  are set but not drawn (the header shows them). Frame and dividers autosave; `ShellState` (versioned JSON) restores
  selection, panel visibility, tab, collapsed projects, manual unread, new-thread drafts.
- **Sidebar** (`Sidebar/`): source-list `NSOutlineView`, "Needs You" then projects → threads. `SidebarTree` builds it;
  updates are identity diffs, no animation. Each row observes its own `SessionRowModel`. Return renames, ⌫ archives or
  removes, folder drop and open panel add projects, hover/selected pencil starts a thread, context menus.
- **Content** (`Content/`): `ThreadHeaderView` (title editable in place; project › directory · status), mounted
  surfaces, "hero" draft (thread created on first send), empty states. A shown "finished" thread is marked viewed.
- **Workspace** (`Shell/WorkspaceController.swift`): selection, LRU of 8 open `ThreadModel`s, commands, undo, restoration.
  Reversible actions go through `UndoCoordinator` (5 s toast plus ⌘Z/⇧⌘Z); only Delete asks for confirmation.

## Seams (change `ShellSurfaces.builtIn` in `Shell/Seams.swift`; one file)
| Slot | Factory | Placeholder today (`Content/TemporarySurfaces.swift`) |
| --- | --- | --- |
| Transcript | `transcript: (ThreadSurfaceContext) -> NSViewController` | `TemporaryTranscriptViewController` |
| Request stack | `requestStack: (ThreadSurfaceContext) -> NSViewController` | `TemporaryRequestStackViewController` |
| Composer | `composer: (ThreadSurfaceContext) -> NSViewController` (adopt `ComposerSurface`) | `TemporaryComposerViewController` |
| Right panel | `rightPanelTabs: [RightPanelTab]` | three `PlaceholderPane`s |
| Terminal drawer | `terminalDrawer: () -> NSViewController` | `PlaceholderPane` |

`ThreadSurfaceContext` gives `thread` (nil for a draft), `directory`, `projectName`, `draft`, `send(_:)` (creates the
thread for a draft), `stop()`, `isRunning`, `visibleError`. Adopt `FocusableSurface` for ⌥⌘M and F6.

## Shortcuts (from `ShellCommand`)
⌘N New Thread · ⇧⌘O Add Project… · ⌘⌫ Archive (disabled while typing) · ⌥⌘⌫ Delete… · ⇧⌘U Mark as Unread ·
⌥⌘R Reveal in Finder · ⌃⇧⌘C Copy Path · ⌥⌘A Next Needs Attention · ⌥⌘M Focus Composer · F6 / ⇧F6 cycle sidebar,
transcript, composer · ⌃` Terminal · ⌃⌘S Sidebar · ⌥⌘I Inspector · ⌘↩ Send · ⌘. Stop. Composer: Return sends (queues
while running), Shift/Option-Return newline, Escape stops. Rename and Pin/Remove Project: menu, context menu, and
Return in the sidebar. Edit, Find and Window menus are standard.

## Measured (debug build, this Mac)
- Switch across 500 threads (`SwitchTimeTests`, select → transcript rendered): warm from cache p50 10.0 ms, p95 11.4 ms,
  max 13.8 ms; cold (first open, from the mock server) p50 10.7, p95 12.8, max 53.9 ms. Sidebar 1,008 rows in 2.4 ms.
- `make smoke`: live after 134 ms, stop 30 ms, child gone. Real e2e: add folder, send, reply in 1.1-1.9 s.

## Section E checklist (by the agent, no human at the screen)
- Purpose/context: pass (header shows project › directory · status). States: pass for empty, draft, cached,
  connecting/offline (toolbar label, content kept), failure (inline error, notice toast); retry is manual.
- Speed: pass (above). Keyboard: pass by construction: every command is in the menu; text keeps ⌘⌫. Not exercised by
  hand. Accessibility: status glyph plus text label, row accessibility labels, toast announcements; VoiceOver unverified.
- Parallelism: 500 threads, "Needs You" sorted by urgency, rows never reshuffle (test). Approvals: pinned above the
  composer, buttons disabled while the reply is sending (temporary UI). Streaming/control: follow-bottom only at the
  bottom; queue/stop labelled; drafts restored. Artifacts: N/A (no diffs yet). Persistence: pass (tests), relaunch by
  hand unverified. Windows: one window (multi-window is M5); drag/drop of folders implemented, not dragged by hand.
  Onboarding: N/A (AgentUI). Evidence: this note.

## Unverified / follow-ups
- Nothing was clicked or typed by a person: IME, real keyboard routing, hover, drag and drop, context menus, the Quit
  path in the running app, and Reduce Motion or Increase Contrast rendering are untested.
- Engine: sessions whose project directory differs from the added folder (a subfolder of a git repo) do not join.
  The shell canonicalises with `realpath`; the engine should also join by `session.projectID`.
- Delete is server-side and irreversible, so it confirms. A 5 s deferred delete with Undo would remove the dialog.
- Per-thread panel state, back/forward and scroll anchors are M2.
