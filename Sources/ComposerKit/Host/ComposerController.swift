import Foundation

/// The composer's behaviour without views: which host it edits, draft persistence, sending with optimistic clearing
/// and restore on failure, prompt history, and the button state. The view controller supplies the current draft and
/// applies drafts; everything here is testable with a fake host.
///
/// Threading: `@MainActor`. Send tasks finish even if the composer goes away, because a failed send must still put its
/// text back into its own thread's draft.
@MainActor
public final class ComposerController {
    /// What the primary button does now.
    public enum PrimaryAction: Hashable, Sendable {
        case send(ComposerDelivery)
        case stop
        /// Stop was requested; waiting for the server.
        case stopping
    }

    public private(set) var host: (any ComposerHost)?
    public private(set) var history = PromptHistory()
    /// Sends awaiting the server's answer.
    public private(set) var pendingSends = 0
    /// The last send failure for this host (cleared by the next successful send or dismissal).
    public private(set) var sendError: String?
    public var sendKey: SendKey = .returnKey
    public var draftSaveDelay: Duration = .milliseconds(150)
    /// How long a draft may take to load before the composer says it could not be loaded and offers Retry. Drafts are
    /// local, so loading normally takes milliseconds.
    public var draftLoadTimeout: Duration = .seconds(5)

    /// The view's current draft.
    public var currentDraft: () -> ComposerDraft = { .empty }
    /// Replace the view's whole state (text, tokens, attachments, selection) without an undo entry.
    public var applyDraft: (ComposerDraft) -> Void = { _ in }
    /// Replace only the text (and tokens) as one undoable edit; attachments stay.
    public var replaceTextUndoably: (ComposerDraft) -> Void = { _ in }
    /// Replace the text and tokens with a recovered prompt joined in front of them, as one undoable edit named "Edit
    /// from Here", with the caret at the draft's selection; attachments stay. Nil: `applyDraft` (no undo entry).
    public var applyRecoveredUndoably: ((ComposerDraft) -> Void)?
    /// Visible state changed (button, error, running).
    public var onStateChange: () -> Void = {}
    /// A VoiceOver announcement.
    public var announce: (String) -> Void = { _ in }

    private var observation: ComposerObservation?
    private var saveTask: Task<Void, Never>?
    private var historyStash: ComposerDraft?
    private var applyingHistory = false
    /// This composer has not yet observed its host's loaded draft. Meanwhile it takes no edit (the view is read-only,
    /// showing `ComposerHost.cachedDraft()` if any, with "Loading draft…") and saves, flushes, hands over or clears
    /// nothing for the thread; then it shows the loaded draft. It is set only when a host is attached, so a composer
    /// never edits on top of a placeholder (AV2-02, R5-01, R5-02).
    public private(set) var awaitingDraft = false
    /// The draft did not load (the host reported a failure, or `draftLoadTimeout` passed): shown with Retry. Still
    /// awaiting, so still nothing is written.
    public private(set) var draftLoadFailed = false
    private var loadWatch: Task<Void, Never>?
    /// Failed submissions this composer already took back (bounded; most recent last).
    private var restoredSubmissions: [Int] = []
    /// The stored draft's revision (`ComposerHost.draftRevision`) this composer's content is based on, and that
    /// content as shown then. A save is written only on top of this revision; otherwise the edit is rebased onto the
    /// newer stored draft first (R3-01).
    private var baseRevision = 0
    private var baseDraft = ComposerDraft.empty

    /// The live composers of a scope (weak), flushed together at quit (N16).
    @MainActor
    public final class Registry {
        public static let shared = Registry()
        private let live = NSHashTable<ComposerController>.weakObjects()
        private var nextSubmission = 0
        public init() {}
        func add(_ controller: ComposerController) { live.add(controller) }
        /// A fresh identity for one submission: a composer restores a given failed send at most once (AV12).
        func makeSubmissionID() -> Int {
            nextSubmission += 1
            return nextSubmission
        }
        /// Hands every registered composer's unsaved edit to its host now.
        public func flushAll() { for controller in live.allObjects { controller.flushDraft() } }

        /// A send for `key` failed after its composer stopped showing it (NF04: a new-thread draft's first send switched
        /// to the thread it created, whose composer mounted with an empty draft): every other live composer of that
        /// draft takes the text back, merged with what was typed there since.
        func restoreFailedSend(_ draft: ComposerDraft, submission: Int, owner: ObjectIdentifier?, message: String,
                               except sender: ComposerController?) {
            guard let owner else { return }
            for controller in live.allObjects where controller !== sender {
                controller.adoptFailedSend(draft, submission: submission, owner: owner, message: message)
            }
        }

