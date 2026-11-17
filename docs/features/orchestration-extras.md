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
counted in Needs You, persisted like other requests, kept across resyncs, never auto-dismissed; they do not mark a
thread running (the agent ended its turn and is woken).

## 1. Scheduled tasks
opencode's experimental schedules (verified on 2.3.0: cron+tz works) bind to one existing session, cannot start a thread
per run, cannot be edited and keep no history, so BelloCode schedules itself (`SchedulerService`, `ScheduleCalendar`).
Rules: every N minutes (from an anchor), HH:MM on weekdays in an IANA zone, once. DST: a missing time runs after the gap
with the same minutes (02:30 → 03:30); a repeated time runs at its first occurrence. **Catch-up:** a run up to 2 min
late is on time; later (quit, asleep) → one catch-up run if the task allows it, else one "skipped" record; never a
burst. Ticks on launch, timer (injected `WallClock`), and `NSWorkspace.didWake`. Destination: a new thread per run in
the project, or a message into a thread (queued if running; a deleted thread disables the task). Prompts are prefixed
`[Scheduled task “name”]`. An agent's first task in a project is paused behind an approval card (Allow Once / Always in
This Project / Deny = delete); agents may only change agent-created tasks and never request a permission mode broader
than their own. UI: Settings ▸ Scheduled Tasks (Window ▸ Scheduled Tasks… ⌃⌘E): list, switch, next run, last result
with Open Thread, inline editor, Run Now, Delete with Undo, revoke project grants.

## 2. GitLab merge requests
`ForgeProvider` (protocol) with one implementation, `GitLabProvider`: REST v4 over an ephemeral URLSession, off the main
actor; `PRIVATE-TOKEN` header from the Keychain (`app.bellocode.gitlab-tokens`, account = instance URL); ETag
`If-None-Match` (304 reuses the cached body, bounded cache); `X-Next-Page` pagination (≤ 10 pages); 401 → "token invalid
or expired" (watch held, re-armed when the token is replaced), 403 scope, 404, 429 waits ≥ `Retry-After`. TLS: system
trust store only (trust a private CA in Keychain Access); no overrides. Instances may carry a path prefix
(`https://host/gitlab`); remotes (`git@`, `ssh://…:port`, `https://host/prefix/…`) match configured hosts. Refs: MR URL
or `!iid` in the thread's project. Reads per MR: the MR (`head_pipeline`, `user_notes_count`, draft), `/approvals`,
pipeline `/jobs`, `/discussions` (unresolved count). Auto-link: the branch's open MR (≤ every 10 min while shown) and MR
URLs printed by `git push`. Watch: every 2 min, doubling to 30 min after failures, stops after 8 failures or when
merged/closed; wakes once per event (pipeline finished, approval given or revoked, new comments, merged/closed) with a
synthetic `[BelloCode MR watch] …` whose first line (the transcript note) says why. Archived threads are not polled;
settled threads keep chips current but absorb events without waking (no replay on unsettle). UI: header chip `!42 Open ·
✕ Pipeline failed (1 job)`, sidebar `!42 ✕`, "Merge Requests" tab (Thread ▸ Show Merge Requests ⌃⌘M) with jobs + log links,
approvals, unresolved discussions, watch state and last wake, Open / Open in BelloCode, Unlink with Undo; Settings ▸
GitLab: add instance + token (secure field, Keychain, never shown again), Test, Replace Token, Remove (confirmed).

## 3. Secrets
`request_secret` (label, reason, https setup URL, delivery) raises a card and returns at once; the agent ends its turn.
Save Securely → Keychain → the thread is woken by a synthetic message with a one-use `secretRef` (this thread, 1 h), or
with delivery `file` a path. `secret_file(secretRef)` → a **named pipe** (0600 in a 0700 dir) that yields the value to
the first reader, then is unlinked; unread pipes vanish after 10 min. `PUT /session/{id}/environment` was checked on
the binary (in memory, applies to every shell command of the session) and rejected: too broad. Decline → a refusal wake.
Guarantees (tested on mock and real binary): the value is never in a tool result, wake text, session message, event
stream, opencode's files, our store or logs (`SecretValue` prints `<secret>`). Limits: another process of the user could
read the pipe first (the agent's command then fails visibly); a command that prints the value leaks it into the
transcript (guidance forbids it); Keychain ACLs may prompt after an ad-hoc re-sign. Settings ▸ Secrets lists labels and
deletes (confirmed).

## 4. HTML visuals
`html_preview` (height, console, CSP-blocked requests, PNG path for export) and `html_render` (stored, shown inline).
Sandbox (`HTMLVisualSandbox`): non-persistent store; no message handlers (`window.webkit` undefined); compiled content
rules block everything but about:/data:/blob: and approved hosts, plus a CSP meta (`default-src 'none'`, inline script
only, `frame-src 'none'`); `window.open` refused; every navigation after load cancelled; links open externally only on a
trusted click (scripted clicks dropped before WebKit pre-connects); theme CSS variables and system fonts injected.
Hosts in `allowNetwork` need an approval card (once for the visual, or always per host; Settings ▸ Secrets revokes).
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
3, extras tools 5; BrowserKit sandbox 4 with a loopback listener: 0 connections; TranscriptKit rows 3), `bun test` 15,
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
