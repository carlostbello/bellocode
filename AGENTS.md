# BelloCode: rules for implementing agents

BelloCode is a native macOS app (Swift 6, AppKit + SwiftUI, macOS 15+) that wraps a bundled opencode v2 server.
Read [docs/PLAN.md](docs/PLAN.md) first, then the research file for the area you are working on.

## Environment

- Command Line Tools only: use `swift build` and `swift test`. There is no `xcodebuild`, no Xcode project.
- `Scripts/make-app.sh` assembles `build/BelloCode.app`. Do not hand-edit the bundle.
- Tests use Swift Testing (`import Testing`). XCTest is not available with Command Line Tools.
- A suite that touches sockets, pipes, processes or web views carries `.timeLimit(.minutes(3))` (10 for real-binary suites;
  this toolchain accepts whole minutes only). Wait on gates or barriers, not sleeps; assert work done, not wall-clock time.
- `Scripts/fetch-opencode.sh` puts the pinned opencode in `Vendor/opencode/<version>/opencode` (run it once per
  worktree; it is cached and fast). `make app`, `make run`, `make smoke` are the common commands.
- The shell cannot take screenshots or drive the UI (no Screen Recording or Automation permission). To check UI,
  render the view or window to a PNG from inside the process (`bitmapImageRepForCachingDisplay` /
  `cacheDisplay`, or `WKWebView.takeSnapshot`) behind a launch argument, write it under `build/snapshots/`, and
  read the image. Measure frame timing in-process (`CADisplayLink`/`CVDisplayLink`, `os_signpost`), not by eye.
- opencode is pinned. Its OpenAPI document and recorded event streams live in `Contracts/`. Never call an endpoint
  from memory: check the contract. Much of what we use is under `/api/experimental`.
- Never read, print or log credentials. `GET /api/credential` returns secret values.
- Do not touch the user's own opencode config or data (`~/.config/opencode`, `~/.local/share/opencode`).

## Working agreement

- Stay inside the module and files named in your brief. If you need a change elsewhere, make the smallest one and
  say so in your report.
- Commit on your branch with clear messages. Do not push, and do not merge into `main`.
- Finish with: what you built, how you verified it (commands and results), what is unverified, and follow-ups.
- Do not write planning documents beyond the short feature or spike note your brief asks for.

## Engineering rules

1. Row identity is the server's stable ID. Never an array index or a fresh UUID.
2. Transcript state lives outside reusable views. One token must not replace or re-render the history.
3. Buffer ordered stream deltas and coalesce UI commits (start at 33 ms). Flush on completion and error. Never drop
   semantic events; dropping intermediate render snapshots is fine.
4. Never re-parse finished Markdown for a new token. Cache by content revision, width, font and theme.
5. Bound every cache and queue. Overflow leads to a visible resync, never silent loss.
6. Preserve the visible item and its offset when content changes above the viewport. Follow the bottom only if the
   user was already there.
7. AppKit and presentation state are `@MainActor`. Parsing, decoding, highlighting, diffing and I/O run off it and
   hand back immutable `Sendable` values.
8. Check cancellation and a session/generation ID before applying an async result.
9. Tasks are owned by a session or window and cancelled with it. No `Task.detached` or `@unchecked Sendable` as a
   shortcut.
10. `AsyncStream` buffering is storage policy, not backpressure.
11. Parse SSE to the WHATWG specification, including arbitrary byte boundaries and multi-line data.
12. A reconnect is not a replay. After any gap, rebuild from the list endpoints.
13. The server child is supervised: drained pipes, verified readiness, restart with backoff, terminate only the
    process we own.
14. Edit commands go through the first responder. Test IME, undo, and terminal or browser shortcut conflicts.
15. SwiftUI for standard UI; AppKit for the window, splits, transcript, composer, diff, terminal and browser.
16. Representable updates are idempotent; the coordinator owns delegates and tears them down.
17. No implicit animation on streaming or layout updates. Panels are instant by default. Respect Reduce Motion.
18. Secrets go in Keychain. The local server is loopback-only with a per-launch password.
19. SQLite migrations are versioned and tested. Local data is a cache of opencode's state.
20. Add `os_signpost` intervals around event receipt, publish, parse, layout and database reads. Never log content.

## UX rules

1. Local feedback within 100 ms. Navigation shows cached content; never a blank pane with a spinner.
2. Every action has a menu item and keyboard access. Text fields, the terminal and the browser keep their keys.
3. Reversible actions apply immediately with Undo. Confirm only what cannot be undone.
4. A blocked agent is never hidden: approvals and questions are pinned above the composer and counted in the
   sidebar. Status is never colour-only.
5. Stop, steer and queue are distinct and labelled. Never claim delivery before the server acknowledges it.
6. Always show project, session, branch and worktree for anything that acts on files.
7. Desktop density: compact rows, no touch-sized padding, no sheets for routine work.
8. Cover empty, loading, stale, offline, failure and success states.
9. Restore drafts, selection, pane sizes and scroll position on relaunch.
10. Run the acceptance checklist in docs/research/03-ux-patterns.md (section E) before reporting done.
