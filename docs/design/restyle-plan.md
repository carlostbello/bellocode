# Restyle plan: current code → `visual-language.md`

Order keeps `swift build` green after every step: tokens first (additive), then shared controls, then one module
per PR, old tokens deleted last. Evidence = the listed `docs/snapshots/` scenarios re-rendered in light and dark,
compared with `docs/design/mock/*.png`. Snapshots cannot capture materials, so each glass surface's opaque fallback
is what the PNG shows. Run the AGENTS.md UX checklist (03 §E) per step.

## 0. DesignSystem (additive, no visual change yet)
- `Tokens.swift`: `DS.Color` (all §1 tokens, dynamic for aqua / darkAqua / both HC variants; accent honours the
  Multicolor rule), `DS.Font` roles as `base + delta` with paragraph styles, `DS.Radius` xs–xl, `DS.Size` (header
  52, row 28, controls 28/24, sidebar 264, panel 416, column 736), `DS.Shadow`, `DS.Motion.popIn/press`. Keep
  `DS.Palette`/`Typography` as deprecated aliases until step 11.
- New controls (layer-backed, `wantsUpdateLayer`, no cells; state→colour and accessibility unit-tested):
  `DSButton` (primary/outline/ghost/destructive/icon × regular/small, shortcut hint), `DSTabBar`, `DSSegmented`,
  `DSSelectButton`, `DSMenuPanel` (glass `NSPanel`, rows, headers, keyboard nav), `DSTextField`,
  `DSCheckbox`/`DSRadio`/`DSSwitch`, `DSKbd`, `DSPill`, `DSSpinner` (stepped, pauses off-screen), `DSScroller`,
  `DSGlassView` (effect view + tint + Reduce Transparency fallback), `DSRowBackgroundView`, `DSStatusGlyph`.
  SwiftUI mirrors: `DSButtonStyle`, `DSMenuRowStyle`, `DSToggleStyle`, `Color.ds`, `Font.ds`.
- Rework `CountBadge`, `UndoToastView`, `EmptyStateView`, `ToolbarButton`; replace `MonogramView` with
  `ProjectIcon` (folder glyph or favicon).
- Package (smallest outside change): add `DesignSystem` to `AgentUI`. Evidence: a control × state × appearance gallery.

## 1. Shell and sidebar (`BelloCodeApp/Shell`, `Sidebar`, `Content/ThreadHeaderView`)
Transparent title bar, one-line 52 pt header (title, crumbs, outline actions, panel toggles); `DSTabBar` replaces
the right-panel `NSSegmentedControl`; plain outline view with `DSRowBackgroundView`, regular-weight 28 pt rows,
`DSStatusGlyph`, two-line Needs-you rows, folder project headers, sentence-case groups, child guides, footer; no
emoji, no dots-as-status; search via `DSTextField` + ⌘K; `SnoozePicker` on `DSMenuPanel`.
Evidence: `app-approval-shell-dark-1280x800`, `app-running-queued-light-1280x800`, `app-draft-dark-1280x800`,
`nav-sections-light`, `nav-multiselect-dark`, `nav-snooze-dark`, `nav-drag-gap-light`, `orch-fanout-sidebar-dark`.

## 2. Transcript (`TranscriptKit/Layout/TranscriptTheme`, `RowLayout`, `BlockLayout`, `Views/Overlays`)
Theme from `DS` (prose 14/22, code 12.5/19, syntax table); bubble `message` r16; code block r8 + 28 pt header;
borderless tables; work groups, tool rows, reasoning, stepped running sweep, one-line system events, inline errors;
theme revision in the layout cache key (rule 4); find bar on DS controls.
Evidence: `transcript-mixed-light`, `transcript-cards-dark`, `transcript-workgroup-expanded-dark`,
`transcript-tool-live-dark`, `transcript-streaming-table-light`, `transcript-find-dark`, `transcript-selection-light`.

## 3. Composer (`ComposerKit/View/*`, `AppStyle.composer`)
Glass r16 container with outline and shadow, prompt 14/21, ghost-select controls bar, 30 pt accent Send, outline
Stop with red square, context strip; `CompletionPanel` on `DSMenuPanel`.
Evidence: `app-draft-dark-1280x800`, `app-running-queued-light-1280x800`, `app-completion-dark-980x640`.

