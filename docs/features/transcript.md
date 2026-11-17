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
