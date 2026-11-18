# Orchestration extras (M3-B)

Status: done 2026-11-16 on opencode 2.3.0 and MockOpenCode. Scheduled tasks, GitLab merge-request linking and watching,
secret requests, HTML visual replies. Agent tools are app tools over client MCP (`bellocode_app_*`, `ExtrasTools`,
routed by `ExtrasHub`), attributed by `_meta` session and scoped to the caller's project; the plugin turns Code Mode off
for them (`codemode: false`, so each call is its own transcript row) and its guidance entry names them in 5 lines.
**Owner change (mid-package):** feature 2 targets GitLab only (self-managed likely). GitHub code, `gh` detection and the
public-API fallback were removed; no forge CLI is used. "Open Pull Request" in the Changes panel became "Create Merge
Request" (GitLab's new-MR page for the branch; no API write).

## State and lifetime
| Feature | State lives in | App running, no window | App quit |
| --- | --- | --- | --- |
| Schedules | `app_schedule`, `app_schedule_run` (≤ 50 runs/task), grants in `app_grant` | Run (app stays alive; status item shows next run) | Nothing runs; catch-up at launch |
| MRs | links in session metadata `bellocode_mrs`; watch baselines `app_mr_watch`; instances in `app_preference`; tokens in Keychain | Polled and woken | No polling; resumes at launch, no repeated wakes |
| Secrets | values in Keychain (`app.bellocode.agent-secrets`); labels only in `app_secret`; refs in memory | Cards answerable | Card persists (no value); refs lost |
| Visuals | `~/Library/Caches/BelloCode/visuals` (≤ 300 docs, `<id>.html/.json/-light.png/-dark.png`) | n/a | Rows keep rendering from cache |
Migration `v5-orchestration-extras` (tables above; unshipped, so the MR table was renamed in place from `app_pr_watch`).
App requests (secret card, schedule/network approval) are a new `PendingRequest.app` case: pinned above the composer,
counted in Needs You, kept across resyncs, never auto-dismissed; they do not mark a thread running (the agent ended its
turn and is woken). Since migration `v7-app-requests` (deep review 1, C3) they live in the app-owned `app_request`
table, not the `pending_request` cache: a cache rebuild, a complete server list and the cache-write give-up keep them;
deleting the thread removes them.

## 1. Scheduled tasks
opencode's experimental schedules (verified on 2.3.0: cron+tz works) bind to one existing session, cannot start a thread
per run, cannot be edited and keep no history, so BelloCode schedules itself (`SchedulerService`, `ScheduleCalendar`).
Rules: every N minutes (from an anchor), HH:MM on weekdays in an IANA zone, once. DST: a missing time runs after the gap
with the same minutes (02:30 → 03:30); a repeated time runs at its first occurrence. **Catch-up:** a run up to 2 min
late is on time; later (quit, asleep) → one catch-up run if the task allows it, else one "skipped" record; never a
burst. Ticks on launch, timer (injected `WallClock`), and `NSWorkspace.didWake`. **Dispatch is armed by the engine's
first successful reconcile** (deep review 1, C7): definitions show at once, but nothing runs while the connection is not
live (launch before the server is ready, a reconnect). A run that cannot reach opencode (no endpoint, connection
refused, 503) keeps its due occurrence (no record, a one-off stays enabled; `SchedulerService.deferred`) and is retried
30 s later or on the next arm; a rejection, timeout or unknown delivery is recorded as before. Destination: a new thread per run in
the project, or a message into a thread (queued if running; a deleted thread disables the task). Prompts are prefixed
`[Scheduled task “name”]`. An agent's first task in a project is paused behind an approval card (Allow Once / Always in
This Project / Deny = delete); agents may only change agent-created tasks of their own project and never request a
permission mode broader than their own. **Approval binding (M6-B, review C2):** a task stores the definition the user
approved (name, prompt, rule, time zone, project, destination, agent, model, permission mode, catch-up) and runs (timer,
catch-up, Run Now) only while its definition equals it; a mismatch found at run time records a failed run and asks
again. Any agent change to those fields, or an agent turning a paused task back on, makes it pending and replaces its
card with a before/after card naming the asking thread (no "Always"); the card carries the SHA-256 of the definition
it shows, and approval applies only to exactly that (a stale card approves nothing). Deny on a change card restores
the approved version. "Always in This Project" covers creation only, never changes. The user's own edits in Settings
keep the approval; Settings' Approve binds to the definition the editor shows. UI: Settings ▸ Scheduled Tasks (Window ▸ Scheduled Tasks… ⌃⌘E): list, switch, next run, last result
with Open Thread, inline editor, Run Now, Delete with Undo, revoke project grants.

