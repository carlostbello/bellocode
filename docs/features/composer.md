# Composer (M1-C)

Status: done 2026-11-16. `ComposerKit` (AppKit, TextKit 2) plus the `ComposerDemo` harness. Since wired into the shell
(thread and new-thread draft composers, `Content/ComposerSurface.swift`); see "Drafts in the shell" below.

## Mounting (`import ComposerKit`)

- `ComposerViewController(style:configuration:)`, `@MainActor`. Add `view` with Auto Layout and pin only its width and
  bottom: it sets its own height (one line, up to `style.maximumHeightFraction` of the window, then scrolls).
  `onHeightChange` reports changes. Keep one per chat pane and set `host` when the selected thread changes.
- `style: ComposerStyle`: fonts, colours, metrics, placeholder; system-semantic defaults. Build it from DesignSystem
  tokens. `minimumLines = 3` gives the "hero" composer. `configuration: ComposerConfiguration`: `sendKey`
  (`.returnKey` / `.commandReturn`), `completionProviders`, `attachmentLimits`, `spellChecking`, debounces.
- Slots: `leadingControls` / `trailingControls` (`NSStackView`, model / agent / permission pickers), `contextLineView`
  (project · branch · worktree line under the card).
- Menu actions through the first responder: `sendPrompt:`, `queuePrompt:`, `steerPrompt:`, `stopAgent:` (wire Stop
  here, not to Escape), `focusComposer:`, `pasteInline:` (large paste stays in the text). Validated by the controller.
- Also: `focus()`, `insert(text:)`, `insert(token:)`, `add(attachments:)`, `removeAttachment(id:)`, `currentDraft()`.
- Completion: `FilePathCompletionProvider(root:)` (`@`, fuzzy, off-main, 50,000 files max, skips hidden, `.git`,
  `node_modules`, build folders), `StaticSlashCommandProvider` (`/` at prompt start). Add more through
  `CompletionProvider` (async, cancellable; the session debounces 40 ms and drops stale answers).

## Appearance (restyle 3, visual-language.md §6 "Composer")
The composer draws from DesignSystem whatever the host passes: `ComposerStyle.resolvedWithDesignTokens()` keeps the host's
behaviour fields (placeholder, minimum lines, height cap, completion size) and takes colours, fonts and metrics from the
tokens. Container: `DSGlassView(.composer)` (solid `raised` under Reduce Transparency and in snapshots), r16,
`composerOutline` + dark inner highlight, `shadow.composer`; focus strengthens the outline to `borderStrong` (accent,
2 pt, under Increase Contrast). Prompt `composer` 14/21 inset 12/14/4; controls bar 8 pt from the edges, 26 pt controls:
ghost paperclip (`attachFiles:`), the host's pickers, outline Stop with the red square, 30 pt accent Send (`disabledFill`
when empty), labelled accent Queue/Steer capsules while running. Chips: `fillHover` r8. Completion: popover glass, 28 pt
rows, neutral `highlight`. `ComposerContextStrip` is the 26 pt project / branch / worktree / send-key strip for
`contextLineView` (the shell still installs its own line).

## `ComposerHost`

