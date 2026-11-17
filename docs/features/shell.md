# Shell: window, header, panels

The main window is sidebar | thread (with the terminal drawer under it) | right panel, in plain `NSSplitView`s with
1 pt `border` dividers (`ChromeSplitView`). Panels open and close instantly; layout, panel visibility, the right
panel's tab and the drawer height restore per window and per thread (`ShellState`).

## Appearance (Restyle 2, docs/design/visual-language.md)
- **Title bar.** Transparent, full-size content, an empty unified toolbar only so the traffic lights sit centred in
  the top 52 pt; no toolbar items, no bezels. The window title and subtitle are still kept current (Window menu,
  Mission Control, VoiceOver) but not drawn.
- **Header bar** (`Shell/WindowChrome.swift`, `ShellHeaderBar`, 52 pt, `canvas` + bottom hairline): over the sidebar
  it is transparent and carries the sidebar and new-thread icon buttons (right-aligned in the sidebar; after the
  traffic lights when the sidebar is collapsed). From the sidebar's divider to the window edge: the thread's title
  (`title`, rename in place) and crumbs (`label text2`, 12 pt glyphs: project / branch · worktree or the directory;
  draft, deleted and waiting states; container, agents and merge-request chips) (`ThreadHeaderView`), then the
  containers runtime status (when enabled), "Open ⌄" (Reveal in Finder, Open in Terminal, Copy Path) and "Commit n"
  as small outline buttons, a divider, and the terminal and right-panel toggles (on = `fillHover`). The bar spans the
  content column and the right panel, as in the mock. Empty areas drag the window; a double-click zooms or
  minimises as the system setting says.
- **Regions.** Sidebar `sidebar`, everything docked `canvas`; plain split items (the system sidebar / inspector
  behaviours would add the floating sidebar material). Show/Hide Sidebar and Show/Hide Right Panel are validated and
  retitled by the split controller and the window (no toolbar items to show or customise, so View ▸ Show Toolbar and
  Customize Toolbar… are gone).
- **Right panel.** A 40 pt `DSTabBar` (Changes, Files, Browser, Terminal, Agents, Merge Requests) with live counts
  (changed files, child threads). When the panel is too narrow, tabs from the end drop their titles (icon only, the
  title stays the accessibility label); the selected tab keeps its title.
- **Sidebar footer.** "Add project" (ghost), the connection state (6 pt dot or glyph + word, `label text2`; the state
  before the source label so the state never truncates) and Settings.
- **Banners above the composer** (status unknown, queued and unconfirmed follow-ups): DS outline / primary / ghost
  buttons, `label` text, a `raised` r16 card for "Status unknown"; the composer's context strip is `meta text3`
  crumbs.
- **Settings** is a sidebar of panes beside grouped rows on `raised` cards (`Settings/SettingsKit.swift`): DS
  switches, radio rows, segmented and select controls, outline buttons; sentence-case group labels.

Snapshots render without font smoothing and with glass drawn as its opaque fallback (in-process rendering cannot
capture vibrancy); `app-*`, `nav-*` in `docs/snapshots/`.