## 4. AgentUI cards and pickers (`AgentUI/Requests`, `Models`, `Modes`, `Accounts`)
Request card attached to the composer (top r16, 16 pt overlap, 4.5 % tint), no accent bar or caps label, outline /
outline / primary buttons with hints, custom radios; model picker with provider headers, check slot, Free in
success, Connect… links, effort `DSSegmented`, kbd footer; mode and account pickers on the same row recipe.
Evidence: `app-approval-shell-dark-1280x800`, `app-question-light-980x640`, `app-child-approval-dark-980x640`,
`app-model-picker-dark-1280x800`, `app-error-offline-light-980x640`.

## 5. Diff (`DiffKit/View/DiffTheme`, `Changes/ChangesPanelController`, `DiffViewController`)
Diff tokens, 19 pt lines, 34 pt gutter, word emphasis, sticky file header, hunk bar, collapsed-context row, hover-only
hunk actions; toolbar on `DSSelectButton`/`DSSegmented`/icon button; M/A/D badges. No pop-ups or segmented controls.
Evidence: `diff-app-changes-dark-1280x800`, `diff-panel-uncommitted-light`, `diff-split-dark`, `diff-unified-light`,
`diff-words-light`, `diff-comment-dark`, `diff-pickers-light`.

## 6. Terminal (`TerminalKit/Terminal/TerminalTheme`, `TerminalTabStrip`, `TerminalFindBar`, pane/surface)
Token ANSI palette, cursor and selection; SF Mono 12; 32 pt ghost tab strip; DS find bar; outline Restart.
Evidence: `terminal-drawer-one-dark`, `-split-dark`, `-find-light`, `-exited-light`.

## 7. Browser (`BrowserKit/Browser/UI/*`)
One 36 pt toolbar (icon buttons, URL `DSTextField`), ghost tabs, agent banner as a tinted info row (ghost Stop,
outline Take over), `DSSwitch`, dialogs and downloads on `DSMenuPanel`.
Evidence: `browser-app-panel-light`, `browser-agent-control-dark`, `browser-dialog-downloads-light`,
`browser-find-light`, `browser-inspect-light`, `browser-responsive-dark`.

## 8. Navigation and palette (`BelloCodeApp/Palette`, `DesignSystem/Navigation.swift`)
600 pt glass palette, window scrim, 48 pt input, grouped 34 pt rows with neutral highlight and semibold match
ranges, kbd footer; undo toast and drop badge on `DSGlassView`.
Evidence: `nav-palette-files-dark-1280x800`, `nav-search-light-1280x800`, `nav-undo-toast-light-1280x800`.

## 9. Orchestration (`OrchestrationUI/AgentsPanelView`, child cards in the transcript)
Summary pills, tree rows with guide lines, glyph + word status, agent-tag pills, hover actions, report boxes.
Evidence: `orch-agents-tree-dark`/`-light`, `orch-waiting-reports-dark`, `orch-child-view-light`, `orch-transcript-cards-light`.

## 10. Settings, onboarding, clean-up
Settings: keep the native window and form; DS controls inside our panes only; first-run and empty states on
`EmptyStateView` (evidence `nav-settings-notifications-dark` + a first-run scenario to add). Then delete the deprecated aliases and `AppStyle` re-mapping. Grep outside DesignSystem must find no `bezelStyle`,
`NSSegmentedControl`, `NSPopUpButton`, `.borderedProminent`, `.bordered`, or accent/`selectedContentBackgroundColor`
row fills. Switch snapshot fixtures to realistic thread titles. Add T3 Code's MIT notice to the acknowledgements.

## Restyle status
- **Step 1, shell and sidebar: done** (Restyle 2). Transparent title bar + drawn 52 pt header bar, one-line title and
  crumbs, outline Open / Commit, panel toggles, hairline dividers, plain split items; plain outline sidebar with the
  row recipe, drawn cells, status glyphs, two-line Needs-you rows, folder project rows, sentence-case sections, child
  guides, footer with connection state; `DSTabBar` right panel with counts; banners above the composer; snooze
  popover. 2,000 threads (debug): one-thread change p50 23.4 ms, filter rebuild p50 84 ms, scroll step p95 2.0 ms.