        /// Every live composer of `owner`'s draft whose stored draft has loaded saves its unsaved edit now, on top of
        /// the latest revision (rebased when the draft moved on), so the stored draft holds everything typed anywhere.
        public func commitEdits(owner: ObjectIdentifier, except sender: ComposerController? = nil) {
            for controller in live.allObjects where controller !== sender {
                guard let host = controller.host, host.draftOwner == owner, !controller.awaitingDraft else { continue }
                controller.flushDraft()
            }
        }

        /// Every live composer of `owner`'s draft whose stored draft has loaded shows the latest revision now (keeping
        /// an unsaved edit of its own, rebased onto it), without waiting for its host observation. Returns how many
        /// composers show the draft.
        @discardableResult
        public func followStoredDraft(owner: ObjectIdentifier, except sender: ComposerController? = nil) -> Int {
            var showing = 0
            for controller in live.allObjects where controller !== sender {
                guard let host = controller.host, host.draftOwner == owner, !controller.awaitingDraft else { continue }
                controller.followStoredDraft()
                showing += 1
            }
            return showing
        }
    }

    /// How `placeRecovered` placed a prompt.
    public enum RecoveredPlacement: Equatable, Sendable {
        /// In front of the stored draft (its tokens and attachments kept); this many live composers show it.
        case placed(composers: Int)
        /// The stored draft never loaded (or the wait was cancelled): nothing was written, so the stored draft is
        /// intact. The caller shows the prompt to the person instead.
        case unloadedDraft
    }

    /// Puts a prompt recovered outside the composer (Edit from Here's rewind, NV09, AV2-02) into `host`'s draft
    /// without losing anything, as one authoritative write (R3-01): every live composer of the draft (any window)
    /// first saves its unsaved edit on top of the latest revision; the prompt then goes in front of the stored draft
    /// through `host` (`ComposerDraft.merging`, so the draft's tokens and attachments are kept); and every composer of
    /// the draft then shows that revision. No composer adds the prompt to its own (possibly stale) copy.
    ///
    /// A stored draft that has not loaded is waited for, never written over or replaced by a text-only merge: the
    /// prompt stays pending until it loads. After `noticeAfter` `onDelay` runs once (the caller says so visibly);
    /// after `giveUpAfter`, or when the waiting task is cancelled, nothing is written and `.unloadedDraft` returned.
    public static func placeRecovered(
        _ draft: ComposerDraft, into host: any ComposerHost, registry: Registry = .shared,
        noticeAfter: Duration = .seconds(10), giveUpAfter: Duration = .seconds(600),
        onDelay: @MainActor () -> Void = {}
    ) async -> RecoveredPlacement {
        // Writing to a draft that never loaded would replace (or, merged as text, strip) its rich record.
        guard await waitUntilLoaded(host, noticeAfter: noticeAfter, giveUpAfter: giveUpAfter, onDelay: onDelay) else {
            return .unloadedDraft
        }
        if let owner = host.draftOwner { registry.commitEdits(owner: owner) }
        host.saveDraft(ComposerDraft.merging(failed: draft, current: host.loadDraft().validated()))
        let showing = host.draftOwner.map { registry.followStoredDraft(owner: $0) } ?? 0
        return .placed(composers: showing)
    }

    /// Waits until `host`'s stored draft has been read. After `noticeAfter` `onDelay` runs once. False when it has not
    /// loaded by `giveUpAfter`, or when the waiting task is cancelled before it loads.
    static func waitUntilLoaded(
        _ host: any ComposerHost, noticeAfter: Duration, giveUpAfter: Duration, onDelay: @MainActor () -> Void
    ) async -> Bool {
        guard !host.isDraftLoaded else { return true }
        let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observation = host.observe { continuation.yield() }
        let start = ContinuousClock.now
        let noticeAt = start + noticeAfter
        let giveUpAt = start + giveUpAfter
        let timers = Task {
            try? await Task.sleep(until: noticeAt, clock: .continuous)
            continuation.yield()
            try? await Task.sleep(until: giveUpAt, clock: .continuous)
            continuation.yield()
        }
        var noticed = false
        for await _ in changes {
            if host.isDraftLoaded || Task.isCancelled { break }
            let now = ContinuousClock.now
            if !noticed, now >= noticeAt {
                noticed = true
                onDelay()
            }
            if now >= giveUpAt { break }
        }
        timers.cancel()
        observation.cancel()
        continuation.finish()
        return host.isDraftLoaded
    }

