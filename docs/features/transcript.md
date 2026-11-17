# Transcript (M1-F)

Status: mounted in the app 2026-11-17 (gate G1 decision B: virtualised `NSTableView` rows, CoreText drawing, a
transcript-level selection model). Code: `Sources/TranscriptKit/Transcript/`; harness `Sources/TranscriptDemo/`.

## Architecture and row model
- **Data flow.** `TranscriptController` binds a `TranscriptSource` (`ThreadModel` conforms; `StaticTranscriptSource`
  for tests and demos). Observation tracks the list and the newest 256 messages individually (older finished ones are
  re-validated when the list changes). A change marks messages dirty; `sync` rebuilds only the last turn's rows while a
  reply streams (grouping never crosses a user message), diffs rows by ID (common prefix/suffix) and inserts/removes
  table rows with anchoring. First content is built off-main (rows, estimates, exact layouts of the bottom three
  viewports), then measured in the background (utility QoS, half the cores, batches via `AsyncStream`).
- **Rows** (`RowBuilder`): one per user message, assistant part (text, reasoning, file, sub-agent, todo list), run of
  consecutive tool calls of a turn (a *work group*, possibly spanning several step messages; named after its first
  call), error, lifecycle event (interrupted, compacted, model/agent changed) and a "Working…" row. IDs come from server
  message/part IDs (`m:`, `p:`, `g:`, `e:`, `l:`). A huge text part stays one row but is laid out per Markdown block;
  monospaced blocks are measured arithmetically and drawn per visible line, and rows over 1,000 pt draw into a canvas
  covering only the visible part, so a 100 KB fence costs what is on screen.
- **Blocks** (`RenderBlocks`): a row's blocks depend on content only; expansion (`RowUIState`) hides blocks at zero
  height, so positions (row, block, UTF-16 offset) survive expansion, reuse and relayout. Successful calls collapse
  behind "Read 4 files, ran a command · 3 s"; failed and running calls always show; running output shows live.
- **Markdown**: swift-markdown 0.9.0 (cmark-gfm). `MarkdownStream` line-buffers the tail (complete lines plus whole
  words of a plain paragraph; holds a heading until content follows, a bare list marker, a possible table header, a
  partial code line) and re-parses only from the last top-level block (blocks before it are final in CommonMark;
  reference definitions switch to full re-parse). `finish` equals a one-shot parse at every split point of a corpus (test).
- **Highlighting**: `HighlightService` protocol; `TokenizerHighlighter` (no dependencies, cached by content, bounded,
  checks cancellation) for Swift, TS/JS, Python, Rust, Go, C/C++/ObjC, Java, Kotlin, Ruby, SQL, JSON, YAML, shell,
  HTML/XML, CSS, diff. Colours: `DS.Syntax` (light, dark, increased contrast). Unknown languages are plain.
- **Layout** (`LayoutEngine`, `@concurrent`, results handed back with `sending`): cached by (row ID, version, UI version,
  column width, theme revision, top padding); LRU bounded by count and CTLine cost; parse cache bounded by count and
  bytes. Code and wide tables scroll horizontally inside the row, tool output is capped (220 pt) with its own scroll.

## Public API and mounting
`TranscriptViewController(controller:)` + `bind(_ source:anchor:)`; `TranscriptController` exposes `scrollAnchor` /
`restore(anchor:)` (`TranscriptAnchor` = message ID + offset), `jumpToLatest`, `goToTurn(previous:)`,
`goToLastFailure`, find (`showFind`, `setFindQuery`, `findNext/Previous`, `useSelectionForFind`), copy (`copySelection`,
`copyMessage`, `copyAsMarkdown`, `copyCode`), `baseFontSize`, and a delegate (open sub-agent thread, anchor changed).
The shell's `transcript` seam builds `TranscriptSurfaceController` (`Content/TranscriptSurface.swift`): binds the
`ThreadModel`, restores/saves the anchor via `updateUIState`, follows the text-size setting, opens sub-agent threads
through `ThreadSurfaceContext.onOpenThread`, and runs the new `ShellCommand`s when the transcript is not first
responder: Find in Thread ⌘F, Find Next/Previous ⌘G/⇧⌘G, Use Selection for Find ⌘E, Copy Message, Copy as Markdown
⇧⌥⌘C, Copy Code, Jump to Latest ⇧⌘J, Previous/Next Prompt ⌥⌘↑/⌥⌘↓, Go to Last Failure ⌥⌘L.

## Measured (release, Apple M5 Max, 120 Hz, window 900×900, `.build/release/TranscriptDemo --scenario all`)
Spike: G1-B report (120 Hz, 9,983 rows from an in-process workload). Production: the Engine fed by MockOpenCode
`.large` (10,000 messages → 13,579 rows, 2.2 M pt), display at 165 Hz (6.06 ms frames, so ">16.7 ms" means ≥3 missed
refreshes instead of 2). Frames: p50/p95/p99/max ms. Reports: `docs/features/transcript-bench/*.json` (S2–S4, S7 run
alone; S1, S5, S6, S8 from one `--scenario all` run).

