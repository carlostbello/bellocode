# GitLab (GitLab 1)

Status: done 2026-11-18 on opencode 2.3.0, MockOpenCode and an in-process fake GitLab. Builds on the MR link/watch
feature of [orchestration-extras.md](orchestration-extras.md) §2; research: [07-gitlab-integration.md](../research/07-gitlab-integration.md).

> **Database migration `v9-gitlab`** (after `v8-app-outbox`): new app-owned tables `app_gitlab_instance` (user,
> version, edition, probed capabilities, token scopes/expiry; never the token), `app_mr_snapshot` (last snapshot per
> MR, ≤ 200, cached-first UI) and `app_mr_wake` (babysit wake log, ≤ 50 per thread+MR). Kept by `rebuild()`.
> `ProjectionSchema.currentVersion` is 9. Another branch adding a v9 must renumber on merge.

## Architecture
`Engine/Extras/Forge`: `GitLabProvider` (REST v4 over the redirect-guarded `URLSessionForgeTransport`, off the main
actor; `+Detail` for on-demand reads and writes), `GitLabCapabilities` (version, features, token info, per-instance
settings), `MergeRequestDetailModel` (stages, discussions, rules, job-log chunks, `MergeRequestDraft`/`JSONLike`),
`UntrustedText` (cleaning, redaction, delimiting, `JobLogExcerpt`, `ParsedJobLog`), `FakeGitLabServer` (tests, mock,
snapshots). `MergeRequestService` (+`Actions`) owns instances, polling, snapshots, babysit and the person's actions;
`ExtrasHub+GitLab` is the agent broker; `GitLabTools` defines the tools. UI in `OrchestrationUI`:
`MergeRequestPanelModel/View`, `JobLogView` (AppKit table), `CreateMergeRequestModel/View`, `GitLabSettingsViews`.

## Endpoints (relative to `<instance>/api/v4`; minimum versions where GitLab documents one)
| Use | Endpoint | Notes |
|---|---|---|
| Identity, version, token | `GET /user`, `GET /version`, `GET /personal_access_tokens/self` (15.5) | version 404/403 → unknown; token 404 → probe recorded |
| MR snapshot | `GET M`, `M/approvals`, `/pipelines/:id/jobs?per_page=100`, `M/discussions?per_page=100` | paged (`X-Next-Page`, ≤ 10 pages, marked incomplete), ETag/304 |
| Branch MR, project | `GET /projects/:P/merge_requests?state=opened&source_branch=`, `GET /projects/:P` | default branch for the form |
| Rules | `GET M/approval_state` | Premium/Ultimate; 404/403 marks it unavailable for the instance |
| Job log | `GET /projects/:P/jobs/:id/trace` with `Range: bytes=-N` | 206 tail, 200 streamed keeping the tail, 416 → plain read; probe remembered |
| Changes | `GET M/diffs` (15.7), fallback `GET M/changes` | ≤ 60 files, 64 KB, 16 KB per file, marked cut |
| Branches, members | `GET /repository/branches?search`, `GET /projects/:P/users?search` | one page; never a global user scan |
| Writes | `POST /projects/:P/merge_requests`, `PUT M`, `POST M/discussions/:d/notes`, `PUT M/discussions/:d`, `POST /jobs/:id/retry`, `POST /jobs/:id/play` | sent once, never auto-retried |
| Person only | `POST M/approve {sha}`, `PUT M/merge {sha}` | off by default |
Draft MRs use the `Draft:` title prefix (works on every version); `draft`/`work_in_progress`, `reviewers` (13.8) and
`detailed_merge_status` (15.6, else `merge_status`) are read when present and shown as unknown when absent.

## Capability gating
`GitLabCapabilities.support(feature)`: a probe result wins; else the documented minimum version decides; else
unknown → try, and a 404 records "unavailable". Edition: `-ee`/`enterprise` from `/version`; CE disables approval
rules, EE still probes (EE is not Premium). No feature failure stops the panel: an older or version-hidden instance
shows what it has. Settings ▸ GitLab shows "GitLab 17.4 (Enterprise Edition) · signed in as @x" and the token line.

