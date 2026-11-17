# Restyle implementation guide (for module agents)

Source of truth: `visual-language.md`. Code: `Sources/DesignSystem/Tokens/` (tokens) and `Controls/` (controls).
Gallery: `swift run DesignGallery` → `build/snapshots/design/{tokens,controls,menus,composition}-{dark,light}.png`
(copies in `docs/snapshots/design-*.png`); `swift run DesignGallery --dump-tokens` prints every value.

## Tokens: what to use for what
- Surfaces: `DS.Color.canvas` (window, transcript, panels, terminal), `.sidebar`, `.raised` (composer, cards, menus,
  toasts), `.message` (user bubble), `.codeFill` (code, command previews), `.fillSubtle` (search, tracks), `.fillHover`.
- Text: `.text`, `.text2` (labels, verbs), `.text3` (metadata, section labels), `.text4` (timestamps, chevrons,
  disabled; below AA by design, never for content), `.icon`, `.placeholder`. Sidebar titles `.sidebarText`.
- Lines: `.border` (dividers, card edges), `.borderStrong` (inputs, outline buttons, popover edge), `.composerOutline`.
- Status: glyph + word, colour third: `.warningText` approval, `.infoText` question/running/links, `.dangerText`
  failed, `.successText` done; fills/surfaces `.warning`/`.warningSurface` etc. `DS.Color.tone(_:)` returns all three.
- Selection: rows `.rowHover`/`.rowSelected`/`.rowActive` (+ `.rowRing` in light); palette/menu highlight
  `.highlight`/`.fillHover`; text `.textSelection`. **Never** `accent` or `selectedContentBackgroundColor` as a fill.
- Accent (`.accent`, `.accentHover`, `.focusRing`) follows the user's macOS accent unless Multicolor. One per view.
- Diff/syntax/terminal: `.diff*`, `.syntax*` (also `DS.Syntax.*`), `.terminalCursor`, `.ansiCyan`, `.ansiMagenta`.
- Type: `DS.TextRole` (`.prose`, `.composer`, `.body`, `.bodyEmph`, `.title`, `.label(Emph)`, `.meta(Emph)`, `.code`,
  `.codeSmall`, `.terminal`); `NSFont.ds(.body)`, `Font.ds(.body)`, `role.attributes(color:)` for line height and
  tracking. All scale with `DS.Typography.current.baseSize`. Medium for emphasis; never bold rows.
- Metrics: `DS.Space.s2…s24`, `DS.Size.*` (header 52, rows 28, controls 28/24, column 736…), `DS.Radius.xs…xl`
  (`DS.Radius.apply(_:to:)` sets continuous corners), `DS.Shadow.*`, `DS.Motion.*`, `DS.Surface` for materials.
- Legacy `DS.Palette`, `DS.Typography.title/caption/…`, `DS.Spacing`, `DS.Radius.small/…` now alias the new values.
  Replace them as you touch code; they are deleted in restyle step 10.

## Replacing stock controls
| Stock | Use |
|---|---|
| `NSButton` push/accessoryBar/`.bordered*` | `DSButton(title:variant:size:symbolName:shortcutHint:)`; SwiftUI `.buttonStyle(DSButtonStyle(.primary, hint:))` |
| Icon `NSButton`, toolbar toggles | `DSButton(icon:accessibilityTitle:)`; `isToggle = true` for panel toggles |
| `NSSegmentedControl` (panel tabs) | `DSTabBar(items:)` with `DSChoiceItem(id:title:symbolName:count:)`; `onSelect` |
| `NSSegmentedControl` (layout, effort) | `DSSegmented`; SwiftUI `DSSegmentedPicker` |
| `NSPopUpButton` / pull-down | `DSSelectButton(title:symbolName:chevron:)` + `popUpMenu` (plain) or `onOpen` → `DSMenuPanel` |
| Custom popover lists, pickers, completion | `DSMenuPanel(entries:)` (`show(below:)`), or embed `DSMenuListView` (`look = .palette`) |
| `NSTextField` with bezel, `NSSearchField` | `DSTextField(style: .standard/.search)`; edit through `.field` |
| `NSButton` checkbox/radio, `NSSwitch` | `DSToggle(kind:)`; SwiftUI `.toggleStyle(DSToggleStyle(.switch))` |
| Coloured dots, emoji, `NSProgressIndicator` spinner | `DSStatusGlyphView` / `DSSpinner`; SwiftUI `StatusLabel` |
| `MonogramView` | `ProjectIcon` (folder glyph or favicon) |
| Count capsules, tags, kbd text | `CountBadge`, `DSPill(_:tone:)`, `DSKbd` (SwiftUI `DSPillView`, `DSKbdView`) |
| Source-list selection, row highlight | `DSTableRowView` (table `selectionHighlightStyle = .none`, `.plain`), `DSRowBackgroundView` |
| Opaque popovers, `NSVisualEffectView` | `DSGlassView(surface: .popover/.composer)`; content in `contentView` (flipped) |
| Boxes, cards | `DSCard(style: .raised/.inset/.tinted(tone)/.message)` |
| Default scrollers | `DSScroller.install(on: scrollView)` |

## Snapshot acceptance
1. Re-render your module's scenarios (restyle-plan.md lists them) in light and dark.
2. Put each next to `docs/design/mock/*.png` at the same scale (mock is 2x). Check surface ramp, weights, radii,
   status glyph + word, one accent, no stock bezel. Then the UX checklist (03-ux-patterns.md §E).
3. Glass is drawn opaque in stills (in-process rendering cannot capture vibrancy): set
   `DSGlassView.forcesSolidFallback = true` in harnesses and say so in your report.
4. Render without font smoothing (`cgContext.setShouldSmoothFonts(false)`, see `Sources/DesignGallery/Sheet.swift`):
   `cacheDisplay` darkens stems and makes 13 pt regular look medium, unlike the mock.

## Pitfalls
- Dynamic colours resolve at draw time. Take `.cgColor` only inside `draw(_:)`, `updateLayer()` or
  `effectiveAppearance.performAsCurrentDrawingAppearance`; redraw in `viewDidChangeEffectiveAppearance`.
- Inside `extension DS` the name `Color` is `DS.Color`; write `SwiftUI.Color` there.
- Increase Contrast variants only resolve when the system setting is on; tests use `DS.Variant(matching:)`.
- Focus: controls take keyboard focus only under Full Keyboard Access (like `NSButton`), so clicks never steal focus
  from the composer or terminal. Draw focus with `drawFocusRingIfNeeded`; `focusRingType = .none`.
- Rows are virtualised: one `draw(_:)` fill per row, cached template symbols (`DSDraw.symbol`), and spinners on the
  shared `DSStepClock` (one timer, subscribers only while on screen). No per-row timers, effect views or shadows.
- Press scale is a layer transform; never animate frames or layout. Panels stay instant (`DS.Motion`).
- `@State` does not compile here (no SwiftUI macro plugin): use `@StateObject` over an `ObservableObject`.
- Text on light hover (`text2` on `rowHover`) is 4.4:1 with spec values; do not put long secondary text there.
