# MockOpenCode (M0-C)

A scriptable fake opencode 2.3.0 server on `127.0.0.1:<ephemeral>` (Basic auth `opencode:<password>`) that plays
scripted turns as real-format events, so UI and engine work runs without a model.
## Coverage

| Endpoint / event | Status |
| --- | --- |
| `GET /api/info`, `/api/project`, `/`, `/doc`, `/health`; 401 envelope | faithful (shape checked against the binary) |
| `GET/POST /api/session`, `GET/PATCH/DELETE /api/session/{id}` (filters `parentID`, `archived`, `directory`, `project`, `search`; `limit`, `cursor`, `order`) | faithful; cursors are opaque but differ in bytes |
| `GET …/message` (`order`, `type`, paging), `…/message/{id}`, `…/inbox`, `POST …/prompt` (async, idempotent `id`, `delivery`), `…/interrupt` | faithful shapes; turn content is scripted |
| Permissions: `GET /api/permission/request`, `GET/POST …/permission[/{id}]`, `POST …/reply` (`once`/`always`/`reject`) | faithful; `always` remembers `save` resources per session |
| Forms: `GET /api/form`, `GET/POST …/form[/{id}]`, `POST …/reply`, `DELETE …/form/{id}`; 409 when settled | faithful |
| `/api/provider[/{id}]`, `/api/model`, `/api/model/default`, `/api/agent[/{id}]` | captured from the binary (prompts shortened) plus a fictional `mockai` provider |
| `GET /api/event` (`types` filter, `server.connected`, heartbeats, 4,096-frame drop-on-overflow) | faithful framing and envelope (`id`, `created`, `type`, `location?`, `data`, `durable{aggregateID,seq,version}`) |
| `session.created/renamed/metadata.updated/permissions/archived/unarchived/deleted`, `permission.*`, `form.*`, `project.updated` | faithful (event shapes checked against the binary) |
| `session.inbox.*`, `execution.*`, `step.*`, `text.*`, `reasoning.*`, `tool.*`, `usage.updated` | order and shapes follow `Contracts/…/events-sample.sse` and the OpenAPI schemas |
| Everything else (fs, vcs, pty, worktree, revert, compaction, MCP, plugins, credentials, `exp/*`) | missing: 404 `NotFoundError` |

## Writing a script

Swift DSL: `TurnScript { TurnStep.reasoning("…"); TurnStep.text("…", chunkSize: 3, rate: 200);
TurnStep.tool("edit", input: [...], output: "…", permission: PermissionAsk(action: "edit", resources: ["a"]));
TurnStep.question("Pick", options: ["a", "b"]); TurnStep.subagent(description: "…", prompt: "…") { … };
TurnStep.fail("Rate limit", status: 429) }`. Also `.delay`, `.interrupt`, `.dropEventStreams`, `.duplicateNextEvent`.
JSON form: `{"name": …, "steps": [{"type": "text", "text": …, "chunkSize": 3, "rate": 200}, …]}`; a fail step nests
its error: `{"type": "fail", "error": {"type": "provider", "message": …}}`. Examples in `Fixtures/scripts/`, loaded
with `TurnScript.loadLibrary(directory:)`. A prompt plays `#script:<name>` if its text names one, else the next
`enqueueScript(_:for:)`, else the scenario default. Rates go up to 1,000 deltas/s; `MockServerOptions.testing` uses a
virtual clock (sleeps return at once, ids and timestamps are deterministic, turns wait for subscribers to drain).

Faults: `setEventSplitting(.fixed(n) | .seeded(seed:maxPiece:), pieceDelay:)`, `dropEventStreams()` (flush, then close
without the terminating chunk), `dropEventStreams(afterFrames:)`, `duplicateNextEvent()`, `injectHTTPFault`
(status/body, delay, connection reset; counted or until `clearHTTPFaults()`), `restart()` (new port, same state).
Large data: `FixtureGenerator(seed:)`, `Scenario.large(...)` (10,000-message session, one 100 KB code block).

## Pointing the app at it (convention only; the app is not changed)

`MockOpenCodeServer.runStandalone(scenario:)` prints `{"url":…,"password":…}` and stops when stdin closes. When
`BELLOCODE_SERVER_URL` is set the app should not spawn opencode and use that URL with `BELLOCODE_SERVER_PASSWORD`.

## Known divergences

- No location bootstrap events (`integration.updated`, `agent.updated`, …), no `session.instructions.updated`, no
  `shell.created/exited`, no titles generated after the first prompt, cost always 0, token counts synthetic.
- Interrupt: open blocks end, an unsettled tool gets `tool.failed{type:"aborted"}`, the step gets `step.failed`, then
  `execution.interrupted{reason:"user"}`; blocked permissions are withdrawn with a synthetic `permission.replied
  {reply:"reject"}` and forms with `form.cancelled`. The real sequence was not observed (it needs a model).
- A steered prompt is delivered after the current script ends, inside the same execution, not at the next step.
- Sub-agents run at once and never wake the parent. `reject` fails only that tool. `permission.create` always
  answers `effect: "ask"` (the real one evaluates rules).

## Verified against the real binary

`BELLOCODE_CONTRACT_REAL=1 swift test --filter RealBinaryContract` runs pinned 2.3.0 in a temporary sandbox (XDG dirs,
HOME) and the mock through the same sequence (info, session CRUD/lists, messages, bad `limit`, inbox, idle interrupt,
permission and form create/list/get/reply incl. 404/409, catalog, delete, 401) and compares every response and event
shape: all match (3 runs, no process left). It found: lists order by `time.updated`; `session.deleted` is durable v2.
Turn events are checked against the recorded stream only, since producing them needs a model prompt.
