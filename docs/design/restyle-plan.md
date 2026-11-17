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
