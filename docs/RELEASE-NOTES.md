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
  is `bellocode-auto-5` (AF14, GV03, GW02).
- **Auto reads options the way programs do.** An abbreviated long option (`git grep --op=CMD`, `sort --out=FILE`,
  `grep --rec`), a clustered or attached short option (`sort -ro FILE`, `sort -oFILE`) and `grep --color -r` are now
  the option they spell, so they are no longer allowed as read-only commands, and a recursive spelling gets the
  secret-file preflight. `diff -r`, `git diff --no-index` and `git grep --no-index`/`--untracked` get the same
  preflight. `git stash` with no subcommand, and `git branch`/`tag`/`remote` with anything but listing options, now
  go to the reviewer (GW02, AF14). `uniq - FILE` and `xxd - FILE` (stdin in, FILE written) and any operands after
  `--` count as an output file too (GR3-01).
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
- **A short Brokered or Placeholder value saved by an earlier release is no longer used** in that mode; Settings ▸
  Secrets names it until you rotate it to at least 8 bytes or make it Visible (AF16).
- **Settings ▸ Secrets ▸ Uninspected destinations shows what is saved** for the selected project, so Save no longer
  replaces it with a blank field (NV06). A failed Revoke or Restore there, and a GitLab token replacement the Keychain
  refuses, are reported instead of ignored (NV12).
- **Typed browser shortcuts belong to a shown, focused browser.** ⌘L, ⌘R, ⇧⌘R, ⌘=, ⌘-, ⌘0, ⇧⌘C, ⌃⇥ and ⌃⇧⇥ act on the
  built-in browser only while its tab is shown and has focus; otherwise the composer, a text field or the terminal
  keeps the key. Chosen from the Browser menu they work as before, and the ⌃⌘ browser shortcuts stay global (NV05).
- **⌃⌘↩ and ⌃⌥⌘↩ in the composer** run Git ▸ Run Suggested Git Action and GitLab ▸ Submit Review… instead of inserting
  a blank line; the composer keeps only the Return combinations that send (NV03).
- **Show Merge Requests, Show Issues and Show To-dos work without an open thread**: on a new-thread draft (Issues for
  its project) and with nothing selected (Merge Requests, To-dos) (NV02).
- **Revoking Shared Chrome for a project stops its calls already waiting or running**: none is sent after the
  revocation, including a first call still waiting for the browser's MCP process to start, and a running call's
  result is withheld (AV05).
- **Removing a code root ends secret use by its projects on open connections too**: a workspace connection kept
  alive across the change is judged by the new scope at its next request (AV2-04).
- **Stop Shared Chrome is available when a start failed or a stop was not confirmed**, from the Browser menu, the
  Command Palette, Settings ▸ Browser and the panel (AF23).
- **Approved pushes need git 2.46 or Apple Git-155 or later.** BelloCode pins an approved push to the reviewed address
  in a way older git does not honour, so on an older Command Line Tools git the push plan and the approved push are
  refused with a message naming the version ("Update the Command Line Tools, or push from a terminal"); nothing is
  sent. Sync and Publish are not affected (AF06, GV10).
- **Free models are promised only when one can be chosen now** (usable and not hidden with Hide Model) in the draft
  hint, onboarding and Settings ▸ Accounts, whose empty state otherwise says "Connect a provider to use your own
  models." (NF24, NV14).
- **A resumed session whose checkout was replaced gets no repository instructions.** Each session's repository root
  (its path and folder identity) is now kept on disk in BelloCode's data folder, so after a server restart a session
  whose checkout folder became a link to, or was swapped for, another checkout gets no `AGENTS.md` text instead of
  the other checkout's. So does a session whose pin cannot be read or stored, and an old session that may have lost
  its pin when the store (10,000 sessions) overflowed, unless its folder's path holds no link at all. Sessions
  started before this version count as such: one reached through a link (a code folder on another volume) gets no
  repository instructions until a new session is started there. New sessions are not affected (AF08).

