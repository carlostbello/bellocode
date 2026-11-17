# Visual audit: why BelloCode reads as cheap

Scope: every PNG in `docs/snapshots/` at commit `fbc15e2`, judged against T3 Code's source (see
`visual-language.md`) and against a well-made Mac app. Ranked by how much each defect hurts the first impression.
"Snapshot artefact" items at the end are not design defects.

## Ranked defects

1. **Stock AppKit bezels in the most important card.** `app-approval-shell-dark`, `orch-agents-tree-dark`: Deny,
   Always allow and Allow once are grey `.push`/`.accessoryBarAction` bezels with the shortcut crammed inside the
   bezel (`Alw… ⌥⇧⌘Y`, `All… ⌥⌘Y` truncate at 980 px). The primary action is not visually primary: all three are the
   same grey slab. `app-question-light`: Dismiss and Submit answer are white rounded-rect push buttons from 2012.
   This card is where the user makes the riskiest decision in the app; it currently looks the least designed.
2. **No surface hierarchy; every region is the same flat grey.** `app-*-dark`: sidebar, header, transcript and
   composer are all ~`#232323`/`#262626` (`windowBackgroundColor`/`textBackgroundColor`), separated only by a
   hairline. Light (`app-running-queued-light`) is `#ececec` sidebar on `#ffffff` content with a grey header strip.
   Nothing is raised, nothing recedes. T3 uses a true-black (dark) / near-white (light) canvas with exactly one
   raised tone (`#111` / white) for the composer, cards and popovers, and a lighter tone only for the user's bubble.
3. **Bold everywhere in the sidebar.** `app-approval-shell-dark`, `nav-palette-files-dark`: every thread title is
   semibold 13 pt white, so "unread", "selected" and "ordinary" look identical and the list shouts. Project names
   are bold too. T3: thread titles regular, project names medium, metadata in a quieter grey.
4. **Status dots as the main glyph, in saturated system colours.** Sidebar rows in every `app-*` and `nav-*`
   snapshot lead with a 6 px system-blue dot, a raw orange `✋` emoji (`Worktree agent stable`) or a brown speech
   bubble. The emoji renders as a colour bitmap at the wrong optical weight; the dots repeat on every row so they
   carry no information. Needs You uses a bright orange capsule (`5`) that is louder than the selection.
5. **Coloured monogram squares.** `AT` blue and `BE` yellow tiles next to every project (`app-*`, `nav-sections`,
   the header breadcrumb). Saturated, typographically crude (bold caps at 9 pt), and they compete with status.
6. **Default segmented control and pop-up buttons for panel chrome.** `diff-app-changes-dark`: the right-panel tab
   bar is an `NSSegmentedControl` (`± Changes | Files | Browser | Terminal`) with a stock selected bezel; under it two
   `NSPopUpButton`s ("This Turn", "Turn 4:…") with up/down chevrons, a second segmented control for layout and a
   stock `…` pull-down. Four control styles in one 30 px strip. `orch-agents-tree-dark` repeats it with a fifth tab.
7. **Dense, harsh diff chrome.** `diff-app-changes-dark`, `diff-split-dark`, `diff-unified-light`: full-saturation
   red/green row fills on near-black, row-height file headers with an `M`/`A` badge in a stock square, a separate
   grey "2 unchanged lines · Click to show" bar between every hunk, and a blue "Revert" link on every hunk header.
   The gutter is the same colour as the code; nothing guides the eye to the changed tokens.
8. **System-blue selection fills.** `nav-palette-files-dark`: the palette's selected row is a saturated accent slab
   with white text; `diff-pickers-light` uses a lavender `selectedContentBackgroundColor` slab. T3 selects with a
   neutral 6–11 % foreground wash and keeps the accent for the one primary action.
9. **Weak type hierarchy in the header and transcript.** `app-approval-shell-dark`: the header title is 15 pt bold,
   the breadcrumb under it 12 pt medium with the same weight as body; two lines where T3 uses one 52 px bar. The
   transcript's assistant prose, tool rows and the "Working…" line are all 13 pt `labelColor`; tool rows differ only
   by a green tick (`transcript-workgroup-expanded-dark`). Prose at 13 pt / ~17 pt line height feels cramped.
