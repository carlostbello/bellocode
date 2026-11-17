# Built-in browser (M4-A)

Status: done 2026-11-16 against opencode 2.3.0 and MockOpenCode. A WKWebView pane per window that the person and the
thread's agent share, the agent driving it through opencode's `experimental.browser` bridge (gate G3).

## Architecture
- **OpenCodeKit** `Browser/`: `BrowserContract.swift` holds every wire type of contract v4 (one file per version);
  `pluginRPC`/`browserRPC` (`POST /api/rpc/{rpcID}/{method}`, own URLSession so pending `attach` calls never starve the
  shared pool); `BrowserAttachment` (actor): attach handshake, `attached` barrier, ordered state/result outbox with
  retry, command fetch → perform → result with our deadline (below the server's 60 s), local vs server cancel; session
  instruction entries; `EventFilter.types`.
- **Engine** `Browser/BrowserBridgeService` (`engine.browser`): one hub subscription for control events routed by
  connection ID; per-thread bind/unbind, retry with backoff on transport loss, at most 8 attachments (LRU parks the
  rest), republish after stream gaps, per-thread "agent control" switch (app preference), observable status.
- **BrowserKit** `Browser/`: `BrowserTab` (web view live or suspended to a snapshot + WebKit `interactionState`),
  `BrowserTabSet` (a thread's tabs; the bridge host with ownership/pause/generation/dialog gates), `BrowserOperations`
  (from the spike), `AgentScript` (isolated `WKContentWorld`), `NativeInput`, `BrowserWorkspace` (sets, ≤ 8 live web
  views, off-screen parking window for agent work in undisplayed tabs, per-project `WKWebsiteDataStore(forIdentifier:)`,
  ephemeral private tabs, history, downloads, persistence), `UI/` (pane, tab strip, toolbar, bars, find, shelf).
- **App** `Content/BrowserSurface.swift`: "Browser" right-panel tab following the displayed thread, Browser menu (router
  → key window), terminal links, dev-server offers, picks → composer; Settings ▸ Browser (+ "Your Chrome").
- Persistence: app preferences in the projection store (`browser.set.<session>`, `browser.sets` ≤ 200,
  `browser.history` ≤ 500, `browser.controlDisabled`). No schema migration.

## Contract version
`attach {version: 4}`. opencode 2.3.0 answers another version with `400 RpcError {type: "rpc.invalid_input",
message: "Expected 4 at [\"version\"]"}` (seen on the real binary); an `attached` control with another version is
treated the same. Status becomes `incompatible`: the footer and a bar say "Agent bridge incompatible … Browsing works;
the agent cannot control it", nothing retries. The mock reproduces the answer (`setBrowserContractVersion`).

## Operations (`OperationSupport.matrix`, also the source of the guidance text)
| Status | Operations |
| --- | --- |
| Supported | tabs.*, navigate, back, forward, reload, stop, frames, snapshot, find, evaluate, click, fill, fill_form, select, check, press, wait, screenshot (png/jpeg), dialog, console, files.upload, files.list/get (captures **and completed downloads**, new) |
| Reduced | hover (CSS :hover only in a key window), scroll (no wheel), drag/files.drop (synthetic), network.list/get (Resource Timing) |
| Unsupported → `[browser.unsupported]` | preview, trace.*, cpu.*, heap.*, lighthouse |
Since the spike: screenshots of background tabs work (parking window); suspended tabs resume on use; new codes
`not_shared`, `user_control`, `control_disabled`; results over 512,000 characters → `too_large`.

## Ownership and safety
- The agent sees only shared tabs: tabs it opened (marked ✦) and tabs the person shares (person icon). Private tabs
  (lock) are never published, saved or shareable. Unpublished tabs are unknown to the server; the host checks again.
- A real click or key in a tab the agent drove in the last 8 s pauses the agent there (`user_control`; reading still
  works) until Resume. Stop cancels running commands (`cancelled`); Take Over = Stop + pause. A bar names the running
  action; the agent cursor and an element outline show clicks. User input is told apart by an app event monitor that
  ignores the agent's synthesized events.
- Agent control can be turned off per thread (footer switch, Browser menu): detaches at once, removes the guidance.
- Permission: the plugin itself appends `{browser,*,allow}` on attach and removes it on detach, so no approval card
  is raised for `browser.*`; the per-thread switch is the gate. Camera/microphone: denied unless allowed in the bar
  (60 s → deny), remembered per site only while the app runs; geolocation has no public WKWebView delegate and stays
  denied. HTTP sign-in credentials go straight to WebKit, never stored or logged. Injected scripts run in an isolated
  world; the page world only gets the console hook (untrusted).

## Model guidance
Session instruction entry `bellocode.browser` (`PUT /api/experimental/session/{id}/instructions/entries/{key}`),
rendered by opencode as `<context key="bellocode.browser">` in the system instructions: WebKit not Chromium, the
unsupported/reduced lists, localhost is the user's Mac, shared-tab and pause rules, dialogs first. Written on attach,
deleted on unbind or control off. Verified on 2.3.0: asked without tools, the agent listed preview, trace, cpu, heap
and lighthouse as unavailable.

## Verification
`swift test` (OpenCodeKit `BrowserContractTests` 6 + `BrowserAttachmentTests` 9, Engine `BrowserBridgeServiceTests`
6, BrowserKit `BrowserLogicTests` 8, app `BrowserShellTests` 2 incl. whole-menu shortcut uniqueness). `swift run BrowserDemo --selftest` 119/119,
`--bridge` 14/14 (Engine + mock + WKWebView), `--snapshots`, `--e2e` (real 2.3.0, `opencode/big-pickle`, 2 prompts,
isolated temp data): form completed with native trusted input (`tabs.open, wait, snapshot, fill×2, select, check,
click, evaluate`), reply `Confirmation BC-87 …`, guidance verified, version mismatch seen, server exited.
Snapshots: `docs/snapshots/browser-{app-panel-light,agent-control-dark,inspect-light,responsive-dark,find-light,
dialog-downloads-light}.png`; app `--snapshot` state `browser`.

## Section E checklist (agent, no human at the screen)
Purpose/context: footer names status, shared tab count, project › thread; tab tooltips name ownership. States: empty,
new tab, loading (progress), failure/crash (Try Again/Reload), suspended (snapshot), agent running, paused, dialog,
permission, sign-in, offline/incompatible/replaced bridge: by self-test and snapshots. Speed: tab and thread swaps
< 100 ms (tests). Keyboard: every command in the Browser menu; ⌃⌘B Show Browser, ⌘L/⌃⌘[/⌃⌘]/⌘R/⌘+/-/0, ⌃⌘T/⌃⌘W/⌃⌥⌘T, ⌃⇥ (⌘[ ⌘] ⇧⌘T ⇧⌘B stay with Go/Changes, docs/features/navigation.md); ⌘F/⌘G find
in page when the browser has focus; pages see keys first. Accessibility: tabs are labelled radio buttons with
ownership text, bars are labelled groups, status never colour-only; VoiceOver unverified. Persistence: tabs, URLs,
history, zoom, preset, appearance per thread (bridge test). Approvals: N/A (no card; see Permission).

## Known gaps
Nested frames flatten to the main frame; closed shadow roots invisible; hover is script-only unless the window is
key; no DPR emulation (public API); geolocation always denied; no recording; browser history is app-wide; drafts
have no browser until the thread exists; terminal URL detection reads a 4 KB output tail.

## Needs a human at the screen
Hover and menu ⌘-shortcuts with the window focused; swipe back/forward; real sites (sign-ins, uploads, camera);
drag-reordering tabs and the suggestions list feel; VoiceOver; Web Inspector via Safari ▸ Develop.
