# G1-A: one TextKit 2 document for the transcript

**Answer: no.** One `NSTextView` (TextKit 2, viewport layout) can hold the 10,000-message transcript, stream into
it, and give native cross-message selection and copy. It fails the G1 bar on smooth scrolling. Long jumps (find,
reveal, jump to latest from far up) stall the main thread for seconds. Anchoring holds only when I take care to
avoid TextKit's own geometry. **Recommendation: build the transcript on candidate B; keep A's ideas only for
single-message text.** Confidence: medium-high (about 75%). See "Caveats" for what could change it.

Machine: Apple M5 Max, 36 GB, macOS 27.0.1. All scenarios ran on the built-in display at 120 Hz (8.33 ms
frames), window 1100×848 pt @2x. The exception is the final S8 run: by then the main display had become a 4K
external at 165 Hz (6.06 ms), and its "missed %" uses that interval. Build: `swift build -c release`, Swift 6.4, Command Line Tools. Every run held the display awake with
`caffeinate`. The competing B spike ran on the same machine for part of the session; the runner waited for it to
be idle and logged its state, and every run cited below had B idle at start and end unless marked.
Reports: `docs/spikes/G1-A-reports/` (copies of `build/spikes/G1-A/`). `S2-final-120Hz.json` is the S2 run on the
final code; `S8-*-165Hz.json` are the steps inside S8; screenshots are in `build/snapshots/G1-A-*.png`. Run with
`.build/release/TranscriptSpikeA --scenario S1…S8|huge|find|visual`.

## Workload and build of the candidate

The workload is deterministic (seed 42): 10,000 alternating messages, 11.6 MB of source, 7.77 M UTF-16 characters
in the document, 488k attribute runs. It contains 400 tables, 1,500 code fences plus one 100 KB fence, 2,000 tool
cards, 300 reasoning blocks, 200 diffs and 100 asynchronous images. The source is 11.6 MB rather than 10, because
tool output and prose run long.

The streaming tail sends 100 deltas/s of 1–16 characters for 60 s. A tail-only parser runs off the main actor, and
commits are coalesced at 33 ms. The streamed text equals a full render in every run, and unit tests check this for
every split size from 1 to 16 and for random splits. Markdown and highlighting are hand-written (`SpikeMarkdown`).
Block backgrounds come from a custom `NSTextLayoutFragment`. Cards are a text header with a link that toggles
them. Images are `NSTextAttachment`s that grow on delivery. There are no view-backed attachments. TextKit 1 fallback
was watched for on every run and never happened.

Two changes were needed before anything else worked:
1. **Chunked `NSTextStorage`.** The stock storage memmoves its run array once per inserted run, so inserting at
   the top is quadratic. Prepending 100 messages took 364 ms, and replacing all content took 53 s. A storage with
   one chunk per message brings an edit to 1–4 ms.
2. **Native single-attribute and longest-range lookups.** Without them, TextKit's per-edit attribute fixing walked
   all 488k runs through Swift dictionary bridging (470 ms per edit, 598 ms to install history). A production
   storage would be written in Objective-C so that `string` is not copied on every access.

## Results (release, uncontended standalone runs unless marked)

| Scenario | Result |
|---|---|
| S1 cold open | First content frame 52 ms after load starts (360 ms from process launch, including 140 ms to generate the workload). Interactive at the same moment: the newest 150 messages are selectable and the view is at the bottom. Full history installed at 977 ms in one 60 ms main-thread insert, with 7% of frames missed during the install. Footprint 231 MB, resident 426 MB. |
| S2 scroll top→bottom→top at 6,000 pt/s (5.5 + 7 min) | Final code at 120 Hz: down 29% of frames missed, p95 22 ms, p99 25 ms, max 85 ms. **Up 57% missed, p95 55 ms, p99 105 ms, max 223 ms**, with 30 main-thread stalls over 100 ms. Earlier code: up 51–72% missed, worst 1.6 s, and one 34.6 s stall. At 165 Hz (S8): up 59% missed, p95 40 ms. Slow frames going up are spread evenly over the whole document. The estimated document height drifts between 1.85 M and 2.6 M pt. |
| S3 stream while following | Frames: 19% missed, p95 18 ms, p99 63 ms, max 300 ms. Delta to visible: p50 35 ms, **p95 141 ms**, max 367 ms. Commit (main actor): p50 3.8 ms, p95 11.5 ms, of which the storage splice is p95 2.5 ms and the rest is keeping the bottom pinned. Parse (off main): p95 0.2 ms. CPU 39%. Stayed pinned to the bottom. |
| S4 stream while scrolled up and scrolling | Frames: 14% missed, p95 18 ms, p99 26 ms, max 388 ms. Delta to visible: p50 32 ms, p95 109 ms. Drift during 18 pauses while streaming: **0 pt** (both by geometry and by pixels). CPU 54%. |
| S5 anchoring (pixel-verified) | Tool card expanded above the viewport, near and far: 0 pt. Late image above, near and far: 0 pt. **Prepend 100 older messages: 0, 14, 14, 14 pt** in four runs, with a **main-thread insert of 0.45–1.3 s**. Without compensation, drift reaches hundreds of points or the content no longer matches. |
| S6 resize 900→1400→900 pt over 2 s | Mid-document: 2% of frames missed, max 47 ms, and text re-wraps to the new width. **The reading position is lost.** Re-anchoring after a width change cost 3.4 s per step, so it is off. While following: stays at the bottom, but 1.0–2.4 s frames on width changes. |
| S7 select 20 messages and copy | Click plus shift-click selects 21 messages and 15,119 characters in 5 ms; copy takes 0.9 ms. A real drag with autoscroll overshoots to 598–663 messages within 0.5 s. |
| Huge 100 KB code block | Scrolling through its 36k pt: 0% missed down, 0.5% up, max 45 ms. **Jumping to it takes 5.9 s on the main thread.** |
| Find off-screen | Both needles found, selected and visible, including the one in a collapsed card, which expands. **Main-thread time 1.8–5.6 s**, all inside `relocateViewport`. The off-main model search takes 45–108 ms. |
| S8 memory (S1–S7 in one process, then 20 open/close cycles; 165 Hz) | Footprint / resident after each scenario: S1 226/429 MB, S2 447/579, S3 491/639, S7 833/2,177. Over 20 cycles the footprint plateaus (722–738 MB, then down to 279 MB) and settles at 280 MB. **Resident stays at about 2.2 GB** and is not returned to the OS. A first S8 run gave 260–336 MB footprint across cycles. No growth per cycle. |