| Scenario | Spike | Production |
|---|---|---|
| S1 open → first content frame | 96 ms (open pass 72); exact heights for all 570 ms; 224→138 MB | 98 ms (open pass 94; newest 70-row window 35 ms); all 13,567 rows exact 789 ms; 329→205 MB¹ |
| S2 3× flicks down / up | 8.3/8.3/16.9/50.7, >16.7 1.2 %, >33: 1 / 8.3/16.7/19.6/90.5, 5.0 %, 5 | 6.1/15.1/22.8/143, 3.4 %, 65 / 6.1/16.8/22.5/36.7, 5.2 %, 15 |
| S2 realistic 1× (60 s) | 8.3/8.3/18.5/23.4, 3.6 %, >33: 0 | 6.1/15.6/19.8/29.3, 3.3 %, >33: 0 |
| S2 watchdog, sync layouts, geometry error | 2 stalls >50 ms (122); 26; 0 pt | 0 stalls >50 ms (max 40); 21; 0 pt |
| S3 stream following, 100 deltas/s | 8.3/8.3/8.3/17.9; delta→visible 24.9 / 40.2 ms (p50/p95) | 6.1/6.1/10.5/16.3, 0 >16.7; mock delta→laid out 29.8 / 43.1 ms; Engine publish→laid out 6.6 / 9.7 ms; →shown (line buffer) 52 / 89 ms; 0 pt from bottom; text equal |
| S4 stream, reading 3 viewports up | 8.3/8.3/8.3/20.9; drift 0 pt | 6.1/6.1/6.1/15.2; drift 0 pt over 8 pauses; released, pill, rejoined (distance 0) |
| S5 anchors (expand above, late image, prepend, expand while scrolling 900 pt/s) | 0 / 0 / 0 / 0 pt | 0 / 0 / 0 / 0 pt |
| S6 resize 900→1400→900 | 8.3/8.3/8.3/10.9; 0 pt | 6.1/17.8/20.2/20.8 (column fixed at 760 pt); re-wrapping 560→1000→560: 6.2/23.8/28.5/48.8; 0 pt |
| S7 drag-select + copy; find | 25 messages, copy 3.1 ms; find 26 ms / collapsed 123 ms | 60 rows, autoscroll 0 frames >16.7, copy 2.6 ms (16,341 chars), survives ±30k pt; find 305 ms² / collapsed 81 ms |
| S8 memory | 174 MB after; cycles plateau 111 MB | 266 MB after; 20 cycles 393–437 MB, live malloc flat 141–157 MB; 246 MB after close¹ |

¹ Includes the in-process mock server and Engine (each holding the 10,000-message thread; 112 MB live at open) and
decoded 640×360 images (bounded 96 MB; the spike's were 32×32). During S2's full traversal footprint peaks at 863 MB
(live malloc 594 MB): a regression from the spike's ~380 MB, bounded (no growth across S8 cycles) but not yet explained.
² First query builds the index for 13,579 rows (parse + case/diacritic folding); later queries take tens of ms.
Differences: rows are richer than the spike's (syntax-highlighted code, real tables, tool lines), so 3×-speed flicks
show more >33 ms frames (65 vs 1 going down, mostly at row-mix boundaries); at realistic speed there are none. The
streaming path adds the Engine's 33 ms coalescing and the T3 line buffer by design.

## docs/research/03 section E (by the agent; no human at the screen)
Purpose/context: pass (prompts, replies, tool lines name verb, target, status and time; sub-agent cards name agent
and status; the shell's header shows project/branch/worktree). States: empty ("No messages yet"), loading older
("Loading earlier messages…"), streaming, running ("Working…"), sending, failed tool/turn/provider error,
interrupted, offline (content kept): pass by test or snapshot. Speed: toggle and copy apply synchronously; open 95 ms
for 10,000 messages. Keyboard: every command has a menu item (Edit, Find, View); arrows/Page/Home/End scroll,
Shift+arrows (Option for words, Command for ends) extend, Escape closes find then clears selection, Tab leaves;
driven programmatically only. Accessibility: rows are static-text elements with label (who/what, time), value (the
visible text) and custom actions (copy, expand/collapse, open link, open sub-agent); a finished reply is announced
once; status is glyph + word, never colour only; increased contrast and text size re-resolve the theme; no
animation (Reduce Motion has nothing to remove). VoiceOver itself: unverified. Streaming and control: following only
at the bottom, 0 pt drift while reading (S4), pill debounced, selection kept while text arrives: pass. Persistence:
the scroll anchor is saved per thread and restored (tested round trip). Windows: narrow widths (column re-wraps,
S6), light/dark. Artifacts: sub-agent card opens the child thread; diff review is DiffKit's (N/A here).

## Known gaps
- Reasoning duration is measured live (BelloCore parts carry no timestamps); history shows "Thought" without one.
- Tree-sitter, Mermaid, math, GitHub alerts, `<details>`, footnotes and image zoom are not rendered (text fallback).
- Copy puts plain text and Markdown on the pasteboard, not RTF; no drag-out of a selection.
- Accessibility exposes text per row, not character ranges (no VoiceOver text navigation inside a row yet).
- Tool calls fetch no detail lazily: inputs/outputs come with the message. Tool-call visibility settings (hide
  successful, zen) are not offered yet. "Use Selection for Find" uses the transcript's selection even from the composer.
- The in-process mock cannot sustain 100 deltas/s past ~25 s on the 10,000-message session (its per-delta cost grows
  with the reply), so S3/S4 stream 20 s; the transcript's own share was measured separately (Engine publish → laid out).

## Needs a human at the screen
Real trackpad momentum and rubber-banding (all scrolling here is programmatic), on-screen frame pacing with the display
unlocked (frames are display-link delivery), VoiceOver reading order and actions, IME (the view is read-only, but
Look Up/force click and Services), hover timestamps and link tooltips, the look of the pill and find bar over vibrancy.
