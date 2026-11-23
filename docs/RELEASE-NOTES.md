# Release notes

BelloCode is versioned by the `VERSION` file; the bundled opencode is pinned in `Scripts/opencode-version`. Every
release so far bundles opencode **2.3.2**, is arm64 only, and is ad-hoc signed (not notarised). How a release is built
and opened: [RELEASE.md](RELEASE.md). What the reviews found and how each finding was handled:
[reviews/README.md](reviews/README.md).

## Unreleased (1.0.2)

The fixes from the three v1.0.1 final pre-push checks ([Astra](reviews/v1.0.1-astra-final-check.md) AF01–AF27,
[Neon](reviews/v1.0.1-neon-final-check.md) NF01–NF24, [GLM](reviews/v1.0.1-glm-final-check.md) GF01–GF14), merged as
P5–P9 on `develop`, plus the documentation for the first public push. `VERSION` still says 1.0.1 until this is tagged.

### Behaviour you will notice

- **Auto asks more often about recursive searches.** The preflight for `grep -r` / `-R` now walks every folder grep
  would enter, `.git` and `node_modules` included, follows links as grep does and expands globs; a search whose tree
  holds a secret-looking file, or whose operands depend on a shell variable, now comes to you. `--include`/`--exclude`
  rules apply in order with the last match winning, as grep applies them, and a brace expansion, a glob the shell
  would expand in an option or the pattern, or an operand that cannot be examined also asks. The risk policy version
  is `bellocode-auto-4` (AF14, GV03).
- **Workspace containers run as a verified numeric user.** The image's user is resolved from its own account files
  without running it, root and unknown names are refused before anything starts, and every exec (commands,
  terminals, MCP servers, probes, port relays, secret commands) uses the numeric `uid:gid`. An existing workspace that
  was created by name is treated as out of date and recreated once. `$HOME` and cache folders are prepared by
  BelloCode's own pinned image instead of the project image as root, and the workspace has no added capabilities
  (AF09, AF10).
- **Quit asks when a draft cannot be saved.** A draft whose attachment or record could not be written stays unsaved
  and is retried; at quit, BelloCode offers Try Again or Quit Anyway instead of losing it silently (AF22).
- **The right panel's Files tab is gone.** It was a placeholder; open files with Quick Open (⌘P) or the Command
  Palette's `/` scope. A saved "files" selection falls back to Changes (NF07).
- **Shared Chrome closes a thread's tabs when the thread is archived or deleted**, as the setting in Settings ▸ Browser
  always said (on by default; tabs shared with another thread stay open) (NF11).
- **A message to a held thread waits.** After one agent stops another thread, a `thread_send` to it is queued without
  waking it, until you resume, including one sent while the stop is still being confirmed (GF02, GV08). `create_threads` refuses unknown agents and sub-agents (GF14).
- **Command Palette** lists the Browser and Shared Chrome commands and refreshes GitLab to-dos while open (NF20).

### Fixes by area

- **Git and rewind (P7):** Generate Message reads untracked files inside the checkout only and never follows a link
  out of it (AF01). Restore Stashed Changes restores the index too and drops the stash only after verifying it (AF05).
  A pending push is bound to the remote and URL it was approved for, and the force-push confirmation binds the remote
  revision it protects (AF06, AF21). Commit and Push reports a failed push (NF05). Rewind is scoped to the thread's
  worktree root, and rollback and Undo act there; a failed Undo is reported (AF19, AF20, NF12).
- **Project boundary and opencode config (P7, P8):** repository instruction reads open no path through a link, atomically with the lookup, and re-check every folder's identity after the read; hard-linked instruction files are refused (AF08);
  a trust change reloads every active location it covers (AF17); a Settings save never overwrites an external
  editor's save to `opencode.json` (AF24); Restart Server waits for the server before refreshing (NF06); Reload opencode
  Configuration reports its result when Settings is closed (NF16).
- **Secrets and the CLI (P5):** the CLI takes the server address and password from one authority and the password
  broker only admits the bundled helper (AF02, AF18). Secret row writes are serialised so a use count cannot undo a
  revocation; grant kinds are checked at delivery; short values cannot be put into a hidden mode; environment cleanup
  is retried (AF03, AF04, AF16, AF26). The egress proxy re-authorizes a substitution right before sending (AF15).
- **Containers and the Docker filter (P6, P6b):** dev-container staging copies through pinned folder descriptors and
  never blocks on a FIFO (AF07, AF25); CRLF Dockerfiles and a nameless global `ARG` are parsed correctly (AF11, AF12);
  an oversized chunk size no longer crashes the filter (AF13); "Sign in to the registry" opens Settings ▸ Containers
  (NF08).
- **Engine, client MCP and models (P8):** the app and Shared Chrome tools are hosted for projects added while
  connected and again after a server restart (NF01); live message updates are no longer dropped after a sub-agent
  refresh (NF02); global MCP servers are registered when a project is shown (NF03); the Auto tab loads its log at once
  (NF22); scheduled tasks sort consistently (NF23); an unreadable background-model preference keeps its warning and
  the plugin's mirror (AF27).
