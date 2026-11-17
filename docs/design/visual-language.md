# BelloCode visual language

Target: T3 Code's visual language, built natively. Mock: `docs/design/mock/index.html` (PNGs beside it); where
they disagree, this file wins. **Principles:** one canvas, one raised tone, one accent; hierarchy from tone and
weight, not colour or borders; status = glyph shape + word; floating things glass, docked things solid; nothing
animates while content streams.

**Attribution.** Palette, metrics and recipes are derived from T3 Code (github.com/pingdotgg/t3code, MIT, © 2026
T3 Tools Inc.), mainly `apps/web/src/index.css` and `apps/web/src/components/**`; refs are `file:line` at the clone
of 2026-11-16, cross-checked with the installed Nightly 0.1.10 CSS. BelloCode's acknowledgements must carry T3
Code's MIT licence notice. No T3 logo, name, wordmark, stage artwork or other brand asset is used.

## 1. Colour tokens
Implement as `DS.Color` dynamic `NSColor`s (`NSColor(name:dynamicProvider:)`) with four variants: light, dark,
light + Increase Contrast, dark + Increase Contrast (the HC notes under each table list the changes).

### Surfaces (elevation)
| Token | Dark | Light | Use | Source |
|---|---|---|---|---|
| `canvas` | `#000000` | `#FCFCFC` | Window, transcript, right panel, terminal | index.css:1117,1193 (`--background`) |
| `sidebar` | `#000000` | `#FAFAFA` | Sidebar | index.css:1172,1236-1259 (`[data-app-sidebar]`) |
| `raised` | `#111111` | `#FFFFFF` | Composer, attached cards, menus, popovers, palette, toasts | index.css:1196-1199 (`--card`,`--popover`,`--surface-raised`) |
| `message` | `#1E1E1E` | `#EBEBED` | User message bubble | index.css:1141,1208 |
| `codeFill` | white 3.5 % | `#FAFAFA` + `border` 70 % | Code blocks, command previews | MarkdownCodeBlock.tsx:66 (`bg-input/32`, `bg-secondary`) |
| `fillSubtle` | white 3 % | `#FAFAFA` | Search field, segmented track, report boxes | `--muted`/`--secondary` |
| `fillHover` | white 4 % | `#F4F4F5` | Ghost-control hover/pressed, selected tab | `--accent` index.css:1146,1205 |
| `scrim` | canvas 64 % + blur 4 | canvas 60 % + blur 4 | Behind palette and dialogs | index.css `dialog-backdrop` |
| `rowHover` | `#F1F3F7` 8 % | `#F4F4F5` | Sidebar/list row hover | index.css:1271 |
| `rowActive` | `#F1F3F7` 11 % | `#FFFFFF` + inset ring `#E4E4E7` 70 % | Current thread | index.css:1272; SidebarThreadRow.tsx:990 |
| `rowSelected` | `#F1F3F7` 7 % | `#FFFFFF` + same ring | Multi-select, file list | index.css:1273 |

Increase Contrast: `raised` dark `#161616`; borders become 20 % (dark) / `#A1A1AA` (light); `fillHover` doubles.

### Text
| Token | Dark | Light | Use |
|---|---|---|---|
| `text` | `#F5F5F5` (sidebar `#F1F3F7`) | `#18181B` | Titles, prose, values |
| `text2` | `#A1A1A1` | `#71717A` | Secondary labels, control labels, tool verbs |
| `text3` | `#8F8F8F` | `#71717A` | Row metadata, section labels (`--secondary-label` index.css:1277) |
| `text4` | `#A1A1A1` 55 % | `#71717A` 60 % | Timestamps, gutters, chevrons, disabled |
| `icon` | `#A1A1A1` 90 % | `#71717A` | Default icon tint (`--sidebar-icon-color` index.css:106) |
| `placeholder` | = `text2` | = `text2` | Composer and field placeholders |

