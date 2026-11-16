# G1-B: virtualised AppKit rows for the transcript

**Question.** Can a virtualised list of reusable, self-sizing AppKit rows carry 10,000 messages with a streaming tail,
smoothly and with stable anchoring, and how good can cross-row text selection be made? **Answer: yes on performance and
anchoring; cross-message drag selection and copy work through a transcript-level model, but without native text-system
extras (see caveats).** Code: `Sources/TranscriptKit/SpikeRows/`, harness `Sources/TranscriptSpikeB/`. Reports:
`docs/spikes/G1-B/*.json` (copies of `build/spikes/G1-B/`), snapshots in `build/snapshots/G1-B-*.png`.

**Setup.** Apple M5 Max (18 cores, 36 GB), macOS 27.0.1, `swift build -c release`, window 900×900 pt at 2× on the
MAG321UP OLED reported at **120 Hz** (8.33 ms frames; the panel can do 165 Hz but ran at 120). The session was **locked**
during all runs (display kept awake with `caffeinate`): frame numbers are main-thread display-link delivery and watchdog
stalls; WindowServer compositing was not exercised. The competing G1-A spike shares this machine; every run waited for it
(and any compiler) to be idle and logs contamination; the final run (22:34–22:55 UTC) had none. Workload: seed 42,
10,000 messages, 10.4 MB, 400 tables, 1,500 fences + one 100 KB fence, 2,000 tool calls, 300 reasoning, 200 diffs,
100 async images; transcript height 3.08 M pt. Run: `.build/release/TranscriptSpikeB --scenario all`.

## Results (final run)

| Scenario | Result |
|---|---|
| S1 cold open | open → first content frame **96 ms** (off-main open pass 72 ms), interactive 96 ms, process launch → first frame 459 ms (incl. 180 ms workload generation). Background: exact heights for all 9,983 rows 570 ms (utility QoS, 9 cores), search index 82 ms. Footprint 224 MB at open, 138 MB settled (live malloc 61 MB). |
| S2 scroll top→bottom→top | Traversal at 3× realistic flicks (mean 6,740 pt/s, peaks ~40k pt/s), 454 s + 458 s: p50/p95/p99/max **8.3 / 8.3 / 16.9 / 50.7 ms** down, **8.3 / 16.7 / 19.6 / 90.5 ms** up; >16.7 ms: 630 (1.2 %) / 2,574 (5.0 %); >33 ms: **1 / 5**. Realistic 1× flicks, 60 s (mean 3,240 pt/s): 8.3 / 8.3 / 18.5 / 23.4 ms, 247 >16.7 ms (3.6 %), **0 >33 ms**. Watchdog: 2 stalls >50 ms (122 ms) in 15 min. 26 synchronous layouts of 23,842. NSTableView geometry error vs model: 0 pt. |
| S2 synthesised wheel | 20 s of `CGEvent` pixel scroll events with phases into `NSScrollView.scrollWheel(with:)`: 0 frames >8.3 ms, but NSScrollView moved only 225 pt (it ignores synthetic momentum): **not a usable driver**; all other numbers use per-frame programmatic user scrolling. |
| Pathological 100 KB fence | One 32,834 pt row. Frames while it was visible (1,415): p99 8.3 ms, max 17.1 ms. |
| S3 stream, following | 65 s, 100 deltas/s (6,493 deltas, 55 KB, prose + tables + fences): frames 8.3 / 8.3 / 8.3 / 17.9 ms, 1 >16.7, 0 >33. Delta→visible **p50 24.9 ms, p95 40.2 ms**, max 124 ms. CPU 9.7 % of one core. Distance from bottom while following: 0 pt. No dropped deltas (produced = applied). |
| S4 stream, scrolled up | 60 s reading/scrolling 3 viewports up: 8.3 / 8.3 / 8.3 / 20.9 ms, 10 >16.7, 0 >33. Anchor drift while reading: **0 pt** (21 phases). Released on scroll up; no unexpected follow; rejoined by Jump to Latest (distance 0) and by scrolling to bottom. CPU 28 %. |
| S5 anchors | Drift **0 pt** for: expand tool card above (+452 pt), late image above (+195 pt), prepend 100 messages; visible pixels changed 0.02 % (scroller). Expanding a card above **during** 900 pt/s scrolling: 0 pt error vs user travel. |
| S6 resize 900→1400→900 in 2 s | 8.3 / 8.3 / 8.3 / 10.9 ms, 0 >16.7. Anchor block moved 0 pt during and after; 0 % pixels differ after the round trip. Re-wrap at 1,400 checked visually. |
| S7 selection + copy | Drag from a message start to below the view, autoscroll across **25 messages** (3 fences, 3 collapsed cards, 4 tables): autoscroll frames p99 8.3 ms, max 17.3 ms. Copy 3.1 ms, 13,252 chars; 0 of 86 middle blocks missing, fences verbatim, collapsed cards → header only, tables → TSV. Selection survived scrolling ±30,000 pt (rows reused) and copied identically. |
| Find off-screen | Prose 3,000 rows away: found + revealed 26 ms. Text inside a collapsed tool output 2,500 rows away: card auto-expanded, centred, highlighted, 123 ms. |
| S8 memory | After S1–S7: footprint 174 MB (live malloc 44 MB). 20 open/close cycles: footprint plateaus at 111 MB from cycle 8, malloc 44.5 MB constant. After close: 111 MB. During long fast scrolling footprint peaks ~380 MB while live malloc stays ~90 MB (allocator high-water from layout churn, returned on close). |

