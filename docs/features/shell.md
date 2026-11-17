# The integrated app: shell, composer, approvals, Engine (M1-B + M1-E)

Status: integrated 2026-11-16 against MockOpenCode and opencode 2.3.0 (`opencode/big-pickle`, free, two prompts).

## What runs together
- **Launch**: `AppRuntime` owns the engine, its server (bundled `Contents/Helpers/opencode`, `--mock`, or
  `BELLOCODE_SERVER_URL`) and the one `AuthService` (shut down before `engine.stop()`). `AppDelegate` builds the menu,
  the main window, Settings (⌘,: General = send key, text size, appearance; Accounts = AgentUI) and, on first launch,
  the non-modal onboarding window (free models work at once). "Connect…" in the model picker opens a Connect window.
  `--smoke-test`, `--snapshot <name>` (12 states, see `Launch/SnapshotRunner.swift`).
- **Content column** (`Content/`): header › transcript (temporary placeholder; seam unchanged for TranscriptKit) ›
  request stack (AgentUI, `RequestStackSurface.swift`) › "Status unknown" banner › queued follow-ups (Queued / Steering /
  Parked, Steer Now, Remove) › composer (ComposerKit, `ComposerSurface.swift`). One centred column (760 pt max,
  24 pt margins). Drafts use the hero composer (3 lines) and dock once the first send creates the thread.
- **Composer**: plan toggle and model picker leading, permission mode trailing, context line (project · branch or
  folder · Local checkout/Worktree, read from `.git` off-main). `/` lists server commands and skills (a leading
  command runs `session.command`); `@` lists agents and the server's `fs/find` results (local index offline).
  Attachments: files by `file://` URI; pasted images and large pastes are written to
  `~/Library/Application Support/BelloCode/attachments` (7 days / 512 MB, cleaned at launch) and sent as URIs;
  mentions carry `{start,end,text}` (UTF-16). The optimistic user message shows attached files.
- **Styles**: `AppStyle` maps DesignSystem tokens (card surface/border, radius 12, fonts from the text-size setting)
  into `ComposerStyle` and `AgentUIStyle`. Side panels hold their width (sidebar 260 pt default, resizable, autosaved).
- **Engine fixes**: folders resolve their opencode project with `GET /api/location` (a repo subfolder lists the repo's
  threads, keeps its folder name); credential/integration events refresh the catalog and, through its revision, the
  AuthService lists; a turn orphaned by a server restart shows "Status unknown" with **Stop** (interrupt, then
  recorded interrupted locally; resyncs keep it) and **Resume** (same, then a continue prompt). Nothing is automatic.

## Shortcuts (one table: `Shell/ShellCommand.swift`; uniqueness is tested)
| Command | Keys | Command | Keys |
| --- | --- | --- | --- |
| New Thread | ⌘N | Send | ⌘↩ (↩ in the composer) |
| Add Project… | ⇧⌘O | Queue After This Turn / Steer at Next Step | menu only |
| Archive Thread | ⌘⌫ (not while typing) | Stop Agent | ⌘. (Escape never stops) |
| Delete Thread… | ⌥⌘⌫ | Choose Model… | ⇧⌘M |
| Mark as Unread | ⇧⌘U | Permission Mode… | ⇧⌘A |
| Reveal in Finder / Copy Path | ⌥⌘R / ⌃⇧⌘C | Plan Mode | ⌥⌘P |
| Next Needs Attention | ⌥⌘A | Allow Once / Always Allow | ⌥⌘Y / ⇧⌥⌘Y |
| Focus Composer | ⌥⌘M | Deny or Dismiss / Submit Answer | ⌥⌘N / ⌥⌘↩ |
| Next / Previous Region | F6 / ⇧F6 (includes pending requests) | Previous / Next Request | ⌥⌘[ / ⌥⌘] |
| Sidebar / Inspector / Terminal | ⌃⌘S / ⌥⌘I / ⌃` | Settings… | ⌘, |
| Paste Inline (no chip) | ⌥⌘V | Connect Provider…, Welcome… | menu only |
| New / Split / Close Terminal | ⌘T / ⌘D / ⇧⌘W | Next / Previous Terminal, Clear, Send Selection | ⌘} / ⌘{, ⌘K, ⇧⌘L (docs/features/terminal.md) |

The focused composer handles ⌘↩ and ⌥⌘↩ itself (`performKeyEquivalent`), so its send-key policy wins while typing
(⌘↩ = alternate follow-up when Return sends). Request actions act on the front request of the displayed thread;
an arriving request never takes focus (tested).

## Verified
- `swift test`: all suites pass, including `IntegratedShellTests` (real window: type, Send command, streamed turn,
  approval via the Allow Once command with focus kept, queue while running, Stop, draft with token kept across
  switches; draft send with image + `@` mention docks and shows the file; server `/` and `@` completion),
  `IntegrationFixesTests` (subfolder project, event-driven sign-in refresh, Stop/Resume after a simulated crash).
- Real run (`BELLOCODE_SHELL_E2E=1 swift test --filter RealServer`, server from `build/BelloCode.app`): add folder,
  draft send with `@README.md` and a PNG accepted (reply quoted the README; server kept `red.png image/png`; the
  free model does not read images), then an edit permission approved through the Engine API created the file.
  The request shape (`files[].uri/source/mention`) is the one the 2.3.0 server accepted.
- `make app`, `make smoke` (live 139 ms, child exited), `swift run ComposerDemo` (129 checks),
  `swift run AgentUIDemo --all` (50 snapshots). Snapshots: `docs/snapshots/app-*.png` (8 of 48 rendered).

## Section E checklist (by the agent; no human at the screen)
Purpose/context: pass (header and context line: project, branch/folder, workspace; request cards name operation,
agent and child). States: empty, first run, draft, loading/cached, running, queued/parked, approval, question,
child approval, unknown-after-restart, offline with cached content, send failed with text restored: pass by snapshot
and test. Speed: switch timing unchanged (`SwitchTimeTests`). Keyboard: every command has a menu item and keys
above; F6 reaches requests; not driven with real keys. Accessibility: labels on banner, queue rows, context line;
status always glyph + text; VoiceOver unverified. Parallelism: Needs You bubbling of child approvals verified.
Approvals: removal after server 204 (AgentUI). Streaming/control: queue/steer/stop labelled, Parked explained.
Persistence: drafts with tokens across switches (in memory; text persists). Onboarding: shown once, skippable.

## Needs a human at the screen
Real typing, IME and key routing (⌘↩ precedence, SwiftUI shortcuts vs menu), popover look (snapshots cannot render
vibrancy, so pickers appear flat grey), hover, drag and drop, VoiceOver, Reduce Motion/Transparency, the onboarding
and Settings windows in use, real OAuth sign-in, the quit path with a running turn, and multi-display behaviour.

## Follow-ups
Transcript replaces the placeholder (then the transcript's own width preference is no longer special-cased);
per-project default model/mode for drafts; persist "Status unknown" decisions across relaunch (orphans are only
detected when the server restarts during a run); deferred Delete with Undo; rich drafts are not persisted to disk.