## 2. GitLab merge requests
`ForgeProvider` (protocol) with one implementation, `GitLabProvider`: REST v4 over an ephemeral URLSession, off the main
actor; `PRIVATE-TOKEN` header from the Keychain (`app.bellocode.gitlab-tokens`, account = instance URL); ETag
`If-None-Match` (304 reuses the cached body *and* its pagination headers, bounded cache); `X-Next-Page` pagination
(≤ 10 pages; a list cut at the cap is marked incomplete: "at least N unresolved", a note in the panel and the agent's
list); 401 → "token invalid or expired" (watch held, re-armed when the token is replaced), 403 scope, 404, 429 waits ≥
`Retry-After`. TLS: system trust store only (trust a private CA in Keychain Access); no overrides. **Token transport
(M6-B):** redirects are followed only within the same scheme, host and port; any other is refused before it is followed
(`ForgeError.redirected`), so the token never reaches another origin or plain HTTP. `http://` instances are refused
unless the person ticks "Allow unencrypted HTTP for this instance" (stored per instance, warned in the list, forgotten
on removal); the provider checks before reading the token. Remotes match instances by scheme, host and port (HTTPS);
an SSH remote resolves only when one configured instance has its host. Instances may carry a path prefix
(`https://host/gitlab`); remotes (`git@`, `ssh://…:port`, `https://host/prefix/…`) match configured hosts. Refs: MR URL
or `!iid` in the thread's project. Reads per MR: the MR (`head_pipeline`, `user_notes_count`, draft), `/approvals`,
pipeline `/jobs`, `/discussions` (unresolved count). Auto-link: the branch's open MR (≤ every 10 min while shown) and MR
URLs printed by `git push`. Watch: every 2 min, doubling to 30 min after failures, stops after 8 failures or when
merged/closed; wakes once per event (pipeline finished, approval given or revoked, new comments, merged/closed) with a
synthetic `[BelloCode MR watch] …` whose first line (the transcript note) says why. Each watch has a generation
(deep review 1, C8): a poll whose watch was unwatched, unlinked or removed and re-added while its GitLab read was out
neither restores, reschedules nor wakes; archive/settle is re-checked after the read. Link edits to one thread's metadata
run one at a time (C9). Archived threads are not polled;
settled threads keep chips current but absorb events without waking (no replay on unsettle). UI: header chip `!42 Open ·
✕ Pipeline failed (1 job)`, sidebar `!42 ✕`, "Merge Requests" tab (Thread ▸ Show Merge Requests ⌃⌘M) with jobs + log links,
approvals, unresolved discussions, watch state and last wake, Open / Open in BelloCode, Unlink with Undo; Settings ▸
GitLab: add instance + token (secure field, Keychain, never shown again), Test, Replace Token, Remove (confirmed).

## 3. Secrets
`request_secret` (label, reason, https setup URL, delivery) raises a card and returns at once; the agent ends its turn.
Save Securely → Keychain → the thread is woken by a synthetic message with a one-use `secretRef` (this thread, 1 h), or
with delivery `file` a path. `secret_file(secretRef)` → a one-read **named pipe** path (projects without container execution only; the app always
runs containerised, where `secret_exec` is the path: see "Guarantee" below). `PUT /session/{id}/environment`
was checked on the binary (in memory, applies to every shell command of the session) and rejected: too broad. Decline
→ a refusal wake. Values longer than 8 KB (the macOS FIFO buffer) are refused at Save.