### Fixes by area

- **Git and rewind (P7):** Generate Message reads untracked files inside the checkout only and never follows a link
  out of it (AF01). Restore Stashed Changes restores the index too and drops the stash only after verifying it (AF05).
  A pending push is bound to the remote and URL it was approved for, and the force-push confirmation binds the remote
  revision it protects (AF06, AF21). Commit and Push reports a failed push (NF05). Rewind is scoped to the thread's
  worktree root, and rollback and Undo act there; a failed Undo is reported (AF19, AF20, NF12).
- **Project boundary and opencode config (P7, P8):** repository instruction reads open no path through a link, atomically with the lookup, and re-check every folder's identity after the read; hard-linked instruction files are refused (AF08);
  a trust change reloads every location the server has loaded below it, however many, and stays pending with a problem when that list cannot be read (AF17, GV07); a Settings save never overwrites an external
  editor's save to `opencode.json` (AF24); Restart Server waits for the server before refreshing (NF06); Reload opencode
  Configuration reports its result when Settings is closed (NF16).
- **Secrets and the CLI (P5):** the CLI takes the server address and password from one authority and the password
  broker only admits the bundled helper (AF02, AF18). Secret row writes are serialised so a use count cannot undo a
  revocation; grant kinds are checked at delivery; short values cannot be put into a hidden mode; environment cleanup
  is retried (AF03, AF04, AF16, AF26). The egress proxy re-authorizes a substitution right before sending (AF15).
- **Secrets and egress, second round (Q1):** a revocation published after the proxy's last check cancels the pending
  write and returns only once it has ended, and only once the proxy holds a snapshot at least that new (AF15); the
  response is scanned for the value actually sent, so a rotation in flight cannot echo it back (AV01); transfer codings
  and repeated `Content-Encoding` fields are undone before scanning (AV02); an overflowing chunk size is refused
  instead of terminating the app (AV09); every refusal before sending gives its reserved uses back, in memory and in the
  store, and an upgrade with a placeholder reserves nothing (AV13, GV05, NV07); a thread's environment replacements are
  ordered, so a stale one cannot land after a revocation's (AF26, GV04); a short hidden value saved by an earlier release
  is never activated (AF16).
- **Secrets, egress and Shared Chrome, third round (R3c,** [Astra](reviews/v1.0.1-astra-verification-2.md)**):** a
  revocation whose environment replacement was superseded before it was sent waits for the newer replacement's answer
  instead of returning with the value still on the server (AF26); concurrent use refunds leave the same count in the
  database and in memory (AV13); the egress proxy judges each request and dispatch by the gateway scope as it is now,
  not as it was when a kept-alive connection opened, and cancels in-flight writes a scope change withdraws (AV2-04);
  Shared Chrome checks a call's authorization at the transport as each request is sent (AV05).
- **Containers and the Docker filter (P6, P6b):** dev-container staging copies through pinned folder descriptors and
  never blocks on a FIFO (AF07, AF25); CRLF Dockerfiles and a nameless global `ARG` are parsed correctly (AF11, AF12);
  an oversized chunk size no longer crashes the filter (AF13); "Sign in to the registry" opens Settings ▸ Containers
  (NF08).
- **Containers, second round (Q2):** the Dockerfile reader the image policy relies on reads a file as BuildKit does
  (a byte-order mark, every trailing CR, Go's blanks, continuations joined with nothing between, builder flags byte by
  byte, `--mount` options as CSV, global `ARG` defaults expanded) and refuses a file it cannot be sure about: invalid
  UTF-8, a form feed, vertical tab, NEL, no-break space or control character in an instruction or a leading comment,
  `//syntax=` or JSON directives, a quoted base image, a variable in `COPY --from` (AF11, GV01). A dev container's
  Dockerfile is read through the project folder's descriptor, so a folder swapped for a link cannot hand the builder a
  file from outside the project (AV06). The context copy is iterative and bounded at 128 folders deep (a context about
  130 deep used to crash the app); an unreadable folder or too many open files is reported as such, and the app raises
  its open-file limit at launch (GV06). The workspace setup helper mounts volumes only at fixed paths of its own and
  makes nested cache folders as the user, so a populated or shared cache can no longer cover its programs; cache paths
  from image labels must be plain absolute paths away from `$HOME`'s parents and BelloCode's own mounts, and caches
  outside `$HOME` now have their root folder given to the user too (AF09). Enterprise roots reach Alpine's, the RHEL family's and openSUSE's
  default CA files as well as Debian's (GV09).
