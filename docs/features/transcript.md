# Transcript (M1-F, M2-B)

Status: mounted in the app 2026-11-17 (gate G1 decision B: virtualised `NSTableView` rows, CoreText drawing, a
transcript-level selection model). Code: `Sources/TranscriptKit/Transcript/`; harness `Sources/TranscriptDemo/`.

## Architecture and row model
- **Data flow.** `TranscriptController` binds a `TranscriptSource` (`ThreadModel` conforms; `StaticTranscriptSource`
  for tests and demos). Observation tracks the list and the newest 256 messages individually (older finished ones are
  re-validated when the list changes). A change marks messages dirty; `sync` rebuilds only the last turn's rows while a
  reply streams (grouping never crosses a user message), finds them from the end, replaces that range in place, diffs it
  by ID (common prefix/suffix) and re-indexes only rows after the first difference, so a streaming commit costs the same
  at 1,000 or 10,000 messages (M2-F); then inserts/removes table rows with anchoring. First content is built off-main (rows, estimates, exact layouts of the bottom three
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

## Appearance (restyle 3, docs/design/visual-language.md §6 "Chat column")
`TranscriptTheme` resolves every colour from `DS.Color` (text / text2 / text3 / text4, `message`, `codeFill`, `border`,
`textSelection`, `findMatch`, semantic text tones) and every size from `DS.TextRole`: prose 14/22 (strong is semibold),
headings 18/16/14 semibold, code 12.5/19, tool rows and summaries `body` 13, tool targets mono 12, metadata `meta` 11.
User bubble: `message`, r16, padding 10/14, 21 pt lines, ≤ 80 % of the 736 pt column. Code block: `codeFill` r8 (light adds
a 70 % `border` hairline), 28 pt header with the language in mono `meta text3` and a ghost copy icon (check once copied).
Tables: no outer border, `borderStrong` under the header, `border` under rows, outer columns flush, tabular digits,
stretched to the column. Work-group line 24 pt (chevron `text4`, summary `text3`, `· 12s` `text4`); tool row 26 pt (14 pt
glyph: check `successText`, triangle `dangerText`, drawn spinner; verb `text3`; target `text`; `+n`/`−n`). The spinner
steps on `DSStepClock`; a cell subscribes only while it shows one and redraws only the spinner bands (static under Reduce
Motion). Reasoning: `text2` 13/20 beside a 2 pt guide. System events: one centred `meta text3` line. Errors: inline
triangle + `dangerText` title + message. Cards: fill only in dark, `border` 70 % in light, r10. Jump pill: outline
`DSButton` on opaque `raised`; find bar: `DSTextField(.search)` and DS icon buttons on the popover glass; `DSScroller`.

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

## Measured (release, Apple M5 Max, 165 Hz, window 900×900)
Workload: the Engine fed by MockOpenCode `.large` (10,000 messages → 13,579 rows, 2.2 M pt, 100 KB code row at the
midpoint, 100 images of 640×360). Frames: p50/p95/p99/max ms; ">16.7 ms" at 165 Hz means ≥3 missed refreshes. M1-F
column: as reported in M1 (`docs/features/transcript-bench/`). M2-B columns: `docs/spikes/transcript-perf/before/`
(commit e2fbcaf, run 2026-11-16 in the same session as the after runs) and `.../after/` (S1 and S3–S7 of both builds
were run back to back; S2 between two control runs).

| Scenario | Spike (G1-B) | M1-F production | M2-B after |
|---|---|---|---|
| S1 open → first content frame | 96 ms; all heights 570 ms; 224→138 MB | 98 ms; all 13,567 rows exact 789 ms; 329→205 MB¹ | 93 ms (before, same session: 97); measure-all 796 ms (797); **201**→217 MB (332→207) |
| S2 3× flicks down | 8.3/8.3/16.9/50.7, >33: 1 | 6.1/15.1/22.8/143, >33: 65 | 6.1/6.1/26.7/1150, >33: 445 of which **2 CPU-bound**² |
| S2 3× flicks up | 8.3/16.7/19.6/90.5, >33: 5 | 6.1/16.8/22.5/36.7, >33: 15 | 6.1/9.7/41.0/684, >33: 609 of which **2 CPU-bound**² |
| S2 realistic 1× (60 s) | 8.3/8.3/18.5/23.4, >33: 0 | 6.1/15.6/19.8/29.3, >33: 0 | 6.1/6.1/9.4/21.7, >16.7: 8 (0.1 %), **>33: 0** |
| S2 memory during the traversal | peak ~380 MB | **peak 863 MB** (malloc 594), 266 MB after | **peak 401 MB** (318 and 340 in two other runs), 221 MB after (malloc 140) |
| S2 sync layouts, geometry error | 26; 0 pt | 21; 0 pt | 175 (before-build in the same conditions: 537); 0 pt |
| S3 stream following, 100 deltas/s | 8.3/8.3/8.3/17.9 | 6.1/6.1/10.5/16.3 | 6.1/6.1/6.1/15.8, 0 >16.7; delta→visible p50/p95 49/85 ms (before: 50/201); Engine→applied 4.9/7.5 ms |
| S4 stream, reading 3 viewports up | drift 0 pt | 6.1/6.1/6.1/15.2; 0 pt | 6.1/6.1/12.4/15.3; 0 pt; released, pill, rejoined |
| S5 anchors | 0/0/0/0 pt | 0/0/0/0 pt | 0/0/0/0 pt |
| S6 resize; re-wrap 560↔1000 | max 10.9 | max 20.8; re-wrap max 48.8 | max 6.1; re-wrap max 15.1, 0 >16.7 (before: max 32.3) |
| S7 copy; find (first query) / collapsed | copy 3.1 ms; find 26 / 123 ms | copy 2.6 ms; find 305 / 81 ms | autoscroll 0 >16.7 (before: 1 >33); copy 2.0 ms; find **131 ms, 25 ms main-thread CPU**, longest frame 6.1 ms (before: 294 ms) / 33 ms (78) |
| S8 20 open/close cycles; after close | 111 MB plateau | 393–437 MB; 246 MB after close¹ | **170–199 MB** (malloc 113–127); 171 MB after close = floor 149.5 + **21.5 MB** |

¹ Footprint includes the in-process mock server and Engine holding the 10,000-message thread (the *floor*: 149.5 MB
footprint, 86 MB malloc, measured with the history loaded and no transcript ever mounted; 42 MB of it is the Engine's
SQLite page cache, most of the rest message text held by the mock and the Engine).
² A frame over 33 ms is CPU-bound when the main thread itself used ≥27 ms of CPU in it (`over33msCPUBound`). The other
slow frames had the main thread off-CPU: preempted or waiting on window-server IPC. A control run with a trivial
workload (`--scenario control`, one layer moved per frame) right before and after S2 had **14 and 50 frames over
33 ms per minute** (max 364 ms): the machine was shared with other agents' builds (load 3–15) and the locked screen
played the aerial video wallpaper. The before-build's S2 in the same conditions: 247 / 424 over 33 ms, footprint 849 MB
after the traversal (malloc 589).

**Conditions.** Display MAG321UP at 165 Hz (measured 6.06 ms), backing scale 1.0 (4K at "looks like 3840×2160"), screen
**locked** (display awake via `caffeinate -d -i -u`): frames are display-link delivery, not on-screen compositing.
Retina (2×) backing stores are 4× larger than measured here.

**Streaming commit cost against history (M2-F, review M3).** `--scenario stream-cost --large N --rate 150
--stream-seconds 12` records every sync while a tail streams (release, same machine, screen locked, load 2–8 from other
agents; reports in `docs/spikes/transcript-perf/stream-cost/`). Main-thread CPU per tail commit p50 / p95, rows touched:

| Messages (rows) | Before (fbc15e2) | After |
|---|---|---|
| 1,000 (1,367) | 0.94 / 1.37 ms, 7,832 rows | 0.22 / 0.27 ms, 7 rows |
| 5,000 (6,787) | 3.59 / 5.15 ms, 38,932 rows | 0.47 / 0.85 ms, 7 rows |
| 10,000 (13,581) | 5.52 / 6.31 ms, 77,902 rows | 0.44 / 1.05 ms, 7 rows |

What remains per commit scales with the streaming reply, not the history (its image-source check scans the reply text).

**S2/S3 after M2-F** (`docs/spikes/transcript-perf/m2-f/`, release, screen locked, load 25 → 7 during the runs from other
agents; no control run). S3: 6.1/6.1/6.1/6.1 ms, 0 >16.7, delta→visible p50/p95 38/80 ms, Engine→applied 0.9/1.2 ms
(M2-B after: 49/85, 4.9/7.5). S2 3× down / up: >33 ms 397 / 328 of which 3 / 2 CPU-bound (M2-B: 445 / 609, 2 / 2),
main-thread CPU p99 13.8 / 13.7 ms (13.7 / 13.8); realistic 60 s: 18 frames >33 ms, none CPU-bound, CPU p99 8.5 ms
(M2-B: 0, 9.7 ms; the off-CPU frames match the higher load at the start); peak footprint 330 MB (401), 230 MB after
(221); synchronous layouts 109 (175); geometry error 0 pt. No regression attributable to the change.

**Commands.** `swift build -c release --product TranscriptDemo`, then `caffeinate -u -t 2; caffeinate -d -i -u
.build/release/TranscriptDemo --scenario S2` (≈17 min; `S1`…`S8`, `all`; `--stream-seconds 20` for S3/S4). Diagnosis:
`--scenario P [--fraction 0.4] [--sample] [--hold N] [--pause-above MB]` (3× downward traversal with per-frame phase
attribution in wall and CPU time, peak sampling, per-cache malloc release, main-thread stack samples of slow frames for
`atos -p`); `--scenario control --seconds 60`; S2 `--profile` adds the phase breakdown. Reports: `build/transcript-bench/`.

## Memory and frame budget (M2-B)
**Causes found** (in-process attribution, `heap`/`leaks`/`footprint`, a main-thread stack sampler):
1. **Row views leaked into NSTableView's purgatory** (memory, new in production). `rowViewForRow` returned a fresh,
   unidentified `TranscriptRowView` per row; `NSTableRowData._rowViewPurgatory` retained every one: 11,615 row views,
   each with its own `NSISEngine`, layout aux and backing layer, after one traversal (`before/heap-census-peak.txt`).
   Live memory grew with distance scrolled and was released only by closing. Row views are now dequeued by identifier
   (17 live).
2. **64-bit backing stores** (frames and memory). On this wide-gamut display `NSViewBackingLayer` picks a 16-bit float
   format (`rgba64_*` in samples): twice the memory and a slower rasterization path. Setting `contentsFormat` on it is
   reset by AppKit; the canvas now backs onto a plain `CALayer` in RGBA8 (the view stays its delegate).
3. **A new backing surface for nearly every row drawn** (frames). Reused cells resized their canvas to each row's
   height (2,338 resizes in 2,526 draws), and each resize allocated a surface through the window server; under load the
   main thread waited on that IPC (`mach_msg` in samples). Canvas heights now come in 128 pt steps.
4. **Main-thread CPU in prefetch, eviction and accessibility** (frames). Every prefetch pass built a layout input for the
   whole window, which parsed Markdown on the main thread for each image row once any image had loaded, and every
   finished layout started a full pass (10.3 s of a 40 % traversal); eviction sorted the cache and freed layouts inside
   the frame (2.2 s); configure computed each row's full accessibility value (0.7 s); asking `isVoiceOverEnabled` took
   up to 10 ms. Now: key check first, image sources cached per row version, one prefetch pass per run-loop turn, linear
   LRU scan with release after the frame (1 ms per turn), lazy accessibility, cached VoiceOver state.
5. **Image cache** (memory): 96 MB FIFO of decoded bitmaps, each drawn image also holding a GPU-side copy: the largest
   item of the remaining peak. Now LRU by last draw, 32 MB, thumbnails ≤1,600 px.
6. **Tall-row line cache** (frames): the 100 KB code row's canvas covers ~160 lines; `MonoLines` kept 120 and dropped
   half, so every canvas reposition re-created all CTLines (a 290 ms frame). Now 320, oldest quarter dropped.
7. **Find index** built on first query (305 ms) and inserting every parsed row into the parse cache. Now built off the
   main actor in 512-row chunks on up to four utility tasks, prewarmed when the find bar opens, reading the parse cache
   without storing; one string per block (folded when offsets survive) instead of two.

**Prototype decisions.** Kept: cost-bounded layout cache (same 300 rows / 25,000 units), velocity-aware prefetch
(0.5 s ahead, 10 in flight vs 0.35 s, 8: no measured harm), layouts only for visible monospaced lines, canvas limited to
the visible part of rows over 1,000 pt (900 pt margins), background measurement at utility QoS on half the cores.
Weakened: eviction was gradual in count but not in cost (sort + inline release per store); the mono line cache was
smaller than a tall canvas; the canvas lost the stable format and size it effectively had. New costs examined: per-row
layers (cause 1), eager accessibility (cause 4), Markdown AST retention (none: the swift-markdown `Document` is not
kept; the parse cache held ~5 MB live at 4,000 rows), highlight cache (~2.5 MB), work groups (no measurable cost), the
Engine's message cache (part of the 150 MB floor; unchanged and out of scope: it is not what regressed).

| Cache | Budget | At the S2 peak | Eviction | Memory pressure |
|---|---|---|---|---|
| Layouts | 300 rows and 25,000 cost units (prose CTLines + up to 320 mono lines per block) | 300 rows, ~4,000 units, ~9 MB | LRU (linear scan), displayed rows kept; released after the frame, ≤64 queued | dropped except displayed |
| Parse (`RenderBlockCache`) | 4,096 rows, 24 MB of source text | ~4,000 rows, ~5 MB live | LRU down to ¾ | dropped |
| Highlight (`TokenizerHighlighter`) | 2 M UTF-16 units of code | ~0.8 M units, ~2.5 MB | LRU down to ¾ | dropped |
| Decoded images | 32 MB, ≤1,600 px | 32 MB | LRU by last draw, displayed kept | dropped except displayed |
| Find index | one string per block (≈ the thread's text); built on first find | 0 (S2 does not search) | per row version | dropped on critical |
| Image metadata (M2-F) | sizes: 2,048 sources, LRU (decoded kept); rows per source: loads in flight only; failures: 256 per binding | — | LRU; cleared on unbind (in flight, failures) | — |
| Accessibility text (M2-F) | one per live cell (the row's visible text and line starts), built when a client asks | 0 without a client | row or layout change | — |
| Row and cell views, canvases | AppKit reuse; canvases in 128 pt steps, tall rows viewport + 1,800 pt | 17 + 17 views, ~10 MB of canvases at 1× | — | — |

Memory pressure: a `DispatchSource` memory-pressure source owned by the controller (cancelled in `close()`).
Regression guards in `swift test` (no display needed; `CacheBudgetTests.swift`): parse, highlight, image and layout
budgets; a 1,500-row headless traversal asserting cache costs within budget and bounded row views (it fails with the
old row views: +1,495); memory pressure; first find query < 50 ms of main-thread CPU; Use Selection for Find with a
focused text view. M2-F adds: `StreamingCostTests` (rows touched per streaming commit equal at 62 and 902 rows, no copy
of the row storage, equality with a full rebuild), `FindRevealTests` (revealing an uncached 200 KB row parses and lays
out nothing on the main actor; a pending reveal is dropped on a thread switch), `ImageMetadataTests` (bounded metadata
across 30 image threads, retry of a failed load on revisit), `AccessibilityTextTests`.

## docs/research/03 section E (by the agent; no human at the screen)
Purpose/context: pass (prompts, replies, tool lines name verb, target, status and time; sub-agent cards name agent
and status; the shell's header shows project/branch/worktree). States: empty ("No messages yet"), loading older
("Loading earlier messages…"), streaming, running ("Working…"), sending, failed tool/turn/provider error,
interrupted, offline (content kept): pass by test or snapshot. Speed: toggle and copy apply synchronously; open 95 ms
for 10,000 messages. Keyboard: every command has a menu item (Edit, Find, View); arrows/Page/Home/End scroll,
Shift+arrows (Option for words, Command for ends) extend, Escape closes find then clears selection, Tab leaves;
driven programmatically only. Accessibility: rows are static-text elements with label (who/what, time), value (the
visible text), the text interface (character count, string and bounds for a range, line for an index and range for a
line from the layout's lines, range for a point, visible range, selected text and a settable selected range that is the
transcript selection) and custom actions (copy, expand/collapse, open link, open sub-agent); a finished reply is
announced once (tested); status is glyph + word, never colour only; increased contrast and text size re-resolve the theme; no
animation (Reduce Motion has nothing to remove). VoiceOver itself: unverified. Streaming and control: following only
at the bottom, 0 pt drift while reading (S4), pill debounced, selection kept while text arrives: pass. Persistence:
the scroll anchor is saved per thread and restored (tested round trip). Windows: narrow widths (column re-wraps,
S6), light/dark. Artifacts: sub-agent card opens the child thread; diff review is DiffKit's (N/A here).

## Known gaps
- Reasoning duration is measured live (BelloCore parts carry no timestamps); history shows "Thought" without one.
- Tree-sitter, Mermaid, math, GitHub alerts, `<details>`, footnotes and image zoom are not rendered (text fallback).
- Copy puts plain text and Markdown on the pasteboard, not RTF; no drag-out of a selection.
- The accessibility text interface was exercised by calling its methods in process; what AppKit's accessibility server
  exposes to VoiceOver and VoiceOver's reading by line/word/character were not checked (needs VoiceOver at the screen).
  Rows off screen have no element: reaching them relies on the table scrolling, as before.
- Tool calls fetch no detail lazily: inputs/outputs come with the message. Tool-call visibility settings (hide
  successful, zen) are not offered yet.
- Frame targets at 3× speed are met for frames our own work makes slow (2 down / 2 up over 33 ms); the total count
  (445 / 609) is dominated by off-CPU frames that a trivial control also shows on this shared, locked machine. Needs a
  run on an idle machine with the display unlocked (no other builds, no lock-screen video) to state the absolute count.
- Settled footprint after close is 171 MB in the harness, of which 149.5 MB is the mock server and Engine (floor); the
  transcript's own share is 21.5 MB. Under 150 MB absolute would need changes in Engine/MockOpenCode, outside M2-B.
- The 100 KB code row still costs up to ~300 ms of main-thread CPU on its first draw (≈160 lines realized and
  highlighted at once); later repositions reuse cached lines. Realizing lines off-main would remove it.
- Peak footprint varies by run (318–401 MB) with transient graphics and allocator memory (deferred reclaim), not live
  malloc (≤148 MB). All runs were at backing scale 1; at 2× canvases cost 4×.
- The find index is not bounded below the thread's text size (≈10 MB for the large fixture, estimated); it is built only
  when find is used and dropped under critical memory pressure.
- The in-process mock cannot sustain 100 deltas/s past ~25 s on the 10,000-message session (its per-delta cost grows
  with the reply), so S3/S4 stream 20 s; the transcript's own share was measured separately (Engine publish → laid out).

## Needs a human at the screen
Real trackpad momentum and rubber-banding (all scrolling here is programmatic), on-screen frame pacing with the display
unlocked (frames are display-link delivery), VoiceOver reading order and actions, reading and selecting by
line/word/character inside a reply, IME (the view is read-only, but
Look Up/force click and Services), hover timestamps and link tooltips, the look of the pill and find bar over vibrancy.
