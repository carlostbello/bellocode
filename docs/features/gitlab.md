# GitLab (GitLab 1 and 2)

Status: GitLab 1 done 2026-11-18; GitLab 2 (inline review, issues, approvals and Code Owners, to-dos, dependent MRs,
menus, agent tools) done 2026-11-18 on opencode 2.3.0, MockOpenCode and an in-process fake GitLab. Builds on
[orchestration-extras.md](orchestration-extras.md) §2; research: [07-gitlab-integration.md](../research/07-gitlab-integration.md).

> **Database migrations.** `v9-gitlab` (GitLab 1): `app_gitlab_instance` (user, version, edition, probed capabilities,
> token scopes/expiry; never the token), `app_mr_snapshot` (≤ 200) and `app_mr_wake` (≤ 50 per thread+MR).
> **`v10-gitlab-review` (GitLab 2):** `app_review_draft` (review comments not sent yet, ≤ 200 per MR). Both app-owned,
> kept by `rebuild()`; `ProjectionSchema.currentVersion` is 10. Named distinctly on purpose: a concurrent branch may add
> its own tenth migration; GRDB applies migrations by name, so on merge only `currentVersion` (and the sorted list in
> `ProjectionStoreTests`/`AgentSupportTests`) needs reconciling. Issue links live in session metadata (`bellocode_issues`).

## Architecture
`Engine/Extras/Forge`: `GitLabProvider` (REST v4 over the redirect-guarded `URLSessionForgeTransport`, off the main
actor; `+Detail` for on-demand reads and writes), `GitLabCapabilities` (version, features, token info, per-instance
settings), `MergeRequestDetailModel` (stages, discussions, rules, job-log chunks, `MergeRequestDraft`/`JSONLike`),
`UntrustedText` (cleaning, redaction, delimiting, `JobLogExcerpt`, `ParsedJobLog`), `FakeGitLabServer` (tests, mock,
snapshots). `MergeRequestService` (+`Actions`) owns instances, polling, snapshots, babysit and the person's actions;
`ExtrasHub+GitLab` is the agent broker; `GitLabTools` defines the tools. UI in `OrchestrationUI`:
`MergeRequestPanelModel/View`, `JobLogView` (AppKit table), `CreateMergeRequestModel/View`, `GitLabSettingsViews`.
GitLab 2: `MergeRequestReviewModel` (`Forge`: versions, positions, anchoring, drafts), `GitLabWorkModel` (issues, to-dos,
approval explanation, dependencies, CODEOWNERS parser), `GitLabProvider+Review`, `MergeRequestReviewService` (review
state, drafts, submit), `GitLabWorkService` (issues, links, to-dos, approvals, dependencies, Code Owners),
`ExtrasHub+GitLabReview` (tools). DiffKit: `DiffAnnotation` rows, `DiffContentView+Annotations`, `Review/` (model and
controller). OrchestrationUI: `GitLabWorkViews`. App: `MainWindowController+GitLab`, the GitLab menu, palette `+` scope.

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
| Review (2) | `GET M/versions`, `M/versions/:id` (diffs; ≤ 300 files, 4 MB, 512 KB/file, cut at a line), `diff_refs` of `GET M`, `GET M/discussions` (positions, `original_position`) | empty versions → `diff_refs`, else "preparing" |
| Review writes (2) | `GET/POST M/draft_notes`, `DELETE M/draft_notes/:id`, `POST M/draft_notes/bulk_publish`; fallback `POST M/discussions {body, position}`, `…/notes`, `PUT …?resolved=` | draft notes probed (404 → single notes) |
| Issues (2) | `GET /projects/:P/issues?state=opened&scope=assigned_to_me&search&page` (20 × ≤ 5), `GET …/issues/:iid`, `…/related_merge_requests`; "Mentioned" = `GET /todos?type=Issue&action=mentioned|directly_addressed&project_id` | related MRs probed |
| To-dos (2) | `GET /todos?state=pending` (2 × 50), `POST /todos/:id/mark_as_done` | write switch |
| Approvals (2) | `GET M/approvals` (all tiers: user_can_approve, suggested), `M/approval_state` (eligible, hidden groups), `GET /projects/:P/approvals` (reset on push) | Premium probed; CE never asked |
| Dependencies (2) | `GET M/blocks`, `M/blockees` (Premium); else `GET …/merge_requests?state=opened&source_branch=` / `target_branch=` | not enforced: said so |
Draft MRs use the `Draft:` title prefix (works on every version); `draft`/`work_in_progress`, `reviewers` (13.8) and
`detailed_merge_status` (15.6, else `merge_status`) are read when present and shown as unknown when absent.