- **App UI and drafts (P9):** a failed first send from a draft returns its text to the new thread's composer (NF04);
  Start Thread from Issue fills an open draft (NF09); the draft's model hint only promises free models when they exist
  (NF24); the Issues view follows the displayed project (NF18); Shared Chrome viewers follow who has control and Stop
  during a start is reconciled (NF17, AF23); the menu bar's Scheduled Tasks… brings BelloCode forward (NF21).
- **GitLab (P9):** the request gate re-checks the 429 hold for queued requests and never exceeds its limit (GF11);
  the token used for redaction is read off the main actor once per result (GF12); titles, branch, job and stage names
  and other header fields are cleaned and redacted (GF13).
- **Tests (P8):** time limits on every suite that touches sockets, processes or web views; the uptime-timer guard
  scans `Tests/`; assertion-free and wall-clock checks replaced (NF13, NF14, NF15). `make test` passes (1,644 tests).
- **Documentation and licences:** a public README, a [user guide](USER-GUIDE.md), these notes, a review index,
  CONTRIBUTING.md, the Apache-2.0 notice for the seccomp profile derived from moby/profiles (now also bundled in the
  app's Acknowledgements folder), stale versions and statuses corrected, and personal paths removed from recorded
  fixtures (GF01, GF03, GF06, GF08–GF10).

## 1.0.1 (2026-11-20)

A corrective release for the two independent reviews of 1.0.0 ([Astra](reviews/v1.0.0-astra-review.md) A01–A30,
[Neon](reviews/v1.0.0-neon-review.md) N01–N38), merged as P1–P4.

- **opencode config, CLI, plugin, models (P1):** the CLI's connection file no longer holds the password; one server per
  data root, with a lock the CLI and the app share; release builds ignore development overrides. Trust reports success
  only when the plugin acknowledges it and fails closed on write errors. The plugin confines repository reads. JSONC
  edits handle CR/CRLF, BOMs and comments after trailing commas and keep comments. Model edits are serialised, storage
  failures are shown, and Reload Now is confirmed.
- **Secrets and egress (P2):** each new Keychain value is bound to its policy across crashes, and values are updated
  in place, never deleted first; every broker hop re-authorizes against the secret as it is now and unsent uses are
  given back; removing a code root narrows secrets; response decoding cannot spin or miss an escape at the end of a
  buffer; the egress gateway runs the image this launch built and never leaks a failed tunnel.
- **Docker filter, containers, Auto (P3):** the whole build context is judged before the daemon sees it; the host
  docker-only client is confined and sandboxed and gets enforced egress; dev containers build a staged copy, with no
  network under enforced egress and never as root; the git credential broker refuses non-canonical repository paths;
  Auto's deterministic-allow and escalation bypasses are closed and reviews are bound to the exact operation
  (`bellocode-auto-2`).
- **Git, rewind, drafts, browser, transcript (P4):** worktree handoff restores the stash with its index and verifies
  before dropping; rewind writes stay beneath the worktree and refuse submodules; the git runner's deadline always
  completes; drafts use ordered, fenced writes with a flush at quit; the shared browser treats an unconfirmed stop as
  not stopped and a stop wins over crash recovery; the transcript no longer re-parses Markdown on the main actor per
  streaming tick.
- Working-tree diffs use git plumbing so a refresh never takes the index lock.

## 1.0.0 (2026-11-20)

The first build handed to the owner, after the [release-readiness review](reviews/release-1.0-review.md) (R01–R35)
and its fixes.

- **Core app:** a native window with a project and thread sidebar, command palette, search, notifications and
  restoration; a virtualised, streaming transcript; a composer with drafts, attachments, queue and steer; approvals and
  questions pinned above the composer; model picker, onboarding and accounts; isolated opencode data with credential
  import.
- **Code and git:** a Changes panel with review comments and revert; terminals on opencode's PTYs; worktrees and
  branches; git parity with T3 Code (actions, HTTPS credentials through BelloCode's helper, checkpoints and rewind,
  clone and publish).
- **Orchestration:** delegation to child agents, fan-out threads, thread-to-thread messages and stops, the Agents panel,
  scheduled tasks, HTML visuals and `send_to_user` cards.
- **GitLab:** merge request panel, pipelines and job logs, babysitting, create MR, inline review, issues, to-dos,
  approvals, and agent tools, through the GitLab API with a personal access token.
- **Containers:** Rancher Desktop execution with three modes (shared workspace over code roots, project container or
  dev container, host docker-only), a filtered Docker endpoint, services, caches, image policy, global MCP servers,
  company CA and proxy, network diagnostics and prune.
- **Security:** Auto mode with a risk policy, reviewer and audit log; Full-access risk notices; attributed interrupts;
  a Keychain secret manager with brokered, placeholder (egress proxy) and visible secrets.
- **Browsers:** a built-in WebKit browser with the opencode browser bridge, and one shared containerised Chromium driven
  by `browse`.
- **opencode:** pinned 2.3.2 with a recorded contract and an upgrade gate, the `bellocode-opencode` CLI, per-project
  trust for repository configuration, and per-task model settings.
- **Packaging:** `make release` builds an ad-hoc signed arm64 zip and checks a quarantined copy of it.
