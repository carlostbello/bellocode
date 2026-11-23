# Auto mode, Full-access risk notices and thread interrupts

Status: built 2026-11-18 on opencode 2.3.0 (pinned) with the hook contract re-checked on 2.3.2. Research:
[research/08](../research/08-auto-mode-risk-secrets.md). Owner direction (PLAN §0): full access, but surface risky
things; implement T3's Auto; agents may interrupt other threads; MCP servers always need a person.

> **Database: migration `v11-auto-audit`** (table `app_auto_audit`; named distinctly, `currentVersion` 11). Default mode
> for new threads is now **Full access** (owner's stated intent); the picker changes it per draft or thread.

## Verified hook contract (`AutoHookRealBinaryTests`, isolated HOME/XDG; same code path in 2.3.0 and 2.3.2)
- `Permission.evaluate`: agent rules + session rules are checked for a **deny first, which returns before any plugin
  hook** (test: trace empty for a configured deny). Then saved project grants are appended as `allow`, ask/allow is
  computed, and `permission.evaluate` runs with `{sessionID, agent, action, resources, metadata, source, effect}`. A
  hook may set `effect`/`message`. **Promise hooks are awaited** (probe slept 400 ms; create returned after 403 ms).
- **Saved "always" grants vs the hook:** in an Ask session a saved grant turns the next request into `allow`; in an Auto
  session the same request is `ask` because the hook turned the grant's `allow` back (test passes on both versions).
- Tool order (live, Full access): `execute.before` → `permission.evaluate` → `execute.after`. The shell tool differs
  since 2.3.2: `execute.before` → `shell.create.before` (BelloCode's container helper is substituted) →
  `permission.evaluate` (asserted in the tool's `prepare` callback, which `Shell.create` calls after the hook; a refusal
  throws before anything is spawned) → `execute.after`. The hook has no effect beyond the substitution, so the order
  is harmless. `execute.after` may add to `result.metadata`
  (verified: `bellocode_permissions` reaches the app's tool part).
- Coverage (binary source + live): built-in read, edit/write/patch, glob, grep, shell (one resource per parsed
  command), external_directory, webfetch, websearch, question, skill, subagent, todowrite, code-mode `execute`, browser
  and every MCP tool (`<server>_<tool>`, live: `bellocode_app_queue`) assert a permission, so Auto sees them.
  BelloCode's own plugin tools do not (they apply their own scoping). Children copy the parent's rules (marker included).
- **App away:** an unanswered Auto request stays pending on the server (test: still listed after 2 s). On reconnect the
  resync lists it again and it is triaged again; nothing is allowed without the app. Plugin missing: Auto's `* ask` rules
  still ask for everything except saved grants (reviewed only once the plugin loads).
- Non-waking synthetic input (`resume: false`) is parked in the **inbox** until the next run (probe).

## Policy (`RiskPolicy`, version `bellocode-auto-5`, pure and unit-tested; precedence below, a model can override none)
1. **opencode's configured denies** (never reach BelloCode).
2. **Hard deny** (reply `reject` with the reason): BelloCode/opencode data and config (`~/.config/opencode`,
   `~/.local/share|state/opencode`, `~/Library/Application Support/BelloCode`, `bellocode-exec.json`), `~/Library/Keychains`,
   Docker sockets, `security dump-keychain|find-*-password -w/-g|export`, `docker run` with the socket/`--privileged`.
3. **Mandatory escalation** (the person decides): secret-looking files (`.env*` except example/sample/template/dist,
   keys and certs, `id_*`, `.netrc`, `.npmrc`, `.pypirc`, `.git-credentials`, `credentials*`, `secrets*`, `*.tfvars`,
   keychains) and credential dirs (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.docker/config.json`, gcloud, azure, gh);
   secret-like env vars (`$*TOKEN*`, `$*SECRET*`, …, `printenv NAME`) and environment dumps (`env`, `jq env`/`$ENV`);
   searches over hidden or ignored files (`rg -u`/`--hidden`/`--no-ignore`, `ag -u`, hidden-file globs such as `cat .*`) and
   a `grep -r` whose tree holds a secret-looking file (bounded scan of every folder grep enters, `.git` and
   `node_modules` included; `--include`/`--exclude`/`--exclude-dir`/`--include-dir` applied in order, the last matching
   rule winning and a file counting as read when GNU or BSD grep would read it (BSD also matches the whole path);
   following links as `-r`/`-R` do; glob operands expanded as the shell does, hidden names included; a shell variable, a
   brace expansion, a glob the shell would expand in an option or the pattern, an operand or folder that cannot be
   examined, or over 20 000 entries, counts as one; N05, AF14, GV03; the command is read with GNU's and BSD grep's
   option grammars, abbreviations (`--rec`, `--dir=rec`) included, optional values (`--color`) only attached, and an
   option neither knows read as recursive with and without a value, GW02); the same scan for `diff -r`,
   `git diff --no-index` and `git grep --no-index`/`--untracked`/`--no-exclude-standard`; paths outside the project and its worktrees
   after `~`, `..`, `cd` and symlink resolution (`/tmp` exempt for container commands); cross-project
   (`bellocode_other_project`); agent/MCP/isolation config (`opencode.json*`, `.opencode/`, `.mcp.json`, `.devcontainer/`,
   `.git/hooks`, `.git/config`, `git config`, proxy/TLS env vars, firewall tools; written by output redirections or by any
   program that is not read-only, N05); credential-bearing or uploading network
   requests (auth headers, `-u`, userinfo or token query, `-d @file`, `-F file=@`, `scp`/`rsync` to hosts); destructive git
   (reset --hard, clean -f, push --force/delete, branch -D, checkout --/., restore, stash drop/clear, filter-branch, …);
   irreversible deletes (`rm -r/-f`/globs, `find -delete`, shred, dd, mkfs); publish/deploy (`git push`, npm/cargo/gem
   publish, docker push, kubectl apply, terraform apply, helm, …); package installs and lifecycle scripts (npm/pnpm/yarn/bun
   install/add/ci, npx, pip/uv/poetry, cargo/go/gem/brew/apt, …); adding MCP servers (`opencode|claude mcp`); commands it
   cannot analyse (substitution, eval, `sh -c`, inline interpreter scripts, piping into a shell, encoded payloads, parse errors, sudo).
4. **Deterministic allow** (`once`): in-project non-secret read/list/glob/grep; in-project non-policy edits; read-only
   commands (ls, cat, grep/rg, find without -exec/-delete, git status/diff/log/show, …) whose every path is inside, and
   never with an option that runs a program (`rg --pre`, `git grep -O`/`--open-files-in-pager`, `--ext-diff`, `--textconv`,
   `sort --compress-program`, `ag --pager`) or writes a file (`sort -o`, `tree -o`, `file -C`, `xxd -r`) or sets the
   clock (N05). Every spelling a program reads counts as the option (GW02): any unique abbreviation of a long option,
   since getopt_long and git's parse-options take them (`git grep --op=CMD`, `sort --out=FILE`), its value attached or
   as the next word, and a short option anywhere in a cluster or with an attached value (`sort -ro FILE`, `-oFILE`;
   an attached value naming a secret, a protected store or a policy file counts as naming it). `git branch`, `tag`
   and `remote` are read-only only with listing options, and `git stash` only as `list`/`show`. Mandatory
   escalations match abbreviations too (`git reset --har`, `rm --rec`);
   todowrite, question, skill, subagent, BelloCode app tools (they ask themselves).
5. **Saved grant** (non-mandatory only): a project grant the person saved with "Always" covers it (`once`).
6. **Reviewer** for everything else (unknown tools, MCP tools, builds/tests, network without credentials, …).

Corpus: `RiskPolicyTests` (~150 cases incl. indirection and encoded commands). Shell analysis is best effort, not a boundary.

**Code roots** (owner decision, PLAN §0): `Engine.codeRoots: CodeRoots` (BelloCore; or a `CodeRootsProvider`, then
`refreshCodeRoots()`), default none = each thread's project and worktrees only. Paths inside any root are in scope for
Auto and Full-access notices (no escalation or notice for location alone; `external_directory` inside roots is allowed
once); `bellocode_other_project` whose target directory is inside a root is in scope (allowed once in Auto). Secrets,
policy files, destructive or publishing actions inside a root still count; protected stores stay refused; outside every
root still escalates. Tests: `RiskPolicyCodeRootTests`, `AutoCodeRootTests`.

## Reviewer (`AutoReviewer`)
`POST /api/experimental/generate/text`: stateless, no session, no tools, nothing stored (chosen over a dedicated session:
no transcript, no rule inheritance; over `session.generate`: that uses the working thread's history). Model: Settings ▸
Models ▸ Auto reviewer, else the thread's model, else the server default, else a fast catalogue model; while a paid
provider is connected the automatic steps never pick a free model (the free tier refuses `generate.text` once its
allowance is used). A provider refusal escalates with `provider_limit` and similar codes naming the model
([models.md](models.md)). Input (bounded, redacted): action, tool, ≤8 project-relative targets, command ≤600 chars with
`KEY=`, auth headers, bearer, userinfo and long opaque strings redacted, thread title ≤80, policy note; never history,
file contents or output. Fixed policy text first, then one JSON object `{"untrusted": …}` (JSON-escaped, so injected text
stays a string). Output: exactly `{"decision":"allow_once"|"escalate","reason_code","explanation"}` (one ```json fence
tolerated); anything else, timeout (default 5 s, ContinuousClock; returns at the deadline even if the backend ignores
cancellation), cancellation, model error, full queue (2 running, 8 waiting), hourly budget (240) → **escalate** with a
reason code. Cache 60 s keyed by the **exact operation** (A09: every resource, path, URL and the whole command, the session, directory and
roots, the policy version and the reviewer model with its variant, hashed, never logged), not by what the reviewer was shown;
an input that does not fit (more than 16 targets, a target over 300 or a command over 2 000 characters) is escalated
(`review_incomplete`), never judged clipped. **Binding:** applied only if the request is still in triage, the session is still
Auto in the same run (`busySince`), the recomputed input hash matches and the policy version is unchanged; else the
person decides (`stale_review`). Auto replies `once` or `reject`, never `always`.

## Engine and UI
Auto sessions' requests enter a **triage set** in the projection (not shown, not counted, never persisted; a signal
wakes `AutoModeService`, nothing is dropped). Escalations move into the normal pending list with `AutoEscalation`: the
existing pinned card leads with "Auto asks you: Reads a secret-looking file: .env" and counts in Needs You. Approved calls
carry `ToolCall.risk.autoApproval`: the transcript shows "✓ Auto-approved · reason · reviewer model|policy|your saved scope"
under the call (routine reads, todos, questions, skills, sub-agents stay quiet; the audit lists them). Right panel **Auto**
tab: per-thread audit (cached first, loaded at once by the thread's ID, one cancellable load, so an offline thread still
shows its decisions; v1.0.1 NF22; ↑/↓/Return expand), counts, policy and reviewer. Thread ▸ Set Permission Mode: Ask
⌃⌥⌘1, Auto-edit ⌃⌥⌘2, Auto ⌃⌥⌘3, Full access ⌃⌥⌘4; Show Auto Audit Log ⌃⌘J; Mark Risk Notices Reviewed; Resume
Interrupted Thread ⌃⌥⌘P (uniqueness tests pass). The picker (⇧⌘A) lists Auto with what runs and what always asks.

## Full access (and opencode-default) risk notices
The reducer runs the same detectors on each tool call's input plus the evaluations the plugin stamped on its result
(opencode's own canonical resources), at start (**attempted**) and at the end (**completed**/**failed**). The transcript
shows "⚠ Destructive git: reset --hard · completed · best effort" under the call; the thread's tray shows "N risk notices to
review (not blocking)" with Audit Log and Mark Reviewed; Needs You lists the thread after blocking items as "Review N risk
notices" (never "Approval"). Audit kind `notice`. **Coverage limits:** static analysis of shell text cannot see what
scripts, Makefiles, package scripts or binaries do at runtime, aliases, files read by programs, or data sent by allowed
tools; terminals, host git, service containers and MCP server internals are not instrumented; history loaded from the
server is not re-scanned (live events only). No notice promises complete detection.

## Interrupts (`thread_interrupt`, plugin contract 2)
Same project (including unrelated threads): **no approval**; a reason is required; attributed to the calling session
(server-side caller/target lookup; unattributed, deleted or archived targets refused; an idle target is reported, not
stopped). Rate limits per caller (3/5 min) and per target (2/5 min); a thread an agent stopped cannot interrupt others for
60 s (cascade cap); concurrent requests for one target are de-duplicated. Another project still asks
(`bellocode_other_project`, escalated in Auto). Reported: requested `stop` vs actual `stopped|still_running|failed|not_running`
plus the cascade report. The target gets `metadata.bellocode_interrupt` (`held: true`) and a parked
`[BelloCode interrupt]` note; the caller's transcript shows "✕ Stopped “X”: reason · requested stop, stopped". The target's
tray shows "Stopped by “Y”: reason. Its queued work is held until you resume." with Open Thread and **Resume** (⌃⌥⌘P):
clears the hold and posts a resuming note that starts a run (opencode then delivers the parked queue). Resume is a
continuation, not a rollback. `thread_send` to a held thread is queued, never steered, and admitted with
`resume: false`, so it never wakes the thread or clears the hold (v1.0.1 GF02). A `thread_send` that arrives while an
interrupt of that thread is still confirming its stop waits for it and is held the same way, even if the hold record
could not be written (GV08).

## Verification
`make test` (Swift Testing, 1,069 tests; new: RiskPolicy 18, AutoReviewer 8, AutoMode 9 + interrupt 2 + audit store 1);
`make plugin-test` 49 (bun in a container; auto helpers, hooks, interrupt rules); `BELLOCODE_AUTO_REAL=1 swift test --filter
AutoHookRealBinary` (`BELLOCODE_AUTO_BINARY=…/2.3.2/opencode` for 2.3.2). Live on 2.3.0 with the free model (8 prompts):
tool order and metadata (pass), MCP + subagent asserts in Auto (pass), `.env` read escalated end to end through the real
engine (pass), same-project interrupt attributed and held without approval (pass). `--snapshot auto` (24 PNGs);
docs/snapshots/auto-{mode-picker-dark,chip-audit-dark,escalation-light,risk-notice-light,interrupt-resume-dark}.png.

## Section E checklist
Purpose/context: cards and audit name action, targets, thread, project, source and policy. States: empty audit (no thread /
nothing yet, per mode), deciding (hidden, sub-second), escalated, refused, stale review, reviewer timeout/offline/busy/budget,
notices attempted/completed/failed, held/resumed. Speed: policy decisions are local; the reviewer is bounded by its timeout.
Keyboard: every action has a menu item and shortcut; audit list keyboard-navigable; Tab order not driven. Accessibility:
status words and glyphs (never colour alone), banner labels; VoiceOver not run. Approvals: escalations use the existing
card (multi-request, deny with note); Auto never claims an approval before the server's acknowledgement. Persistence:
audit persists; triage is rebuilt from the server. Not run: two windows, large text, VoiceOver.

## Unverified / follow-ups
- A routine Auto approval and a live reviewer call end to end on the real binary: the two runs after the escalation run
  produced no tool calls (consistent with the free tier's usage limit seen earlier); mock-engine tests cover both paths.
- Live child-session trace (children inherit rules: verified in `PolicyRealBinaryTests`); browser bridge tools (source only).
- Reviewer prompt-injection against a real model (tests cover quoting, parsing and that mandatory gates never reach it).
- Unattended (scheduled) runs in Auto: opencode turns `ask` into deny when nobody is present.
- Saved grants are shown/revoked where they already are (Settings); Auto ignores them for mandatory categories.
