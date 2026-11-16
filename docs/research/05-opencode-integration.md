# 05 — Embedding opencode v2 ("opencode2") as BelloCode's only backend

Research date: 2026-11-16. Subject version: **opencode 2.3.0** (`/opt/homebrew/bin/opencode` →
`/opt/homebrew/Cellar/opencode-v2/2.3.0/bin/opencode`, Homebrew formula `anomalyco/tap/opencode-v2`).
Source read at `github.com/anomalyco/opencode` commit `0ac0d7e` (root `package.json` version `2.3.0`), T3 Code at
`github.com/pingdotgg/t3code` commit `1d1489d`, browse at `github.com/anomalyco/browse` commit `c3b29be`.

Legend: **[V]** verified on this machine (command run / endpoint hit), **[S]** read in source or docs at the commits
above, **[U]** unverified inference.

## 0. What "opencode2" is

- There is no separate product called "opencode2". It is **opencode major version 2**, a rewrite with a new
  `/api/*` HTTP API, a new schema/event model and a new plugin API. [V] `brew info opencode-v2` →
  "OpenCode V2 - the AI coding agent for the terminal", homepage `github.com/anomalyco/opencode`, MIT, conflicts with
  the `opencode` formula (the 1.x line, still published on npm as `opencode-ai@1.19.5`).
- T3 Code names its driver exactly this way: `packages/provider-opencode/src/server/v2/OpenCode2Server.ts`,
  `OpenCode2Client.ts`, `openCode2Catalog.ts`, comment "One OpenCode 2 process serves all directories". [S]
- The official TypeScript client is `@opencode/client` 2.3.0 (described on npm as "Private generation target for
  clients derived directly from OpenCode's authoritative Effect HttpApi"); the plugin API is `@opencode/plugin` 2.3.0. [V]
- v1 docs/plugins/SDK (`@opencode-ai/sdk`, `/session/:id/message`, `permission.updated`, `bash`/`task` actions) do
  **not** apply. The v2 docs warn: "In V2, use `permissions`, `shell`, and `subagent` instead of `permission`, `bash`,
  and `task`." [S] `services/site/src/docs/content/permissions.mdx`

## 1. Server mode

### Launch

`opencode serve [--hostname H] [--port P] [--cors ORIGIN]... [--service | --stdio]` [V] `opencode serve --help`.

| Mode | Behaviour | Source |
| --- | --- | --- |
| default | Binds `hostname` (default `127.0.0.1`); port given, or first free port from **4096** upward. Prints `server listening on http://…`. If no password env var, generates one and prints `server password …`. Runs until killed. | [S] `packages/server/src/process.ts` `listen()`, `packages/cli/src/server-process.ts` |
| `--stdio` | Prints **one JSON line** `{"url":"http://127.0.0.1:PORT"}` on stdout, then lives **until its stdin closes** (an ownership lease: the OS closes the pipe even if the parent crashes). Deletes `OPENCODE_PASSWORD`/`OPENCODE_SERVER_PASSWORD` from its own env so tools never inherit it. This is exactly how the TUI starts a private server (`cli/src/services/standalone.ts`: `serve --stdio --port 0`, `OPENCODE_PASSWORD=<random>`, `stdin: "pipe"`, SIGTERM then kill after 3 s). | [V][S] |
| `--service` | The per-user shared background server (`opencode service start|stop|status|get|set`). Registration in `$XDG_STATE_HOME/opencode/service.json` (`{id, version, url, pid, password}`), settings in `$XDG_CONFIG_HOME/opencode/service.json`; default port `0xC0DE` = **49374**; `chdir($HOME)`. Used by the TUI/CLI by default and by opencode Desktop. | [V] files exist; [S] `cli/src/services/service-config.ts`, `packages/desktop/src/main/service/background-service.ts` |

Measured [V]: `opencode serve --stdio --port 0` with isolated XDG dirs reported its URL and answered `/api/info`
in **0.09 s**; closing stdin made it exit with code 0 in **0.01 s**. Default mode also listened within ~0.1 s; the DB
bootstrap ran 59 migrations in 5 ms on a fresh data dir. Per-directory "location" activation (config, plugins,
providers, MCP) happens lazily on the first request for that directory (catalog reads may take seconds cold —
T3 comment "Cold catalogs take seconds").

### Auth

- HTTP **Basic auth, username `opencode`**, password from `OPENCODE_PASSWORD` (preferred) or `OPENCODE_SERVER_PASSWORD`
  (v1 name, still accepted). [V] wrong username → 401; [S] `server/src/auth.ts`, `cli/src/env.ts`.
- Also accepted: `?auth_token`-style query credential and short-lived HMAC tokens/cookies for browsers; one-time
  WebSocket tickets (`POST …/connect-token` with header `x-opencode-ticket: 1`, then `?ticket=`), used by browsers
  that cannot set headers. A native Swift client can just send `Authorization: Basic …` on the WebSocket upgrade. [S]
- Unauthenticated: `GET /`, `/doc`, `/health` return the bundled web UI HTML (200). `GET /api/info` requires auth even
  while starting (returns 503 + `retry-after: 1` while starting, 500 if failed). [V][S]
- The OpenAPI document declares `security: []` on every operation, so generators will not add auth — add it in a
  transport middleware. [V]

### Health / readiness / shutdown

- Readiness = `GET /api/info` → `{"version":"2.3.0","pid":…,"hostname":…,"urls":["http://127.0.0.1:…"],
  "paths":{"tmp":"/private/tmp/opencode"},"capabilities":{"persistentPty":true}}`. T3 uses only this ("Only server
  info proves readiness") and rejects versions below a minimum. [V][S]
- Shutdown: close stdin (stdio mode) or SIGTERM; the event stream emits `location.shutdown`. Execution claims survive
  unclean death and are **resumed on next start** (crash recovery), so killing the server mid-turn is recoverable
  but tool side effects may repeat/abort. [S] `specs/v2/session.md`

### One server, many projects

One server serves **all directories**. Every location-scoped operation takes the directory via either the query
`location[directory]=/abs/path` (OpenAPI: `style: deepObject`) or the header `x-opencode-directory:
<percent-encoded path>`; if neither is given the server's **cwd** is used; session-scoped routes resolve location from
the session row. [V] `GET /api/location` with the header returned the other project; [S] binary/`LocationQuery`.
Gotcha [V]: `GET /api/permission/request` without a location returned `[]` while a request was pending in another
directory — always pass the location.

### Logs

`$XDG_DATA_HOME/opencode/log/opencode.log` (logfmt: `timestamp=… level=INFO run=… message=… role=server`).
`--print-logs` mirrors to stderr; `--log-level`. [V]

### Where data lives — and isolation

`opencode debug paths` [V]:

```
data   ~/.local/share/opencode     (opencode.db = SQLite WAL with sessions/messages/credentials, snapshot/, shell/, tool-output/, repos/, log/)
config ~/.config/opencode          (opencode.json[c], service.json, plugins/, agents/, commands/, skills/)
state  ~/.local/state/opencode     (service.json registration, locks/, pty/)
cache  ~/.cache/opencode           (bin/: extracted opencode-pty helper, downloaded rg, npm plugin installs)
tmp    $TMPDIR/opencode  (server reported /private/tmp/opencode)
```

Isolation knobs [V for XDG, S for the rest; `strings` of the binary lists all `OPENCODE_*` vars]:

| Variable | Effect |
| --- | --- |
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, `XDG_CACHE_HOME` | Move every dir above. **Verified**: a server started with these under the scratchpad wrote its DB, logs, snapshots, `opencode-pty` there and never touched `~/.local/share/opencode`. |
| `OPENCODE_CONFIG_DIR` | Global config dir only. |
| `OPENCODE_CONFIG` / `OPENCODE_CONFIG_CONTENT` | Extra config file / inline JSON layer (T3 sets `OPENCODE_CONFIG_CONTENT="{}"`). |
| `OPENCODE_DISABLE_PROJECT_CONFIG` (`OPENCODE_CONFIG_PROJECT_DISABLE`) | Ignore repo `opencode.json`/`.opencode/`. |
| `OPENCODE_DISABLE_CLAUDE_CODE[_SKILLS]` | Stop reading `.claude/` skills. |
| `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_DISABLE_MODELS_FETCH`, `OPENCODE_MODELS_PATH/URL` | Pin behaviour/offline catalog. |
| `OPENCODE_DISABLE_FREE_MODELS` | Hide the free "opencode" zen models. |
| `OPENCODE_CLIENT` | App name reported in server info / headers (BelloCode should set it). |
| `OPENCODE_DB`, `OPENCODE_TEST_HOME` | Present in binary; semantics unverified [U]. |

Also note: the planning agent's writable dir is `$HOME/.opencode/plan/*` (seen in the `plan` agent's rules) [V], so
`HOME` matters too; managed policy can come from `/Library/Managed Preferences/ai.opencode.managed.plist` [S].

**Sharing vs isolating** — three viable topologies:

1. **Private + isolated** (recommended default): `serve --stdio --port 0` with XDG dirs under
   `~/Library/Application Support/BelloCode/opencode/{config,data,state,cache}`. No interference with the user's
   install, BelloCode owns versions and plugins. Cost: separate sessions/credentials from the user's TUI.
2. **Private process, shared data** (XDG left default): sessions/credentials visible to the user's TUI. Risky: two
   server processes on one SQLite DB is not a supported topology — opencode Desktop explicitly avoids "two services
   could boot against the same database", and session execution ownership is process-local [S]. Do not do this.
3. **Adopt the user's background service**: read `~/.local/state/opencode/service.json` (url+password) or run
   `opencode service start`, then connect. Live-shares sessions with TUI/Desktop, but BelloCode then depends on the
   user's opencode version and config. Offer as an advanced "Connect to existing opencode" option (T3 supports an
   external `serverUrl`+`serverPassword` the same way [S]).