`draftKey`, `loadDraft()`, `saveDraft(_:)` (debounced 150 ms while typing; immediate on send, switch, teardown),
`send(ComposerSubmission) async -> .accepted | .failed(message) | .unconfirmed(message)`, `stop()`, `runState` (idle / running / stopping),
`supportsSteer`, `supportsAttachments`, `defaultFollowUp` (queue), `errorMessage` / `clearError()`, `recentPrompts()`,
`observe(_:) -> ComposerObservation`. Return from `send` only after the server admitted the prompt: the composer clears
at once, shows "Sending…", and on failure puts text, tokens and attachments back (merged before anything typed since,
into the thread that sent it) with the error inline. `.unconfirmed` (every answer lost; the host keeps it under its
ID for an explicit retry) leaves the composer clear and shows the message: restoring it would invite a duplicate.
`isDraftLoaded` (default true), `draftLoadFailed` / `retryDraftLoad()` and `cachedDraft()`: a composer takes edits for
a host only after it has observed that host's loaded draft (`ComposerController.awaitingDraft` false). Until then the
view is read-only and says "Loading draft…", showing `cachedDraft()` (the newest rich copy in the draft cache, else
the archived record) if there is one, never a blank pane; typing, paste, drop, completion, `insert(text:)` /
`insert(token:)` (false) and `add(attachments:)` (`.draftLoading`) are refused, Send and history recall are
unavailable, and the controller saves, flushes, hands over or clears nothing for the thread. A switch-away flush
therefore saves only once the composer has observed the loaded draft, closing the window in which a model had
loaded but the composer's queued observation had not yet run (AV2-02). When the observation runs the loaded draft is
shown as is: nothing was edited, so there is nothing to join. If the host reports a failure, or the draft has not
loaded after `draftLoadTimeout` (5 s), the error line says it could not be loaded and offers Retry
(`retryDraftLoad()`, which `ThreadModel` answers by reading the thread again); still nothing is written.
`ThreadModelComposerHost.saveDraft` also refuses a write before the load. There is no pre-load hand-over or join any
more: R5's, which could lose a file chosen while loading when the stored text was identical (R5-02) or keep a pasted
image only in the released thread model (R5-01), is removed. Insertions from other panes report the refusal: review
comments, terminal output and picked elements show the attachment message, GitLab's composer target returns false
("…or was still loading its draft…"), and Edit in Composer on an unconfirmed send is offered only once the composer
takes it (if the composer changed before the text arrived, an alert shows the text with Copy Message). A failed send
whose thread is new and still loading its draft waits for that draft (up to 10 minutes) before putting the text back.
`ThreadModelComposerHost(threadModel)` adapts an Engine
`ThreadModel` (via `ComposerThreadSource`); tokens, attachments and selection live in a bounded in-memory
`ComposerDraftCache` and are used while the persisted text still matches (entries are scoped to the thread source
that stored them, so another engine's thread with the same session ID cannot replace them; a reopened model gets the
newest matching entry for its session). It now reports `supportsAttachments = true` and names its thread source as
`draftOwner` (the object that stores its draft; NF04).
`draftRevision` (default 0, for a host that is its draft's only writer): one revision per stored draft, shared by every
host of the same thread (one per window, plus Edit from Here's). `ThreadModelComposerHost` bumps it on every save
through any of them and when the thread's text changes some other way, and reports it through `observe`. A composer
saves only on top of the revision it last read (compare-and-swap): when the draft moved on, an unchanged composer
shows the newer draft, and an edited one is rebased onto it (the newer draft first, then its own edit after a blank
line, with "This draft also changed in another window. Both versions are kept." announced), so an idle second window
never writes its stale copy over a newer draft (R3-01).
A send's only clear is that compare-and-swap save of the empty composer on the revision it showed, made at Send.
Dispatch, after the attachments are prepared, clears nothing: `ThreadModelComposerHost` passes the submission's text to
the thread, and `ThreadModel.send(text)` with explicit text never clears or restores the draft (only `send()` of the
draft itself does). So a draft another window saved while the send was in flight stays, even with the same text and
different mentions; text equality is never taken as proof that a draft is the one sent (R4-01). A failed send is put
back by the composer itself, in front of the latest draft.

## What the prompt API needs for attachments (Contracts/opencode-2.3.0/openapi.json)

`POST /api/session/{id}/prompt` takes `text` plus `files: [PromptInput.FileAttachment]` (`uri` required; optional
`name`, `description`, `source` = `{type:"uri",uri}` or `{type:"inline"}`, `mention` = `{start,end,text}`),
`agents: [{name, mention?}]`, `skills: [{id, mention?}]`, `delivery`, `id`. There is no byte field on input (only the
server's `Prompt.FileAttachment` carries `data` + `mime`), so the host must turn every attachment into a URI:
`.file(url)` → `file://` URL; `.data` (pasted images) and `.text` (large pastes) → write to an app-owned temp file and
send its `file://` URL (or try a `data:` URI; unverified). File tokens become `files` entries with `mention` from
`PlacedToken` (UTF-16 offsets, as JavaScript counts). `OpenCodeKit.PromptRequest.FileAttachment` has since gained
`source` and `mention` (`OpenCodeKit/DTO/Prompt.swift`), and attachments ship.

## Verified by script (`swift run ComposerDemo`: 17 scenarios, 129 checks, all pass; `swift test`: 42 tests)

Japanese and Chinese composition via `setMarkedText` (Return, Up/Down and `@` inside marked text never send, recall or
complete; commit then Return sends); emoji and ZWJ deletion; Return / Shift / Option / Command-Return in both send-key
modes; optimistic clear, failure restore, merge with newer typing; queue / steer / Command flip / steer fallback / Stop /
Stopping; Escape never sends or stops; `@` and `/` completion with keyboard accept, no-match state, Escape dismissal;
token insert, undo/redo with stable token ID, caret snapping, whole-token delete, typing beside a token, plain-text copy; paste of image +
text, rich text (arrives plain), files, duplicates, large text → chip, undo/redo of chips; history with draft stash and
Undo; growth, cap, scroll-to-caret, shrink; per-thread drafts with selection, no undo across threads, failure routed to
its own thread; spell checking off for code; VoiceOver labels on text, chips, remove, send/queue/stop, menu.
Snapshots: `build/snapshots/composer-{empty,draft,unfocused,token,completion,attachments,error,running-queue,
running-steer,running-stop,capped,hero}-{light,dark}.png`.

## Drafts in the shell (v1.0.1 final-check fixes)

- **Rich drafts persist** in `ComposerDraftArchive` (one versioned JSON record per draft key under Application Support
  `BelloCode/drafts`; text stays in the thread's or project's stored draft). A commit is all or nothing: a draft whose
  attachment or record write fails keeps its previous record, stays pending and is written whole by the next save or
  flush. Quit asks "Some drafts could not be saved" (Try Again / Quit Anyway) while one is still pending (AF22).
- **Failed first send from a draft** (the send that creates the thread): the shell has already switched to the new
  thread, so the text, merged with anything typed since, goes back into every live composer with the same
  `draftOwner` (the new thread's) with the error there, not into a stored draft nobody re-reads (NF04). Each
  submission has an identity and is restored at most once per composer; only a draft that already holds the failed
  text in front, its tokens in place and every attachment counts as shown, so a newer edit that merely starts with
  the same words still gets the attachment and error back (AV12).
- **Edit from Here's rewound prompt** goes into its thread's latest draft as one write (R3-01, AV2-02).
  `ComposerController.placeRecovered` first has every live composer of the thread save its unsaved edit on top of the
  latest revision, then puts the prompt in front of the stored draft through one host (`ComposerDraft.merging`, so
  mentions and attachments stay), then has every composer show that revision. With the thread on screen, the visible
  composer places it (`placeRecovered` / `placeRecoveredIfLoaded` on its controller) with the same result: the other
  composers' edits are saved first, it catches up with the latest revision, and the prompt goes in front of that draft
  (`ComposerDraft.merging`) as one undoable edit named Edit from Here, saved at once; the caret goes to the end of the
  prompt. It is never inserted at the selection, so selected text is not replaced. The other composers follow.
  A stored draft that has not loaded is waited for, never written as plain text, and this includes a visible composer
  still awaiting its draft (the person came back to the thread during the rewind): nothing is inserted or saved
  until the draft loads (the composer is read-only meanwhile), the composer shows the loaded draft, and then the
  prompt goes in front
  (if the window shows another thread by then, the prompt goes into its own thread's draft through that thread's host).
  After 10 s a notice says the prompt will be added when it loads; after 10 minutes (or if the wait is cancelled)
  nothing is written and an alert shows the prompt with Copy Prompt.
- **Command-Return key equivalents:** the composer takes, before the menu, only the Return combinations that send
  (⌘↩; ⌥⌘↩ with the Command-Return send key). ⌃⌘↩ (Git ▸ Run Suggested Git Action) and ⌃⌥⌘↩ (GitLab ▸ Submit
  Review…) reach the menu; with no menu item to take them, they insert a newline as before (NV03).
- **Start Thread… from a GitLab issue** with the project's new-thread draft on screen inserts into that open composer
  (the draft wires `onInsertIntoComposer` as a thread does), so the text is no longer lost on the next keystroke (NF09).
- **Draft model hint** follows the catalog: "Free built-in models work without signing in…" only when every enabled
  model is free; otherwise, and before the catalog arrives, "Choose a model with ⇧⌘M." (NF24).

## Needs a human at the keyboard

Real input methods (candidate windows, Kotoeri live conversion), dictation, VoiceOver speech and announcement timing,
mouse on popover rows and chips, drag and drop of files, Quick Look on Space, Full Keyboard Access focus order,
increased contrast and Reduce Transparency rendering, the actual feel of undo grouping (the demo posts one event per
step because event-grouped undo does not close while a script runs).

## Measured (debug build, this Mac, `ComposerDemo latency growth`)

Keystroke (insert + height + layout + display): p50 0.30 ms, p95 0.35 ms, max 0.5 ms. With a 2,000-line (90 KB)
inline draft: p50 1.7 ms, p95 1.9 ms; inserting that draft and measuring its height once: 38 ms. Heights: one line
20 pt, two 36 pt, cap 192 pt in a 480 pt window. Height updates are coalesced to one per run-loop turn.

## docs/research/03 section E checklist

Purpose/context: pass (context-line slot; the shell supplies project, branch, worktree). States: empty, sending,
failure, retry, running, stopping, no-match covered; offline is the host's error text. Speed: pass (above).
Keyboard: pass by script; FKA order unverified. Accessibility: labels and announcements pass; VoiceOver speech
unverified; status never colour-only (labelled pills, icon + text errors). Parallelism, approvals, artifacts: N/A
(other packages). Streaming and control: queue / steer / stop labelled, delivery claimed only after the host answers;
the queued list is the timeline's job. Persistence: drafts with selection per thread pass; relaunch keeps text only
(rich state is in memory) at M1-C; tokens and attachments now persist in
`ComposerDraftArchive` (see below). Windows/integrations: Quick Look and drag and drop unverified. Localization: Japanese,
Chinese, emoji pass; RTL untested. Evidence: Darwin 27.0, Swift 6.4, Command Line Tools, debug build.
