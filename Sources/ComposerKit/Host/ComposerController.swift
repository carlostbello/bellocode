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

    /// The view's current draft.
    public var currentDraft: () -> ComposerDraft = { .empty }
    /// Replace the view's whole state (text, tokens, attachments, selection) without an undo entry.
    public var applyDraft: (ComposerDraft) -> Void = { _ in }
    /// Replace only the text (and tokens) as one undoable edit; attachments stay.
    public var replaceTextUndoably: (ComposerDraft) -> Void = { _ in }
    /// Visible state changed (button, error, running).
    public var onStateChange: () -> Void = {}
    /// A VoiceOver announcement.
    public var announce: (String) -> Void = { _ in }

    private var observation: ComposerObservation?
    private var saveTask: Task<Void, Never>?
    private var historyStash: ComposerDraft?
    private var applyingHistory = false
    /// The host's stored draft has not been read yet; nothing is saved over it until it has.
    public private(set) var awaitingDraft = false
    /// The user edited while `awaitingDraft`; the stored draft is merged in front of the edit when it arrives.
    private var editedWhileAwaiting = false

    /// Every composer alive in the process, for `flushAllDrafts` (weak).
    private static let live = NSHashTable<ComposerController>.weakObjects()

    public init() { Self.live.add(self) }

    /// Hands every composer's unsaved edit to its host now (quit: a debounced save still waiting would be lost, N16).
    public static func flushAllDrafts() {
        for controller in live.allObjects { controller.flushDraft() }
    }

    isolated deinit {
        saveTask?.cancel()
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
        editedWhileAwaiting = false
        applyDraft(awaitingDraft ? .empty : newHost?.loadDraft().validated() ?? .empty)
        observation = newHost?.observe { [weak self] in self?.hostDidChange() }
        onStateChange()
    }

    private func hostDidChange() {
        reconcileLoadedDraft()
        onStateChange()
    }

    /// The host's stored draft arrived: show it, or put it in front of what was typed meanwhile and save the result.
    private func reconcileLoadedDraft() {
        guard awaitingDraft, let host, host.isDraftLoaded else { return }
        awaitingDraft = false
        let loaded = host.loadDraft().validated()
        guard editedWhileAwaiting else {
            applyDraft(loaded)
            return
        }
        editedWhileAwaiting = false
        saveTask?.cancel()
        saveTask = nil
        let current = currentDraft()
        let merged = current.text == loaded.text && current.attachments.isEmpty
            ? loaded : ComposerDraft.merging(failed: loaded, current: current)
        applyDraft(merged)
        host.saveDraft(merged)
    }

    /// The text or attachments changed by the user.
    public func draftDidChange() {
        if !applyingHistory, history.isBrowsing {
            history.endBrowsing()
            historyStash = nil
        }
        guard let host else { return }
        if awaitingDraft {
            editedWhileAwaiting = true
            return
        }
        let delay = draftSaveDelay
        saveTask?.cancel()
        saveTask = Task { [weak self, weak host] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, let host, self.host === host else { return }
            self.saveTask = nil
            host.saveDraft(self.currentDraft())
        }
    }

    /// Saves now (thread switch, window close, send).
    public func flushDraft() {
        if awaitingDraft {
            // Leaving before the stored draft arrived: hand over only real edits (the host merges them with the
            // stored draft); never the empty placeholder.
            if editedWhileAwaiting { host?.saveDraft(currentDraft()) }
            editedWhileAwaiting = false
            return
        }
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        host?.saveDraft(currentDraft())
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
        guard let host else { return false }
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
        host.saveDraft(.empty)
        pendingSends += 1
        onStateChange()
        Task { [weak self] in
            let outcome = await host.send(submission)
            if case .failed(let message) = outcome {
                // Put the text back into its own thread, merged with anything typed since.
                if let self, self.host === host {
                    let merged = ComposerDraft.merging(failed: draft, current: self.currentDraft())
                    self.applyDraft(merged)
                    host.saveDraft(merged)
                    self.sendError = message
                } else {
                    host.saveDraft(ComposerDraft.merging(failed: draft, current: host.loadDraft()))
                }
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

    /// Stops the running turn (wired by the host to a menu item and to the Stop button).
    public func stop() {
        guard let host, runState == .running else { return }
        announce("Stopping")
        Task { await host.stop() }
    }

    // MARK: History

    /// Recalls the previous prompt. Returns false when there is none (the key then does its normal thing).
    public func historyPrevious() -> Bool {
        let wasBrowsing = history.isBrowsing
        guard case .entry(let text) = history.previous() else { return false }
        if !wasBrowsing { historyStash = currentDraft() }
        replaceHistoryText(ComposerDraft(text: text))
        return true
    }

    /// Recalls the next prompt, or restores the stashed draft past the newest. False when not browsing.
    public func historyNext() -> Bool {
        guard let step = history.next() else { return false }
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
