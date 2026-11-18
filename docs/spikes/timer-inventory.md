# Timer inventory (uptime-clock fault, macOS 27)

On this Mac (macOS 27.0, Darwin 27) timers on the uptime clock do not fire while the process is otherwise idle:
`asyncAfter(deadline:)`, dispatch timer sources, `Timer`, `RunLoop.run(until:)`, `perform(_:afterDelay:)`,
`SuspendingClock`, `Task.sleep(nanoseconds:)`, SwiftUI periodic `TimelineView`, and (seen in `DSMenu`) an
`NSAnimationContext` completion. `Task.sleep` on `ContinuousClock`, `asyncAfter(wallDeadline:)` and `Thread.sleep` work.
Rule: AGENTS.md engineering rule 21. Helpers: `BelloCore/ContinuousTimers.swift` (`ContinuousDeadline`,
`ContinuousTicker`), `DesignSystem/RelativeTime.swift` (`ContinuousTimeline`). Guard: `Tests/BelloCoreTests/TimerGuardTests.swift`.

Classes: **(a)** correctness-critical (its failure hangs work, loses data or leaves a request unanswered);
**(b)** user-visible liveness; **(c)** screen-driven animation. Scope: production targets under `Sources/` and the
harness code tests depend on (MockOpenCode). Demo executables and `BelloCodeApp/Launch` snapshot drivers are listed
only where they used an uptime-clock timer. Line numbers are as of this note.

## Converted in this package

| Class | Where | Was | Now | Controls |
| --- | --- | --- | --- | --- |
| a | Engine/Git/GitRunner.swift:228 | `asyncAfter(deadline:)` | `ContinuousDeadline`, cancelled when the run returns | git / program timeout |
| a | Engine/Containers/FileEventBridge.swift:179 | `asyncAfter(deadline:)` | `ContinuousDeadline` → bridge queue | debounced flush of file events into the container |
| a | BelloCodeApp/Settings/BrowserSettings.swift:98 | `asyncAfter(deadline:)` | `ContinuousDeadline`, cancelled on exit | 15 s limit on the browse tool |
| a | bellocode-exec/main.swift:178 | `asyncAfter(deadline:)` | `asyncAfter(wallDeadline:)` (no BelloCore here) | forced exit 4 s after SIGTERM |
| a | DesignSystem/Controls/DSMenu.swift:471 | fade completion only | ContinuousClock fallback after the fade | menu orderOut and `onClose` |
| a | BrowserDemo/main.swift:90 (harness) | timer source `schedule(deadline:)` | `schedule(wallDeadline:)` | demo watchdog |
| b | BelloCodeApp/Sidebar/SidebarViewController.swift:224 | `Timer.scheduledTimer` 30 s | `ContinuousTicker` | sidebar relative times |
| b | TranscriptKit/.../TranscriptController+Selection.swift:205 | `Timer` 120 Hz | `ContinuousTicker` | selection drag autoscroll |
| b | DesignSystem/Controls/DSStatusGlyph.swift:22 | `Timer` (step clock) | `ContinuousTicker` | every spinner / running glyph |
| b | OrchestrationUI/AgentsPanelView.swift:290 | `TimelineView(.periodic)` 1 s | `ContinuousTimeline` | running task elapsed time |
| b | AgentUI/Accounts/ProviderConnectView.swift:443 | `TimelineView(.periodic)` 30 s | `ContinuousTimeline` | sign-in code expiry text |
| b | AgentUI/Support/Accessibility.swift:20 | `TimelineView(.periodic)` 30 s | `ContinuousTimeline` | `AgeText` |

Earlier package (merged as "HTML visual hang fix"): HTML visual deadlines, secret pipe pacing (`Thread.sleep`),
`MainRunLoop.run(for:)`.

## Already correct (ContinuousClock `Task.sleep(for:)`, `SystemTimeSource`, `SystemWallClock`)