## Behaviours

| Behaviour | Status | Notes |
|---|---|---|
| 1 Open at bottom | Works | Exact layout for the bottom 3 viewports off-main; estimates elsewhere, corrected in the background with anchoring. |
| 2 Follow / release / rejoin | Works | Release on upward wheel or live scroll; rejoin at bottom or via Jump to Latest (menu item + button). |
| 3 Anchor on height change above | Works | Anchor is (item ID, block, offset); 0 pt in every case, including during scrolling. |
| 4 Drag-select ≥20 messages + copy | Works with caveats | Transcript-level model, hit-testing, custom drawing, autoscroll, survives reuse, model-based copy. Missing: highlight in gaps between blocks, Shift+arrow extension, accessibility text ranges, Services/Look Up, rich-text copy. |
| 5 Expand/collapse by click | Works | Header hit-test on mouse-up without drag; async relayout, one frame. |
| 6 Resize re-wraps | Works | Visible rows re-laid out off-main per frame (stale layout drawn clipped for ≤1 frame); others re-measured after resize ends. |
| 7 Find off-screen + reveal | Works | Off-main search over a plain-text index; expands collapsed cards. Spike UI is a bare search field. |

## Design (what made it fast)

- **NSTableView**, one column, `heightOfRow` from our cache, no row selection. Chosen over NSCollectionView: per-row
  height notification is mature and cheap (≤6 ms for 2,700 rows), no layout object to keep in sync. Rows are CoreText
  custom-drawn (no SwiftUI `Text`, no `NSTextView` per row).
- Layout off-main (`@concurrent`, result handed back with `sending`, no `@unchecked Sendable`); keyed by item revision,
  UI-state version and width; LRU bounded by count and CTLine cost with incremental eviction.
- Monospaced blocks never wrap: height = lines × line height (no typesetting), CTLines created lazily per visible line.
- Prefetch looks ahead by velocity (0.35 s of travel), ≤8 layouts in flight. Tail-only streaming: the parser is
  prefix-stable at block starts, so each 33 ms commit re-parses and re-lays out only the open block (unit-tested at every
  delta); one job in flight, latest wins.

## Hardest problems

1. **NSTableView silently estimates row offsets** for rows it has not queried: its document drifted 43,000 pt from our
   heights and moved rows during scrolling, invisible to the anchor logic. Fix: query `rect(ofRow:)` from the first changed
   row on every height change (≈0.5 µs/row; 0 pt error since). This is undocumented behaviour; production must keep a
   regression test for it.
2. **Background work starved frame delivery.** Measuring all rows at the inherited user-initiated QoS on all 18 cores
   delayed the first frame by 600 ms with the main thread idle. Fix: utility QoS, half the cores, coalesced commits.
   CoreText shaping also contends on an internal lock, so more threads do not help.
3. **Cache churn.** A 500-layout count limit evicted 100 layouts at once: bursts of 60–100 ms frames and 520 MB footprint.
   Fix: cost bound + incremental eviction + velocity-aware prefetch (S2 >33 ms frames 543 → 6).
4. **Huge row.** The 100 KB fence costs O(lines) to measure; drawing touches ~60 lines; rows taller than 1,000 pt draw into
   a canvas covering only the visible part plus 900 pt, so no 33,000 pt backing layer. Lines over 400 UTF-16 units are
   truncated on screen (copy is complete); code has no horizontal scroll yet.
5. **Selection** needed its own model: positions are (item ID, block, UTF-16 offset), so selection survives reuse and
   relayout; copy reads the model, so off-screen rows copy correctly. Everything a text view gives for free beyond
   drag/copy/word/block selection is still to build.

## Effort to production (estimate, one engineer)

About **9–12 weeks**: swift-markdown + tree-sitter highlighting and tail reconciliation (2 w); selection parity
(keyboard extension, gap highlight, context menu, drag-out, rich copy, grapheme edges) (2 w); accessibility: per-row
`NSAccessibility` text elements with ranges and a transcript-level selection that VoiceOver can read (3 w, highest
risk, untested here); horizontal scroll for code and wide tables, focusable controls inside cards (approvals) (2 w);
find bar with all-match highlighting, theme changes, Reduce Motion, perf regression tests (1–2 w).

## Recommendation

The row design **passes the G1 bar on this machine**: no frame over 33 ms in any realistic-speed scenario, anchor
drift 0 pt in every case, follow/release/rejoin correct, delta→visible p95 40 ms. The plan assumed B would mean
per-message selection only; that assumption is wrong: cross-message drag selection and copy work. What B lacks is the
native text system's free features, chiefly accessibility. **Recommend B unless G1-A matches these numbers on the same
machine** (then A's native selection and accessibility should win). Confidence: **high** for performance and anchoring
(measured, release, repeated); **medium** for selection reaching text-view parity at the estimated cost. Unverified:
real compositing (locked screen), 165 Hz, VoiceOver, IME (read-only view), full-length traversal at 1× speed.