**Delivery (`SecretPipe`, revised 2026-11-17).** The first design polled `open(O_WRONLY|O_NONBLOCK)` until a reader
appeared, wrote, and unlinked at the deadline or on cancel. A reader blocked in `open` when no writer ever came (racing
the deadline, a cancel, a second reader, or, in tests, another service instance deleting the shared
`bellocode-secrets-<pid>` directory) waited forever, and the suite hung. Now, at creation the app opens the FIFO itself
for reading and for writing (non-blocking, close-on-exec, no SIGPIPE) in `<tmp>/bellocode-secrets/<pid>.<random>/`
(0700, one directory per service instance; the FIFO is 0600):
- a reader's blocking `open` returns at once, because a writer always exists while the pipe is live;
- the value is read from the Keychain off the main thread and written into the pipe's kernel buffer once (never to a
  file; socket buffers are wired kernel memory, not swapped);
- the pipe *finishes* when its buffer has been drained (`FIONREAD` on the app's read end, polled every 20 ms on a private
  dispatch queue, not the cooperative pool), at the 10-minute deadline, or on cancel/quit: unread bytes are discarded,
  the path is renamed to a hidden `.spent-*` node (new opens get ENOENT) and both ends close, so every attached reader
  gets end-of-file at once (`cat` returns; `$(cat P)` is empty);
- a reader that resolved the path just before the rename and reaches `open` after the close would wait for a writer;
  for 250 ms the app opens the spent node for writing whenever a reader is waiting (a non-blocking write-open succeeds
  only then), which wakes it to end-of-file; then the node is unlinked;
- launch (`load()`) removes directories of dead processes (and the old `bellocode-secrets-<pid>` ones), first waking
  any reader blocked on them; `shutdown()` cancels every pipe and removes the instance directory. Finished pipes leave
  the `maxPipes` (16) count, so the bound counts only live pipes.

Pipe mechanics: the value is put into the pipe once, so all readers together receive at most one copy; a reader that
loses a race, opens after it was spent, or is attached at expiry or cancel gets end-of-file immediately (or ENOENT),
never a hang. Same-user processes can open the path first; two racing readers could split the bytes; after a crash a
new opener of a leftover path waits until the next launch wakes it; Keychain ACLs may prompt after an ad-hoc re-sign.