- **Engine, client MCP and models (P8):** the app and Shared Chrome tools are hosted for projects added while
  connected and again after a server restart (NF01); live message updates are no longer dropped after a sub-agent
  refresh (NF02); global MCP servers are registered when a project is shown, including a thread shown before its session has loaded (NF03); the Auto tab loads its log at once
  (NF22); scheduled tasks sort consistently (NF23); an unreadable background-model preference, including a saved row that no longer
  decodes, keeps its warning and the plugin's mirror (AF27).
- **App UI and drafts (P9):** a failed first send from a draft returns its text to the new thread's composer (NF04);
  Start Thread from Issue fills an open draft (NF09); the draft's model hint only promises free models when they exist
  (NF24); the Issues view follows the displayed project (NF18); Shared Chrome viewers follow who has control and Stop
  during a start is reconciled (NF17, AF23); the menu bar's Scheduled Tasks… brings BelloCode forward (NF21).
  For a thread in a worktree, Window ▸ opencode… and Project Environment… open on its project, so trust and
  settings are read and written for the project root, while Open in Terminal still opens the worktree (NV04). File ▸ Reopen
  Closed Thread (⇧⌘T) also brings back a thread deleted within its Undo window (NV13). Thread ▸ Mark Risk Notices
  Reviewed works on a thread whose session has not loaded yet (NV15).
- **Second verification round, app UI and Shared Chrome (Q5):** a failed Shared Chrome start stops a browser it adopted
  from a previous launch, and Stop in Failed stops one still running (AF23); an out-of-range numeric tab ID (or
  service-log line count) from an agent is refused instead of crashing (AV11); threads from before launch close their
  Shared Chrome tabs when archived or deleted, also after a change-stream overflow (NF11); a failed first send whose
  thread composer already starts with the same words still gets its attachment and error back (AV12); closing a
  window detaches its terminals and closes its floating Git panel, popover and palette (NV08); Edit from Here puts
  the prompt into its own thread after a thread switch (NV09); container notices appear on threads shown before
  their session loaded (NV10); Settings ▸ Scheduled Tasks has its vertical divider (NV11).
- **GitLab (P9):** the request gate re-checks the 429 hold for queued requests and never exceeds its limit (GF11);
  the token used for redaction is read off the main actor once per result (GF12); titles, branch, job and stage names
  and other header fields are cleaned and redacted (GF13).
- **Git, rewind and GitLab, second round (Q3,** [Astra](reviews/v1.0.1-astra-verification.md),
  [Neon](reviews/v1.0.1-neon-verification.md), [GLM](reviews/v1.0.1-glm-verification.md)**):** an approved push goes to
  the remote by name with its URL pinned to the one shown, so an `insteadOf` rule can no longer redirect it and
  remote-scoped settings (`sslVerify`, `proxy`) apply again; it publishes only the shown branch, no tags or push options
  (AF06, GV10, AV08). A `.git` that is a link is never a sandbox write root (AV03). Generate Message never reads a file
  swapped in for a link (AF01). Rewind counts delegated children as threads sharing the worktree (AF19). A Settings save
  never deletes another program's `opencode.json` save when its conflict copy fails (AF24). GitLab: a redirect never
  takes the token outside the instance's API base path (AV04); a 429 holds queued requests too (AV14, GV02); when the
  Keychain cannot give the token to redact with, no GitLab content reaches a model (tools error, babysit wakes are held
  and shown as "Updates held") (AV07); Add to Agent Context and Send to Agent never land in a thread you switched to
  meanwhile (AV10). Move Changes to New Worktree opens a thread there instead of "No Thread Selected" (NV01); a
  cancelled push after Commit and Push still refreshes the actions (NV16).