    /// Puts a recovered prompt (Edit from Here) into the draft this composer shows, as the static `placeRecovered`
    /// does for a thread with no composer on screen, and with the same result: the prompt goes in front of the latest
    /// stored draft (`ComposerDraft.merging`: its tokens and attachments kept, the caret at the end of the prompt),
    /// never at the selection and never replacing selected text. Here it is one undoable edit, saved at once on top of
    /// the latest revision; every other live composer of the thread then shows that revision.
    ///
    /// While this composer is still loading its stored draft, nothing is inserted or saved (AV2-02): the prompt waits
    /// for the load (`onDelay` after `noticeAfter`), the composer shows the loaded draft, and only then is the prompt
    /// placed in front of it. If the composer shows another thread by then, the prompt goes into the original
    /// thread's draft through its host. `.unloadedDraft` (nothing written) when the draft never loads or the wait is
    /// cancelled.
    public func placeRecovered(
        _ draft: ComposerDraft, noticeAfter: Duration = .seconds(10), giveUpAfter: Duration = .seconds(600),
        onDelay: @MainActor () -> Void = {}
    ) async -> RecoveredPlacement {
        guard let target = host else { return .unloadedDraft }
        if let placed = placeRecoveredIfLoaded(draft) { return placed }
        guard await Self.waitUntilLoaded(target, noticeAfter: noticeAfter, giveUpAfter: giveUpAfter, onDelay: onDelay) else {
            return .unloadedDraft
        }
        if host === target {
            // The host observation may not have run yet: show the loaded draft now.
            reconcileLoadedDraft()
            if let placed = placeRecoveredIfLoaded(draft) { return placed }
        }
        return await Self.placeRecovered(draft, into: target, registry: registry)
    }

    /// `placeRecovered` when this composer shows its stored draft already: placed now, synchronously. Nil (nothing
    /// done) while the stored draft is still loading or with no host.
    public func placeRecoveredIfLoaded(_ draft: ComposerDraft) -> RecoveredPlacement? {
        guard let host, !awaitingDraft, host.isDraftLoaded else { return nil }
        // Every other composer's unsaved edit goes into the stored draft first; then this one catches up with it.
        if let owner = host.draftOwner { registry.commitEdits(owner: owner, except: self) }
        followStoredDraft()
        var placed = ComposerDraft.merging(failed: draft, current: currentDraft())
        placed.selection = NSRange(location: (draft.text as NSString).length, length: 0)
        placed = placed.validated()
        if let applyRecoveredUndoably { applyRecoveredUndoably(placed) } else { applyDraft(placed) }
        commitShown()
        let others = host.draftOwner.map { registry.followStoredDraft(owner: $0, except: self) } ?? 0
        return .placed(composers: others + 1)
    }

    /// Whether two drafts hold the same text, tokens and attachments (the selection is not content).
    static func sameContent(_ a: ComposerDraft, _ b: ComposerDraft) -> Bool {
        a.text == b.text && a.tokens == b.tokens && a.attachments == b.attachments
    }

    /// A selection in `old` carried into `new`: a position in the unchanged start stays, one in the unchanged end moves
    /// by the change in length, and one inside the changed span goes to its end (UTF-16 offsets, as `NSRange`).
    static func mapSelection(_ selection: NSRange, from old: String, to new: String) -> NSRange {
        let old = old as NSString, new = new as NSString
        let shortest = min(old.length, new.length)
        var prefix = 0
        while prefix < shortest, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
        func map(_ position: Int) -> Int {
            if position <= prefix { return position }
            if position >= old.length - suffix { return position + new.length - old.length }
            return new.length - suffix
        }
        let start = map(selection.location)
        let end = map(selection.location + selection.length)
        return NSRange(location: start, length: max(0, end - start))
    }

    /// An edit made on top of `base`, moved onto `latest` (the stored draft another writer saved since): nothing is
    /// lost. Unchanged here: the latest draft. Unchanged there (or the same edit): this edit. Both changed: the latest
    /// draft first, then this edit after a blank line (`ComposerDraft.merging`), with the caret in this edit.
    static func rebase(_ local: ComposerDraft, base: ComposerDraft, onto latest: ComposerDraft) -> ComposerDraft {
        if sameContent(local, base) { return latest }
        if sameContent(latest, base) || sameContent(latest, local) { return local }
        // This edit already extends the latest draft (all of its text, tokens and attachments): nothing to add.
        if local.containsRestored(latest) { return local }
        return ComposerDraft.merging(failed: latest, current: local)
    }