HC: `text2`/`text3` move to `#C4C4C4` / `#52525B`; `text4` becomes `text3`.

### Borders
| Token | Dark | Light | Use |
|---|---|---|---|
| `border` | white 8 % | `#E4E4E7` | Panel dividers, row dividers, card edges (index.css:1213,1153) |
| `borderStrong` | white 11 % | `#D4D4D8` | Outline buttons, inputs, popover edge (`--input`) |
| `composerOutline` | white 5 % + inner top highlight white 3 % | black 8 % | Composer and attached cards (ComposerSurface.tsx:16-17) |

### Accent, semantic, selection, focus
| Token | Dark | Light | Notes |
|---|---|---|---|
| `accent` | `#346BF1` (oklch .571 .21 264) | `#1B4ED8` (oklch .488 .217 264) | Primary button, Send, focus ring, caret, checkmarks. index.css:1131,1200 |
| `accentHover` | accent 90 % on canvas | same | |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | |
| `success` / `successText` | `#00BC7D` / `#00D492` | `#00BC7D` / `#007A55` | Done, additions |
| `warning` / `warningText` | `#FE9A00` / `#FFB900` | `#FE9A00` / `#BB4D00` | Needs you, approvals |
| `danger` / `dangerText` | `#FB414A` / `#FF6467` | `#FB2C36` / `#C10007` | Failed, Stop, deletions |
| `info` / `infoText` | `#2B7FFF` / `#51A2FF` | `#2B7FFF` / `#1447E6` | Running, questions, links in prose |
| `*Surface` | semantic 16 % | semantic 8 % | Pills and tinted cards (`--warning-surface`) |
| `textSelection` | accent 30 % | accent 20 % | `NSTextView.selectedTextAttributes` |
| `findMatch` / `findActive` | `#8C6C1F` / `#EEA52B` | `#FFDE8B` / `#EEA52B` | index.css:408-425 |
| `focusRing` | accent, 2 px, inset | same | button.tsx (`ring-2 ring-inset ring-ring`) |

**Accent and the user's choice.** If the user's system accent is Multicolor (`AppleAccentColor` unset), use
`accent` above. Otherwise use `NSColor.controlAccentColor` for every `accent` use. Never use
`selectedContentBackgroundColor` or `controlAccentColor` as a row fill.

### Diff, code and terminal
| Token | Dark | Light |
|---|---|---|
| `diffAddLine` / `diffAddGutter` / `diffAddWord` | `#00BC7D` 10 / 16 / `#00D492` 28 % | `#00BC7D` 8 / 14 / 22 % |
| `diffDelLine` / `diffDelGutter` / `diffDelWord` | `#FB414A` 10 / 16 / `#FF6467` 28 % | `#FB2C36` 7 / 12 / 20 % |
| `diffHunk` | `#51A2FF` 7 % fill, `text3` mono 11 | `#2B7FFF` 6 % |
| `diffModifiedIcon` | `infoText` 65 % | `infoText` 50 % mixed with `text2` (index.css:1284-1289) |
| Syntax (kw/type/fn/str/num/comment/prop) | `#FF7AB2 #6BDFFF #67B7A4 #FC6A5D #D0BF69 #7F8C98 #A167E6` | `#9B2393 #0B4F79 #326D74 #C41A16 #1C00CF #5D6C79 #6C36A9` |
| Terminal bg / fg / cursor / selection | canvas / `text` / `#B4CBFF` / `#B4CBFF` 25 % | canvas / `text` / `#26384E` / `#253F63` 20 % (index.css:1185-1230) |

Syntax colours are Xcode's default themes (T3 uses Shiki themes we cannot ship verbatim); keep them a token table.