- **Git, rewind and GitLab, third round (R3b,** [Astra](reviews/v1.0.1-astra-verification-2.md),
  [GLM](reviews/v1.0.1-glm-verification-2.md)**):** an approved push first checks that the git running it clears a
  remote's URL lists on an empty value (its version, then a probe of the same binary) and refuses otherwise (AF06,
  GV10). The host git sandbox derives a checkout's metadata roots from the `.git` it opened, so a `.git` swapped for a
  link after the check grants nothing; worktree back-references are compared by identity and a hard-linked `.git` file
  is refused (AV03). Rewind decides which children the rewound turns created from the server's own message order, not
  from a git timestamp and an estimated clock offset (AF19). GitLab: every babysit wake post, retries included, needs
  the token to redact with, and a wake saved by an earlier version is rebuilt instead of posted (AV07); triage excerpts
  are kept per installation, project and job (AV2-01); a huge `Retry-After`, job duration or expiry date no longer
  traps the app (AV2-03); the author, path, job name, stage and issue title in Add to Agent Context, Send to Agent and
  Start Thread from Issue are redacted too, and every GitLab tool result and error gets a final exact-token pass
  (AV2-05).
- **Third verification round (R3a,** [Astra](reviews/v1.0.1-astra-verification-2.md),
  [GLM](reviews/v1.0.1-glm-verification-2.md)**):** the Dockerfile reader the image policy relies on, and the build
  instrumenter that adds the trust roots to every stage, continue a line only as BuildKit does: a trailing escaped
  escape (`RUN echo \\`) ends the instruction, so the next line's `FROM` is a stage whose base is checked and
  instrumented; the instrumenter also splits CRLF files into lines, honours `# escape=` and no longer takes a comment
  ending in the escape for a continuation (AF11, GW01).
  The plugin's repository instructions are bound to the session's checkout: a session folder that is, or comes to
  be, a link inside a checkout, or that leads into the middle of another checkout, hands over no instructions, and
  each session keeps the root its first prompt found (AF08).
- **Repository instructions across restarts (round 4,** [Astra](reviews/v1.0.1-astra-round3-check.md)**):** the
  root pin is durable. The plugin stores each session's root path, device and inode in
  `<data>/bellocode-instruction-pins/` (a folder the app passes in its options, outside every code root) before it
  hands over any text, and a later lookup, in this server or a restarted one, must find that very folder; a fork or
  child in the same folder starts from its origin's pin. An unpinned session created at or before the store's
  watermark (the store's creation, raised by each eviction) is pinned only when its folder's path holds no link. A
  missing or linked pin folder, an unreadable pin or watermark, or a pin that cannot be written gives no
  instructions (AF08).
  Edit from Here's rewound prompt reaches every open composer of its thread, in any window, so a second window no
  longer saves over it, and when no window shows the thread it goes in front of the saved draft with that draft's
  mentions and attachments kept (AV2-02).
- **Drafts shown in two windows (round 4,** [Astra](reviews/v1.0.1-astra-round3-check.md)**):** a thread's draft has
  one revision, and every composer saves only on top of the latest one. An idle window showing an older copy now
  follows the other window's save, and an edit made there is kept after the newer draft instead of replacing it ("Both
  versions are kept"). Edit from Here puts the rewound prompt in front of the latest draft once, and every window then
  shows it, so an idle window can no longer save its old text over the other window's newer text or attachments
  (R3-01). When the thread's saved draft is slow to load, the prompt waits for it (with a notice) instead of being
  added as plain text, which used to drop the draft's mentions and attachments; if it never loads, the draft is left
  unchanged and an alert shows the prompt with Copy Prompt (AV2-02).
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
