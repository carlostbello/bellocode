# Terminal (M2-A)

Status: done 2026-11-16 against opencode 2.3.0 and MockOpenCode. Model (b) from gate G5: opencode owns the PTY,
SwiftTerm 1.99.3 renders it, so terminals survive app restarts and the agent can read them.

## Architecture
- **OpenCodeKit** `PTY/`: REST calls (`OpenCodeClient+PTY.swift`), `PTYWire` (input frames), `PTYControlMessage`,
  `PTYStreamState` (reconnect-from-cursor rules), `PTYOutputPipe` (4 MiB bounded, ordered, coalescing; the receive
  task waits when full), `URLSessionPTYSocket` (64 MiB frames, ping every 15 s).
- **Engine** `Terminal/`: `TerminalService` (`engine.terminals`) hands out `ThreadTerminals` per session (records,
  exit codes, tab order, selection, split, drawer open/height; saved in `app_terminal`, migration `v3-app-terminals`,
  kept by `rebuild()`), reconciles with the server list (vanished → `ended`, the agent's PTYs adopted, offline →
  `isStale`), and makes `TerminalStream`s: connect, replay, live feed off the main actor, keystrokes, 40 ms debounced
  resizes, observer mode on 4404 with Take Control, backoff reconnect from the cursor. Input while not attached is held
  (≤ 64 KiB) and sent on attach; `send` returns sent/held/refused/ignored. An input that does not fit is refused whole
  and every later one too, and nothing held is replayed, until the person picks Send Held Input or Discard in the pane's
  bar (a beep per refused keystroke; deep review 1, U3). `TerminalIdlePolicy` +
  `closeIdle` is the settle/archive hook.
- **TerminalKit** `Terminal/`: `TerminalWorkspace` (bounded cache of 16 emulators so thread switches are instant),
  `TerminalSurfaceController` (drawer: tabs + side-by-side split; panel: tabs), `TerminalPaneController` (SwiftTerm
  `TerminalView` subclass with our delegate, never `LocalProcessTerminalView`), tab strip, find bar, theme.
- **App**: `Content/TerminalSurface.swift` (`TerminalSurfaces`, one per window; `MainWindowController` is its
  `TerminalShell`); Seams: the drawer factory and a "Terminal" right-panel tab; Settings ▸ Terminal.

Mounting: `let w = TerminalWorkspace(service: engine.terminals)`, `let s = w.makeSurface(.drawer)`, mount `s.view`,
then `s.display(engine.terminals.terminals(for: sessionID), directory:)` on every selection change.

## PTY contract as used (checked against Contracts/opencode-2.3.0/openapi.json and the binary)
Create `POST /api/experimental/session/{sid}/terminal` (login shell `-l`, user's HOME/PATH/LANG/SSH_AUTH_SOCK, TERM
xterm-256color, the thread's directory); list/get/PUT (title, size)/DELETE `…/persistent-pty/{id}`;
`…/terminal/read` is the agent's view (`lines` = bottom rows). WS `…/{id}/connect?cursor&attachment_id&role&
takeover&input_protocol=1` with Basic auth: `attached` → one replay frame → `replay_complete`, then output,
`resized`, `title_changed`, `foreground_process_changed {process}`, `exited {exitCode, finalOffset}`, close 1000. An
exited PTY vanishes from the server at once, so the code is kept only in our record.
Since the containers packages, a terminal of a containerised project runs its shell in the project's workspace
through `bellocode-exec`, as the container's verified numeric uid:gid (v1.0.1 AF10; containers.md, "Workspace,
failures, ports, file watching").

## Behaviour
Every running terminal of the displayed thread is attached; other threads' are detached (PTYs untouched) and replay
only the gap when shown again. Truncated ring or a server behind our cursor → reset + "[earlier output…]" line.
Keys: with focus the terminal keeps every non-⌘ key (F6 included); only ⌃` (drawer) is reserved
(`ShellCommand.isKeptWhileTerminalFocused`). Commands: New ⌘T, Split ⌘D, Close ⇧⌘W, Next/Previous ⌘} / ⌘{,
Clear ⌘K, Send Selection to Composer ⇧⌘L, Rename/Restart/Move (menu, tab context menu). Paste asks only for
multi-line text at a shell prompt (OSC 133) with bracketed paste off. OSC 52 writes blocked by default (visible
notice; setting), reads never. OSC 7 updates the record's directory. Links: Cmd-click → host delegate (default
browser after SwiftTerm's checks; built-in browser later). Send to composer = a named `.text` attachment chip.

## Measured (release, M5 Max, 120x37, occluded window; `swift build -c release --product TerminalDemo -Xswiftc -enable-testing`)
| Workload | Spike (b) remote CG | Production |
| --- | --- | --- |
| `yes \| head -n 2000000` | 1.77 s | 1.78 s |
| `cat` 20 MiB | 0.18 s | 0.20 s |
| `seq 1 5000000` (54 MB) | 4.82 s | 4.85 s; app 1.07 CPU-s (spike 1.4), daemon 7.1 |
| Main-queue latency p99 during output | ≤1.9 ms | 1.28 ms, 0 stalls > 50 ms |
| Keystroke → buffer p50/p95/max (240 keys) | 2.7 / 3.6 / 9.7 ms | 3.5 / 4.4 / 15.1 ms, 0 misses |
Smoke (bundled app): terminal round trip 314 ms, exit code kept, shell gone after stop.

## Verification
`swift test` (OpenCodeKit `PTYTests` 17, Engine `TerminalServiceTests` 11 + `TerminalRealBinaryTests` (create, run,
agent read, resize, reconnect, relaunch re-attach to the same shell, exit 5, restart, close), TerminalKit 8, app
`TerminalShellTests` 3), `make app`, `make smoke`, `swift run TerminalDemo snapshots` (16 PNGs, checks pass).
Snapshots: `docs/snapshots/terminal-{drawer-one-dark,drawer-split-dark,drawer-exited-light,drawer-find-light}.png`.

## Section E checklist (agent, no human at the screen)
Purpose/context: tab tooltip shows directory; empty state names where it opens; header shows project/branch. States:
draft, empty, starting, live, reconnecting, read-only, exited (code), ended, offline/stale, create failure: pass by
test/snapshot. Speed: cached switch < 100 ms (test); output never blocks main (p99 1.3 ms). Keyboard: every command
in the Terminal menu with ⌘ keys; F6 cycles into the drawer, ⌃`/⌥⌘M leave it. Accessibility: tabs are labelled
radio buttons with state text; status never colour-only; VoiceOver unverified. Persistence: tabs, titles, exit codes,
split, drawer open/height per thread across relaunch (tests). Approvals/artifacts: N/A.

## Known gaps and follow-ups
Terminal-excerpt chip (plain text block today); link → built-in browser; ports/servers panel; settle/archive call
`closeIdle`; hidden threads learn exits only as `ended`; snapshots composite SwiftTerm's CG draw (cursor, search
highlight and Metal not captured); occluded windows defer SwiftTerm's own size callback (layout-driven resize covers it).

## Needs a human at the screen
On-screen frame pacing and Metal cost unlocked; IME/marked text and dead keys in the terminal; real ⌃`/F6/⌘ key
routing; tmux, htop (not installed); vim resize redraw by eye; drag-reorder and rename feel; VoiceOver.