    private let registry: Registry

    public init(registry: Registry = .shared) {
        self.registry = registry
        registry.add(self)
    }

    /// Hands every composer's unsaved edit to its host now (quit: a debounced save still waiting would be lost, N16).
    public static func flushAllDrafts() { Registry.shared.flushAll() }

    isolated deinit {
        saveTask?.cancel()
        loadWatch?.cancel()
        observation?.cancel()
    }

    // MARK: Host

    /// Shows `newHost`'s draft. The previous host's draft is saved first, so switching never loses or leaks text.
    public func attach(_ newHost: (any ComposerHost)?) {
        if let host, newHost === host { return }
        flushDraft()
        observation?.cancel()
        observation = nil
        historyStash = nil
        sendError = nil
        host = newHost
        history = PromptHistory(entries: newHost?.recentPrompts() ?? [])
        awaitingDraft = !(newHost?.isDraftLoaded ?? true)
        draftLoadFailed = false
        loadWatch?.cancel()
        loadWatch = nil
        if awaitingDraft {
            // Read-only until the stored draft loads: the newest known copy, so the composer is not blank (UX rule 1).
            applyDraft(newHost?.cachedDraft()?.validated() ?? .empty)
            watchLoad()
        } else {
            applyDraft(newHost?.loadDraft().validated() ?? .empty)
        }
        markBase()
        observation = newHost?.observe { [weak self] in self?.hostDidChange() }
        onStateChange()
    }

    private func hostDidChange() {
        reconcileLoadedDraft()
        if awaitingDraft, host?.draftLoadFailed == true { draftLoadFailed = true }
        followStoredDraft()
        onStateChange()
    }

    /// Whether the person can edit now: a host is shown and its loaded draft has been observed.
    public var acceptsEdits: Bool { host != nil && !awaitingDraft }

    /// The visible error while the draft cannot be loaded (with Retry). Nil otherwise.
    public var draftLoadError: String? {
        guard awaitingDraft, draftLoadFailed else { return nil }
        return "This thread's draft could not be loaded. Nothing will be saved until it loads."
    }

    /// Reads the stored draft again (Retry). Still nothing is written until it loads.
    public func retryDraftLoad() {
        guard awaitingDraft, let host else { return }
        draftLoadFailed = false
        host.retryDraftLoad()
        watchLoad()
        // A host that loads synchronously.
        hostDidChange()
    }

    /// After `draftLoadTimeout` still awaiting the same host: the load counts as failed (shown with Retry).
    private func watchLoad() {
        loadWatch?.cancel()
        let timeout = draftLoadTimeout
        let watched = host
        loadWatch = Task { [weak self, weak watched] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, let watched, self.host === watched, self.awaitingDraft else { return }
            self.loadWatch = nil
            // The load may have finished with its observation still queued.
            self.reconcileLoadedDraft()
            guard self.awaitingDraft else { return self.onStateChange() }
            self.draftLoadFailed = true
            self.onStateChange()
        }
    }

    /// What is shown now is based on the host's current revision.
    private func markBase() {
        baseRevision = host?.draftRevision ?? 0
        baseDraft = currentDraft()
    }

    /// The stored draft moved on (another window's composer saved, a send or restore changed it): show it. An unsaved
    /// edit of this composer is kept, rebased onto it and saved. Runs on every host change; call it directly before
    /// editing on behalf of the person (the observation hop may not have run yet).
    public func followStoredDraft() {
        guard let host, !awaitingDraft, host.isDraftLoaded, host.draftRevision != baseRevision else { return }
        let current = currentDraft()
        if saveTask != nil || !Self.sameContent(current, baseDraft) {
            commitShown()
            return
        }
        var latest = host.loadDraft().validated()
        if Self.sameContent(latest, current) {
            markBase()
            return
        }
        // Keep this view's caret on the same text (moved by what was added before it), not the other window's.
        if !current.text.isEmpty {
            latest.selection = Self.mapSelection(current.selection, from: current.text, to: latest.text)
        }
        applyDraft(latest.validated())
        markBase()
    }

