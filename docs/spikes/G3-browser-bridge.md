# G3 Browser bridge: `experimental.browser` v4 over WKWebView (2026-11-16)

Result: **pass.** A Swift desktop side of opencode 2.3.0's built-in browser bridge drives a visible WKWebView. A real
agent session on a zero-cost model opened a local page, filled and submitted a form, and reported the confirmation.
Prototype: `Sources/BrowserKit/SpikeBridge/` (throwaway, marked SPIKE) and `Sources/BrowserSpike/`. Both are gone since
M4-A (`5ea0d8d`): the bridge became `Sources/BrowserKit/Browser/` and the demo is now `Sources/BrowserDemo/`.

## Contract (opencode 2.3.0: `packages/plugin-browser/src/{rpc,connection,machine,tools}.ts`, desktop prior art `packages/gui-plugins/src/browser/{pane,chromium}.ts`)

- **Transport.** `POST /api/rpc/experimental.browser/{method}?location[directory]=…` with body `{input}` and reply
  `{output}`. Errors are `RpcErrorEncoded` with `type: "unavailable"`. Control arrives on `GET /api/event` as
  `{type: "rpc.experimental.browser.control", data: Control}`. The connection ID is a client UUID used for
  correlation, not authentication.
- **Methods.** `attach {sessionID, connectionID, version: 4}` → `"closed" | "replaced"`; it stays pending for the
  attachment's lifetime. `state {…, state: State}` → void. `command {…, requestID}` → `Command`. `result {…,
  requestID, outcome}` → void. `tunnel.open/read/write/close` relay TCP for remote servers (not needed on loopback).
- **Control.** `attached {connectionID, version: 4}` is the readiness barrier. `command {connectionID, requestID}`
  carries no arguments; fetch them with `command`. `cancel {connectionID, requestID}`. Ignore unknown types and
  other connection IDs.
- **Lifecycle.** Subscribe to events, wait for `server.connected`, then `attach`. The server first grants permissions:
  it appends `{browser,*,allow}` and `{skill,browser,allow}` to `session.permissions`. Every agent denies these by
  default, so the tools and the `browser` skill stay hidden until a browser attaches. The server then emits `attached`.
  Publish `state` and wait for its ack before answering `tabs.open`/`tabs.close`, because the server resolves tab IDs
  only from the published inventory. Retry `state` until it lands or returns `unavailable`. A second `attach` for the
  session returns `replaced` to the first and fails its pending work; the replaced desktop must not reclaim the
  session. Session delete or move and plugin disposal close the attachment. Requests time out after 60 s; the server
  then fails the tool with `[browser.timeout]` and sends `cancel`. Nothing is replayed.
- **Types.** `Tab {id: /^tab_[a-f0-9-]{36}$/, url ≤16384, title ≤2048, loading, loadError?, canGoBack, canGoForward,
  generation: Int≥0}`. `State {tabs, focusedTabID|null}`. `Command {action, generation?, files: File[], inspect?,
  target?}`. `File {id: file_<uuid>, name, mime, data: base64 ≤5 MiB}`. `Result {value: Json, files}`. `Outcome =
  {type: success, result} | {type: failure, code ≤2048, message ≤2048}`. The agent sees `[browser.<code>] <message>`.
  `generation` is the tab's published document generation. The desktop rejects a stale one, except on `navigate`,
  `files.*`, `trace.stop/analyze`, `cpu.stop/analyze` and `heap.*` other than `heap.snapshot`. `inspect`/`target` exist
  for a future per-URL permission layer; 2.3.0 never sends `inspect`.
- **Results.** The server validates each result against the operation's output schema. When files are returned, it
  adds `files[]` and attaches images for the model to see. Refs match `^@?e[1-9][0-9]*$`.

| Operation (input beyond `tabID`) | Output |
| --- | --- |
| `tabs.list {}`, `tabs.close` | `State` |
| `tabs.open {url?, focus?=true}`, `tabs.focus`, `navigate {url}`, `back`, `forward`, `reload`, `stop` | `Tab` |
| `click {ref, button?, count? 1/2, modifiers?}`, `hover {ref}`, `drag {from,to}`, `fill {ref,text}`, `fill_form {fields: text/select/check}`, `select {ref, values}`, `check {ref, checked}`, `press {key}`, `scroll {deltaX?, deltaY}`, `wait {frameID?, condition load/text/textGone, text?, timeoutMs?}`, `files.upload`/`files.drop {ref, paths}` | `Tab` |
| `frames` | `{tab, frames: [{id, parentID?, url, name}]}` |
| `snapshot {frameID?, ref?, depth? 1-20, boxes?}`, `find {frameID?, text}` | `{tab, content, truncated}` |
| `evaluate {frameID?, ref?, script}` | `{tab, value}` |
| `screenshot {ref?, fullPage?, format? png/jpeg/webp, quality?, maxWidth?}`, `files.get {fileID}` | `{tab}` plus one file |
| `dialog {action get/accept/dismiss, promptText?}` | `{tab, dialog: {type, message, defaultValue} \| null}` |
| `console {level?, limit?}`, `network.list {urlContains?, resourceType?, limit?}`, `network.get {id, includeBody?, maxBodyChars?}`, `files.list` | lists with `truncated`/`dropped` |
| `preview {path}`, `trace.*`, `cpu.*`, `heap.*`, `lighthouse` | various (see rpc.ts) |

The reference desktop uses these error codes in its messages: `disconnected`, `tab_unavailable`, `timeout`,
`unsupported`, `cancelled`, `too_large` (over 512,000 JSON characters), `document_changed`. Each message names the
next step to take.

## Support matrix (WKWebView, macOS 27; evidence: `BrowserSpike --selftest`, 89/89 checks)

| Status | Operations | Notes and what the agent sees |
| --- | --- | --- |
| Supported | tabs.list/open/focus/close, navigate, back, forward, reload, stop, frames, snapshot, find, evaluate, fill, fill_form, select, check, click (left/right, 1–2 clicks, modifiers), press, wait, screenshot (viewport, element, full page), dialog, console, files.upload, files.list/get (captures) | Snapshot is an ARIA-like tree built by script in an isolated `WKContentWorld`; it pierces open shadow roots and slots. Refs are tab-unique and expire on the next snapshot or new document. Full page renders through `createPDF`. |
| Reduced fidelity | hover, scroll, drag, files.drop, network.list/get, evaluate with `ref`, middle click, ⌘-chords, screenshot format | **hover**: WebKit drops synthesized `mouseMoved` while the window is not key, so hover falls back to untrusted `mouseover`/`mouseenter` with no CSS `:hover`. **scroll**: exact `scrollBy`, no wheel event. **drag/drop**: synthetic `DragEvent`s. **network**: Resource Timing only; method reported as GET, no headers, bodies or failures (`responseBody: unavailable/backendUnavailable`). **evaluate+ref** runs in the isolated world: same DOM, page globals not visible. **middle click**: script only. **⌘A/C/X/V/Z**: when the app is inactive they are sent as editing actions to the web view. **webp**: `unsupported`; png/jpeg work. |
| Refused while a dialog is open | snapshot, evaluate, click, screenshot… | A blocked page cannot run script or paint in WebKit, so everything except `dialog`, `console`, `stop` and `files.*` fails with `dialog_open` until the agent or the person answers. Chromium can still capture. |
| Unsupported | trace.*, cpu.*, heap.*, lighthouse; preview (not built in the spike) | `[browser.unsupported]` with a hint to use the Performance API or Safari Web Inspector. `preview` is cheap to add with native viewers. Closed shadow roots are invisible to snapshot, as with any script approach. |

## End-to-end (`BrowserSpike --e2e`; logs in `build/snapshots/g3-e2e*.{txt,log,json,png}`)

opencode 2.3.0 ran with temporary XDG directories. The catalog listed 12 zero-cost `opencode/*` models; the spike used
`opencode/big-pickle`. Before the attach, `session.permissions` was null; after it, it held the two allow rules above.
Two prompts were sent in total; each turn took 14–21 s. Second run: the agent loaded the `browser` skill, then issued
`tabs.open → wait load → snapshot → fill_form(text, text, select, check) → snapshot → click → snapshot ×2 → evaluate`.
The page showed `Confirmation BC-87: Ada Lovelace <ada@example.com> on the pro plan` and the agent replied with that
text. Along the way it made three invalid calls (`fill {value}`, untyped `fill_form` fields, `evaluate {expression}`).
The server's schema check rejected all three before dispatch and the agent corrected itself. Every bridge
`result` was `success`. No processes or temporary directories remained afterwards.

## Trusted input

Native input means `NSEvent`s handed straight to the WKWebView (`mouseDown`/`mouseUp`, `keyDown`/`keyUp`,
`insertText`). It reaches the page as `isTrusted: true` with real default actions: focus, caret, submit, checkbox
toggle. It needs no Accessibility permission and never moves the person's pointer. It worked with the window
visible but **not key** (the shell-launched app is never activated). Fill uses JS focus and select-all, then native
`insertText`, giving trusted `beforeinput`/`input` (CDP `Input.insertText` behaves the same). Date and time inputs are
filled by script. Script mode yields untrusted events: `click:false`, `input:false`, and keys insert nothing. One
WebKit quirk: `HTMLElement.click()` on a checkbox still fires *trusted* `input`. The spike delivers natively first
and falls back to script for middle click, or when the target is offscreen or its frame offset is ambiguous. Every
fallback is logged. Not verified: whether hover and menu-routed ⌘-chords work natively in a key window (testing it
would have meant stealing focus from the owner's desktop).

## Frames and shadow DOM

The agent script is a `WKUserScript` with `forMainFrameOnly: false` in a named content world, so it runs in
same-origin frames and in a **cross-site** frame (`localhost` against `127.0.0.1`). `callAsyncJavaScript(in:
WKFrameInfo)` targets each frame. Snapshot, fill, evaluate and native click (the frame offset comes from the parent's
`<iframe>` rect, matched by URL) all passed in both frames. Frame IDs are script-generated per document;
`frames` pings each frame to drop stale entries. Gap: nested frames are flattened to the main frame as parent, and
two iframes with the same URL fall back to script click. Open shadow roots work for snapshot, find, click and fill;
closed ones are invisible.

## Risks

1. **Experimental contract.** The ID says so, and v4 is the fourth version. The server pins `version: 4` in its
   schema, so a bump breaks attach outright (we would see it as `unavailable`). Mitigation: pin opencode, run the
   contract self-test in CI against each new version, keep the wire types in one file.
2. **The skill describes Chromium.** The built-in `browser` skill tells the model it drives Chromium and teaches
   trace, heap and Lighthouse recipes. The agent will try them and get `unsupported`. Upstream needs a capability
   field, or we accept the noise.
3. **Weak models.** The free model needed several tries to get argument shapes right (code mode plus `search`).
   It still finished; stronger models should do better.
4. **WebKit gaps.** No CDP, so no full network log, profiling, heap or Lighthouse. A JS dialog blocks capture and
   script. Hover is unreliable in background windows. Injected script and console hooks can be observed by the page
   (the console hook lives in the page world and its entries are untrusted).
5. **Permission layer.** `inspect`/`target` show a per-URL approval step is coming (#46530); the desktop
   will have to answer inspection commands with metadata only. A sketch is in `BrowserHost.inspect`.

## Verdict: WKWebView is good enough for v1

Everyday agent browsing works with trusted input: dev-server previews, forms, SPA routes, frames, shadow DOM,
dialogs, console and screenshots. Embedded Chromium (CEF) is only needed for DevTools-class operations (network
bodies, traces, heap, Lighthouse). Keep it as a later backend behind the same protocol, and point users at external
Chrome with browse for authenticated or devtools work.

## Recommended production design (BrowserKit)

- `BrowserBridgeClient` (OpenCodeKit, actor): attach, control decoding, `command`/`result`, ordered outbox, `state`
  retry. Wire types are `Sendable` structs generated from rpc.ts, one file per contract version. No AppKit here.
- `BrowserBackend` protocol (`@MainActor`): `perform(BrowserCommand) async -> BrowserOutcome` plus a state stream.
  `WebKitBackend` is v1; `ChromiumBackend` can come later. `BrowserTabModel` owns its WKWebView, generation, frame
  registry, refs, dialog gate, bounded console and captures. Snapshot JSON is decoded off the main actor.
- **Session mapping.** One attachment per opencode session that the user opens in a window. The tab group belongs to
  that session and is persisted in session metadata so it can be restored. Switching threads detaches nothing; each
  attached session keeps its group. Closing the window or the session detaches (`closed`). A `replaced` outcome shows
  "This session's browser moved to another window" with an explicit Reconnect action and no automatic reclaim.
- **Agent activity is visible.** The tab strip badges tabs the agent touched. A status line names the running command
  and a Stop button cancels it. The acted-on element gets an outline overlay. Dialogs appear as a pinned banner with
  Accept/Dismiss that either party can answer. The sidebar counts a blocked page as needing attention (UX rule 4).
  The tab shows project, session and the page origin.
- **Threading.** Tasks are owned by the attachment and cancelled on `cancel` or detach. Every result checks
  generation and attachment ID before it is applied (rules 8 and 9). Logs and the console buffer are bounded, and
  `os_signpost` covers receive, perform and publish.

## Run it

At the time: `swift run BrowserSpike --selftest` or `--e2e`. Today the same checks run against the production
BrowserKit: `Scripts/fetch-opencode.sh`, then `swift run BrowserDemo --selftest` or `swift run BrowserDemo --e2e`
(sends one prompt to a zero-cost model; export the `SWIFTTERM_BUILD_*` values from the Makefile first). Snapshots go
to `build/snapshots/`.