## 2. The HTTP API (2.3.0)

OpenAPI: `GET /openapi.json` (auth required) — OpenAPI **3.1.0**, title "opencode HttpApi", **139 paths, 515
schemas**, 43 paths under `/api/experimental/`. The `opencode api <operationId>` CLI calls any operation. [V]

### Inventory by area (operationId; `exp` = under `/api/experimental`)

- **Server**: `GET /api/info` server.info; `POST /api/pair`, `GET /auth/connect/{code}` (pairing links for remote
  browsers/apps); `GET /api/location`, `POST /api/location/reload`; `GET|DELETE /api/debug/location`,
  `POST /api/debug/heap-dump`; `GET exp/migration/v1` (v1 data import status).
- **Projects**: `GET /api/project` (list: `{id, canonical, vcs, name?, icon?, commands?{start}, time, sandboxes}`),
  `PATCH /api/project/{projectID}`. A project id is the root-commit hash of the repo, or `global` for non-git/empty
  repos. [V] There is **no create/delete project**: a project appears when a location is first used.
- **Sessions**: `GET /api/session` (cursor paging; filters `search`, `parentID` (`null` = top level), `archived`,
  `directory`, `project`, `subpath`), `POST /api/session` (`{id?, parentID?, title?, agent?, model?, location?,
  metadata?, permissions?}`), `GET|PATCH|DELETE /api/session/{id}` (PATCH: `title`, `metadata`, `permissions`,
  `archived`), `GET /api/session/active`, `POST …/fork` (`{before?: messageID}`), `…/agent`, `…/model`, `…/move`
  (to another directory), `…/view` (mark idle transition seen), `PUT …/environment`, `exp/session/stats`,
  `exp/session/import`, `exp/session/{id}/export`.
- **Prompting / execution**: `POST …/prompt` (`{id?, text, files?, agents?, skills?, metadata?, delivery?:
  "steer"|"queue", resume?}` → returns the admitted inbox item immediately, i.e. **always async**), `…/command`
  (slash command), `…/synthetic` (system-authored input), `…/shell` (user shell command), `exp/…/skill`,
  `…/compact`, `…/generate` (side generation from session context), `…/interrupt?resume=`, `…/background` (move
  blocking tools to background), `exp/…/wait` (block until idle), inbox: `GET …/inbox`, `PATCH|DELETE
  …/inbox/{inboxID}` (change delivery / cancel a pending queued prompt).
- **Messages**: `GET …/message` (cursor paging, `order`, `type` filter), `GET …/message/{messageID}`,
  `GET …/context` (messages after last compaction), `exp/…/log?after=&follow=` (durable event log, see below).
- **Revert / undo**: `POST …/revert/stage` (`{messageID, files?}`), `DELETE …/revert` (clear), `POST
  …/revert/commit`; `GET …/diff?from=&to=&context=` (structured per-turn file diffs).
- **Instructions**: `exp/…/instructions/entries` list / `PUT {key}` / `DELETE {key}` — per-session system-prompt
  fragments (T3 injects its orchestration prompt this way).
- **Permissions**: `GET /api/permission/request` (pending, per location), `GET|POST /api/session/{id}/permission`
  (POST lets a client/plugin create an ask), `GET …/permission/{requestID}`, `POST …/permission/{requestID}/reply`
  (`{decision: "once"|"always"|"reject", message?}`), saved rules `GET /api/permission/saved`, `PATCH|DELETE
  …/saved/{id}`. [V] create → `permission.asked`, reply → `permission.replied`.
- **Questions / forms**: `GET /api/form`, `GET|POST /api/session/{id}/form`, `GET|DELETE …/form/{formID}`,
  `POST …/form/{formID}/reply` (`{answer: {...}}`). The `question` tool and MCP elicitations surface as forms
  (`form.created`). Field types: string/number/integer/boolean/multiselect/external(url). [V schema]
- **Files**: `GET /api/fs/read/*`, `GET /api/fs/list`, `GET /api/fs/find?query=&type=&limit=` (ranked fuzzy find),
  `exp/fs/write`, `exp/fs/watch` + unwatch (→ `filesystem.changed`). No grep/symbol search endpoint (agents use
  tools).