## Behaviours

| # | Behaviour | Verdict | Why |
|---|---|---|---|
| 1 | Open at bottom | Works | Tail-first render, then history installed in one off-main build and one insert. |
| 2 | Follow, release, rejoin | Works | Scrolling up releases follow; "Jump to latest" and scrolling to the bottom both rejoin. The follow flag never flipped while streaming. |
| 3 | Anchor on changes above | Works with caveats | Holds only through `relocateViewport(to:)`. Restoring with fragment frames or forced layout drifted by 100–9,700 pt. Prepend drifts 0–14 pt (fails 2 pt in 3 of 4 runs) and stalls 0.45–1.3 s. The scroll bar thumb jumps as the height estimate changes by up to ±900k pt. |
| 4 | Cross-message select and copy | Works with caveats | Native selection crosses messages, code and cards. Copy produces clean text: collapsed cards as one summary line, images as `[image …]`, tables tab-separated, no U+FFFC. Drag autoscroll is unusable over long distances because it follows estimated positions. |
| 5 | Expand/collapse by click | Works | Header link toggles the card; header drift 0 pt; costs one card re-render plus a 1 ms splice. |
| 6 | Resize re-wraps | Works with caveats | Re-wrap is correct and smooth mid-document, but the reading position is lost; resizing at the bottom stalls 1–2 s. |
| 7 | Find off-screen and reveal | Works with caveats | Correct, including collapsed content (searched in the model), but the jump is a multi-second main-thread stall. |

## Cost of interactive content

Cards, reasoning blocks, diffs and tables are styled text, so they cost nothing extra to lay out and are part of
the selection. A toggle re-renders one card (well under 1 ms) and splices one message chunk (1–4 ms), then
re-anchors. Images are attachments; their late arrival is a single attribute edit plus re-anchoring. I built no
view-backed attachments (buttons, live diff views, terminals), so their cost in this design is **not measured**.

## Hardest problems

1. **TextKit 2 geometry is an estimate anywhere outside the laid-out viewport, and it moves.**
   - Fragment frames returned by the API disagreed with what was drawn by up to 9,700 pt. A per-frame pixel check
     over 900 steps found no visible jump, so the frames, not the pixels, were wrong.
   - Every geometry-based algorithm misbehaved because of this: anchor restore, autoscroll, reveal, stop
     conditions in the harness. The fix was always to use `relocateViewport` or hit-testing instead.
2. **Long-distance navigation is O(distance)** on the main thread: 1.8–5.9 s for find, reveal and jumps.
3. **Scrolling up into content not yet laid out** misses 40–70% of frames.
4. **The storage layer needed rewriting.** The stock storage is quadratic for top inserts, and a Swift subclass pays
   bridging costs.

## Effort to production quality

The following is an estimate, not a measurement. It would take 8–12 engineer-weeks to reach production quality,
and the result is still uncertain:
- an Objective-C chunked storage;
- incremental background pre-layout or a custom viewport manager to remove the upward-scroll hitches and the long
  jumps;
- view-backed attachments for interactive widgets;
- an accessibility pass.

The two core risks, scroll hitches and the cost of long jumps, are inside TextKit 2 and were not removed by any
mitigation I tried: a viewport stabiliser, layout prefetch, or full pre-layout (8.6 s and +1.6 GB, and it did not
remove the problems).

## Caveats and what is unverified

- The input is synthetic (pixel scroll-wheel events at 6,000 pt/s, and clicks delivered straight to the text view
  because a shell-launched window cannot become key). It is not a real trackpad with momentum.
- The display-link latency is the presentation time of the next frame, accurate to about ±1 frame.
- `sample` could not attach for later profiling, so the S3 frame drops beyond the commit cost are not attributed.
- VoiceOver, IME and Dark/Light switching were not tested.
- Results get worse within one long session. After a full scroll, S3 missed 34% of frames and S4 21% (19% and 14%
  when run on their own), and S6 at the bottom produced 4–7 s frames.