    /// Saves what this composer shows through its host, on top of the latest revision: when the stored draft changed
    /// since this composer last read or saved it, the edit is rebased onto it first (and shown), so a stale copy never
    /// replaces a newer draft (R3-01).
    private func commitShown() {
        saveTask?.cancel()
        saveTask = nil
        // Nothing is written for a thread whose loaded draft this composer has not observed.
        guard let host, !awaitingDraft else { return }
        var draft = currentDraft()
        if host.draftRevision != baseRevision {
            let latest = host.loadDraft().validated()
            let rebased = Self.rebase(draft, base: baseDraft, onto: latest)
            let joined = !Self.sameContent(rebased, draft) && !Self.sameContent(rebased, latest)
            if rebased != draft {
                applyDraft(rebased)
                draft = currentDraft()
            }
            if Self.sameContent(draft, latest) {
                markBase()
                return
            }
            if joined { announce("This draft also changed in another window. Both versions are kept.") }
        }
        host.saveDraft(draft)
        markBase()
    }

    /// The host's stored draft arrived: show it (nothing was edited meanwhile, so there is nothing to join or save).
    private func reconcileLoadedDraft() {
        guard awaitingDraft, let host, host.isDraftLoaded else { return }
        awaitingDraft = false
        draftLoadFailed = false
        loadWatch?.cancel()
        loadWatch = nil
        saveTask?.cancel()
        saveTask = nil
        applyDraft(host.loadDraft().validated())
        markBase()
        onStateChange()
    }

    /// The text or attachments changed by the user.
    public func draftDidChange() {
        if !applyingHistory, history.isBrowsing {
            history.endBrowsing()
            historyStash = nil
        }
        // Not editable while awaiting: a change reported anyway (a stray programmatic edit) is not saved, and the
        // loaded draft replaces it.
        guard let host, !awaitingDraft else { return }
        let delay = draftSaveDelay
        saveTask?.cancel()
        saveTask = Task { [weak self, weak host] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let host, self.host === host else { return }
            self.saveTask = nil
            self.commitShown()
        }
    }

    /// Saves now (thread switch, window close, send). Only once this composer has observed its loaded draft: before
    /// that it shows a placeholder or a read-only copy and saves nothing (AV2-02: a switch after the model loaded but
    /// before this composer's observation ran). The save itself is a compare-and-swap on the shared revision.
    public func flushDraft() {
        guard !awaitingDraft, saveTask != nil else { return }
        commitShown()
    }

    // MARK: State

    public var runState: ComposerRunState { host?.runState ?? .idle }

    public var errorMessage: String? { sendError ?? host?.errorMessage }

    public func dismissError() {
        sendError = nil
        host?.clearError()
        onStateChange()
    }

    /// The delivery a send would use now.
    public func delivery(alternate: Bool) -> ComposerDelivery {
        SendKeyPolicy.delivery(
            alternate: alternate, isRunning: runState != .idle, defaultFollowUp: host?.defaultFollowUp ?? .queue,
            supportsSteer: host?.supportsSteer ?? false
        )
    }

    /// The primary button: Send when idle; while running, Stop with an empty draft, else the follow-up action.
    public func primaryAction(alternate: Bool, draftIsEmpty: Bool) -> PrimaryAction {
        switch runState {
        case .idle: return .send(.now)
        case .stopping: return draftIsEmpty ? .stopping : .send(delivery(alternate: alternate))
        case .running: return draftIsEmpty ? .stop : .send(delivery(alternate: alternate))
        }
    }

    // MARK: Commands