- **Step 8, palette and toasts: done.** 600 pt glass palette (opaque fallback in stills), scrim, 48 pt input, 34 pt
  drawn rows, key caps, neutral highlight. Open p50 23.5 ms, keystroke p95 5.8 ms (2,000 threads, debug).
- **Step 10, settings: done for the shell's panes** (sidebar of panes, grouped rows, DS controls). Pane bodies owned
  by other modules (Scheduled Tasks, GitLab, Secrets, Accounts) are embedded unchanged. Not done: deleting the
  deprecated aliases, realistic snapshot fixture titles, the MIT notice.
- Left stock on purpose: the snooze date field (`DatePicker`, no DS date control), settings sliders (no DS slider),
  the containers download `ProgressView`, `NSAlert` confirmations, plain `NSMenu` context and "Open" menus.
- Steps 2–7 and 9 belong to the module agents.
## Restyle status: conversation surfaces (restyle 3: TranscriptKit, ComposerKit, AgentUI, OrchestrationUI)
Done: transcript (step 2), composer (step 3), request cards and pickers (step 4), Agents panel (step 9), plus the
scheduled-tasks, merge-request and secrets panes. Evidence in `docs/snapshots/`: `transcript-*`, `composer-*`,
`requests-*`, `models-*`, `modes-*`, `onboarding-*`, `accounts-*`, `orch-*`, `extras-*` (light and dark; solid glass
fallback; no font smoothing). DesignSystem additions: `DSTextFieldStyle`, SwiftUI hint drop in `DSButtonStyle`, more
`Color.ds` tokens (gallery row added).
Differs from the mock: the request card is not yet overlapped by the composer (the shell lays them out; set
`agentUIAttachedOverlap` and overlap by 16 in `RequestStackSurface`); the shell's context line and `AppStyle` mappings
are still the shell's (ComposerKit and AgentUI ignore their visual fields; `ComposerContextStrip` is ready to adopt);
Queue/Steer keep a labelled capsule instead of the plain circle (UX rule 5); the running row has no highlight sweep.
Left stock on purpose: `NSMenu` context and follow-up menus (native), the sign-in method `Picker` when a provider has more
than three methods (`.menu` in a DS outline button), `DatePicker`, `Stepper` and the `Form` pickers of the Scheduled
Tasks settings pane (native Settings window per step 10), SwiftUI `.plain` button style used as a hit target for DS-drawn
rows and radios.
## Restyle status: restyle 4 (diff, terminal, browser, containers, integration) — restyle complete
All steps 0–10 are done. Evidence: `docs/design/after/` (twelve renders and `contact-sheet.png`) and the refreshed
`docs/snapshots/` (light and dark; glass drawn as its solid fallback; no font smoothing; 1x renders, the mock is 2x).
- **Seams.** The request card attaches to the composer (`agentUIAttachedOverlap` = `DS.Size.attachedOverlap` 16, no
  stack edges when attached); status-unknown, delivery-unknown and queued rows share one `raised` tray attached above the
  card or composer; the shell's context line feeds ComposerKit's `ComposerContextStrip` (with the send-key hint);
  `AppStyle` keeps only the hero height, placeholder and text-size fonts. Right-panel tabs use one density for the whole
  bar (all titled → selected titled, others icon + count → all icon + count), icon-only tabs carry tooltips and
  accessibility labels. The runtime status item is a DS button inside the header bar (it used to draw below it) and
  the header crumbs truncate and detach from the end instead of drawing under Open/Commit. Bubble and composer right
  edges align on the 736 column.
- **Diff (step 5).** Token theme (19 pt lines, 34 pt file header, 24 pt hunk bar and context row, `text4` gutter),
  M/A/D badges, folder `text3` + name, hover/focus-only ghost Revert, DS toolbar (selects, segmented, ghost icons), flat
  file list on the row recipe with mixed-state stage boxes, DS commit box, find bar and comment popover, glass
  workspace/branch pickers. Headless DiffKit tests pass; the release scroll benchmark needs an unlocked screen.