10. **The composer looks like a text field, not the centre of the app.** `app-draft-dark-1280x800`: a 1 px grey
   rounded rectangle on the same grey, controls ("Build", "Big Pickle ⌄", "Default ⌄") as loose grey text with a
   hammer glyph, and a disabled grey circle for Send. The Stop button is a black capsule (`app-running-queued-light`)
   that reads like a toast. The project/path strip below uses folder icons twice.
11. **Inconsistent radii and padding.** Composer 12, cards 12, user bubble ~14, palette 10, model picker 8, code
   block 6, search field 4, sidebar selection 6, approval-card left accent bar 2 px with square corners. Padding
   inside the approval card is 8 px on the left (next to a 3 px orange bar) and 12 on the right.
12. **Coloured accent bars and caps labels on cards.** `app-approval-shell-dark` (orange 3 px left bar + `APPROVAL`
   in orange caps), `app-question-light` (blue bar + `QUESTION` caps). This is the "alert component" look of a web
   admin template, not a calm desktop tool. T3 attaches the request to the composer as one glass surface with a 4 %
   tint and a small icon.
13. **Stock popover and palette chrome.** `app-model-picker-dark`: square-ish dark grey panel with no border or
   shadow recipe, a search field with eye and refresh icons, provider rows with grey "not connected" text and a
   blue "Connect…" link per row. `nav-palette-files-dark`: palette 640 px wide, no scrim, the footer hint line in the
   same grey as the content.
14. **Default scrollbars.** Every transcript snapshot shows the system overlay knob at full length beside the
   content (`app-approval-shell-dark` x≈1272). Fine on its own, but it does not match the 6 px pill T3 uses.
15. **Errors and system lines styled as web alerts.** `transcript-cards-dark`, `transcript-mixed-light`: provider
   error is a red-bordered, red-tinted box with red title text; "Conversation compacted" / "Interrupted" are
   centred grey text on full-width rules. Heavy for informational events.
16. **Terminal is fine, its chrome is not.** `terminal-drawer-split-dark`: the pane itself (SwiftTerm) is good. The
   tab strip uses the standard tab-bar look with a filled selected tab and an `x`; the split/add buttons are stock.
   Prompt colours (`→` green, cyan dir) are the default ANSI palette, not matched to the app.
17. **Browser panel controls.** `browser-app-panel-light`: two stacked toolbars (tabs, then nav + URL field + find
   + menu) with stock `NSTextField` rounded bezel for the URL; the agent banner uses two stock push buttons; the
   bottom "Agent control" switch is the system switch.
18. **Settings and onboarding are acceptable.** `nav-settings-notifications-dark` is a standard Settings window
   with a toolbar and form. It is not T3-like, but it is correctly native; restyle last and lightly.

## What it adds up to

Every component was taken from the default control catalogue and coloured with `NSColor` semantic system colours.
The result is a correctly-behaved Mac app with no visual opinion: no surface ramp, no type ramp, five button
styles, four selection styles and saturated status colour used decoratively. T3 Code's look comes from a small,
disciplined set: one canvas, one raised tone, borders at 8 % white, text at three levels, one accent used once
per view, glass for floating things, 13–14 px type with medium (not bold) emphasis, 8 px control radius and 16 px
container radius.

## Snapshot artefacts (not defects)

- Popovers, the sidebar and toasts are drawn in-process with `cacheDisplay`, which cannot capture
  `NSVisualEffectView` blur. `app-model-picker-dark` and `UndoToastView` look flatter and greyer than on screen.
  The target spec still gives every material an opaque fallback colour, so this stops mattering.
- The traffic lights render as grey circles (inactive window) in every `app-*` snapshot.
- The scroll knob is drawn permanently because there is no hover/scroll state in a still render.
- Lorem-style thread titles ("Server browser an stable token") make the sidebar look broken; snapshot fixtures
  should use realistic titles (see the mock) so reviews judge the design, not the data.
- `app-model-picker-dark-1280x800.png` is a 2x render shown at 2000 px wide in some viewers; its type looks larger
  than the others for that reason only.