    /// Sends the current draft. Clears the composer at once; the server's answer decides whether it stays cleared.
    /// Returns false when there was nothing to send or it could not be sent.
    @discardableResult
    public func submit(alternate: Bool = false) -> Bool {
        // A read-only copy shown while the draft loads is not sendable.
        guard let host, !awaitingDraft else { return false }
        let draft = currentDraft()
        guard !draft.isEmpty else { return false }
        if !draft.attachments.isEmpty, !host.supportsAttachments {
            sendError = "This thread can't take attachments yet. Remove them to send the text."
            announce(sendError ?? "")
            onStateChange()
            return false
        }
        let delivery = delivery(alternate: alternate)
        let submission = ComposerSubmission(
            text: draft.text, tokens: draft.tokens, attachments: draft.attachments, delivery: delivery
        )
        saveTask?.cancel()
        saveTask = nil
        historyStash = nil
        history.record(draft.text)
        sendError = nil
        host.clearError()
        applyDraft(.empty)
        // The send's only clear: a compare-and-swap on the revision this composer showed. A newer draft saved by
        // another window meanwhile is kept, not cleared, and dispatch clears nothing later (R4-01).
        commitShown()
        pendingSends += 1
        onStateChange()
        let registry = self.registry
        let submissionID = registry.makeSubmissionID()
        Task { [weak self] in
            let outcome = await host.send(submission)
            if case .failed = outcome, !host.isDraftLoaded {
                // The draft's thread may be new and still reading its stored draft: the text goes back only on top of
                // what is stored, never over a placeholder.
                _ = await Self.waitUntilLoaded(host, noticeAfter: .seconds(600), giveUpAfter: .seconds(600), onDelay: {})
            }
            if case .failed(let message) = outcome {
                // Put the text back into its own thread, merged with anything typed since.
                if let self, self.host === host {
                    // Any newer stored draft first, so the text goes in front of the latest one.
                    self.followStoredDraft()
                    let merged = ComposerDraft.merging(failed: draft, current: self.currentDraft())
                    self.applyDraft(merged)
                    self.commitShown()
                    self.sendError = message
                } else {
                    host.saveDraft(ComposerDraft.merging(failed: draft, current: host.loadDraft()))
                }
                // The draft's owner may have changed with the send (a new thread was created): read it now.
                registry.restoreFailedSend(draft, submission: submissionID, owner: host.draftOwner, message: message,
                                           except: self?.host === host ? self : nil)
            }
            guard let self else { return }
            self.pendingSends -= 1
            switch outcome {
            case .accepted:
                self.announce(delivery.acknowledgement)
            case .failed(let message):
                self.announce("Not sent. \(message)")
            case .unconfirmed(let message):
                // Kept by the host for an explicit same-ID retry; the composer stays clear.
                if self.host === host { self.sendError = message }
                self.announce(message)
            }
            self.onStateChange()
        }
        return true
    }

    /// Another composer's send of this draft failed (see `Registry.restoreFailedSend`): show the text again, merged
    /// in front of the current edit, and save it through this composer's host.
    func adoptFailedSend(_ draft: ComposerDraft, submission: Int, owner: ObjectIdentifier, message: String) {
        guard let host, host.draftOwner == owner else { return }
        // Still loading: the stored draft (which the failed send restored) is what it will show.
        guard !awaitingDraft else { return }
        // Restored once per submission, by identity: matching text is never taken as proof (AV12).
        guard !restoredSubmissions.contains(submission) else { return }
        restoredSubmissions.append(submission)
        if restoredSubmissions.count > 32 { restoredSubmissions.removeFirst(restoredSubmissions.count - 32) }
        // The sender's restore may already be in the stored draft: catch up with it first (keeping an unsaved edit).
        followStoredDraft()
        let current = currentDraft()
        // Shown only when all of it is already there: its text in front, its tokens in place and its attachments.
        // Otherwise it is merged in front (a longer edit that merely starts with the same words gets it back too).
        if !current.containsRestored(draft) {
            applyDraft(ComposerDraft.merging(failed: draft, current: current))
        }
        commitShown()
        sendError = message
        announce("Not sent. \(message)")
        onStateChange()
    }

    /// Stops the running turn (wired by the host to a menu item and to the Stop button).
    public func stop() {
        guard let host, runState == .running else { return }
        announce("Stopping")
        Task { await host.stop() }
    }

    // MARK: History

    /// Recalls the previous prompt. Returns false when there is none (the key then does its normal thing).
    public func historyPrevious() -> Bool {
        guard !awaitingDraft else { return false }
        let wasBrowsing = history.isBrowsing
        guard case .entry(let text) = history.previous() else { return false }
        if !wasBrowsing { historyStash = currentDraft() }
        replaceHistoryText(ComposerDraft(text: text))
        return true
    }

    /// Recalls the next prompt, or restores the stashed draft past the newest. False when not browsing.
    public func historyNext() -> Bool {
        guard !awaitingDraft, let step = history.next() else { return false }
        switch step {
        case .entry(let text):
            replaceHistoryText(ComposerDraft(text: text))
        case .restoreDraft:
            replaceHistoryText(historyStash ?? .empty)
            historyStash = nil
        }
        return true
    }

    public var isBrowsingHistory: Bool { history.isBrowsing }

    private func replaceHistoryText(_ draft: ComposerDraft) {
        applyingHistory = true
        defer { applyingHistory = false }
        replaceTextUndoably(draft)
    }
}
