# G2 Server: OpenCodeKit core (supervisor, HTTP, SSE, EventHub)

Status: partially answered, 2026-11-16, opencode 2.3.0 (`Vendor/opencode/2.3.0`, archive SHA-256 verified).

## Verified

`swift test` runs 78 tests. `IntegrationTests.swift` drives the real binary with isolated XDG/HOME dirs in a temp
dir, sends no prompt, and checks every child pid is gone. Over six full runs:

- `start()` to verified ready (ready line plus `/api/info` pid match): 94 to 107 ms.
- SIGKILL to the new server verified ready: 270 to 369 ms, of which 200 ms ±20 % is backoff. The EventHub
  `.resync(.connected(2))` arrives at about the same moment.
- `stop()` (close stdin, child exits 0): 6 to 9 ms. A stop while the child is still starting leaves no child.

Also: a wrong password gets 401; a session survives a restart; the new server has a new pid, port and password;
every frame in `events-sample.sse` decodes to a known case, identically byte by byte, chunked and with CRLF.

## Event ordering and replay (observed)

- The stream sends only `data:` lines, with no `id:`, `event:` or `retry:`. Heartbeats are `:` comments (30 in the
  sample). The first frame of every connection is `server.connected`, which has no `created`.
- A new location emits `session.created` first, then `project.updated` and the catalog `*.updated` frames (the
  location activates lazily on its first request). `session.created` arrived in the same millisecond as the
  `POST /api/session` response, so do not rely on either order. Match on the ID.
- `PATCH title` emits `session.renamed`; `DELETE` emits `session.deleted`. `durable.seq` is only on durable frames.
- After a reconnect there is only a new `server.connected`. Nothing is replayed, so anything emitted in the gap is
  lost. EventHub therefore sends `.resync` on every connect, and on overflow for a slow subscriber.

## Not verified

- Sleep/wake: the SSE request has a 45 s idle timeout (heartbeat 15 s), so a dead socket should reconnect and resync.
- A kill mid-stream and "no lost or duplicated messages after resync": needs a prompt plus the Engine projection.
- `session.status`/`session.idle` (never seen; use `session.execution.*`), and the experimental session log replay.

## API facts the Engine author must know

- Location scoping is the deep-object query `location%5Bdirectory%5D=<percent-encoded path>`. The brackets must be
  encoded. `x-opencode-directory` is not in the contract, so it is not used. Session routes resolve location from
  the session. `GET /api/session` filters with its own `directory=` parameter.
- Wrappers vary: `{location, data}` for location lists, `{data, cursor}` for session/message lists, `{data}` for
  single objects, a bare array for projects. `limit` is a string; event `types` is a repeated query parameter.
- `PATCH /api/session/{id}`, permission and form replies, and delete all return 204. Re-read or follow events.
- There is no abort endpoint. `POST …/interrupt` returns `{interrupted: Bool}` (false when idle).
- `prompt` only admits the prompt to the inbox; the turn runs async. Idempotency is keyed on the client `id`.
- A non-git directory got a hash project ID, not `global` as research 05 says. Group by the server's `projectID`.
- `Model.Ref.id` is `Model.Info.id` (the catalog entry; corrected on 2.3.2, where tiers such as `gpt-6.2-astra-fast` share `modelID` `gpt-6.2-astra`); `ModelInfo.ref` builds it. Model, provider and agent responses contain
  `headers`/`body`/`request`, which can carry credentials. They are deliberately not decoded.
- `permission.replied` uses `reply`, while the reply body uses `decision`. `form.created` wraps `{form}`.
- Numbers may be the strings `"NaN"`/`"Infinity"`. Errors are `{_tag, message, …}`; `/api/info` is 503 while
  starting. Stream failures arrive as SSE event `effect/http-api/stream/failure`; EventHub reconnects on it.

**Generated client?** Not yet. M1 needs about 25 operations, and the spec's null unions, string-or-number fields,
deep-object query, secret-bearing catalog fields and `security: []` need post-processing anyway. Revisit later.

## Follow-ups

- HOME defaults to `<dataRoot>/home` (as the smoke test). Decide whether the app passes the real HOME (git config).
- Delete `Sources/BelloCodeApp/SmokeTest.swift` once the app launches through `ServerSupervisor`.
- G2 pass needs an Engine test: kill mid-stream on a free model, resync, compare with `GET …/message`.
