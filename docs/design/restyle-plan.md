# Restyle plan: current code → `visual-language.md`

Order keeps `swift build` green after every step: tokens first (additive), then shared controls, then modules
one at a time, deleting old tokens last. Each step's evidence is the listed `docs/snapshots/` scenarios re-rendered
in both appearances and compared with `docs/design/mock/*.png`. Snapshots cannot show materials, so every glass
surface must also have its opaque fallback (that is what the PNG shows). Re-run AGENTS.md UX checklist (03 §E).

## 0. DesignSystem (one PR, additive, no visual change yet)
- `Tokens.swift`: add `DS.Color` (every token in visual-language §1) as dynamic `NSColor`s resolved for
  aqua/darkAqua/HC-aqua/HC-darkAqua; `DS.Color.accent` honours the Multicolor rule. Add `DS.Font` roles
  (`prose`, `composer`, `body`, `bodyEmph`, `title`, `label`, `meta`, `code`, `codeSmall`, `terminal`, headings)
  as `base + delta`, plus paragraph styles with the line heights. Add `DS.Radius.xs/sm/md/lg/xl`, `DS.Size`
  (header 52, row 28, control 28/24, sidebar 264, panel 416, column 736), `DS.Shadow` recipes, `DS.Motion`
  (`popIn` 120 ms + curve, `press` scale). Keep `DS.Palette`/`Typography` as deprecated aliases.
- New `Controls/` files, each layer-backed, `wantsUpdateLayer`, no cells, states from §6, unit-tested for state →
  colour mapping and accessibility role/label:
  `DSButton` (primary/outline/ghost/destructive/icon × regular/small, optional shortcut hint),
  `DSTabBar` (ghost pill tabs with counts), `DSSegmented` (track + thumbs), `DSSelectButton` (ghost select that
  opens a `DSMenuPanel`), `DSMenuPanel` (glass `NSPanel`, rows, headers, separators, keyboard nav),
  `DSTextField` (ring + focus halo), `DSCheckbox`/`DSRadio`/`DSSwitch`, `DSKbd`, `DSPill`, `DSSpinner` (arc,
  stepped, pauses off-screen), `DSScroller` (6 pt overlay knob), `DSGlassView` (NSVisualEffectView + tint +
  Reduce Transparency fallback), `DSRowBackgroundView` (inset 6 pt row fill), `DSStatusGlyph` (shape + word).
- SwiftUI mirrors: `DSButtonStyle`, `DSMenuRowStyle`, `DSToggleStyle`, `Color.ds.*`, `Font.ds.*`.
- Replace `MonogramView` uses with a `ProjectIcon` (folder glyph or favicon). Redo `CountBadge`, `UndoToastView`
  (glass, ghost Undo), `EmptyStateView` (outline button), `ToolbarButton.make` → `DSButton.icon`.
- Package: add `DesignSystem` to `AgentUI` dependencies (smallest change; it already builds against BelloCore)
  so cards and pickers use the shared styles instead of re-deriving them through `AgentUIStyle`.
- Evidence: a new `DesignSystemDemo` snapshot of every control × state × appearance (gallery PNG).

## 1. Shell and sidebar (`BelloCodeApp/Shell`, `Sidebar`, `Content/ThreadHeaderView`)
- [ ] Window: transparent title bar, full-size content, `canvas` background; header 52 holds title + crumbs +
  actions on one line; traffic lights sit in the sidebar's top 52.
- [ ] `MainSplitViewController`: replace the right-panel `NSSegmentedControl` with `DSTabBar`; dividers `border`.
- [ ] Sidebar: plain outline view, `DSRowBackgroundView`, rows 28 regular weight, glyph slot via `DSStatusGlyph`,
  two-line Needs-you rows, project header with folder icon + count + chevron, group labels sentence case, child
  guide lines, footer with connection word. Remove emoji glyphs and coloured dots; unread = dot + medium title.
- [ ] Search field → `DSTextField` variant with ⌘K `DSKbd`. `SnoozePicker` → `DSMenuPanel`.
- Evidence: `app-approval-shell-dark-1280x800`, `app-running-queued-light-1280x800`, `app-draft-dark-1280x800`,
  `nav-sections-light`, `nav-multiselect-dark`, `nav-snooze-dark`, `nav-drag-gap-light`, `orch-fanout-sidebar-dark`.

## 2. Transcript (`TranscriptKit/Layout/TranscriptTheme.swift`, `RowLayout`, `BlockLayout`, `Views/Overlays`)
- [ ] `TranscriptTheme.resolve` reads `DS.Color`/`DS.Font` (prose 14/22, code 12.5/19); bubble `message` r16;
  code block `codeFill` r8 with 28 pt header; tables without outer border; inline code style; syntax token table.
- [ ] Work group, tool rows, reasoning, running sweep (stepped, Reduce Motion static), system events as one meta
  line, errors as inline rows. Cache keys gain theme revision (rule 4) so a token change re-lays once.
- [ ] Find bar (`Overlays.swift`): `DSTextField` + icon buttons, no `.push` Done.
- Evidence: `transcript-mixed-light`, `transcript-cards-dark`, `transcript-workgroup-expanded-dark`,
  `transcript-tool-live-dark`, `transcript-streaming-table-light`, `transcript-find-dark`, `transcript-selection-light`,
  `transcript-wide-table-long-line-light`.

