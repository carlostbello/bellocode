# BelloCode: macOS UX patterns for an agent workbench

Research date: 2026-11-16. Scope: interaction and product design, not implementation or performance engineering. Rankings reflect the author's judgement of likely impact on a coding-agent workbench, not measured population frequency. **Evidence** below means documented platform guidance, a product's own description, or an identifiable public report; **recommendation** means a proposed BelloCode choice. Product documentation establishes that a feature is offered, not that users love it. GitHub issues and comments are self-selected anecdotes, sometimes requests or proposed fixes, not proof of prevalence or of a current release's behavior. Product interfaces and documentation change.

## A. Ranked UX anti-patterns

### 1. Hide the thing blocking progress in a transcript

**Example:** An agent appears to hang while a permission request is buried among tool output. A Zed contributor described repeatedly mistaking this situation for a buggy agent and proposed grouping pending permissions above the input ([Zed PR #50819](https://github.com/zed-industries/zed/pull/50819); proposal, not evidence of a shipped feature). **Why it hurts:** the user must inspect every thread to find the one actionable item; elapsed time gets mistaken for progress. **Alternative:** show “Needs approval” with project, thread, age, and count in a persistent attention queue and on the session row; pin the actual request above the composer, with an accessible jump to its full context. Keep blocked, error, finished-unread, and running distinct. Never imply that a background agent is still progressing when it is waiting for the user.

### 2. Ask for consent without enough context—or ask so often that consent becomes reflex

**Example:** “Allow shell command? Yes / Always” omits the command, working directory, agent, scope, and consequences, or displays a new app-modal sheet for every read. **Why:** ambiguous authority and interruption fatigue make both review and safe delegation harder. **Alternative:** an in-context, keyboard-accessible request card shows the exact command or operation, path/host, affected resource, reason when supplied, and explicit scope and duration of each choice. Offer allow once / deny and only those broader scopes the provider actually supports; do not equate a thread, project, and global grant. Default focus to the safe action, never auto-approve when a timer expires, preserve an audit trail, and route denial or timeout back as the true outcome. Keep high-impact or irreversible actions distinct; undo is not a substitute for permission.

### 3. Overwrite the user's attention with endless streaming and tool logs

**Example:** every command expands to 500 lines and incoming tokens pull the viewport away while the user selects earlier text. A [Zed issue](https://github.com/zed-industries/zed/issues/64755) reports long tool and subagent cards filling the panel and obstructing navigation. **Why:** the user loses place, cannot read or copy, and misses the answer among machinery. **Alternative:** follow the tail only when already at the bottom; otherwise preserve the scroll anchor and show “New output ↓”. Summarize tools by verb, target, status, duration and result; collapse successful output, cap expanded height, and retain searchable/copyable full output. Show failures and requests prominently. Keep streamed text selectable and stable.

### 4. Treat interruption, steering and queued messages as the same action

**Example:** typing while an agent works silently cancels its command, or a message that looks sent stays in an invisible queue. **Why:** users cannot predict whether work stopped, when instructions will take effect, or whether a follow-up survived. **Alternative:** visibly distinguish **Stop now**, **Steer at next supported boundary**, and **Queue after this turn**. Show ordering, delivery state, edit/remove controls and limitations; never claim steering was delivered until acknowledged. Zed documents queue, steer and immediate interruption separately, and notes that steering depends on agent support ([Agent Panel](https://zed.dev/docs/ai/agent-panel)). Preserve the draft when changing mode or session.

### 5. Ship a touch-first Mac port with giant, sparse controls

**Example:** oversized navigation cards and 44-point-everything spacing show only four sessions on a large desktop display; hidden hover menus replace right-click and menu commands. **Why:** a mouse, trackpad, hardware keyboard, multiple windows, and a large resizable canvas invite fast parallel work; excessive whitespace increases scanning and window switching. **Alternative:** use a compact, readable desktop density with user-adjustable text and pane sizes; maintain adequate target sizes and VoiceOver semantics. Apple asks designers to account for macOS windowing, menus, pointer and keyboard ([Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)). In a 2021 [Six Colors analysis](https://sixcolors.com/post/2021/06/wwdc-2021-macos-monterey-further-blurs-lines-between-mac-catalyst-and-ipad-apps/), Stephen Hackett observed that unadapted iPad apps could feel foreign on the Mac and that gesture-only navigation needs rethinking; he also noted Catalyst can use native Mac controls and that good adaptation requires care. Developer James Thomson described substantial UI redesign work to reach a satisfactory Mac/iPad middle ground in a [2019 account linked by Six Colors](https://sixcolors.com/link/2019/10/james-thomson-on-using-and-not-using-mac-catalyst/). These are dated, informed critiques rather than current evaluations of the frameworks. This is a critique of interaction choices, not a claim that Swift, SwiftUI, or Catalyst inherently causes poor UX.

### 6. Make basic Mac interaction feel foreign

**Example:** ⌘Z does nothing in the composer; ⌥← cannot move a word; tab order skips an approval; a focused button has no visible focus ring; ⌘, opens nothing; standard actions are missing from the menu bar. **Why:** users bring years of muscle memory and assistive workflows. **Alternative:** preserve standard text editing, selection, input methods, context menus, Full Keyboard Access, focus indication and system commands; put discoverable commands in conventional menus. Avoid stealing terminal and browser shortcuts. See Apple's [menus](https://developer.apple.com/design/human-interface-guidelines/menus), [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), and [macOS keyboard shortcuts](https://support.apple.com/en-us/102650).

### 7. Throw away the workspace when the window closes or the app restarts

**Example:** relaunch returns to a blank project picker, loses an unsent prompt and all pane widths, or opens a random thread. **Why:** rebuilding context is a recurring tax, especially with many long-running sessions. **Alternative:** restore windows, tabs, projects, selected thread, pane visibility/width, scroll position and drafts where possible. Clearly distinguish restored view state from a live, reconnected agent; do not pretend a process is running if its status is unknown. If a restored repository is unavailable, show its location and recovery choices. Honor the user's macOS window-restoration preference ([Apple window restoration](https://support.apple.com/guide/mac-help/quit-and-reopen-apps-mh35876/mac)).

### 8. Block navigation with generic spinners and ornamental animation

**Example:** selecting a cached thread clears the transcript, displays a centered spinner, and fades the entire pane for half a second. **Why:** the interface discards useful context and makes an inexpensive action feel uncertain. **Alternative:** select immediately, show cached content labeled stale when needed, and refresh in place. Use skeletons only for genuinely unknown structure and avoid flashing them for brief waits; use a spinner for indeterminate work with a meaningful label and a progress bar only when progress is knowable. For local reversible actions, show the expected result optimistically and roll back with an explanation if it fails. Never optimistically assert that an external command, send, approval, PR merge, or filesystem deletion succeeded. Nielsen's [0.1/1/10-second model](https://www.nngroup.com/articles/response-times-3-important-limits/) is a useful heuristic, not a universal guarantee.

### 9. Present every event at equal urgency

**Example:** a dock badge, banner and sound fire for every tool call; the same blue dot represents unread text and a security approval. **Why:** users habituate to noise and miss actual blockers. **Alternative:** one actionable attention count for approvals/questions/failures, separate unread completion marks, a running indicator and a quiet event log. Send notifications only when useful, normally when the app or relevant session is not foregrounded; group by project and expose preference controls. Never encode status by color alone. Use system notification authorization at a moment of demonstrated value.

### 10. Use destructive confirmations as a substitute for recovery

**Example:** a sheet asks “Are you sure?” for archiving a thread, while a one-click “Revert all” silently destroys unrelated manual edits. **Why:** routine confirmations train dismissal and can still fail to protect meaningful work. **Alternative:** archive locally and offer Undo; identify scope and consequences before genuinely destructive or externally visible actions. In review, distinguish agent-proposed, applied, staged, committed and user-edited changes. Never promise reversal unless actually available; preserve or explicitly resolve intervening edits. Apple's [Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo) describes reversible actions as a core interaction.

### 11. Flatten the agent's work into an opaque chat bubble

**Example:** “Done” is shown without changed files, worktree, tests, parent/child tasks, or PR; conversely a wall of raw JSON becomes the only way to understand it. **Why:** users cannot assess scope, navigate evidence, or tell which agent owns work. **Alternative:** structured, drillable artifacts linked to their originating session: changed files/hunks, command results, branch/worktree path, PR status, and child tasks. Show provenance and timestamps; don't infer that a passing command means the complete task is correct.

### 12. Confuse identity and scope across projects, windows and worktrees

**Example:** “Fix login” appears three times with no project or branch; a global keyboard command sends the composer to the wrong active session. **Why:** parallel tasks make unintended edits and misdirected prompts easy. **Alternative:** make project + session + execution location visible in the title/context header and any consequential confirmation; distinguish the repository's main checkout from a worktree; use last-active-window targeting and always expose the target before submission. Allow separate windows, tabs, and side-by-side review. A [Zed multi-window request](https://github.com/zed-industries/zed/issues/9662) illustrates why multi-monitor workflows matter, without establishing what Zed currently supports.

### 13. Lock the user out before explaining the value

**Example:** first launch immediately demands an API key, asks for notification and accessibility permissions, and leaves a blank screen if login fails. **Why:** the user cannot understand provider choices, data destinations, costs or what to do next. **Alternative:** let users inspect an illustrative, clearly labeled sample and add a project before connecting; offer provider login, API key or local model only when supported, explain what each needs and where data goes, link to provider-specific key management, and show validation/retry without erasing input. Ask for OS permissions in context. Zed's [Agent Panel](https://zed.dev/docs/ai/agent-panel) distinguishes first-party providers from external agents and offers a quick-start path.

## B. Ranked UX patterns to adopt

### 1. An attention inbox backed by a calm project/session sidebar

**Example:** Zed documents a threads sidebar grouped by project, recent-thread switcher, archive and cross-project history ([Agent Panel](https://zed.dev/docs/ai/agent-panel)). **BelloCode recommendation:** prioritize “Needs you” above projects, then pinned/recent project groups. Show per-row state with icon + text/accessible label: running, awaiting approval, awaiting answer, failed, completed unread, idle; show child count and elapsed age only when helpful. Sort attention by urgency then age, not by constantly reshuffling live activity. Clear unread only when the relevant completion is actually viewed; keep approval until resolved. Selecting a thread never silently clears a pending request. Provide a filter and “next needs attention” action. Test with 3 projects and 30 sessions, including several simultaneous blockers.

### 2. A persistent decision surface with auditable scope

**Example:** the [Zed pending-permissions proposal](https://github.com/zed-industries/zed/pull/50819) specifically moves requests above the composer to prevent them being lost. **Recommendation:** one pinned request stack per thread, plus global attention list. Expand to see the raw operation and surrounding transcript; choices say exactly what is authorized and for how long. Queue simultaneous requests separately. A user must be able to navigate away and return without losing or accidentally approving a request. The provider is authoritative: display unsupported controls as unavailable with explanation.

### 3. Queue, steer and stop as explicit modes

**Example:** Zed exposes queued messages with edit/remove, steer at a supported boundary, and immediate stop; its docs qualify external-agent support ([Agent Panel](https://zed.dev/docs/ai/agent-panel)). **Recommendation:** composer button and label change while running; queue is default, with a visible numbered queue and cancel/edit. “Steer” only when supported and clearly names the handoff boundary. Stop should acknowledge the request immediately, then show stopping/stopped or failure. Don't equate cancel requested with confirmed cancellation. Keep draft and queued items through navigation and reconnect where the provider permits; disclose otherwise.

### 4. Review changes in context, at the smallest meaningful scope

**Example:** Zed documents a changed-file summary and a review view with per-hunk or whole-set accept/reject ([Agent Panel: Reviewing Changes](https://zed.dev/docs/ai/agent-panel)). **Recommendation:** show baseline, project, branch, changed files and line counts; navigate files and hunks by keyboard; distinguish proposed from already-applied changes. Keep/reject must state actual effect, preserve unrelated edits, show conflicts and report partial failures. Provide “open file”, copy path and side-by-side/unified view. A [Zed issue](https://github.com/zed-industries/zed/issues/26560) asks to distinguish staged and unstaged changes: treat them as separate scopes, not interchangeable labels.

### 5. Fast keyboard navigation with a discoverable command surface

**Example:** Zed's documented thread switcher, palette and transcript navigation expose frequent actions without pointer travel ([Agent Panel](https://zed.dev/docs/ai/agent-panel)). **Recommendation:** make ⌘K a searchable command palette for actions, with labels, shortcuts and disabled reasons; a separate ⌘P searches projects/sessions/files with typed categories, recency and visible scope. Preserve focus on dismissal, accept arrow/Return/Escape, match synonyms, avoid a flickering reordered result list, and expose the same application actions through menu items. Do not offer a palette-only security or destructive action.

### 6. Progressive disclosure of agent activity

**Example:** Zed streams responses with tool indicators and provides separate detailed review ([Agent Panel](https://zed.dev/docs/ai/agent-panel)); the [long-card issue](https://github.com/zed-industries/zed/issues/64755) supplies a counterexample. **Recommendation:** keep assistant prose readable, summarize successful tool batches (“Read 4 files · 3 s”), and expand to exact inputs/results on demand. Pin active requests, failures and critical outcomes. Preserve chronological order and allow jumping between user prompts, tool failures and changed files. Display timestamps on demand; never conceal output required to make an approval decision.

### 7. Workspaces with explicit execution identity

**Example:** Zed documents choosing or creating an isolated worktree from the agent panel; Conductor describes isolated environments per agent and supports several underlying agents ([Zed](https://zed.dev/docs/ai/agent-panel), [Conductor](https://www.conductor.build/)). **Recommendation:** header: `Project / Session · branch · worktree/local/remote`; click through to path, base branch, changes, tests and PR. Show dirty/shared-worktree warnings before starting overlapping edits, not as permanent warning chrome. Show unavailable/unknown state explicitly. For a remote session, indicate the host and which machine owns files and commands.

### 8. Hierarchical delegation without losing the conversation

**Example:** Conductor's public product page illustrates starting another agent and surfacing a PR in the work stream ([Conductor](https://www.conductor.build/)). **Recommendation:** show child agents as a collapsible tree with parent, task, state and last meaningful update; provide a direct jump to child transcript and back. Aggregate “2 running · 1 needs you” at the parent without hiding which child is blocked. Label background commands separately from delegated agents; expose cancellation scope and whether the parent is waiting. Preserve each child's own context and artifacts.

### 9. Design for instant continuity, then honest progress

**Example:** Things exposes a quick-entry workflow and links to specific objects through its documented [URL scheme](https://culturedcode.com/things/support/articles/2803573/); Zed exposes rapid recent-thread switching ([Agent Panel](https://zed.dev/docs/ai/agent-panel)). These establish access paths, not a benchmark of their latency. **Recommendation:** local selection and focus feedback should target ≤100 ms; warm cached navigation ≤200 ms p95 on a representative supported Mac, with a clearly labeled stale state if revalidation is pending. Local reversible changes appear immediately; show pending and rollback on failure. For work exceeding ~1 s, describe activity; around 10 s provide elapsed time, meaningful progress if measurable, and cancel/background controls where supported. Don't fabricate a percentage. Default micro-transitions 120–200 ms ease-out, never gate input on them, and suppress nonessential motion under Reduce Motion. These durations are product hypotheses for user testing, not Apple-mandated numbers.

### 10. System-native windows, settings and integrations

**Example:** Things documents contextual Share → Copy Link and Settings-based control of its URL integration ([Things URL scheme](https://culturedcode.com/things/support/articles/2803573/)). **Recommendation:** support multiple resizable windows and native tabs where useful; restore workspace state; standard Settings under ⌘,; resizable/collapsible sidebar and inspector, toolbar customization when a real toolbar warrants it. Offer drag files into the composer, drag paths out where meaningful, contextual Share/Services for selected text or artifacts, Quick Look for compatible file attachments, and system search integration for opted-in, non-sensitive indexed metadata. A Dock menu may offer New Session and recent projects; a global hotkey should be optional, configurable, collision-aware and off by default. These integrations are contextual enhancements, not reasons to expose private source or conversation content by default.

### 11. Accessible, adaptable visual hierarchy

**Example:** Apple's [Accessibility HIG](https://developer.apple.com/design/human-interface-guidelines/accessibility) and [Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials) describe designing for system accessibility and appearance. **Recommendation:** use semantic text and controls, visible focus, named state, scalable user-configurable text (macOS does not have iOS Dynamic Type in precisely the same form), system appearance/accent, increased contrast, Reduce Transparency and Reduce Motion. Test light/dark and inactive windows. Respect localization expansion, pluralization, bidirectional text and keyboard layouts; separate localized prose from paths and code. Materials should establish hierarchy, not obscure diffs or transcript text. Apple's [Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) calls for considering system-provided controls and the separation of navigation/control layers from content; use current platform guidance conditionally by supported OS, and avoid applying glass to every content surface.

### 12. A setup flow that earns trust and gets to first useful work

**Example:** Zed's first-run guidance separates LLM providers from external agents and explains setup paths ([Agent Panel](https://zed.dev/docs/ai/agent-panel)). **Recommendation:** (1) choose/open a project or explore a labeled example; (2) choose a supported provider with sign-in/API key/local options and explicit billing/data destination; (3) validate non-destructively, show network/auth errors and allow retry/change; (4) start a session with suggested, editable prompts and clear permissions. Show connection state and a route to change or remove credentials in Settings. Never display secrets in logs, sample prompts or error messages. State which actions need a connected provider and which work offline. Empty search, no projects, no history, no changes, disconnected provider and no permission are different states with a useful next action.

## C. BelloCode UX principles: testable product targets

These are proposed acceptance targets, not claims about current implementation or universal research findings. Measure timings on a declared supported reference Mac, warm cache, with p95 over at least 30 interactions; record cold and degraded-network results separately.

1. **Acknowledge locally within 100 ms p95:** selection, button press, keystroke and stop-request feedback. Network completion is separately labeled.
2. **Navigate without a blank pane:** warm project/session switches show cached content within 200 ms p95; label stale content and show refresh failure without deleting it.
3. **Keep motion subordinate:** ordinary transitions target 120–200 ms and never block input; Reduce Motion removes nonessential movement.
4. **Make every blocker findable:** from any window, reach every pending approval/question in at most two actions, with project, thread and age visible; no color-only status.
5. **One authority per decision:** each approval identifies exact operation, execution location, scope and duration, and presents a safe denial path; no timed auto-approval.
6. **Keep user intent legible:** while running, show whether a message is queued, steered, delivered or failed; Stop, Steer and Queue have distinct labels and provider-capability constraints.
7. **Never steal the reader's place:** streaming follows only at the tail; reading, selecting text or scrolling upward keeps the viewport stable and exposes a new-output control.
8. **Make actions discoverable:** every application action has an appropriately placed menu item and keyboard access; frequently used actions also have documented shortcuts. Contextual actions may appear in contextual menus; text input and terminal keys retain their expected meaning.
9. **Restore working context:** relaunch restores eligible windows, selected sessions, panes, scroll anchors and unsent drafts; show uncertain reconnection status rather than inventing live state.
10. **Show consequence before execution:** show the correct repository, branch/worktree and actual operation for approvals, revert and externally visible actions; distinguish pending from confirmed success.
11. **Make reversible actions reversible:** archive, rename and local layout changes support undo; destructive or irreversible operations have specific, scoped confirmation and a recovery path where possible.
12. **Give every artifact provenance:** every diff, tool result, sub-agent and PR links to its originating project/session and shows state and scope; preserve user edits during review or explicitly report conflicts.
13. **Be usable without a pointer:** complete onboarding, project selection, send, approval, review, search and recovery using keyboard and VoiceOver; focus always remains visible and predictable.
14. **Minimize interruption:** background notifications are opt-in/configurable, grouped, actionable and relevant; do not notify for each token/tool call. A badge reflects a documented count, not activity volume.
15. **Design for real variation:** test long localized labels, 200% text scaling, light/dark, accent, increased contrast, Reduce Motion/Transparency, narrow windows and multiple displays; controls remain reachable without relying on hover.

## D. Proposed keyboard map

Shortcuts are proposals to validate against macOS, keyboard layouts and existing user bindings; native focused controls, especially the terminal and browser, take precedence. Show actual bindings in menus and allow reassignment of app-specific shortcuts. ⌘ means Command, ⌥ Option, ⇧ Shift, ⌃ Control.

| Action | Proposed shortcut | Scope / caveat |
|---|---|---|
| New session | ⌘N | Active project; open project chooser if none |
| New window | ⇧⌘N | Independent workspace window |
| Close tab/window | ⌘W / ⇧⌘W | Respect unsent draft and live-task semantics; never silently kill running work |
| Settings | ⌘, | Standard app menu |
| Quit / Hide | ⌘Q / ⌘H | Standard macOS behavior |
| Undo / Redo | ⌘Z / ⇧⌘Z | Focused editor first; app undo where appropriate |
| Find in session | ⌘F | Focused transcript; terminal/browser find handled locally |
| Search projects and sessions | ⇧⌘F | Explicit global scope, result type and snippet |
| Quick open | ⌘P | Projects, sessions and files, grouped and scoped |
| Command palette | ⌘K | App commands; don't intercept a focused terminal/browser |
| Toggle sidebar | ⌃⌘S | View menu; verify against system and user remaps |
| Toggle inspector/review | ⌥⌘I | View menu; distinguish from browser inspector |
| Toggle terminal | ⌃` | View menu; terminal gets keys after focus moves |
| Next / previous tab | ⇧⌘] / ⇧⌘[ | Standard-style tab navigation, user-remappable |
| Next needs attention | ⌥⌘A | Cycles across actionable blockers; not approve |
| Focus composer | ⌥⌘M | Never sends text |
| Send / newline | ⌘Return / Return | Proposed multiline-safe default; configurable; composition/IME must finish first |
| Stop current run | Escape, only when composer is focused and no popover/IME is active; also a menu command | First dismiss transient UI; explicit labeled stop control elsewhere. Never make Escape approve |
| Queue follow-up | ⌘Return while running | Default only when provider supports queue; visible confirmation and edit/remove |
| Steer | No default single-key shortcut | Explicit command/palette choice only where supported; show delivery semantics |
| Accept / reject a review hunk | No default single-key shortcut | Discoverable contextual actions; focus, exact scope and conflict state must be clear |
| Standard text editing, copy, paste, select all | macOS defaults | Preserve ⌥-word navigation, selection, IME, dictation and context menus |

The proposed send shortcut is a product decision, not a macOS standard. Resolve conflicts with web content, tmux, shell control sequences and user-assigned system shortcuts through focus-aware routing; never globally capture a key just because an app command exists. Offer a shortcut reference and localized key equivalents.

## E. Feature UX acceptance checklist

A reviewer can run this for any feature; mark N/A with a reason instead of silently skipping. Test with a mouse, keyboard and VoiceOver. Use a real project plus a disposable test repository for changes.

- [ ] **Purpose and context:** Is the action named in the user's language? Can the reviewer tell which project, session, host and worktree it affects before invoking it?
- [ ] **States:** Exercise first use, normal, empty, loading, stale/offline, partial result, failure, retry, cancel and success. Is each understandable and is there an appropriate next step? Are spinner and progress claims honest?
- [ ] **Speed and feedback:** Does selection/press respond within the stated 100 ms target and warm navigation within 200 ms p95? If not, is useful content retained and progress or delay communicated? Are animations interruptible and compatible with Reduce Motion?
- [ ] **Keyboard:** Complete the entire flow without a mouse. Check logical tab order, visible focus, arrow/Return/Escape behavior, menu discoverability, remapping and no interference with standard text editing, IME, terminal or browser keys.
- [ ] **Accessibility:** Verify VoiceOver labels, roles, values, announcement of meaningful changes and actionable errors; no token-by-token announcement flood. Check large text, contrast, light/dark, accent, Reduce Transparency and no color-only status.
- [ ] **Parallelism:** With multiple projects, windows and at least 30 sessions, can the reviewer find running, blocked, unread and failed work without opening each? Are labels stable and notifications restrained?
- [ ] **Approvals:** Create multiple concurrent requests. Is each visible until resolved, with exact operation, location, scope and expiry? Can the reviewer deny, navigate away and return? Is a broader grant explicit and supported? Does the displayed result match the provider's acknowledgement?
- [ ] **Streaming and control:** Scroll up and select/copy while output arrives. Does the viewport stay put? Try queue, edit, remove, steer and stop; are capability limits, delivery and cancellation state honest? Can a draft survive navigation?
- [ ] **Artifacts and safety:** Open a tool result, child agent, diff and PR from the relevant thread. Check provenance, baseline and staged/unstaged distinctions. Reject one hunk after a manual edit; ensure the UI preserves that edit or explicitly surfaces the conflict. Verify destructive actions have scoped confirmation and reversible actions have working undo.
- [ ] **Persistence:** Resize and rearrange panes, enter an unsent draft, switch threads, close/relaunch and reconnect. Is expected context restored, including scroll anchor where possible, with unknown live status labeled? Try a missing repository and failed provider login.
- [ ] **Windows and integrations:** Exercise two windows, tabs, narrow width and separate monitors; move focus between terminal, browser and composer. Test applicable drag/drop, Services/Share, Quick Look, Dock and notification behavior; ensure private content isn't unexpectedly exposed.
- [ ] **Onboarding/localization:** Start with no provider and no project; find a useful next step and recover from invalid/expired credentials without losing input or exposing secrets. Test long strings, plural counts, a different keyboard layout and bidirectional text alongside paths/code.
- [ ] **Evidence:** Record macOS version, reference machine, build, provider capabilities, timing sample and observed failures. Compare with the targets; do not pass solely because the happy path works.

## Evidence notes and further reading

- Apple's [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), [Menus](https://developer.apple.com/design/human-interface-guidelines/menus), [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Undo and redo](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo), and [Liquid Glass guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) are platform guidance, not evidence that a specific third-party product follows it.
- Nielsen's [response-time limits](https://www.nngroup.com/articles/response-times-3-important-limits/) proposes 0.1 s for perceived immediacy, 1 s for uninterrupted thought and 10 s for attention, with progress and interruption for long operations. The p95, animation, skeleton and stale-content policies above are BelloCode design targets inferred from that framework, not experimentally validated thresholds for this product.
- [Zed Agent Panel docs](https://zed.dev/docs/ai/agent-panel) describe capabilities and state provider-dependent limitations. The [buried permission PR](https://github.com/zed-industries/zed/pull/50819), [oversized-card report](https://github.com/zed-industries/zed/issues/64755), [staged/unstaged request](https://github.com/zed-industries/zed/issues/26560) and [secondary-window request](https://github.com/zed-industries/zed/issues/9662) are individual public observations or requests, not representative surveys and not necessarily descriptions of current releases.
- A [Codex user report](https://github.com/openai/codex/issues/11023) says they love the app while reporting a separate obstacle; another [Codex desktop issue](https://github.com/openai/codex/issues/23794) reports a missing context/token indicator. These are individual experiences, not independent usability studies. Make context usage visible when the provider supplies it, identify its scope and avoid invented precision.
- [Conductor's product site](https://www.conductor.build/) and [Things' integration documentation](https://culturedcode.com/things/support/articles/2803573/) are vendor descriptions, useful for concrete interaction examples but not independent evidence of quality. Public product examples here are not a comprehensive evaluation of Cursor, Claude desktop, T3 Code, OpenCode, Crystal, Superset, Raycast, Arc, Linear, Nova, Tower, Fork, Craft, Superhuman, Ghostty or Warp. No comparative user testing or systematic review of Mac app critiques was performed; broader product sentiment, the exact animation values, default keyboard map and prioritization require validation with BelloCode users.
