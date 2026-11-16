# G5 Terminal: SwiftTerm, app-owned vs opencode-owned PTY (2026-11-16)

Result: **pass, with conditions.** SwiftTerm 1.99.3 (MIT) handles vim, top, fast output, resize, Unicode and
every protocol checked, with no main-thread stalls. Recommended model: **(b) opencode owns the PTY.** The view is
an emulator fed from the WebSocket. (a) stays as a fallback behind the same protocol. Confidence: medium-high.
Not verified: on-screen frame pacing and Metal draw cost (the Mac was locked, see "Limits"), tmux and htop (not installed).

Prototype: `Sources/TerminalKit/Spike/` (throwaway PTY client, both models, metrics) and `Sources/TerminalSpike/`
(one scenario per process). Reports are in `build/spikes/G5/*.json` and snapshots in `build/snapshots/G5-*.png`. Run:
`swift build -c release --product TerminalSpike -Xswiftc -enable-testing -Xswiftc -DSPIKE_FORCE_FRAMES`, then
`.build/release/TerminalSpike <contract|perf|latency|memory|idle|compat|hooks|restart1|restart2|diag> [--model local|remote] [--renderer cg|metal]`.

## SwiftTerm facts

- Pinned `exact: "1.99.3"`. Licence MIT. Its manifest is tools 6.2 with `swiftLanguageModes: [.v6]`. TerminalKit
  builds against it in strict Swift 6 mode with **no relaxed-concurrency wrapper**.
- Bytes are parsed off the main thread. Model (a) uses a gather thread and a parse thread, a Ghostty-style
  pipeline. Model (b) uses `TerminalView.feedSender`, which is `Sendable` and parses on the caller's task under
  the terminal lock. Rendering is display-link driven and coalesced, and suspends while the window is occluded.
- Two renderers: CoreGraphics (default) and Metal (`setUseMetal(true)`). Buffer reads are thread-safe copies:
  `visibleRowsText`, `terminalContentSnapshot`, `terminalInputStateSnapshot`. Also available: `observeOscEvents`,
  `findNext`/`searchMatchSummary`, `pasteText`, `installColors`, `maximumOscBytes`.

## Results (release build, M5 Max, 120x37 grid, occluded window; another agent's process used ~100% of one core)

| Workload | (a) local CG | (a) local Metal | (b) remote CG | (b) remote Metal | `script` to /dev/null, no emulator |
| --- | --- | --- | --- | --- | --- |
| `yes \| head -n 2000000` (4 MB) | 1.57 s | 1.57 s | 1.77 s | 1.75 s | 2.62 s |
| `cat` 20 MiB file | 0.10 s | 0.08 s | 0.18 s | 0.18 s | 0.13 s |
| `seq 1 5000000` (54 MB) | 4.29 s | 4.28 s | 4.82 s | 4.83 s | 7.57 s |
| CPU-s for seq: app / server / pty daemon | 2.1 / – / – | 1.8 / – / – | 1.4 / 0.3 / 6.9 | 1.1 / 0.3 / 7.0 | |
| Main-queue latency p99 during output | ≤1.4 ms | 0.01 ms | ≤1.9 ms | 0.02 ms | |
| Display-link intervals over 33 ms (120 Hz) | 0 | 0 | 0 | 0 | |
| Keystroke to buffer p50 / p95 / max (240 keys) | 1.6 / 1.8 / 5.7 ms | 1.4 / 1.8 / 8.6 ms | 2.7 / 3.6 / 9.7 ms | 5.3 / 6.4 / 9.6 ms | |

- The macOS pty is the throughput limit. The same commands run through `script` with no emulator are *slower*.
  The app used 0.5 CPU-s during the 1.6 s `yes` run. Model (b) is 10–15% slower on bulk output and 2× slower on `cat`.
- CG draw cost was measured with a forced 60 Hz `frameTick()` and `display()` on the main thread (see Limits):
  p95 about 1.0 ms and max 4 ms per frame during all workloads. Metal draws on its own render thread, so main is idle.
- In model (b) the cost is opencode's `opencode-pty` daemon. It runs its own headless emulator, which uses
  ~1.5 cores during sustained output (6.9 CPU-s for `seq`). Fine for interactive use. Note it for log-heavy builds.