**(a)**: OpenCodeKit — ServerSupervisor restart backoff (:201), readiness timeout (:298), exit timeout (`withTimeout`,
:337); EventHub reconnect backoff with jitter (:124); PTYSocket ping (:66); ClientMCPHost restart (:114);
BrowserAttachment attach wait, command deadline, state retry (:155, :272, :388); OrchestrationContract retry (:119);
OpenCodeClient.waitForInfo (:159). Engine — EngineCore stop retry (:250), waitForClient (:300), resync and gap retry
(:373, :416), stream coalescer 33 ms flush (:554), store write-behind (:574), resync retry (:812), prompt delivery
retry (:1596), mode-rule retry (:2047), organise timer for wake and settle rules (:2109); TerminalStream reconnect
backoff (:253, :294); TerminalService save (:438); BrowserBridgeService attach backoff, retry, pump, connection wait
(:354, :516, :530, :560); AuthService refresh poll and OAuth poll (:260, :510); CredentialImporter deadline (:313);
EnvironmentService runtime poll, pull poll, port-forward/container idle stop, reap, config write (:302, :503, :657,
:685, :965, :1006); IsolationCheck probes (:223–:350); GitService watcher start (:501); FileSystemWatcher debounce
(:74); ModelPreferences retry (:128); Engine.start retry (:256); SchedulerService and the GitLab poller
(MergeRequestService) via `SystemWallClock` (:111, :443); SecretService pipe tick (`Thread.sleep`, :341).
ContainerKit — EngineClient.withDeadline (:67), jsonLines poll (:197), output backpressure (:500), ExecSession exit poll
(:95), WorkspaceManager retry (:161), EventMonitor backoff (:63). BrowserKit — BrowserTab callJS poll, load and restore
waits, 60 s media-permission auto-deny (:471, :502–:526, :707); BrowserOperations.settle (:358); HTMLVisualSandbox
deadline (:159). bellocode-exec config retry (`usleep`, :64). MockOpenCode heartbeats and scripted delays.

**(b)**: Undo toast 5 s window (Support/Undo.swift:118); deferred thread deletions (PendingThreadDeletions.swift:81);
palette debounces (PaletteController.swift:321, :344); composer draft save (ComposerController.swift:112,
ThreadModel.swift:570); completion debounce (CompletionSession.swift:78); spell-check delay (ComposerViewController.swift:710);
transcript find debounce, find refresh, pill, anchor notification, measure delay, copied badge, settle
(TranscriptController+Find :77 :347, +Scrolling :130 :276, +Layout :456 :579, +Selection :417); terminal notice and
screen-scan throttle (TerminalPaneController.swift:343, :403); terminal resize debounce (TerminalStream.swift:217);
browser history save, tab-set change, highlight expiry, agent cursor hide (BrowserWorkspace :344 :380,
BrowserContentView :152 :164); sidebar scroll save (:1213); window state save (WorkspaceController.swift:398); reveal
(TranscriptSurface.swift:115); frecency save (Frecency.swift:137); AuthService invalidation debounce (:231);
Observing.waitUntil (:59).

## Left alone

- **(c)** Core Animation and `NSAnimationContext` effects with no dependent work: DSControl press, DSMenu pop-in,
  sidebar row insert/remove, browser click pulse, zero-duration `withoutAnimation` groups. Split-panel collapse
  animates only when `panelDuration > 0` (default 0, instant). No `CVDisplayLink` / `CADisplayLink` in `Sources/`.
- Allowlisted in the guard: `MainRunLoop.run(for:)` (`RunLoop.run(until:)` woken by a ContinuousClock task) and the
  TerminalDemo latency probe (measures dispatch-timer lateness while the main thread is busy; not run by tests).
- Clock reads (`CACurrentMediaTime`, `DispatchTime.now()` for measurement) are not timers and are unaffected.
- `Task.sleep(for:)` in `BelloCodeApp/Launch` snapshot drivers and demo targets: already ContinuousClock.