- **Terminal (step 6).** Token ANSI palette (light, dark, both HC), canvas, 32 pt ghost tabs, DS find bar, exited bar,
  pill and empty state. SwiftTerm's own scroller is private to SwiftTerm and stays the system overlay knob.
- **Browser (step 7).** One 36 pt toolbar, URL `DSTextField` with the security glyph, ghost tabs, tinted banners
  (ghost Stop, outline Take Over), DS find bar, downloads shelf, switch, info-tone agent cursor and highlight.
- **Containers / Environment.** Settings recipe (grouped rows), DS fields, pills, Verify Isolation rows, Ports rows,
  `DSProgressBar` for pulls.
- **Step 10 leftovers.** Realistic fixture titles and prose (same seeded draws, so IDs and counts are unchanged);
  Settings ▸ Acknowledgements with T3 Code's MIT notice, opencode, ripgrep and the linked packages (licence texts
  copied into the bundle by `make-app.sh`); deprecated `DS.Palette`, `DS.Spacing`, legacy type names and radii,
  `MonogramView`, `SidebarRowView`, `ToolbarButton` deleted. New DS controls: `DSMenuSelect`, `DSStepper`,
  `DSSlider`, `DSProgressBar`, `DSToggle.isMixed`, `glassPopover`, `DSComposerSelectStyle`, `DSBareTextField`,
  `DSTextField.leadingSymbolName` (gallery rows added).

Left stock on purpose: `DatePicker` in the snooze popover and the Scheduled Tasks editor (no DS date control; the
native field keeps per-component keyboard entry, locale and VoiceOver), `NSAlert` confirmations, `NSMenu` context and
select menus (spec), the snooze `NSPopover` chrome, SwiftTerm's scroller, WebKit page content.

Still differs from the mock: unified diffs keep two line-number columns (old and new) where the mock shows one; the
diff file header is not sticky; Queue/Steer keep a labelled capsule (UX rule 5); fixture tables, code and file names in
generated transcripts are still synthetic; stills cannot show glass, hover or the running sweep.

### UX acceptance checklist (03-ux-patterns.md §E), restyled surfaces, agent run without a person at the screen
- Purpose and context: pass — header crumbs, composer context strip, Changes status line and terminal/browser footers
  name project, branch and workspace; narrow headers drop the container crumb first (the drawer strip still shows it).
- States: pass in renders — empty (no project, no thread, no terminals, new tab, no changes), loading ("Loading
  changes…", spinners), stale ("Updating…"), offline (`integ-error-offline`), failure (Failed: + glyph), success.
- Speed and feedback: partial — no layout or animation was added to streaming paths; transcript cost and cache tests,
  the composer typing metric (p95 0.40 ms) and harness timings pass; frame timing on screen not measured (bench below).
- Keyboard: pass by construction — every DS control is a first-responder control under Full Keyboard Access; menus and
  shortcuts unchanged (shortcut-uniqueness test passes); DS fields keep AppKit field editors (IME, undo).
- Accessibility: partial — labels, roles and values on new controls (tabs, stepper, slider, select, mixed checkbox,
  icon-only tabs); status is glyph + word everywhere checked; VoiceOver not run.
- Parallelism, approvals, streaming and control, artifacts and safety, persistence, onboarding: unchanged behaviour,
  covered by the existing suites (three full passes).
- Windows and integrations: 980 and 1280 widths rendered; two windows, monitors, drag and drop not exercised.
- Evidence: macOS 27.0 (Darwin 27.0.0), Command Line Tools build, opencode 2.3.0, Rancher Desktop smoke check passed.

### Needs a person at a real screen
Materials (glass vibrancy and Reduce Transparency), text weight at 2x without the snapshot's disabled smoothing,
hover and pressed states (Revert, tabs, rows, slider knob), drag (tab reorder, slider, split dividers), VoiceOver
announcements for the new controls, the attached card/composer seam while the composer grows, DiffDemo `--bench`
frame timing with an unlocked screen, and the menu-based selects' popup placement.
