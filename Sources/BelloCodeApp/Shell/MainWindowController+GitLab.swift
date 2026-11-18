import AppKit
import BelloCore
import Engine

// GitLab 2 (docs/features/gitlab.md): the GitLab menu's actions, forwarded to the window's Merge Requests tab
// (MergeRequestSurface.swift), and Start Thread from an issue (a draft in the project with the issue quoted; the
// person chooses branch and workspace in the draft's pickers; the issue is linked when the thread is created).

extension MainWindowController {
    var gitLabCommandState: GitLabCommandState { mergeRequests?.commandState ?? GitLabCommandState() }

    private func gitLab(_ command: ShellCommand) {
        guard commandContext().isEnabled(command) else { return NSSound.beep() }
        mergeRequests?.perform(command)
    }

    @objc func gitLabReviewMergeRequest(_ sender: Any?) { gitLab(.reviewMergeRequest) }
    @objc func gitLabSubmitReview(_ sender: Any?) { gitLab(.submitReview) }
    @objc func gitLabDiscardReviewDrafts(_ sender: Any?) { gitLab(.discardReviewDrafts) }
    @objc func gitLabCloseReview(_ sender: Any?) { gitLab(.closeReview) }
    @objc func gitLabNextReviewThread(_ sender: Any?) { gitLab(.nextReviewThread) }
    @objc func gitLabPreviousReviewThread(_ sender: Any?) { gitLab(.previousReviewThread) }
    @objc func gitLabReplyToReviewThread(_ sender: Any?) { gitLab(.replyToReviewThread) }
    @objc func gitLabToggleReviewThreadResolved(_ sender: Any?) { gitLab(.toggleReviewThreadResolved) }
    @objc func gitLabAddReviewThreadToAgent(_ sender: Any?) { gitLab(.addReviewThreadToAgent) }
    @objc func gitLabRefreshMergeRequests(_ sender: Any?) { gitLab(.refreshMergeRequests) }
    @objc func gitLabToggleBabysit(_ sender: Any?) { gitLab(.toggleBabysit) }
    @objc func gitLabShowFailingJobLog(_ sender: Any?) { gitLab(.showFailingJobLog) }
    @objc func gitLabSendFailureToAgent(_ sender: Any?) { gitLab(.sendFailureToAgent) }
    @objc func gitLabRetryFailedJob(_ sender: Any?) { gitLab(.retryFailedJob) }
    @objc func gitLabPlayManualJob(_ sender: Any?) { gitLab(.playManualJob) }
    @objc func gitLabOpenMergeRequest(_ sender: Any?) { gitLab(.openMergeRequestInGitLab) }
    @objc func gitLabUnlinkMergeRequest(_ sender: Any?) { gitLab(.unlinkMergeRequest) }
    @objc func gitLabApproveMergeRequest(_ sender: Any?) { gitLab(.approveMergeRequest) }
    @objc func gitLabMergeMergeRequest(_ sender: Any?) { gitLab(.mergeMergeRequest) }
    @objc func gitLabShowIssues(_ sender: Any?) { gitLab(.showIssues) }
    @objc func gitLabStartThreadFromIssue(_ sender: Any?) { gitLab(.startThreadFromIssue) }
    @objc func gitLabLinkIssueToThread(_ sender: Any?) { gitLab(.linkIssueToThread) }
    @objc func gitLabShowTodos(_ sender: Any?) { gitLab(.showTodos) }
    @objc func gitLabOpenTodo(_ sender: Any?) { gitLab(.openTodo) }
    @objc func gitLabMarkTodoDone(_ sender: Any?) { gitLab(.markTodoDone) }

    /// Wires Start Thread: the issue (link and selected or whole text, quoted as untrusted) goes into the project's
    /// new-thread draft, whose workspace and branch pickers decide where it runs; the issue is linked to the thread the
    /// first send creates.
    func wireStartThreadFromIssue() {
        mergeRequests?.startThreadFromIssue = { [weak self] issue, instance, selection in
            guard let self, let directory = self.mergeRequests?.context?.projectDirectory else { return }
            let known = self.workspace.engine.extras?.mergeRequests.knownSecrets(instance) ?? []
            let text = IssueThreadPrompt.make(issue, selection: selection, known: known)
            if case .draft(let shown) = self.workspace.selection, shown == directory, let insert = self.container.context?.onInsertIntoComposer {
                // The draft is on screen: its composer takes the text as one undoable edit.
                self.workspace.pendingIssueLinks[directory] = PendingIssueLink(issue: issue, instance: instance)
                insert(text)
            } else {
                self.workspace.startThread(from: issue, instance: instance, text: text, in: directory)
            }
            self.focusComposerSoon()
        }
    }
}

extension WorkspaceController {
    /// Links a pending issue to the thread its draft created (called from the draft context's creation hook).
    func linkPendingIssue(directory: String, to id: SessionID) {
        guard let pending = pendingIssueLinks.removeValue(forKey: directory), let work = engine.extras?.gitLabWork else { return }
        Task { try? await work.link(pending.issue, instance: pending.instance, to: id) }
    }
}

/// An issue waiting for its draft's thread to exist.
struct PendingIssueLink {
    var issue: GitLabIssue
    var instance: String
}