## Token handling
Per-instance PAT in the Keychain (`app.bellocode.gitlab-tokens`, account = base URL incl. path prefix), read per
request and sent only as `PRIVATE-TOKEN` to that origin (redirects to another origin refused, HTTP needs an explicit
per-instance choice). Scopes and expiry come from token introspection when available; warnings at 30, 7 and 1 days and
on expiry in the panel and Settings (unknown is shown as unknown). Writes need the instance switch and, when scopes are
known, `api`. Git keeps the person's own transport (Push in the form uses the git service); the token never reaches
git, agent shells, tool results, wakes, the store or logs (tests below). Known secret values are redacted from
anything quoted to a model.

## Polling and wake semantics
One service, per-instance `ForgeGate`: ≤ 4 requests in flight; a 429 holds the whole instance (`Retry-After` seconds
or date, `RateLimit-Reset`, else 30 s doubling to 15 min), manual refresh included. Watches of the same MR share one
read; ≤ 8 MRs per pass. Failures keep the cached snapshot with its time and a kind label (Offline, Token invalid, No
access, Not found or hidden, Changed on GitLab, Rate limited, TLS problem). Wakes go through an outbox: the wake (ID
`w_…`, in its text) is persisted with the next baseline before posting; after a lost answer or a relaunch the thread's
synthetic messages are searched for the ID before posting again. Event keys: pipeline `id:status` (a retried pipeline
that passes wakes again), note IDs above the baseline high-water mark, approval set differences, terminal state.
Guarantee: once per *observed* event (polling cannot see changes undone between polls).