- **VCS**: `GET /api/vcs`, `/vcs/base`, `/vcs/status`, `/vcs/branch`, `/vcs/diff?mode=working|branch|committed&base=`,
  `POST /api/vcs/init`. **Worktrees**: `GET|POST|DELETE /api/worktree` (`{projectID, from?, branch?, directory?,
  name?}`; runs the project's setup script), `POST /api/worktree/refresh`.
- **Terminal**: PTY `GET|POST /api/pty`, `GET|PUT|DELETE /api/pty/{id}`, `POST …/connect-token`, `GET …/connect`
  (WebSocket, `cursor` for replay). Persistent PTYs (survive reconnect, bound to a session, readable by the agent):
  `exp/session/{id}/terminal[/read]`, `exp/persistent-pty/{id}[/snapshot|/connect-token|/connect]`, `…/handoff`,
  `…/shutdown`. Shell jobs: `GET|POST /api/shell`, `GET|DELETE /api/shell/{id}`, `GET …/output`. Background jobs:
  `exp/job` (shell / subagent / image jobs with status).
- **Models / providers / auth**: `GET /api/model`, `/api/model/default`, `GET /api/provider[/{id}]`; integrations
  `GET /api/integration[/{id}]`, `POST …/connect/key`, `…/connect/external`, `…/connect/oauth` → attempt,
  `GET|DELETE …/connect/oauth/{attemptID}`, `POST …/complete`, `…/connect/command` (+status/cancel),
  `exp/integration/wellknown`; credentials `GET|POST /api/credential`, `PATCH|DELETE /api/credential/{id}`,
  `POST …/activate`; `exp/usage/limits`.
- **Agents / commands / skills / references**: `GET /api/agent[/{id}]`, `GET /api/command`, `GET /api/skill`,
  `GET /api/reference`.
- **MCP**: `GET /api/mcp` (status), `PUT|DELETE exp/mcp/{server}` (add/remove at runtime), `POST
  exp/mcp/{server}/connect|disconnect`, `GET /api/mcp/resource`, and **client-hosted MCP**: `POST
  exp/client-mcp/token`, `GET exp/client-mcp?name=` (WebSocket; the *client* acts as an MCP server whose tools the
  agent can call — see §5).
- **Plugins**: `GET /api/plugin`, `GET /api/plugin/gui?id=` (a plugin's CommonJS GUI bundle for opencode Desktop),
  `POST /api/plugin/check|update`, **`POST /api/rpc/{rpcID}/{method}`** (call a plugin-defined RPC; plugin RPC
  events arrive on `/api/event`).
- **Config**: `GET /api/config`, `GET /api/config/shell`, `PATCH exp/config` (global config update).
- **Experimental extras**: schedules `exp/schedule` (+get/delete/pause/resume), artifacts `exp/artifacts`
  (+providers/view), `exp/generate/{text,image,decisions}`, `exp/voice/*`, `exp/media/{hash}`,
  `GET|POST /api/websearch[/provider]`.
- **Absent in 2.3.0** (vs v1 / the brief): no **share** endpoint (config still has `share`), no **LSP** endpoints
  (config `lsp` only), no **TUI control** POST endpoints (only `tui.*` events), no summarize endpoint (use
  `compact`), no explicit todo endpoint (todo tool is behind `experimental.todo`). [V]

### Event stream (SSE)

`GET /api/event[?types=a,b]` — one **server-wide** stream across all locations (each frame carries `location.directory`
when applicable); no per-directory stream. Frames are bare `data: {json}` lines (no `event:`/`id:` lines), heartbeat
comment every 15 s, first frame `server.connected`. [V] The server describes it as "**Volatile by contract**: a slow
consumer overflows and fails the stream, and events during disconnection are missed." Each connection has a 4,096-frame
dropping queue; overflow terminates only that connection. [S] `specs/v2/event-stream-architecture.md`

Common envelope [V]: `{id: "evt_…", created: ms, type, location?: {directory}, metadata?, data, durable?:
{aggregateID, seq, version}}`. Events with `durable` are also persisted in the session's event log.

Observed sequence for one prompt that ran one shell tool on the free model [V] (`events.txt` in the scratchpad):

```
session.created → session.inbox.enqueued → session.execution.started → session.instructions.updated
→ session.inbox.delivered → session.step.started{assistantMessageID, agent, model, snapshot}
→ session.step.first-token → session.reasoning.started{ordinal} → session.reasoning.delta{delta}×n
→ session.tool.input.started{id,name:"shell"} → session.reasoning.ended{text} → session.tool.input.ended{text}
→ session.tool.called{id,input,executed:false} → session.step.streamed → shell.created → session.tool.progress{metadata}
→ shell.exited → session.tool.success{content:[{type:"text",text}],metadata} → session.step.ended{finish:"tool-calls",cost,tokens,snapshot,files}
→ session.usage.updated → session.step.started (2nd step) … session.text.started → session.text.delta×n
→ session.text.ended{text} → session.step.ended{finish:"stop"} → session.execution.succeeded
```

Full type list (from the `types` enum) [V]: `location.shutdown, models-dev.refreshed, credential.updated|switched,
integration.updated, provider.updated, model.updated, agent.updated, session.created, session.agent.selected,
session.model.selected, session.moved, session.renamed, session.metadata.updated, session.permissions,
session.viewed, session.archived|unarchived, session.usage.updated, session.deleted, session.forked,
session.inbox.delivered|enqueued|cancelled|delivery.changed, session.execution.started|succeeded|failed|interrupted,
session.instructions.updated, session.synthetic, session.skill.activated, session.shell.started|ended,
session.step.started|first-token|streamed|ended|failed, session.text.started|delta|ended,
session.reasoning.started|delta|ended, session.tool.input.started|delta|ended, session.tool.called|progress|success|failed,
session.retry.scheduled, session.compaction.started|delta|ended|failed, session.revert.staged|cleared|committed,
filesystem.changed, reference.updated, permission.asked|replied, plugin.updated, project.updated,
worktree.updated|resolved, command.updated, config.updated, skill.updated, pty.created|updated|exited|deleted,
persistent-pty.added|removed|updated, shell.created|exited|deleted, form.created|replied|cancelled, websearch.updated,
artifact.updated, session.status, session.idle, tui.prompt.append|command.execute|toast.show|session.select,
installation.updated|update-available, vcs.branch.updated, mcp.status.changed, mcp.resources.changed,
experimental.mcp.event` plus plugin RPC events (`V2Event.rpc`, arbitrary `type`). Note: `session.idle`/`session.status`
were not emitted in the observed run; `session.execution.*` are the reliable turn boundaries. [V]

Streaming part identity: text/reasoning blocks are keyed by `(assistantMessageID, ordinal)`; tools by
`(assistantMessageID, id)` (tool-call ids are unique only within a step). Deltas (`*.delta`, `tool.input.delta`,
`compaction.delta`, `tool.progress`, `usage.updated`) are **live-only**; `*.started/ended`, `tool.called/success/failed`,
`step.*`, `execution.*` are durable. `session.message.content.updated` (durable) carries a full replacement of an
assistant message's content. [S/V]

**Replay / ordering**: per-session durable log `GET /api/experimental/session/{id}/log?after=<seq>&follow=true`
"subscribes before replay and emits one synchronization marker (`log.synced`) at the captured watermark before live
durable events continue". Live deltas are not replayed. For full state after a gap, re-read projections
(`GET …/message`, `…/inbox`, `/api/permission/request`, `/api/form`). [S] `specs/v2/session.md`; [V] the log
endpoint returned only `{"type":"log.synced",…,"seq":23}` for `after=0` and for no cursor on a finished session, so
replay-from-zero semantics are **unclear [U]** — treat projections as the source of truth on (re)connect.
Recommended client pattern (also T3's): open `/api/event` **before** issuing work, buffer, then fetch projections;
on reconnect re-fetch everything for visible sessions and treat in-flight tool/step state as stale.

### Swift client generation

- Viable with care. Obstacles [V]: OpenAPI 3.1 `anyOf` with `{type:null}` everywhere; numbers typed as
  `number | enum["Infinity","-Infinity","NaN"]`; a wildcard path `/api/fs/read/*`; `deepObject` query object
  `location[directory]`; SSE response with custom `x-effect-stream`; three `x-websocket` endpoints; `security: []`;
  43 experimental paths that may change.
- Recommendation: use **swift-openapi-generator** only for request/response DTOs and simple routes (filter the spec
  to stable tags; post-process nulls), and hand-write: the transport (Basic auth + `x-opencode-directory` header
  instead of deepObject), the SSE decoder (a tagged `enum OpenCodeEvent` decoded on `type` with an `.unknown(type,
  json)` fallback so new event types never break the stream), WebSocket clients (PTY, client-MCP), and the
  `fs/read/*` call. Pin generation to the bundled binary's spec (`GET /openapi.json` at build time) and fail CI on
  diff.

## 3. Data model (from schemas [V] and specs [S])

- **Project** `{id, canonical, vcs?, name?, icon?, commands?{start}, time, sandboxes[]}`; ids are repo root hashes or
  `global`.
- **Session** `Session.Info {id "ses_…", parentID?, fork?{sessionID, boundary{before|through messageID}}, projectID,
  agent?, model?{id, providerID, variant?}, cost (USD), tokens{input, output, reasoning, cache{read, write}},
  outcome?: succeeded|failed|interrupted, time{created, updated, busy?, idle?, viewed?, archived?}, title?, subpath?,
  metadata? (free-form object), permissions? (ruleset), revert?, location{directory}}`.
  - Children: `parentID` (subagent sessions; listing with `parentID=null` gives top-level threads).
  - Forks: `POST …/fork {before?}` creates a session with `fork.sessionID/boundary`.
  - `metadata` is client-owned free-form storage → BelloCode can keep pin/attention/labels/PR links here.
  - `time.idle` vs `time.viewed` + `POST …/view` gives native **unread** detection.
- **Messages** `Session.Message.Info` union: `user {text, files?, agents?, skills?}`, `assistant {agent, model,
  content: (text|reasoning|tool)[], snapshot?{start,end,files}, finish?, cost?, tokens?, error?, retry?, time{created,
  firstToken?, streamed?, completed?}}`, `synthetic`, `system`, `skill`, `shell {shellID, command, status, exit?,
  output?}`, `compaction (running|completed|failed, reason auto|manual, summary)`, `agent-switched`, `model-switched`,
  `location-switched`, `idle`. Ids `msg_…`.
- **Tool state machine**: `streaming {input: string}` → `running {input, metadata}` → `completed {input, content:
  (text|file{uri,mime})[], metadata?}` | `error {input, error{type,message,status?}, content?}`; `time{created, ran?,
  completed?}`; `executed` flag distinguishes provider-hosted tools. On restart, orphaned streaming/running calls are
  failed, never replayed. [S] `specs/v2/session.md`
- **Inbox**: every prompt is first a durable inbox item (`user|synthetic|compaction|move`) with `delivery` `steer`
  (deliver at the next safe step boundary, default) or `queue` (deliver when idle, one at a time). Admission is
  idempotent on a client-chosen `id`. [S]
- **Permission request** `{id "per_…", sessionID, action, resources[], save?[], metadata?, source?{type:"tool",
  messageID, id}, message?}`; replies `once|always|reject`; rules `{action, resource, effect allow|deny|ask}`, last
  match wins, default `ask`. Built-in actions: `read, edit, glob, grep, shell, subagent, external_directory, question,
  skill, browser, websearch/webfetch …` (plugins may add more). [S] `permissions.mdx`
- **Forms** `{id, sessionID, title, metadata?, fields[]}` — questions and elicitations.
- **Snapshots/revert**: each step records git-tree snapshot ids (`step.started.snapshot`, `step.ended.snapshot/files`,
  `assistant.snapshot`), stored in `data/opencode/snapshot/<projectID>` (separate from the user's git). Revert is a
  stage → (optionally apply files) → commit/clear protocol; `session.revert` holds the staged boundary. [V/S]
- **Worktrees**: first-class (`/api/worktree`, `worktree.*` events, `opencode run --worktree`, built-in tools
  `worktree_create/list/remove`, `session_move`). [V]
- **Cost/tokens**: per step (`session.step.ended.cost/tokens`), per message, per session (`Session.Info.cost/tokens`,
  `session.usage.updated`), aggregate `exp/session/stats` (by model/tool/day), `exp/usage/limits` (OpenCode Go/Console).
- **Jobs**: `Job.Info` = shell | subagent `{childSessionID, agent, description, status}` | image.
- **Todos**: `todowrite`-style tool exists in core but is gated behind `experimental.todo` [S]; no todo projection
  endpoint — render from tool calls.

## 4. Sub-agents and orchestration primitives already present

- **Agents** [V] built-in: `build` (primary, default), `plan` (primary, read-only: `edit` denied except
  `~/.opencode/plan/*`), `general`, `explore` (subagents), hidden `compaction`, `title`, `summary`. Custom agents via
  config `agents` / `.opencode/agents/*.md`, `mode: primary|subagent|all`, per-agent model, prompt, steps, permissions.
  Plan/build mode = switching the session's agent (`POST …/agent`).
- **`subagent` tool** (v1 "task") [S] `core/src/tool/plugin/subagent.ts`: input `{agent, description, prompt, model?,
  sessionID?}`. Subagents **always run in the background**: the call returns `{sessionID, status:"running"}`
  immediately; each time the child goes idle it posts a `<subagent>` report to the parent's inbox and wakes the
  parent. Passing `sessionID` sends a follow-up to an existing child. Depth limited by
  `experimental.subagent_depth`.
- **Child sessions from the API**: `POST /api/session {parentID, agent}` + `prompt` gives the same parent-wake
  semantics — this is the GUI's "delegate" primitive. [S]
- **Session-to-session messaging**: `POST /api/session/{other}/synthetic` or `/prompt` with `delivery` from any client
  or plugin; plugins also get `ctx.session.synthetic(...)`. [S]
- **Background work**: background shells (`/api/shell`, `shell_timeout_background`), `…/background`, `exp/job`,
  `exp/session/{id}/wait`; the `experimental.idle` plugin hook sees outstanding background work. [S]
- **Workflows**: built-in `/goal <objective>` plugin (autonomous loop with a judge model: verdicts
  done/continue/blocked/paused/wait, max 50 rounds) [S] `core/src/plugin/goal.ts`; **schedules** (in/at/every/cron +
  shell/code conditions, posts a prompt into a session) behind `experimental.schedules`; artifacts behind
  `experimental.artifacts`.
- **Permission handling in a GUI**: subscribe to `permission.asked` (and `form.created`), render, `POST
  …/permission/{id}/reply`. Session-level rules (`PATCH session.permissions`) implement modes like T3's
  full-access / auto-accept-edits / ask (T3 builds `shell: ask`, `edit: ask|allow`, `external_directory: ask`, plan
  mode `edit: deny`). Saved "always" rules are listed/editable via `/api/permission/saved`. On reconnect, list pending
  requests per location and per session (T3 does `permission.list` + `form.list` per session). [S] T3 `v2/adapter.ts`

## 5. Plugin infrastructure

### Server plugins (`@opencode/plugin`, Promise or Effect API)

- Shape [S] `packages/plugin/src/README.md`: `export default Plugin.define({ id, setup: async (ctx) => { … return
  cleanup } })`. `ctx.options` = config options.
- **Transform hooks** (replayable, location-scoped): `ctx.agent|command|integration|mcp|model|provider|reference|
  skill|tool|vcs|websearch.transform(editor => …)` + `.reload()`. Custom tools: `ctx.tool.transform(t =>
  t.add({name, description, input: Schema, output?: Schema, options:{codemode?}, execute: async (input, ctx) =>
  ({output, content, metadata?})}))`; tool context carries `sessionID, agent, messageID, callID, progress()`.
- **Runtime hooks**: `ctx.session.hook("prompt"|"context"|"compaction"|"generate"|"title"|"fork"|"retry"|
  "model.request"|"http.request"|"http.response"|"experimental.ws.*"|"experimental.model.resolve"|
  "experimental.idle")`, `ctx.aisdk.hook("sdk"|"language")`.
- **Domain APIs** on ctx [S] `effect/plugin.ts`: `session` (list/create/get/remove/prompt/generate/command/compact/
  synthetic/interrupt/update/move/context/wait/instructions), `permission`, `event` (subscribe), `shell`, `worktree`,
  `vcs`, `storage` (plugin-private KV), `rpc` (register RPC definitions with methods + events, callable over
  `POST /api/rpc/{rpcID}/{method}` and streamed on `/api/event`), `experimental.{terminal.read, generate, artifact}`,
  `credential.activate`, `plugin.list`, `location`, `app`.
- **Loading** [S] `docs/content/plugins.mdx`: config `"plugins": ["npm-pkg[@ver]", "@scope/pkg", "./local/dir",
  "/abs/dir", "file:///…", {package, options}, "-id" (disable), "*"]`; auto-discovery of `.ts`/`.js` files and
  package dirs in `.opencode/plugins/` and `<config>/plugins/`. Local plugins hot-reload on file change. npm/git
  packages are installed by an **embedded npm (arborist) inside the binary** into the cache — no system node/npm
  needed, but **network is needed for package plugins** on first run. Local-path plugins need no network.
- **Runtime**: plugins run **in-process inside the opencode server**, on the Bun 1.4.4 runtime compiled into the
  binary [V `strings`], with Node-compatible APIs (fs, net, child_process, fetch, WebSocket). TypeScript is loaded
  directly. `effect` and `@opencode/plugin` imports are resolved to the host's copies (declare `effect` as a peer).
- **Can**: add/replace/remove tools, agents, commands, skills, MCP servers, providers/models; edit context before each
  model call; add synthetic input and drive loops; register RPC + events; open sockets/HTTP to the Swift app;
  create permission requests; store data. **Cannot / should not**: block the server (it is in-process — a crash or
  hang affects every session), render UI except via opencode Desktop's GUI bundle format (Electron/Solid —
  irrelevant to a Swift app), or rely on being per-session (plugins are per location; use `context.sessionID`).
- **GUI plugins** (`./gui-experimental` export, `GET /api/plugin/gui`) target opencode Desktop's Electron/Solid host;
  BelloCode cannot run them natively. [S] `packages/gui-plugins/README.md`

### Built-in plugins worth knowing

`opencode.browser` (desktop browser bridge, see §6), `opencode.tool.subagent`, `opencode.tool.question`,
`opencode.tools` (`session_rename`, `session_move`, `worktree_*`, `models`), schedule/artifact tools, `goal`,
`fork-notice`, MCP code-mode defaults, `opencode.config.policy`. Disable with `"plugins": ["-id"]`. [S]

### Code mode

Many tools (MCP tools by default) are exposed through Code Mode: the model writes JS calling `tools.<ns>.<fn>()`
inside an `execute` tool. A GUI must therefore render `execute` calls with nested tool activity (the browser tools are
`tools.browser.*`). `codemode: false` on an MCP server or tool exposes it directly. [S]

### Channels from opencode to the Swift app (choose per capability)

| Channel | How | Good for |
| --- | --- | --- |
| **Client-hosted MCP over WebSocket** | Swift app opens `GET /api/experimental/client-mcp?name=bellocode&location[directory]=…` (Basic auth) and speaks MCP *server* JSON-RPC over text frames. Tools appear as `bellocode_*` for that location only while the socket is open; stacked connections, last wins. Calls carry `_meta["ai.opencode/sessionID"]`. The TUI uses it to give the agent "open terminal" tools. | GUI-only tools that make no sense when the app is closed (preview, browser fallback, reveal-in-app, secrets prompt). No extra process. Marked experimental. [S] `core/src/mcp/index.ts`, `server/src/handlers/mcp.ts`, `core/src/mcp/client.ts:718` |
| **Remote MCP registered at runtime** | `PUT /api/experimental/mcp/{name}` with `{type:"remote", url, headers:{Authorization}}` pointing at an HTTP MCP endpoint the Swift app hosts on 127.0.0.1 (T3's pattern: one server name per thread `t3-code-<thread>`, session rules `deny t3-code-*` + `allow <name>_*`). | Per-thread tools with thread identity baked into the URL/token. [S] T3 `v2/adapter.ts` `prepareTurn` |
| **Server plugin (TS, in-process)** | Bundled directory in the .app, listed in BelloCode's isolated config `plugins: ["/…/BelloCode.app/Contents/Resources/opencode-plugin"]`. Talks to Swift via a unix socket/localhost HTTP given in `options`, and exposes RPC to Swift via `/api/rpc/bellocode/<method>` + events on `/api/event`. | Hooks (idle, prompt, context), policy, agent/command injection, durable server-side behaviour that must work while the app UI is closed. |
| **Plugin RPC** | Swift calls `POST /api/rpc/{rpcID}/{method}`; plugin emits typed events on `/api/event`. | Swift → plugin commands and plugin → Swift notifications without a second socket. |

### Proposed "BelloCode plugin" split

1. **`bellocode` server plugin** (TS, bundled, local path, no network):
   - `experimental.idle` hook: drain BelloCode's own follow-up queue rules, auto-continue policies, "wait for
     background job" behaviour.
   - Tools: `thread_create`/`thread_send`/`thread_list`/`thread_wait` (wrappers over `ctx.session.*` with parentID so
     orchestration stays inside opencode semantics), `project_list`, `link_pull_request` (writes session `metadata`,
     emits RPC event), `request_secret` (creates a form with a secret field or calls Swift via RPC and returns a
     reference, never the value), `schedule_*` passthrough if `experimental.schedules` is not enabled.
   - RPC definition `bellocode` with events (`attention.requested`, `pr.linked`, `notify`) the app listens to on
     `/api/event`.
   - Context hook: inject BelloCode environment instructions (or use session instruction entries from Swift).
2. **App-hosted client MCP `bellocode-ui`** (Swift, WebSocket, per open project location): `html_preview`,
   `preview_open`/`preview_snapshot` (if not using the opencode browser bridge), `reveal_file`, `open_url`,
   `show_diff`, `notify_user`, `request_secret` (native secure prompt). These disappear automatically when the app
   disconnects, which is the right semantics for UI tools.
3. **opencode's own browser bridge** implemented by Swift (§6) — not an MCP at all.

Key risk: client-MCP and RPC routes are under `/api/experimental` (may change between 2.x minors); pin the binary.

## 6. "The opencode browse plugin"

### What it is

- **browse** (`github.com/anomalyco/browse`, MIT, npm `@opencode/browse`, latest 0.1.0; installed here 0.0.16 as a
  115 MB native arm64 binary at `~/.local/bin/browse`, package `@opencode/browse-darwin-arm64`) — "let your AI agents
  use your real browser … A small native MCP server and a Chromium extension, for OpenCode, Claude Code, Codex…". It
  is an **MCP server**, not an opencode plugin. [V] `browse --version`, `browse doctor`; [S] README.
- The user's opencode config registers it [V] (secrets redacted; none present):
  `{"mcp":{"servers":{"browse":{"type":"local","command":["/Users/carlosbello/.local/bin/browse","mcp"],
  "environment":{"OPENCODE_BROWSER_RUNTIME":"auto-update"}}}}}`.
- Architecture [S][V doctor]: agent spawns `browse mcp` (stdio proxy) → starts/uses the **relay** (`browse serve`, Rust)
  on `127.0.0.1:19988` (fallback 19990–19997), token in `~/.local/share/browse/relay-token` → the **Chrome-family
  extension** connects to the relay over a **WebSocket** (paired once with a one-time code; per-browser key proven on
  every connection; relay accepts only published extension IDs plus `OPENCODE_BROWSER_EXTENSION_ORIGINS`) → the
  extension executes relay commands with **`chrome.debugger`**. The extension protocol (v2,
  `src/agent-relay/protocol.ts`) is a command set `debugger.attach/detach/sendCommand`, `tabs.create/remove/group`,
  page status, settings… i.e. **a raw CDP tunnel**. Playwright-style `execute` runs in **QuickJS inside the relay**
  against that CDP connection; sessions = named tab groups; `handoff()` for human steps; secrets typed without the
  agent seeing them; network capture to HAR; recording; journal under `~/.local/state/browse`.
- Tool surface: opencode (code-mode client) gets **plain tools** (`navigate, snapshot, click, fill, type, press,
  select, hover, drag, scroll, wait_for, dialog, upload, eval, screenshot, screenshot_diff, network, console,
  recording, emulate, webmcp, tabs, handoff, demonstrate, settings, status`); other MCP clients get `execute`,
  `status`, `tabs` + session tools (`session_new/use/adopt/allowlist/reset/delete/list`, `secrets_*`,
  `flight_recorder`, …). `OPENCODE_BROWSER_TOOLS=plain|execute|all` overrides. [S] README "Tools"
- Relay status at research time: not running (doctor "Relay: unreachable"), so the extension pairing state on this
  machine is unknown. [V]

### Separately: opencode v2's *built-in* browser bridge (`opencode.browser`)

This is the important discovery. opencode 2.3.0 ships a built-in plugin `@opencode/plugin-browser` that gives the
agent `tools.browser.*` (tabs.list/open/focus/close, preview, navigate/back/forward/reload/stop/frames, snapshot, find,
evaluate, wait, screenshot, click/hover/drag/fill/fill_form/select/check/press/scroll/dialog,
files.upload/drop/list/get, console, network.list/get, trace.*, cpu.*, heap.*, lighthouse) **driving a browser owned
by the desktop client**. The server owns tools, permissions and invocation scope; the **desktop owns tabs and CDP**.
The tools and the `browser` skill stay hidden (permission `browser`/`skill browser` = deny, [V] in agent rules) until
a desktop attaches to the session. [S] `packages/plugin-browser/README.md`, `src/rpc.ts`, `src/connection.ts`

Desktop-side contract (`rpcID = "experimental.browser"`, version 4) [S]:

1. Subscribe to `/api/event` (control events: `{type:"attached"|"command"|"cancel", connectionID, requestID?}`).
2. `POST /api/rpc/experimental.browser/attach {input:{sessionID, connectionID, version:4}}` — long-lived pending call
   for the attachment's lifetime; returns `closed|replaced`. `attached` event = ready.
3. Publish the authoritative tab inventory with `state {tabs[{id "tab_<uuid>", url, title, loading, canGoBack,
   canGoForward, generation}], focusedTabID}`.
4. On a `command` control event, fetch it with `command {sessionID, connectionID, requestID}` → `{action:{type:<op>,
   …}, files[], inspect?, target?}`, run it, answer with `result {…, outcome: success{result:{value, files}} |
   failure{code, message}}`.
5. Optional network tunnelling `tunnel.open/read/write/close` so pages load through the server's network (only needed
   for remote servers; local BelloCode can browse directly).

### Options for BelloCode's embedded browser pane

| Option | Feasibility | Fidelity | Verdict |
| --- | --- | --- | --- |
| (a) WKWebView + shim speaking **browse's** protocol | Would require impersonating the extension (pairing key proof, origin allowlist via env) **and emulating CDP** (`Accessibility.getFullAXTree`, `Input.dispatch*`, `Runtime` isolated worlds, `Page.captureScreenshot`, `Network.*`, Target management) on top of WebKit. WebKit's inspector protocol is not CDP. | Low; brittle against a 0.x protocol that changes weekly. | **Reject.** |
| (a') WKWebView + **opencode's `experimental.browser` RPC** implemented in Swift | Swift implements attach/state/command/result; ops mapped to WKWebView: navigate/back/forward/reload/stop (native), snapshot/find/click/fill/select/check/hover/press/scroll/evaluate/wait/dialog (injected JS in a `WKContentWorld`, native `NSEvent` synthesis for trusted clicks/keys), screenshot (`takeSnapshot`), console (injected hook), preview (native viewers), files.upload (JS DataTransfer, limited). Unsupported ops return `failure` (`trace.*`, `cpu.*`, `heap.*`, `lighthouse`, full `network.*` bodies). | Medium–high for everyday agent browsing; zero extra processes; tools/skill auto-appear per session, permission integration free. | **Recommended v1.** |
| (b) Embed Chromium (CEF) | CDP available in-process (`SendDevToolsMessage`) → implement the *same* `experimental.browser` contract with full fidelity (this is what opencode Desktop's Electron does in `gui-plugins/src/browser/cdp.ts`). Running the browse extension inside CEF (chrome.debugger) is **unverified [U]**. | High. Cost: ~150–250 MB framework, separate signing/notarization of helper apps, Chromium update cadence, memory. | **Recommended v2 / pro mode**, behind the same Swift `BrowserBackend` protocol. |
| (c) Keep external Chrome + browse, present it from the app | Works today with zero code: browse is already in the user's config; BelloCode only shows status (`browse status --json`), pairing/doctor UI, and "watch in Chrome". Cannot embed the window; screen mirroring via ScreenCaptureKit is possible but not interactive. | Full browse fidelity incl. the user's real logins, passkeys, extensions. | **Keep as complementary**: "real browser" for authenticated tasks; the embedded pane for dev-server previews. |
| (d) BelloCode-native MCP with **browse's tool names** | Possible (client-MCP from Swift), but duplicates (a') with a non-native contract, collides with browse's names when both are configured, and loses opencode's built-in permission/skill integration. | Same as (a'). | Only if the built-in bridge's experimental contract becomes unusable. |

**Recommendation**: implement opencode's `experimental.browser` desktop contract in Swift over WKWebView (a'), keep
the browse MCP available for the user's real Chrome (c), and design the Swift browser layer so a CEF backend (b) can
later replace WKWebView under the same contract. Present both clearly: "App browser" (agent tools `browser.*`) vs
"Your Chrome (browse)".
**Key risk**: the bridge is `experimental` (RPC id literally `experimental.browser`, `version: 4`) and was designed
around CDP; WKWebView cannot satisfy every operation and opencode may change the contract in any 2.x release — pin
the embedded opencode version and run a contract test suite against each upgrade. Secondary risk: two browser tool
families confuse the model; set agent/session permissions or instructions so it prefers one per task.

## 7. Packaging

- Distribution [V]: single self-contained Mach-O per platform, built with **Bun 1.4.4** compile (JS bundle embedded).
  `opencode-darwin-arm64.zip` is 108 MB, unzipped binary **224 MB** (arm64 only, thin). Intel: separate
  `opencode-darwin-x64-baseline.zip`. URLs: `https://opencode.ai/files/bin/<ver>/opencode-darwin-{arm64|x64-baseline}.zip`
  with SHA-256 in the tap formula. Linux arm64/x64 tarballs too. Ship both macOS slices (or `lipo` them into a
  universal binary — untested [U]).
- Runtime extras [V/S]: on first PTY use it extracts an **ad-hoc-signed helper** `cache/opencode/bin/opencode-pty/
  0.5.2-…/opencode-pty`; `rg` is taken from PATH, else `cache/opencode/bin/rg`, else **downloaded from GitHub**
  (network). Bundle `rg` in the app and put it on the child's `PATH`. Models catalog fetch (`models.dev`) is
  network but can be disabled/pinned (`OPENCODE_DISABLE_MODELS_FETCH`, `OPENCODE_MODELS_PATH`). Package plugins need
  the npm registry; local plugins do not.
- Licence: **MIT** (`LICENSE`, "Copyright (c) 2025 opencode"); redistribution inside a commercial app is allowed with
  the notice included. Bundled third-party (Bun, ripgrep MIT/Unlicense, etc.) need their notices too; the formula
  ships `sbom.spdx.json` [V] which can seed the acknowledgements.
- Code signing [V]: binary is signed `Developer ID Application: Anomaly Innovations, Inc. (5NZ4Q7NXJ4)`, hardened
  runtime, timestamped, entitlements `allow-jit`, `allow-unsigned-executable-memory`,
  `disable-executable-page-protection`, `allow-dyld-environment-variables`, `disable-library-validation` (JIT runtime
  needs). `spctl -t install` reports "Unnotarized Developer ID" for the bare file. For BelloCode: place it in
  `Contents/Helpers/opencode` (or `Contents/MacOS`), **re-sign with BelloCode's Developer ID + hardened runtime +
  the same JIT entitlements**, and notarize the whole app. The runtime-extracted `opencode-pty` and downloaded `rg`
  live in the user cache, outside the signed bundle (fine for a non-sandboxed Developer ID app; **incompatible with the
  Mac App Store sandbox** [U]). Prefer setting `OPENCODE_PTY_BIN` to a bundled, signed copy of the helper if the
  variable means what its name suggests [U].
- Updating: pin a version per BelloCode release; disable self-update (`OPENCODE_DISABLE_AUTOUPDATE=1`, config
  `update: "disable"`); verify SHA-256 at build; on upgrade, the DB migrates forward automatically (59 migrations at
  2.3.0) — downgrades are unsafe [U]. Keep the generated client and contract tests tied to the pinned spec.

## 8. Auth / provider setup without the TUI

All through the API [V schemas; flows S]:

1. `GET /api/integration` → integrations with `methods[]`: `key {label, form?}`, `oauth {id, label, form?}`,
   `command {id, label, command[]}`, `external {id, label, form?}`, `env {names[]}`; `connections[]` shows what is
   connected.
2. API key: `POST /api/integration/{id}/connect/key {key, answer?, label?}`.
3. OAuth: `POST …/connect/oauth {methodID, answer?, label?}` → `{attemptID, url, instructions, mode: "auto"|"code",
   paste?, time.expires}`. Open `url` in the system browser (or `ASWebAuthenticationSession`); for `auto` the server's
   own callback completes it — poll `GET …/connect/oauth/{attemptID}` or watch `integration.updated` /
   `credential.updated`; for `code` (or `paste`) collect the code/redirect URL and `POST …/complete {code}`; cancel with
   `DELETE`.
4. Command-based (e.g. CLI logins): `POST …/connect/command` + status/cancel.
5. Credentials: `GET|POST|PATCH|DELETE /api/credential`, `POST …/activate` (multiple accounts per integration).
   **Warning**: `credential.list` "List every stored integration credential, including its secret value" — never log
   these responses.
6. MCP OAuth servers show `Mcp.Status.NeedsAuth` and link to an `integrationID`; the same OAuth flow applies.
7. Free models: a fresh isolated server exposes 13 zero-cost `opencode/*` models (e.g. `big-pickle`) with a public key
   [V] — BelloCode works before any login (can be disabled with `OPENCODE_DISABLE_FREE_MODELS`).
8. Importing an existing setup: `opencode auth export|import` (CLI) can copy credentials from the user's global install
   into BelloCode's isolated data dir with consent.

## 9. Gaps BelloCode must fill (and things that are *not* gaps)

Already native (do not rebuild): queued follow-ups (`delivery: "queue"`, inbox list/edit/cancel), steering, unread
basis (`time.idle` vs `time.viewed` + `/view`), child sessions and background subagents, forks, worktrees, per-turn
diffs, revert, PTYs incl. agent-readable persistent terminals, schedules (experimental), session metadata storage,
cross-project session listing (`GET /api/session` without a directory filter, filter by `project`), usage stats.

Gaps:

| Need | Why opencode doesn't cover it | Where to build |
| --- | --- | --- |
| Durable, gap-free UI state across app restarts / SSE drops | Event stream is volatile; durable log is per-session and replay semantics unclear | Swift: projection cache (SQLite/GRDB) refreshed from projections on connect; event stream only for liveness |
| Thread index across *servers* / archived-project management, search over transcripts | API lists sessions; full-text search only on titles (`search`) [U] | Swift index (FTS) fed from message projections |
| Attention model (needs input, failed, done-unseen, waiting on PR) | Only raw signals (permission/form pending, outcome, idle/viewed) | Swift reducer; persist flags in `session.metadata` |
| Notifications / dock badge / menu bar | None | Swift |
| PR linking, PR watching, CI status | No GitHub integration in API | Plugin tool writes `metadata.prs`; Swift (or plugin) polls GitHub via `gh`/API; wakes session with `synthetic` |
| Scheduled tasks that survive the server being stopped | Schedules live in the server process; BelloCode-owned server stops with the app | Keep app/agent alive (login item) or BelloCode scheduler that starts the server and posts prompts |
| Multi-thread orchestration UX (fan-out, wait-all, handoff between projects) | Primitives exist; no workflow object | Plugin tools + Swift orchestration view over parent/child trees |
| Secrets for the agent (env/tokens without exposing values) | `credential` is for provider integrations; forms return values to the model | Plugin `request_secret` + Swift Keychain; inject via `PUT /session/{id}/environment` [U semantics] or shell env |
| Rich previews (HTML/markdown/images) | `browser.preview` exists only via the desktop browser bridge | Swift implementation of `preview` op + client-MCP `html_preview` |
| Project registry (add/remove/rename/icons, last opened) | Projects are implicit; no create/delete | Swift; `PATCH /api/project` for name/icon |
| Sharing / export | No share endpoint; export exists (`exp/session/{id}/export`) | Swift export UI |
| Model/agent pickers with BelloCode defaults | Available via API | Thin Swift UI |
| Remote servers / SSH | opencode supports remote + pairing + tunnels; out of scope v1 | Later |

## Recommended integration architecture

### Process topology

```
BelloCode.app (Swift, non-sandboxed, Developer ID, hardened runtime)
 ├─ Contents/Helpers/opencode            (pinned 2.x, re-signed, JIT entitlements)
 ├─ Contents/Helpers/rg                  (bundled ripgrep, on child PATH)
 ├─ Contents/Resources/opencode-plugin/  (bellocode server plugin, TS, local path)
 └─ spawns ONE child:  opencode serve --stdio --port 0
        env: OPENCODE_PASSWORD=<random per launch>, OPENCODE_CLIENT=bellocode,
             XDG_{CONFIG,DATA,STATE,CACHE}_HOME=~/Library/Application Support/BelloCode/opencode/*,
             OPENCODE_DISABLE_AUTOUPDATE=1, PATH=<bundle Helpers>:<login-shell PATH>
        stdin = pipe held by the app (lease) ; stdout line 1 = {"url": …} ; stderr → app log
        cwd = app support dir (every request names its directory explicitly)
```

One server for all projects; restart with backoff on exit; on restart reconcile (crash recovery resumes claimed
sessions server-side). Optional "connect to existing opencode service" mode for power users.

### Swift client layers

1. **Transport**: `URLSession` with Basic auth, `x-opencode-directory` header per call, typed error decoding of
   `{_tag, message}` bodies.
2. **Generated DTOs** (swift-openapi-generator over a filtered spec) + hand-written `OpenCodeEvent` enum with unknown
   fallback.
3. **EventHub**: single `/api/event` SSE connection (reconnect with jitter; on reconnect emit `.resync`), fan-out by
   `sessionID`/`location`.
4. **Projection store** (actor + SQLite): sessions/projects/messages/pending permissions/forms/inbox; applies events
   optimistically, re-fetches projections on `.resync` or on durable-seq gaps (`durable.seq`).
5. **Domain services**: SessionService (prompt/steer/queue/interrupt/fork/revert/diff), ApprovalService
   (permission + form queue across all locations), TerminalService (PTY WebSockets), AuthService (integration flows),
   WorktreeService, BrowserBridge, ClientMCPHost.
6. **View models** (Observation) per window/thread; streaming text assembled from `(messageID, ordinal)` deltas,
   tools from `(messageID, toolID)` state machine; render code-mode `execute` calls with nested activity.

### Plugin/MCP design

- `bellocode` **server plugin** (bundled, loaded via isolated config `plugins: ["<bundle>/opencode-plugin"]`):
  idle/continuation hooks, orchestration tools (threads, delegate, wait), PR-link tool, instruction injection, RPC
  `bellocode` with events to the app.
- `bellocode-ui` **client MCP** hosted by Swift over `GET /api/experimental/client-mcp` per open location: preview,
  reveal, notify, secret prompt, open URL. Per-thread scoping by `_meta["ai.opencode/sessionID"]`.
- Session-level instruction entries (`PUT …/instructions/entries/bellocode`) for per-thread prompt context (T3
  pattern).
- Session permission rulesets set by the app's mode picker (full access / auto-edit / ask / plan).

### Browser strategy

- v1: Swift `BrowserBridge` implementing opencode's `experimental.browser` v4 contract over WKWebView; attach per
  visible session; unsupported ops fail fast with explanatory codes.
- Keep browse (external Chrome) as the "real browser" tool family; surface `browse status`/pairing in settings;
  instruct agents when to use which.
- v2 option: CEF backend behind the same `BrowserBackend` protocol for full CDP fidelity (trace/heap/lighthouse,
  network bodies).

## Risks and unknowns

1. **Experimental surfaces**: client-MCP, plugin RPC routes, browser bridge (`experimental.browser` v4), schedules,
   artifacts, session log, MCP add/remove are all under `/api/experimental` — expect breaking changes within 2.x.
   Mitigation: pin binary, contract tests, generated-client diff gate.
2. **Event stream volatility**: missed events by design; replay-from-zero of the durable log returned only
   `log.synced` in testing [U] — rely on projections.
3. **Spec quality for codegen**: 3.1 null unions, Infinity/NaN enums, deepObject params, `security: []`.
4. **WKWebView fidelity** for agent browsing (trusted input, AX tree, network capture) vs CEF cost.
5. **Signing/notarization** of a re-signed Bun JIT binary plus runtime-extracted ad-hoc helper (`opencode-pty`) and
   downloaded `rg`; App Store sandbox likely impossible [U]. `OPENCODE_PTY_BIN` semantics unverified.
6. **Plugins run in-process**: a bug in the BelloCode plugin can stall every session; keep it thin, push UI work to
   Swift.
7. **First-run network**: models catalog, `rg` download (avoid by bundling), npm plugins (avoid by bundling local).
8. **Data isolation vs user expectations**: isolated sessions/credentials will not show in the user's TUI; offer
   import (`opencode auth export/import`) and an "attach to existing service" mode; never run two servers on one DB.
9. **browse version drift**: installed 0.0.16 vs npm 0.1.0; its tool set differs by client name; relay not running at
   research time, so pairing state on this machine is unknown.
10. **Credential exposure**: `GET /api/credential` returns secret values; never log/persist those responses.
11. **Unverified items**: `OPENCODE_DB`/`OPENCODE_TEST_HOME` semantics; universal-binary `lipo`; CEF + browse extension
    via `chrome.debugger`; `PUT /session/{id}/environment` semantics; transcript search beyond titles.

## Evidence index

- Commands: `opencode --help`, `opencode {serve,service,auth,api,plugin,session,mcp,pair,acp,debug,run,reload} --help`,
  `opencode debug paths`, `brew info opencode-v2`, tap formula `opencode-v2.rb`, `codesign -dvvv/--entitlements`,
  `spctl -a -t install`, `strings | grep OPENCODE_`, `browse --version|--help|skill|doctor`, `npm view
  @opencode/{client,plugin,sdk,browse}`.
- Live server (isolated XDG dirs under the session scratchpad, ports 47123 and an ephemeral stdio port; both stopped):
  `/openapi.json` (saved as `scratchpad/oc/openapi.json`), `/api/info`, `/api/location`, `/api/project`,
  `/api/agent`, `/api/model`, `/api/provider`, `/api/session` (create/get/messages), one prompt on the free
  `opencode/big-pickle` model (cost 0), `/api/event` capture (`scratchpad/oc/events.txt`), permission create/reply,
  `exp/session/{id}/log`.
- Source: opencode `specs/v2/{session,tools,event-stream-architecture}.md`, `packages/plugin/src/README.md`,
  `packages/plugin/src/effect/{plugin,session}.ts`, `packages/plugin-browser/{README.md,src/rpc.ts,src/connection.ts}`,
  `packages/core/src/tool/plugin/{subagent,question,opencode}.ts`, `packages/core/src/mcp/{index,client}.ts`,
  `packages/server/src/{process.ts,handlers/mcp.ts,handlers/pty.ts}`, `packages/protocol/src/groups/{rpc,mcp,pty}.ts`,
  `packages/cli/src/{server-process.ts,services/standalone.ts,services/service-config.ts}`,
  `packages/core/src/ripgrep/binary.ts`, `services/site/src/docs/content/{plugins,permissions}.mdx`,
  `packages/gui-plugins/README.md`, `packages/desktop/src/main/service/background-service.ts`.
- T3 Code: `packages/provider-opencode/src/server/{OpenCodeRuntime.ts,v2/OpenCode2Server.ts,v2/adapter.ts,
  openCode2Catalog.ts}`.
- browse: `README.md` (Install, Tools, How it works, Security), `src/agent-relay/protocol.ts`.
