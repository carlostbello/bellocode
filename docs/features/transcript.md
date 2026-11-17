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
BENCH_TABLE

## docs/research/03 section E (by the agent; no human at the screen)
CHECKLIST

## Known gaps
GAPS

## Needs a human at the screen
Real trackpad momentum and rubber-banding (all scrolling here is programmatic), on-screen frame pacing with the display
unlocked (frames are display-link delivery), VoiceOver reading order and actions, IME (the view is read-only, but
Look Up/force click and Services), hover timestamps and link tooltips, the look of the pill and find bar over vibrancy.