- Memory, 100,000-line scrollback: an empty terminal adds 13 MiB, and 100k rows of 100 columns add **117 MiB**
  (≈1.2 KiB per row). This stays flat after 300k lines (capped at 100,037 rows). Both models are identical in the app.
  The daemon is 15 MiB and keeps a **2 MiB replay ring** per PTY. `terminalContentSnapshot(.all)` on a full buffer
  briefly costs about 500 MiB: never use it for agent reads.
- Idle (occluded, 20 s): app 0.00–0.02% CPU for 1 or 4 terminals. Server 0.4–0.5%, daemon 0%.
- 8 terminals in one window cost +26 MiB. After close, 8/8 views were deallocated and 0 shells remained, provided the
  window's first responder is released. The memory run without that kept one view alive.

## PTY contract as observed (opencode 2.3.0; matches `Contracts/opencode-2.3.0/openapi.json`)

| Call | Observed |
| --- | --- |
| `POST /api/experimental/session/{sid}/terminal` `{command,args,cwd,title,env,size}` | `{data: PersistentPty.Info}` with id `pty_persistent_…`, status running, pid. the spike passed the user's `HOME`/`PATH`/`TERM` in `env` (the server's own env is isolated) |
| `GET …/session/{sid}/terminal` | list. An exited PTY is **removed at once**: list `[]`, GET 404 `PtyNotFoundError` |
| `PUT /api/experimental/persistent-pty/{id}` `{size,title?,attachmentID?}` | resizes (the shell's `stty` follows) |
| `DELETE …/persistent-pty/{id}` | 204, and kills the process |
| `GET …/{id}/snapshot` | `{info, text, checkpoint (base64 VT that redraws the screen), cursor}` |
| `GET …/session/{sid}/terminal/read?lines=N` | agent view: `{ptyID,title,cwd,foregroundProcess,screen{text,cols,rows,cursor}}`. `lines` = the **bottom** N screen rows |
| WS `GET …/{id}/connect?cursor=&attachment_id=&role=controller\|observer&takeover=&input_protocol=1` | Basic auth header works (`connect-token` tickets are for browsers) |

WebSocket framing: server text frames are JSON: `attached {attachmentID,inputProtocol,info,role,generation,replay{requestedOffset,availableOffset,endOffset,truncated}}`,
then **one binary frame with the whole replay** from `max(cursor, head)`, then `replay_complete {endOffset}`. After that:
binary output frames, `controller_changed`, `resized {cols,rows,checkpoint}`, `title_changed`,
`foreground_process_changed`, `exited {exitCode,finalOffset}`, and close 1000. Client input frames are binary
`[flag u8: 1 input, 0 resize][cols u16 BE][rows u16 BE][payload]`. Offsets are byte offsets: the cursor to
reconnect with is `endOffset` plus the bytes received since.
A second controller without `takeover` is closed with **4404 "terminal unavailable"**. `takeover=true` moves control
(`controller_changed` to both). Observers attach read-only.
Verified: reattach after closing the view replays output written while detached. Reattach from a saved cursor
replays 0 bytes. After **the app process exits and a new one starts** with the server kept running, the same shell
(env var kept), its scrollback and output produced while no app ran are all restored (`restart1`/`restart2`).
Retention: after 3 MB of output, `availableOffset` 994,036 and `endOffset` 3,091,188 (2 MiB), `truncated: true`.
Cleanup: with stdin-lease shutdown, the server, daemon and shells all exit, and nothing is left.

## Compatibility matrix (both models, buffer and input state checked, PNGs inspected)

| Check | Result | Check | Result |
| --- | --- | --- | --- |
| vim (alt screen, draw, exit restores) | pass | 24-bit fg/bg, 256 colour | pass |
| Resize while vim runs, 4 sizes (`&columns`x`&lines` = grid) | pass | CJK, emoji+skin tone, ZWJ, flags = 2 cells; combining = 1 | pass |
| top (full screen, redraw after resize) | pass | Alternate screen 1049 enter/leave | pass |
| tmux, htop | not installed, untested | Mouse reporting SGR 1006 (`^[[<0;10;6M`) | pass |
| Bracketed paste (`pasteText`) | pass | OSC 8 link via delegate (Cmd-click) | pass |
| OSC 7 cwd, OSC 2 title | pass | OSC 133 A/B/C/D parsed | pass |
| OSC 52 | (b) delegate called and blocked; (a) not run, see problems | TERM=xterm-256color, COLORTERM=truecolor | pass |

In model (b), vim scrolled by one line on two shrinks, likely because it saw an intermediate size. A Ctrl-L repaint
changed nothing, so the emulator and vim agreed. Resize ordering is worth a production test.
Hooks (both models): find in scrollback, select-all with `getSelection`, a send-to-composer callback, implicit URL
detection, palette, foreground and background from a colour table, and a font change all pass. The font change
resizes the grid and the PTY (120x37 to 81x25 at 18 pt).

## SwiftTerm problems found

1. `LocalProcessTerminalView` writes **OSC 52 to `NSPasteboard.general`**. `clipboardCopy` is `public`, not
   `open`, so it cannot be overridden. Production must use a plain `TerminalView` with its own delegate (as (b) does).
2. Unknown OSC codes are logged to stdout ("Unknown OSC code"). This is harmless but noisy, so route or silence it.
3. While occluded, frames stop. This is correct, but testing needs the forced clock, which uses `@testable` internals.
4. `cacheDisplay` snapshots miss the layer background, and Metal views are not captured. Use the window
   server for on-screen verification later.
5. A synthesised first click is swallowed while the window is not key, so tests deliver mouse events to the view.

libghostty does not need to be reconsidered. Nothing missed a target, the pty and the daemon cost more than the
emulator, and SwiftTerm 1.99 already uses a Ghostty-style IO pipeline.

## Recommended production design (TerminalKit)

- `TerminalSession` (`@MainActor`, owned by a thread or window, cancelled with it): `ptyID`, `sessionID`, saved
  `cursor`, `status`, `title`, `cwd`, `foregroundProcess`. Its identity is the server's `pty_persistent_*` id
  (rule 1). A `TerminalTransport` protocol has two implementations: `OpenCodePTYTransport` (production, in
  OpenCodeKit: REST plus the WebSocket client) and `LocalPTYTransport` (fallback for no server or a crashed daemon).
- `TerminalSurface`: an AppKit `TerminalView` subclass with its own `TerminalViewDelegate`, wrapped in a representable
  whose coordinator owns the delegate. Bytes go from the socket's receive task into `feedSender` (off main, rule 7).
  Keystrokes and resizes go out as input frames. Clipboard and links route to BelloCode (the in-app browser).
  OSC 52 is denied by default, with an explicit per-session "allow writes" toggle and no reads. OSC payloads are
  capped at 1 MiB.
- Persistence: terminals live on the server. On launch, list each session's terminals and attach from cursor 0
  (the ring is ≤2 MiB) for full context. Keep the cursor while attached and reattach from it after a socket drop.
  On `truncated`, reset the emulator first (rule 12). Exited PTYs vanish server-side, so keep a local "exited (code)"
  row from the `exited` frame.
- Agent reads: opencode exposes `terminal/read` and `snapshot` to the agent itself. BelloCode only has to create
  terminals bound to the thread's session. Pass the user's `HOME`/`PATH`/`LANG`/`SSH_AUTH_SOCK`/`TERM` in `env`
  so shells do not see the server's isolated XDG/HOME.
- Signposts around feed, frame and attach. Scrollback defaults to 10k rows (≈12 MiB), and the setting is capped at 100k (≈120 MiB).

## Limits of this run and follow-ups

- The Mac was locked for the whole run (`diag`: screen locked, window occluded). Display-link intervals measure
  main-thread responsiveness, but SwiftTerm itself was not drawing. CG cost comes from the forced clock. **Re-run
  `perf` and `latency` unlocked** to get on-screen frame pacing and Metal draw cost.
- Untested: tmux and htop (install them and rerun `compat`); IME and undo through the first responder; the
  the `persistent-pty/handoff` path across a server restart (whether PTYs survive one is unverified);
  `OPENCODE_PTY_BIN` with a bundled, signed helper.