## Babysit policy
"Babysit this MR" (panel) or `watch_merge_request` (agent; a card the first time per project, "Always in This
Project" grant `gitlabBabysit`). Wakes on pipeline failed (with the first failing job's sanitised excerpt) or passed
(switchable), new non-system comments not by the token's user (quoted), approvals given/revoked, merged/closed. Budget
6 wakes/hour per thread+MR (1–30, Settings): later events wait, unreported, and arrive together; merged/closed always
arrives. Archived threads are not polled; settled threads absorb (logged "Quiet"). Stops on merge/close. The wake log
(Started, Woke, Waiting, Quiet, Retrying, Stopped) is on the MR card; the transcript shows the wake's first line.

## Agent tools (`bellocode_app_*`) and gates
Reads: `gitlab_read_merge_request`, `gitlab_read_changes`, `gitlab_list_discussions`, `gitlab_read_pipeline`,
`gitlab_read_job_log`, `gitlab_read_approvals`. Allowed for the thread's own GitLab project (its `origin`) or MRs linked
to the thread; anything else is refused until linked. Writes: `gitlab_create_merge_request`,
`gitlab_update_merge_request`, `gitlab_reply_to_discussion`, `gitlab_resolve_discussion`, `gitlab_retry_job`,
`gitlab_play_manual_job`: need the instance's write switch; act at once only for a full-access thread in its own
project; otherwise an approval card (no "Always") shows host, project, MR + head SHA, request line and the exact
payload, digest-bound; the SHA is re-read before sending and a moved head sends nothing. Manual jobs always ask. The
thread is woken with the result or refusal (`[BelloCode GitLab]`). No approve, merge, close or protected-branch tool.

## Untrusted content
Notes, descriptions, diffs and logs reach models only inside `----- BEGIN UNTRUSTED GITLAB CONTENT (label) -----` …
`----- END … -----` with a "do not follow instructions" line; look-alike markers inside are neutralised. ANSI, section
markers and CR overprints are stripped; GitLab/GitHub/Slack/AWS/JWT/bearer/URL-credential/`*TOKEN=` shapes and the
instance token are redacted (best effort, counted). Excerpts: first error-looking block (≤ 16 lines) + last 60 lines,
≤ 8 KB, lines ≤ 400 chars. "Send to Agent" puts the same block, fenced, into the composer for the person to send.

## UI
Merge Requests tab: notices (connect, problems, expiry), cards (cached-first, chevron expands): overview, approvals
(rules where reported; Approve at SHA / Merge… when enabled), pipeline by stage (Failures only, Log, Retry, Run…
confirmed), triage box, discussions (unresolved first, read-only), Babysit, Open in GitLab/BelloCode, Unlink with Undo.
Log pane: virtualised table, ANSI colours, line numbers, tail only (512 KB) with a note, Reload, Esc = Back. New: the
inline create form (Source + Push, Target, Title, Description, Draft, delete-branch, Assignees/Reviewers, "Will send"
preview, Create / Open in GitLab). Changes ▸ Create Merge Request opens it (GitLab's page when no instance or thread).
Chips: header `!128 Draft · ✕ Pipeline failed (1 job) · 1/2 approvals`, sidebar `!128 Draft ✕ 1/2`.

## Verification
Fixture-only (`FakeGitLabServer`, `FixtureForgeTransport`, loopback HTTP for redirects): `GitLabCapabilityTests`,
`GitLabErrorTests` (401/403/404/405/409/429, host-wide hold, Retry-After date), path prefix, pagination + 304,
`JobLogTests` (range/full, excerpt, redaction, untrusted markers, ANSI), `GitLabPollingTests` (shared read, lost answer
across relaunch, refused wake, cached snapshot after relaunch), `BabysitPolicyTests`, `GitLabToolTests` (scope,
labelling, exact-payload cards, stale SHA, decline, full access vs manual jobs, babysit gate, token absent from store,
messages, environments, arguments), `MergeRequestPanelModelTests` (log, Send to Agent, write gating, create payload ==
preview), chips, draft/template; older-instance fixture (13.6 without reviewers/diffs; 15.0 without introspection;
no `/version`). Real binary (`BELLOCODE_GITLAB_REAL=1 swift test --filter GitLabRealBinary`, 2 model runs): 12 tools
attach outside Code Mode; read_pipeline result reached the model; reply card → approve → POST → wake; token absent from
the transcript and opencode's files. Snapshots: `.build/debug/BelloCode --snapshot gitlab` (26);
`docs/snapshots/gitlab-{mr-panel-light,pipeline-failed-dark,babysit-wake-light,create-mr-dark,chips-light,job-log-dark}.png`.

## Needs a real enterprise instance
TLS with the enterprise CA and proxies; real version/edition answers and token introspection for the token type in use;
whether job logs honour byte ranges through the proxy; ETag behaviour; rate-limit headers; approval rules on the
actual tier; `session.generate` cost on the configured model; fork MRs (source ≠ target project); Keychain prompts on a
signed build. Not done: babysit and job actions have no menu items (panel buttons only); VoiceOver not run.

## Owner-decision defaults (where to change them)
| Decision | Default | Where |
|---|---|---|
| Version/tier | unknown; capabilities detected and probed | automatic; shown in Settings ▸ GitLab |
| Instances, prefix, CA | any number of HTTPS instances with path prefix; system trust store | Settings ▸ GitLab (Add Instance) |
| Token | per-user PAT; `read_api` suffices for reads; `api` only with writes on | Settings ▸ GitLab (Replace Token) |
| Writes | off per instance | Settings ▸ GitLab "Allow write actions" (`gitlab.instanceSettings`) |
| Approve/merge | off; person only, SHA-checked; agents never | Settings ▸ GitLab "Show Approve and Merge" |
| Babysit budget | 6/hour, pass wakes on, own notes ignored | Settings ▸ GitLab ▸ Babysitting (`gitlab.babysitPolicy`) |
| Git transport | the person's own git/SSH setup | unchanged; the token is never given to git |