## Capability gating
`GitLabCapabilities.support(feature)`: a probe result wins; else the documented minimum version decides; else
unknown → try, and a 404 records "unavailable". Edition: `-ee`/`enterprise` from `/version`; CE disables approval
rules, EE still probes (EE is not Premium). No feature failure stops the panel: an older or version-hidden instance
shows what it has. Settings ▸ GitLab shows "GitLab 17.4 (Enterprise Edition) · signed in as @x" and the token line.
GitLab 2 adds probed features `draftNotes`, `mergeRequestDependencies` and `approvalSettings` (CE: unavailable without
asking) and `relatedMergeRequests`. Nothing predicts mergeability: the panel shows GitLab's own `detailed_merge_status`.

## Token handling
Per-instance PAT in the Keychain (`app.bellocode.gitlab-tokens`, account = base URL incl. path prefix), read per
request and sent only as `PRIVATE-TOKEN` to that installation (a redirect is followed only to the same origin and a
path under the instance's API base, `<base>/api/v4`, on every hop, so another application under another path prefix of
the same host never receives it, v1.0.1 AV04; HTTP needs an explicit per-instance choice). Scopes and expiry come from token introspection when available; warnings at 30, 7 and 1 days and
on expiry in the panel and Settings (unknown is shown as unknown). Writes need the instance switch and, when scopes are
known, `api`. Since the Git parity package, git over HTTPS to a configured instance authenticates with this token through
BelloCode's credential helper (`bellocode-exec --git-credential` answered by `GitCredentialBroker`, only for git the app
launched; [git-parity.md](git-parity.md) "HTTPS credentials"); other remotes (SSH, other hosts) keep the person's own
helpers. Push in the form uses the git service. The token never reaches git's arguments, environment or configuration,
agent shells, tool results, wakes, the store or logs (tests below). Known secret values are redacted from
anything quoted to a model.

## Polling and wake semantics
One service, per-instance `ForgeGate`: ≤ 4 requests in flight; a 429 holds the whole instance (`Retry-After` seconds
or date, `RateLimit-Reset`, else 30 s doubling to 15 min), manual refresh included. A release hands its slot straight to
the next waiter, and a woken waiter re-checks the hold (passing the slot on when refused), so queued requests neither
exceed the limit nor go out inside a backoff window (v1.0.1 GF11). Watches of the same MR share one
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