## 3. Composer (`ComposerKit/View/*`, `AppStyle.composer`)
- [ ] `ComposerStyle` gains radius 16, glass + outline + shadow, prompt font 14/21, insets 12/14/4, control 26.
- [ ] `ComposerControls`: controls bar as ghost selects; Send 30 pt accent circle; Stop outline capsule with red
  square; context strip (project, branch, worktree). `CompletionPanel` → `DSMenuPanel` rows. Attachment chips r8.
- Evidence: `app-draft-dark-1280x800`, `app-running-queued-light-1280x800`, `app-completion-dark-980x640`.

## 4. AgentUI cards and pickers (`AgentUI/Requests`, `Models`, `Modes`, `Accounts`)
- [ ] `PendingRequestStackView`: attached glass card (top r16, overlaps composer 16, 4.5 % semantic tint), no
  left bar or caps label; buttons `DSButtonStyle` outline/outline/primary with hints; custom radios.
- [ ] `ModelPickerView`: `DSMenuPanel` look: search row, provider headers, check slot, meta, Free in success,
  Connect… links, effort `DSSegmented`, kbd footer. `PermissionModePicker`, `AccountsViews`: same row recipe.
- Evidence: `app-approval-shell-dark-1280x800`, `app-question-light-980x640`, `app-child-approval-dark-980x640`,
  `app-model-picker-dark-1280x800`, `app-error-offline-light-980x640`.

## 5. Diff (`DiffKit/View/DiffTheme.swift`, `Changes/ChangesPanelController`)
- [ ] `DiffTheme` from `DS.Color` diff tokens; line height 19, gutter 34, word emphasis; sticky file header 34;
  hunk bar 24; collapsed-context row; hunk actions on hover only.
- [ ] Toolbar: `DSSelectButton` for scope/turn, `DSSegmented` for unified/split, `DSButton.icon` overflow; file
  rows with M/A/D badges. Remove `NSPopUpButton`/`NSSegmentedControl`.
- Evidence: `diff-app-changes-dark-1280x800`, `diff-panel-uncommitted-light`, `diff-split-dark`,
  `diff-unified-light`, `diff-words-light`, `diff-comment-dark`, `diff-pickers-light`.

## 6. Terminal (`TerminalKit/Terminal/TerminalTheme`, `TerminalTabStrip`, `TerminalFindBar`)
- [ ] ANSI palette and cursor/selection from tokens; SF Mono 12. Tab strip 32 with ghost tabs; find bar on
  `DSTextField` + icon buttons; exited-state banner with outline Restart.
- Evidence: `terminal-drawer-one-dark`, `terminal-drawer-split-dark`, `terminal-drawer-find-light`,
  `terminal-drawer-exited-light`.

## 7. Browser (`BrowserKit/Browser/UI/*`)
- [ ] One 36 pt toolbar: icon buttons + URL `DSTextField`; tab strip as ghost tabs; agent-control banner as a tinted
  info row with ghost Stop / outline Take over; `DSSwitch` for Agent control; dialogs/downloads on `DSMenuPanel`.
- Evidence: `browser-app-panel-light`, `browser-agent-control-dark`, `browser-dialog-downloads-light`,
  `browser-find-light`, `browser-inspect-light`, `browser-responsive-dark`.

## 8. Navigation and palette (`BelloCodeApp/Palette`, `Navigation.swift`)
- [ ] Palette panel 600 wide, scrim over window, 48 input, grouped rows 34 with neutral highlight, match ranges in
  semibold `text`, kbd footer. Undo toast and drop badge via `DSGlassView`.
- Evidence: `nav-palette-files-dark-1280x800`, `nav-search-light-1280x800`, `nav-undo-toast-light-1280x800`.

## 9. Orchestration (`OrchestrationUI/AgentsPanelView`, transcript child cards)
- [ ] Summary pills, tree rows with guides, status glyph + word, agent-tag pills, hover actions, report boxes.
- Evidence: `orch-agents-tree-dark`, `orch-agents-tree-light`, `orch-waiting-reports-dark`, `orch-child-view-light`,
  `orch-transcript-cards-light`.

## 10. Settings and onboarding (last, light touch)
- [ ] Keep the native Settings window and form layout; swap stock checkboxes/radios/buttons for DS controls only
  where they sit inside our panes; sentence-case section labels; empty/onboarding states use `EmptyStateView`.
- Evidence: `nav-settings-notifications-dark` plus onboarding/first-run scenarios (add one if missing).

## 11. Clean-up
- Delete deprecated `DS.Palette`/`Typography` aliases and `AppStyle` re-mapping; grep must show zero
  `bezelStyle`, `NSSegmentedControl`, `NSPopUpButton`, `.borderedProminent`, `.bordered`, `controlAccentColor` row
  fills and `selectedContentBackgroundColor` outside DesignSystem. Update snapshot fixtures to realistic titles.
- Add T3 Code's MIT notice to the acknowledgements (see visual-language.md, Attribution).