**Guarantee (restated in M6-B after review C3).** What BelloCode guarantees: the value is typed into a private card,
kept in the Keychain, and **never put into the transcript, a tool result, a wake message, opencode's files, our store
or logs by BelloCode**; in containerised projects (the app's only mode) it is given **only to a command the person
approved verbatim** on a card (label, project, folder, variable, command, network and write access), once or "Always
for This Command" (bound to secret + project + variable + exact command + access; deleting the secret revokes it). That
command runs in a one-shot container with no network and a read-only project unless the card said otherwise, receives
the value on stdin (not in any container or exec configuration), and is removed afterwards.

What it does **not** guarantee: that the model cannot obtain the value. The approved command receives it and can print,
encode, split, write or (with network) send it; the output goes back to the agent, and exact-value redaction
(`<secret>`) only prevents accidental display. Approving a command means trusting it with the secret. The host pipe
path (`secret_file`, builds without container execution) is weaker still: the agent chooses whatever reads the pipe,
so it is disclosure to the agent's command, and the secret card says that a command that receives the value can reveal
it. Other limits: a process of the same user on the Mac,
or another Docker API client, can inspect a running container's processes; the value is in the one-shot command's
environment while it runs. Tests: fake-runtime end to end (nothing runs before Allow, verbatim command, stdin delivery,
Once vs Always, changed command or access asks again, Deny, revocation) and a live Rancher run (offline, read-only,
HOME=/tmp, nothing left behind).

Settings ▸ Secrets lists labels and deletes (confirmed).

## 4. HTML visuals
`html_preview` (height, console, CSP-blocked requests, PNG path for export) and `html_render` (stored, shown inline).
Sandbox (`HTMLVisualSandbox`): non-persistent store; no message handlers (`window.webkit` undefined); compiled content
rules block everything but about:/data:/blob: and approved hosts, plus a CSP meta (`default-src 'none'`, inline script
only, `frame-src 'none'`); `window.open` refused; every navigation after load cancelled; links open externally only on a
trusted click (scripted clicks dropped before WebKit pre-connects); theme CSS variables and system fonts injected.
Hosts in `allowNetwork` need an approval card (once for the visual, or always per host; Settings ▸ Secrets revokes).
Grant binding (checked in M6-B): "once" is bound to the visual's ID, which is a hash of its HTML, title and thread, so
changed content is a new visual with no grant; "always" is a per-host decision by design and covers any visual's
traffic to that host (a data-disclosure decision, see containers.md "For the security team"). Merge-request watches
are not grants: they read with the person's token what that token can see and wake the thread; linking an MR is not
approved per MR (policy point).
Transcript: a `.visual` row draws a cached snapshot through the image loader (virtualised); clicking makes it live (≤ 2
live web views, dropped off-screen); Open in Browser (built-in browser, data: URL with the same CSP) and Save Image.

## Proven on the real binary (opt-in `BELLOCODE_EXTRAS_REAL=1`, 8 model runs on opencode/big-pickle)
All 16 app tools attach and are outside Code Mode (zero-prompt test, re-run after the GitLab rename). Secret end to end:
card → save → wake with ref → `secret_file` → `wc -c < PATH` printed the length; the sentinel absent from messages, SSE
and opencode's data dir. One turn called schedule_task (pending approval), link (metadata written beside
`bellocode`), html_render (visual row); approved + Run Now produced a reply in a new thread. A watched item woke the
thread exactly once. The link/watch runs used the earlier GitHub fixtures; the GitLab provider is proven with recorded
GitLab fixtures only (the run budget was spent before the owner's change). Also found: client-MCP tools default to Code
Mode; WebKit rule regexes reject disjunctions.

## Verification
`swift test` (EngineTests incl. ScheduleCalendar 7, Scheduler 6, MR model 6, GitLabProvider 4, MR service 7, secret pipe
3 + delivery races 8 + delivery 6, extras tools 5; BrowserKit sandbox 4 with a loopback listener: 0 connections; TranscriptKit rows 3), `bun test` 15,
`make app`, `make smoke`, shortcut uniqueness. Snapshots: `.build/debug/BelloCode --snapshot extras` (26);
`docs/snapshots/extras-{schedules-light,mr-panel-dark,secret-card-light,approval-card-dark,visual-light,visual-live-dark}.png`.

## Section E checklist (agent, no human at the screen)
Purpose/context: cards name project, label, scope; MR rows name project path, branches, source. States: empty, loading
("Checking GitLab…"), failure (token invalid, rate-limited, unreachable, not configured), pending approval, paused,
stopped watch, success. Speed: local; network off main. Keyboard: menu items ⌃⌘E/⌃⌘M, card shortcuts as approvals;
SwiftUI tab order not driven. Accessibility: labelled rows/cards, status never colour-only; VoiceOver not run.
Approvals: concurrent cards stack (n of m). Persistence: definitions, baselines, grants, cards survive relaunch.
Not run: VoiceOver, real pointer, two windows, a real GitLab instance, a real Keychain prompt.

## Known gaps / needs a human or credentials
A real GitLab (token scopes, approvals on CE vs EE, a private CA), notification delivery, Keychain prompts on a signed
build. Visual files are not deleted with their thread; a grant change does not refresh already-cached snapshots in an
open transcript. The live overlay follows scroll but not row reflow during streaming. No MR creation via API (opens the
new-MR page). `queueSteerAndStopWhileRunning` is still flaky (pre-existing).