## 2. Typography
Families: **SF Pro** via `NSFont.systemFont` (T3's stack starts `-apple-system`, index.css:176) and **SF Mono** via
`NSFont.monospacedSystemFont` (`ui-monospace, "SF Mono"`, index.css:179). No bundled fonts. Fallbacks are the
system's. Use `monospacedDigitSystemFont` (or `.monospacedDigit()`) for counts, times and diff stats.

| Role | Size / line | Weight | Tracking | Use |
|---|---|---|---|---|
| `prose` | 14 / 22 | regular, strong 600 | 0 | Assistant prose, user bubble (21 line) |
| `prose.h1/h2/h3` | 18 / 23, 16 / 21, 14 / 18 | semibold | 0 | Markdown headings (index.css h1 1.25rem → scaled 0.9) |
| `composer` | 14 / 21 | regular | 0 | Prompt text (T3 prompt default 14, settings.ts:167) |
| `body` | 13 / 18 | regular | −0.08 (SF default) | Sidebar rows, menu rows, palette rows, table cells |
| `bodyEmph` | 13 / 18 | medium (500) | | Project names, button labels, card titles |
| `title` | 13 / 18 | semibold | | Thread header title, approval question |
| `label` | 12 / 16 | regular / medium | | Composer controls, crumbs, tabs, toolbar selects |
| `meta` | 11 / 14 | regular | +0.06 | Row metadata, section labels (medium), kbd, pills |
| `code` | 12.5 / 19 | regular | 0 | Code blocks (T3 default 13, settings.ts:168) |
| `codeSmall` | 11.5 / 19 | regular | 0 | Diffs, command previews (12), tool targets (12) |
| `terminal` | 12 / 1.2 | regular | 0 | Terminal (ghostty/surface.ts:25) |

Rules: medium is the emphasis weight in chrome; semibold only for the thread title, headings and table headers;
**never bold sidebar rows**. Section labels are sentence case, 11–12 pt medium `text3`, never all caps. All sizes
scale with `DS.Typography.baseSize` (13 default) as `base + delta`.

## 3. Spacing, sizing, radii
Spacing scale (pt): 2, 4, 6, 8, 10, 12, 14, 16, 20, 24. Gutter of the chat column 24; content max width 736
(`--chat-content-max-width: 46rem`, index.css:131).

| Metric | Value | Source |
|---|---|---|
| Title bar / header height | 52 | `--workspace-topbar-height` index.css:123 |
| Sidebar width | 264 (min 220, max 360) | |
| Right panel width | 416 (min 320) | `--thread-details-panel-width` family |
| Sidebar row | 28 (two-line Needs-you row 40), inset 8 from sidebar edge, content inset 10 | index.css:104-111 |
| Control heights | 28 default, 24 small, 26 composer control, 30 send, 20 micro | button.tsx sizes `sm:h-8/h-7/h-6` |
| Menu / picker row | 28–30; palette row 34; palette input 48 | menu.tsx `sm:min-h-7`; command.tsx |
| Icon box | 16 (glyph 14 in rows, 12 in meta) | button.tsx `size-4` |

| Radius | Value | Use |
|---|---|---|
| `r.xs` | 4 | kbd, pills, inline code, badges |
| `r.sm` | 6 | sidebar rows, small buttons, diff file rows |
| `r.md` | 8 | buttons, inputs, tabs, code blocks, picker rows, popovers' inner rows (`--control-radius`) |
| `r.lg` | 10 | menus and pickers (`rounded-lg` + 2) |
| `r.xl` | 16 | composer, attached cards, palette, user bubble (`rounded-2xl`) |
| Window | system | Never draw our own window corners. All other radii use `cornerCurve = .continuous`. |

## 4. Borders, shadows, materials
- Borders are 1 px hairlines drawn **inside** (inset ring), never outside. Dividers between regions are `border`.
- Cards inside the transcript have no border in dark (fill only), `border` 70 % in light.
- `shadow.composer`: dark `0 14 32 −18 black 75 %`; light `0 1 2 black 5 %` (index.css `--shadow-composer*`).
- `shadow.popover`: dark `0 18 44 −18 black 80 %` + inner top highlight white 4 %; light `0 16 40 −18 black 35 %`
  (menu.tsx). `shadow.dialog`: `0 24 72 −20 black 90 %` (index.css `dialog-glass`).
- Buttons with fill: inner top highlight white 16 %; pressed: inner top black 8 % (index.css:196-197).

Materials (NSVisualEffectView): T3's glass is `background 80 % + blur 12–16 px + saturate 1.08–1.14`
(index.css:119-121). Native mapping:

| Surface | Native | Fallback (Reduce Transparency, snapshots) |
|---|---|---|
| Menus, pickers, completion list, palette, toasts, tooltips | `.popover` / `.menu`, `.behindWindow` in own `NSPanel`, plus a `raised` 80 % tint layer | `raised` |
| Composer and attached request cards | `.withinWindow`, `.headerView`, `raised` 80 % tint | `raised` |
| Thread header and right-panel tab bar | solid `canvas` + scroll-edge fade (24 pt) | same |
| Sidebar | solid `sidebar` (T3 is solid). Optional setting "Translucent sidebar": `.sidebar` material | `sidebar` |
| Transcript, diff, terminal | solid `canvas` | — |

## 5. Icons
T3 uses Lucide at 16 px with stroke 1.75 (index.css:1731). Use **SF Symbols**: `.regular` weight, `.medium` scale,
13 pt point size in a 16 pt box (14 pt glyph rows: 12 pt; meta: 10 pt `.semibold` for checks only), tinted `icon`;
monochrome rendering; no filled variants except status dots and the Stop square. Map: search `magnifyingglass`,
new thread `square.and.pencil`, sidebar `sidebar.left`, right panel `sidebar.right`, terminal `apple.terminal`,
branch `arrow.triangle.branch`, worktree `square.on.square.dashed`, folder `folder`, approval `exclamationmark.shield`,
question `questionmark.bubble`, failed `exclamationmark.triangle`, done `checkmark`, changes `plusminus`, files
`doc.on.doc`, browser `globe`, agents `point.3.connected.trianglepath.dotted`, send `arrow.up` (`.semibold`), copy
`doc.on.doc`, attach `paperclip`. Running is a 12 pt drawn arc spinner (1.5 pt stroke, `infoText` head, `borderStrong`
track), not `NSProgressIndicator`. No emoji anywhere. No coloured monograms: projects get a `folder` glyph, or the
project's favicon if one exists (T3 `ProjectFavicon.tsx`), at 14 pt.

## 6. Components
Every control is custom-drawn: `DSButton: NSControl` (layer-backed, `wantsUpdateLayer`, draws fill, ring,
highlight from tokens per state; no `NSButtonCell`), SwiftUI `DSButtonStyle`/`DSMenuRowStyle` for hosted views.
States everywhere: **rest, hover** (tracking area), **pressed** (scale 0.97 on buttons, T3 button.tsx
`active:scale-[0.97]`; none under Reduce Motion), **selected**, **disabled** (opacity 64 %), **focused** (2 pt inset
accent ring, only for keyboard focus via `focusRingType = .none` + own ring when `window.firstResponder` is us and
`NSApp.isFullKeyboardAccessEnabled` or the focus came from Tab).

### Buttons
| Variant | Rest | Hover | Pressed | Notes |
|---|---|---|---|---|
| Primary | `accent` fill, `onAccent` text, top highlight, shadow `accent` 24 % 0 1 2 | `accentHover` | no shadow, inner black 8 % | One per view (Allow once, Send, Create) |
| Outline (secondary) | `raised`/white 3.5 % fill, `borderStrong` ring, `text` | fill `fillHover` / white 6 % | no shadow | Deny, Always allow, Commit, Open |
| Ghost | none, `text` (or `text2` muted) | `fillHover` | `fillHover` | Toolbars, row actions, Stop/Retry in rows |
| Destructive | `danger` 90 % fill, white | `danger` | | Confirmed destructive only |
| Icon | 28×28 (24 small), ghost recipe, `icon` tint → `text` on hover | | | Never a bezel |
Height 28, padding 10, `label` 13 medium (small: 24 / 8 / 12). Shortcut hint inside the button: `meta` 11 medium at
62 % opacity, 4 pt after the label; drop the hint before truncating the label.

### Sidebar
Search field (28, `fillSubtle` + `border` ring in dark, `#F4F4F5` light, ⌘K kbd). "Needs you" label + warning
count pill; each Needs-you row is two lines: title `body` + sub `meta` with the status **word** coloured
(`Approval` warningText, `Question` infoText, `Failed` dangerText) and the project. Project header 30, folder glyph,
name `bodyEmph`, count `meta text3`, disclosure chevron at the right (`text3`, 12). Group labels (Pinned, Working,
Active, Snoozed, Settled) 24 high, `meta` medium `text3` + count `text4`, indented to the title column (34).
Thread row 28: 14 pt glyph slot (spinner / shield / bubble / check / triangle; empty when idle), title `body`
regular, trailing relative time `meta text4`. Settled rows recede (`text3`). Child threads indent 22 more with a 1 px
`border` guide line. Selected = `rowActive`; never accent. Unread = 6 pt `infoText` dot in the glyph slot **plus**
`bodyEmph` title (the only time weight changes). Footer 44: "Add project" ghost, connection dot + word, settings icon.
Native: `NSOutlineView` with `.plain` style, `selectionHighlightStyle = .none`, own `NSTableRowView` drawing the
row fill with 6 pt radius inset 8 from the edges; no source-list style.

### Thread header (52, one line)
Title `title`; crumbs `label text2` with 12 pt glyphs: project / branch · worktree; spacer; outline-small
"Open ⌄" and "Commit n"; divider; icon toggles for terminal and right panel (on = `fillHover`). The window's title
bar is transparent (`titlebarAppearsTransparent`, `fullSizeContentView`), traffic lights in the sidebar's top 52.

### Chat column
- User bubble: right-aligned, max 80 %, `message` fill, `r.xl`, padding 10/14, `prose` 14/21. Grouped consecutive
  messages get a 6 pt radius on the joined corners (TimelineUserMessageRow.tsx:905-913).
- Assistant prose: no container, `prose`, paragraph gap 10, list gap 4, inline code 0.86 em on `text` 10 %, r.xs.
- Code block: `codeFill`, `r.md`, header 28 (language `meta` mono `text3`, copy icon-button), body padding 6/14/12.
- Table: no outer border; header `body` semibold with `borderStrong` bottom; rows `border` bottom; cell padding 6/12,
  first/last column flush (index.css:2264-2300). Numbers right-aligned, tabular.
- Work group (collapsed): one 24 pt line, chevron 12 + summary `body text3` + `· 12s` `text4`. Expanded: child tool
  rows indented 18 with no box (TimelineWorkGroupRows.tsx).
- Tool row: 26 high, status glyph 14 (check successText, triangle dangerText, spinner), verb `text3`, target `text`
  (mono 12 for paths/commands), diff stat `+n` successText `−n` dangerText. Output expands into a `codeFill` box.
- Running indicator: spinner + label with a moving highlight sweep (2.2 s, stepped, `live-tool-shine` index.css)
  and elapsed `text4`. Under Reduce Motion: no sweep, static `text3`.
- Reasoning: collapsed "Thought for 4s" row in the work-group style; expanded text `text2` 13/20, left guide 2 pt
  `border`.
- System events (compacted, interrupted, model changed): one centred `meta text3` line, no rules.
- Errors: inline row with triangle `dangerText` + message `text`; a `dangerSurface` card only for blocking errors.

### Composer
Container `raised` (glass), `r.xl`, `composerOutline` ring, `shadow.composer`. Prompt inset 12/14/4, `composer`
font, min 1 line (hero 3), max 40 % height. Controls bar: padding 6/8/8, controls 26 high, `label` 12, `text2`,
14 pt glyph + chevron 12 `text4`; hover/open = `fillHover` + `text`. Order: attach, agent mode (Build/Plan), model,
reasoning effort, permissions; spacer; Stop (outline capsule, red 8 pt square + "Stop") while running; Send 30 pt
circle `accent` with `arrow.up` white. Send when running queues; tooltip and the strip under the composer say
"↩ queues · ⌘↩ steers". Disabled Send: `text` 12 % fill, `text2` glyph. Under the composer, a 26 pt context strip:
project, branch, worktree (`meta text3`, 12 pt glyphs).

### Approval and question cards
Attached above the composer as one object: same glass surface, top radius 16, overlaps the composer by 16 so the
seam disappears (ComposerBanner.tsx). Tint: semantic 4.5 % over `raised`. Row 1: 16 pt glyph (shield warningText /
bubble infoText), question `title`, one-line reason `text2`, time `meta text4`. Command preview in `codeFill`
mono 12, indented to the text column (24). Footer: risk note `label` with a 12 pt glyph; actions right-aligned:
outline Deny, outline Always allow, primary Allow once, each with its shortcut hint. Question: options are 28 pt
rows with a custom 14 pt radio (ring `borderStrong`, selected fill `accent` + white dot); Submit is primary,
Dismiss is ghost. Multiple pending: "1 of 3" with ‹ › icon buttons in the header.

### Right panel
Tab bar 40: tabs are ghost pills 26 high, padding 7, `label` 12 medium, 14 pt glyph, count `meta text3`;
selected = `fillHover` + `border` ring (light: white + ring + 0 1 2 black 4 %). Not an `NSSegmentedControl`.
Changes toolbar 36: scope select (ghost select: text + `chevron.up.chevron.down` 12), file count + stat, a 2-segment
layout toggle (custom: `fillSubtle` track, 20 high thumbs `rowActive`), overflow menu. File list rows 26 with a
14 pt M/A/D badge (r 3, semantic 14 % fill, mono 9 bold), name `label`, folder `text3`, stat right.
Diff: sticky file header 34 (`canvas`, `border` bottom), hunk bar 24 `diffHunk`, lines 19 high `codeSmall`, gutter 34
`text4` 10.5 pt, line fills per §1 with word emphasis; collapsed context "14 unchanged lines" 24 high with
`border` top and bottom. Hunk actions (Revert, Comment) appear on hover only.

### Terminal drawer
`canvas` background, 1 px `border` top, tab strip 32 with ghost tabs (selected `fillHover`), close glyph appears on
hover; split/add as icon buttons. ANSI palette derived from the semantic tokens (red = dangerText, green =
successText, yellow = warningText, blue = infoText, cyan `#6BDFFF`/`#0B4F79`, magenta `#A167E6`/`#6C36A9`).

### Command palette
Centred `NSPanel` 600 wide, 96 from the window top, `r.xl`, glass, `borderStrong` ring, `shadow.dialog`, scrim
over the whole window. Input 48 (`magnifyingglass` 16 `text3`, 15 pt text, scope pill). Groups: label 28 `meta`
medium `text3`. Rows 34, `r.md`, icon 14 `icon`, title `body` with match ranges in `text` semibold and the rest
`text2`, subtitle `label text3`, kbd on the right. Highlight `text` 9 % (dark) / 6 % (light); never accent.
Footer 38: `text` 2.5 % fill, `border` 7 % top, kbd hints. (command.tsx)

### Menus, popovers, model picker
Own `NSPanel` (or `NSMenu` for plain context menus, which stays native). 10 radius, glass, `borderStrong` ring,
`shadow.popover`, padding 4. Rows 28–30, `r.sm`, highlight `fillHover` (dark white 7 %). Group headers 26 `meta`
medium `text3` with a right-aligned status. Separator 1 px `border` inset 8. Model rows: check 14 `accent` in a
leading slot, name `body`, trailing `meta text3` context and price; Free in `successText`. Unconnected providers
recede (`text3`) with a `Connect…` link in `infoText`. Effort: segmented control (custom, as above). Footer kbd hints.

### Inputs, toggles, kbd, pills, toasts, empty states, scrollbars
- Text field: 28 high, `r.md`, `canvas` fill, `borderStrong` ring, focus → accent ring 1 + 3 pt accent 24 % halo.
- Checkbox 14 r 4, switch 26×16 track (`borderStrong` → `accent`), radio 14. All custom-drawn.
- Kbd: 18 high, min 18, `r.xs`, `text` 8 % (dark) / 6 % fill, `meta` medium `text2`.
- Pills (status, counts, agent tags): 18 high, padding 6, `r.xs`, semantic surface + semantic text, `meta` medium.
- Toast: bottom-centre, glass, `r.lg`, 36 high, icon + text + ghost "Undo"; auto-dismiss 6 s; no slide under
  Reduce Motion.
- Empty state: centred, 32 pt glyph `text4`, `body` title, `label text2` hint, one outline button. No illustrations.
- Scrollbars: overlay style, custom `NSScroller` knob 6 wide, radius 3, `scrollThumb` (dark white 36 %, light
  `#D9D9D9`), hover white 45 % / `#BFBFBF`; no track.

## 7. Motion
- Panels, sidebar, right panel, terminal drawer: **instant** (T3 default 0 ms, settings.ts:166). Same under Reduce Motion.
- Hover/pressed fills: immediate. Button press scale 0.97, release 100 ms ease-out; no scale under Reduce Motion.
- Popover, menu, palette: in = opacity 0→1 + scale 0.98→1, 120 ms `cubic-bezier(0.32,0.72,0,1)` (`--ease-drawer`);
  out = 80 ms fade. Reduce Motion: fade only. Sidebar row reorder: 150 ms ease-out (Sidebar.motion.ts:1).
- Streaming: a new block fades in once (opacity, 150 ms, index.css `data-streaming`); nothing else moves.
- Spinner, live sweep, status pulse: stepped (6–30 steps), paused off-screen; static glyph under Reduce Motion.
- Never animate layout, scroll position, row height, or anything driven by a stream delta.

**Density.** Rows 26–30, controls 24–28, 13 pt body, no 44 pt touch targets, no sheets for routine work. Whitespace
comes from the 736 column and 24 gutters, not from padding inside controls.

## 8. Ten rules
| Do | Don't |
|---|---|
| 1. Use the surface ramp: canvas → raised → message. | Paint regions in different greys or add borders to separate them. |
| 2. Select with a neutral wash (`rowActive`). | Fill rows, palette results or tabs with the accent colour. |
| 3. Spend the accent once per view (the primary action). | Make every link, count and status blue. |
| 4. Regular weight for rows; medium for emphasis. | Bold sidebar titles, project names or button labels. |
| 5. Status = glyph shape + word, colour as a third cue. | Coloured dots, emoji or caps labels as the status. |
| 6. Custom-draw every control from tokens. | Ship any `NSButton` bezel, `NSSegmentedControl`, `NSPopUpButton` or `.borderedProminent`. |
| 7. Glass for floating surfaces, solid for docked ones. | Glass on the transcript or sidebar list; opaque grey popovers. |
| 8. 8 pt controls, 16 pt containers, continuous corners. | A different radius per component. |
| 9. Hairlines inside, 8 % white / zinc-200. | 1 pt opaque grey borders on cards and dark-mode boxes. |
| 10. Instant panels; motion only for feedback. | Animate streaming, layout or panel toggles. |