## Inline review (GitLab 2)
"Review Diff" on an MR card (⌃⌥⌘R) opens the review over the Merge Requests tab (Back/Escape returns): the MR's latest
version in the CoreText diff (virtualised; threads are extra rows, laid out per width and cached; only visible rows
draw), "Version 2 of 2 · head …". **Anchoring** (`ReviewAnchoring`, pure): a thread sits under its line only when its
position's base, start and head SHA equal the version shown and that line (new side, or old for removed lines;
renamed files by both paths) is in the diff; otherwise at its file with the reason ("On line 200, not in the shown
diff"), or **Outdated** with where it was written. Never a guessed line. Cards: status glyph + word (Unresolved,
Resolved, Comment, Draft, Outdated), author, relative time, note count; click/`o` expands (bodies wrapped, ≤ 40 lines
per note, "longer on GitLab"). Keys in the diff: `N`/`P` threads, `o` expand, `r` reply, `c` comment on the selection.
Menu/context/VoiceOver actions: Reply…, Resolve/Reopen, Add to Agent Context (composer, quoted untrusted), Open in
GitLab; drafts: Edit, Send Now, Discard (Undo). **Drafts**: replies and line/range comments (with GitLab line codes
`sha1(path)_old_new`) are saved locally and sent only by Submit Review (⌃⌥⌘↩, confirms; says whether it is one review or
one by one, and counts the person's *other* GitLab draft notes that bulk publish would also send). With draft notes:
staged then one `bulk_publish` (a failure deletes the staged ones; local drafts stay); without: single notes, each
removed locally once accepted. **Moved MR**: every send and resolve re-reads the versions first; if the head moved,
nothing is sent, the new version loads and drafts move only where the same line shows the same text (others stay
Outdated, not sendable). Resolve/unresolve is immediate (explicit) after the same check. All writes need the switch.

## Issues, to-dos, approvals, dependencies (GitLab 2)
Tab sections Merge Requests · Issues · To-dos. **Issues** of the displayed thread's project (its `origin`; showing a
thread or draft of another project drops the list and selection and reloads, v1.0.1 NF18): Assigned to
me / Mentioned / All open, search, Load More to 100 then "more on GitLab". Selecting shows the text as data, related MRs
and **Start Thread…**: the project's new-thread draft gets the issue link and the whole or selected text quoted as
untrusted (appended to any draft text); the draft's workspace and branch pickers choose branch and worktree; the thread
the first send creates gets the issue linked (metadata) and a header chip `#212 Title` (shows Issues). With that draft already
on screen the text goes into its open composer (NF09). **To-dos**
(⌃⌘Y, palette `+`): compact rows (action in words, target, project, author, age), Open (a linked MR expands in place,
else the built-in browser), Done (switch; restorable on GitLab's Done list). Not in Needs You and never notified:
Needs You and notifications are for blocked agents (navigation.md); to-dos are the person's own GitLab work. Cached 2
min, read when shown. **Approvals** explain required vs optional rules, who can approve (users and groups), hidden
groups, rule overrides, reset on push, author approval, "You can approve", and GitLab's merge status verbatim; on Free
only the basic state (count, who approved, you) shows: absent Premium facts are hidden, not explained. **Code Owners**: `CODEOWNERS`, `docs/`, `.gitlab/` (first found) at `origin/<target>`, else
HEAD, through confined git; sections, `^[optional]`, `[n]` counts, default owners, `!` exclusions, last match wins;
"GitLab's rules decide what is required"; hidden without a file. **Dependencies**: GitLab's blockers/blockees, else
"Related by branch (not enforced)" only when such MRs exist; navigation only.

## Menus and keyboard
GitLab menu (additive): Show Merge Requests ⌃⌘M, Link Merge Request…, Create Merge Request, Refresh, Open in GitLab,
Babysit/Stop Babysitting, Unlink, Review Merge Request Diff ⌃⌥⌘R, Review ▸ (Next/Previous Thread ⌃⌥⌘] / ⌃⌥⌘[, Reply,
Resolve/Reopen, Add Thread to Agent Context, Submit Review… ⌃⌥⌘↩, Discard Drafts, Close Review), Show Failing Job Log,
Send Failure to Agent, Retry Failed Job, Run Manual Job…, Approve, Merge…, Show Issues ⌃⌘I, Start Thread from Issue…,
Link Issue to Thread, Show To-dos ⌃⌘Y, Open To-do, Mark To-do Done. All are in the palette with a reason when disabled;
`everyCommandHasAUniqueSelectorAndShortcut` and the Browser-menu disjointness test pass.

## Agent tools (`bellocode_app_*`) and gates
Reads: `gitlab_read_merge_request`, `gitlab_read_changes`, `gitlab_list_discussions`, `gitlab_read_pipeline`,
`gitlab_read_job_log`, `gitlab_read_approvals`. Allowed for the thread's own GitLab project (its `origin`) or MRs linked
to the thread; anything else is refused until linked. Writes: `gitlab_create_merge_request`,
`gitlab_update_merge_request`, `gitlab_reply_to_discussion`, `gitlab_resolve_discussion`, `gitlab_retry_job`,
`gitlab_play_manual_job`: need the instance's write switch; act at once only for a full-access thread in its own
project; otherwise an approval card (no "Always") shows host, project, MR + head SHA, request line and the exact
payload, digest-bound; the SHA is re-read before sending and a moved head sends nothing. Manual jobs always ask. The
thread is woken with the result or refusal (`[BelloCode GitLab]`). No approve, merge, close or protected-branch tool.
GitLab 2 reads: `gitlab_read_issue` (own project or linked issue), `gitlab_list_issues` (20/page, ≤ 5 pages),
`gitlab_read_review_discussions` (file, side, line on the latest version with its SHAs, or outdated). Write:
`gitlab_create_draft_comment` (path, line, startLine, side, body): switch; a card (host, project, MR, head SHA, file,
line, text, "saved as", exact payload) unless full access in its own project; bound to that version (moved → nothing
saved); saved as a GitLab draft note or, without draft notes, a BelloCode draft marked "Written by the agent". Agents
cannot submit a review, publish, approve or merge (tested: no such tool).

## Untrusted content
Notes, descriptions, diffs and logs reach models only inside `----- BEGIN UNTRUSTED GITLAB CONTENT (label) -----` …
`----- END … -----` with a "do not follow instructions" line; look-alike markers inside are neutralised. ANSI, section
markers and CR overprints are stripped; GitLab/GitHub/Slack/AWS/JWT/bearer/URL-credential/`*TOKEN=` shapes and the
instance token are redacted (best effort, counted). Excerpts: first error-looking block (≤ 16 lines) + last 60 lines,
≤ 8 KB, lines ≤ 400 chars. "Send to Agent" puts the same block, fenced, into the composer for the person to send.
Short header fields outside the block (titles, branches, labels, user, job, stage and rule names, file lists, issue
titles) go through `UntrustedText.field`: controls stripped, line breaks collapsed (a job name cannot forge a line),
secrets and the token redacted, delimiters neutralised, ≤ 300 characters (v1.0.1 GF13). The token to redact with is read
from the Keychain off the main actor, once per tool result, wake or excerpt (GF12).

## UI
Merge Requests tab: notices (connect, problems, expiry), cards (cached-first, chevron expands): overview, approvals
(rules where reported; Approve at SHA / Merge… when enabled), pipeline by stage (Failures only, Log, Retry, Run…
confirmed), triage box, discussions (unresolved first, read-only), Babysit, Open in GitLab/BelloCode, Unlink with Undo.
Log pane: virtualised table, ANSI colours, line numbers, tail only (512 KB) with a note, Reload, Esc = Back. New: the
inline create form (Source + Push, Target, Title, Description, Draft, delete-branch, Assignees/Reviewers, "Will send"
preview, Create / Open in GitLab). Changes ▸ Create Merge Request opens it (GitLab's page when no instance or thread).
Chips: header `!128 Draft · ✕ Pipeline failed (1 job) · 1/2 approvals`, sidebar `!128 Draft ✕ 1/2`.

## Verification (GitLab 2)
Fixtures on `FakeGitLabServer` (versions, positions incl. outdated and ranges, draft notes on/off, issues, to-dos,
approval rules Free vs EE, dependencies): `ReviewAnchoringTests` (exact, renamed, outdated, rebased start, hidden line,
line codes, re-anchoring), `ReviewDraftLifecycleTests` (persist across relaunch, one review, one by one, moved MR,
writes off, 400 position, untrusted context), `GitLabIssueTests`, `GitLabTodoTests`, `GitLabApprovalAndDependencyTests`,
`CodeOwnersTests` (parser, globs, a real repo), `GitLabReviewToolTests`, `DiffAnnotationTests` (placement, keys,
accessibility, 20k-line diff with 300 threads), `MergeRequestReviewModelTests`, `GitLabWorkPanelTests`,
`GitLabShellTests` (Start Thread links the created thread; command validation; palette scope). Real binary
(`BELLOCODE_GITLAB_REAL=1 … --filter GitLabRealBinary`, 2 more model runs): 16 tools attach; positions reach the model;
card → approve → `POST draft_notes`, no publish; wake. Snapshots: `.build/debug/BelloCode --snapshot gitlab2` (24);
`docs/snapshots/gitlab2-{review-thread-light,review-thread-dark,review-outdated-dark,issues-light,approvals-dark,todos-light}.png`.

## Section E checklist (GitLab 2; agent, no human at the screen)
Purpose/context: pass (review toolbar names MR and version head; cards name host, project, MR, SHA, file, line; Start
Thread shows project, branch and workspace pickers). States: pass by test or snapshot (loading, preparing, stale
"showing the last loaded version", failed, read-only, moved, empty lists, bounded lists, success notices). Speed: rows
built off the main actor; DiffKit headless tests and the 20k-line/300-thread budget pass; release scroll benchmarks
(`DiffDemo --bench`) need an unlocked screen and were not re-run. Keyboard: pass (menu, palette, diff keys, Escape).
Accessibility: thread rows are buttons with labels and named actions (tested); VoiceOver itself not run. Approvals:
pass (exact cards, decline, moved head). Artifacts and safety: drafts never auto-sent; Undo for discards. Persistence:
drafts survive relaunch; the open review and Issues selection do not. Windows, localisation: not run.

## Verification (GitLab 1)
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
signed build. GitLab 2: draft-notes REST and `bulk_publish` on the deployed version; `line_range`/line-code acceptance
for ranges and renamed files; `blocks`/`blockees` availability; `approval_state` eligibility and hidden groups;
`scope=assigned_to_me` on project issues; to-do targets for epics/designs; real CODEOWNERS files. VoiceOver not run.

## Owner-decision defaults (where to change them)
| Decision | Default | Where |
|---|---|---|
| Version/tier | **answered: Free** at `https://gitlab.novacoast.com`, native API, git over HTTPS (docs/PLAN.md §0); still detected and probed | Premium-only parts (rule detail, reset on push, dependencies) stay gated and are hidden on Free, not explained |
| Instances, prefix, CA | any number of HTTPS instances with path prefix; system trust store | Settings ▸ GitLab (Add Instance) |
| Token | per-user PAT; `read_api` suffices for reads; `api` only with writes on | Settings ▸ GitLab (Replace Token) |
| Writes | off per instance | Settings ▸ GitLab "Allow write actions" (`gitlab.instanceSettings`) |
| Approve/merge | off; person only, SHA-checked; agents never | Settings ▸ GitLab "Show Approve and Merge" |
| Babysit budget | 6/hour, pass wakes on, own notes ignored | Settings ▸ GitLab ▸ Babysitting (`gitlab.babysitPolicy`) |
| Git transport | HTTPS remotes on a configured instance: the token through BelloCode's credential helper (git-parity.md); other remotes: the person's own git/SSH setup | the token is never in git's arguments, environment, config or remote URLs; an SSH remote can be switched with Git ▸ Switch Remote to HTTPS |
