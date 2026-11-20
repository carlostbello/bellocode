import AgentUI
import AppKit
import BelloCore
import Engine

/// Action methods the window answers. Menu items and toolbar items use a nil target, so these travel the responder
/// chain (first responder → … → window → `MainWindowController`); text views see Edit commands first. The composer's
/// own actions (`sendPrompt:`, `queuePrompt:`, `steerPrompt:`, `stopAgent:`, `focusComposer:`) have the same names, so
/// a focused composer answers them itself and the window forwards them otherwise.
@MainActor
@objc protocol ShellActions {
    func newThread(_ sender: Any?)
    func addProject(_ sender: Any?)
    func renameThread(_ sender: Any?)
    func archiveThread(_ sender: Any?)
    func deleteThread(_ sender: Any?)
    func markUnread(_ sender: Any?)
    func togglePinProject(_ sender: Any?)
    func removeProject(_ sender: Any?)
    func revealInFinder(_ sender: Any?)
    func copyPath(_ sender: Any?)
    func nextNeedsAttention(_ sender: Any?)
    func focusComposer(_ sender: Any?)
    func focusNextRegion(_ sender: Any?)
    func focusPreviousRegion(_ sender: Any?)
    func toggleTerminal(_ sender: Any?)
    func sendPrompt(_ sender: Any?)
    func queuePrompt(_ sender: Any?)
    func steerPrompt(_ sender: Any?)
    func stopAgent(_ sender: Any?)
    func retryUnconfirmedSend(_ sender: Any?)
    func chooseModel(_ sender: Any?)
    func choosePermissionMode(_ sender: Any?)
    func togglePlanMode(_ sender: Any?)
    func allowRequestOnce(_ sender: Any?)
    func allowRequestAlways(_ sender: Any?)
    func denyRequest(_ sender: Any?)
    func submitRequestAnswer(_ sender: Any?)
    func showPreviousRequest(_ sender: Any?)
    func showNextRequest(_ sender: Any?)
    func newTerminal(_ sender: Any?)
    func closeTerminal(_ sender: Any?)
    func splitTerminal(_ sender: Any?)
    func selectNextTerminal(_ sender: Any?)
    func selectPreviousTerminal(_ sender: Any?)
    func clearTerminal(_ sender: Any?)
    func renameTerminal(_ sender: Any?)
    func restartTerminal(_ sender: Any?)
    func moveTerminal(_ sender: Any?)
    func sendTerminalSelectionToComposer(_ sender: Any?)
    // M2-D: sidebar organisation, palette, search, history and windows (docs/features/navigation.md).
    func togglePinThread(_ sender: Any?)
    func settleThread(_ sender: Any?)
    func snoozeLaterToday(_ sender: Any?)
    func snoozeTomorrow(_ sender: Any?)
    func snoozeNextWeek(_ sender: Any?)
    func snoozeUntil(_ sender: Any?)
    func wakeThread(_ sender: Any?)
    func toggleNeverAutoSettle(_ sender: Any?)
    func groupThreadsByProject(_ sender: Any?)
    func showThreadsByState(_ sender: Any?)
    func filterSidebar(_ sender: Any?)
    func moveProjectUp(_ sender: Any?)
    func moveProjectDown(_ sender: Any?)
    func showCommandPalette(_ sender: Any?)
    func showQuickOpen(_ sender: Any?)
    func showGlobalSearch(_ sender: Any?)
    func goBackInHistory(_ sender: Any?)
    func goForwardInHistory(_ sender: Any?)
    func reopenClosedThread(_ sender: Any?)
}

/// Every app command with its menu title and shortcut (docs/research/03-ux-patterns.md, section D), including the
/// composer's and AgentUI's. The menu, the context menus, validation and docs/features/shell.md all come from this one
/// table; `everyCommandHasAUniqueSelectorAndShortcut` checks it has no conflicts.
enum ShellCommand: String, CaseIterable, Sendable {
    case newThread, addProject
    case renameThread, archiveThread, deleteThread, markUnread
    case togglePinProject, removeProject, revealInFinder, copyPath
    case nextNeedsAttention, focusComposer, focusNextRegion, focusPreviousRegion, toggleTerminal
    case sendMessage, queueFollowUp, steerFollowUp, stopRun, retryUnconfirmed
    case chooseModel, permissionMode, togglePlan
    case allowOnce, allowAlways, denyRequest, submitAnswer, previousRequest, nextRequest
    case findInThread, findNext, findPrevious, useSelectionForFind
    case copyMessage, copyAsMarkdown, copyCode, jumpToLatest, previousTurn, nextTurn, lastFailure
    case showSettings, connectProvider, showWelcome
    case newTerminal, closeTerminal, splitTerminal, nextTerminal, previousTerminal, clearTerminal, renameTerminal
    case restartTerminal, moveTerminal, sendTerminalSelection
    // M2-D (docs/features/navigation.md).
    case togglePinThread, settleThread, snoozeLaterToday, snoozeTomorrow, snoozeNextWeek, snoozeUntil, wakeThread
    case toggleNeverAutoSettle, groupByProject, showThreadsByState, filterSidebar, moveProjectUp, moveProjectDown
    case commandPalette, quickOpen, globalSearch, goBack, goForward, reopenClosedThread, newWindow
    // M2-C: Changes tab, diff, git and worktrees (Content/ChangesSurface.swift, MainWindowController+Changes.swift).
    case showChanges, nextChange, previousChange, nextChangedFile, previousChangedFile, addReviewComment, openInEditor
    case revertHunk, revertFile, revertTurn, commitChanges, pushBranch, createMergeRequest
    case toggleDiffLayout, toggleDiffWhitespace, toggleDiffWrap, chooseWorkspace, chooseBranch, removeWorktree
    // M3-A: Agents panel (Content/AgentsSurface.swift, MainWindowController+Agents.swift).
    case showAgents, nextAgent, previousAgent, openAgent, followUpAgent, stopAgentTree, openParentThread
    // M3-B: orchestration extras (Content/MergeRequestSurface.swift; Settings ▸ Scheduled Tasks).
    case showMergeRequests, showScheduledTasks
    // M6-A: containerised execution (Settings ▸ Containers / Environment, docs/features/containers.md).
    case showContainers, showEnvironment, verifyIsolation
    // GitLab 2 (docs/features/gitlab.md, MainWindowController+GitLab.swift): inline review, issues, to-dos, and GitLab 1's
    // panel-only actions (babysit, jobs, approve, merge, unlink).
    case reviewMergeRequest, submitReview, discardReviewDrafts, closeReview, nextReviewThread, previousReviewThread
    case replyToReviewThread, toggleReviewThreadResolved, addReviewThreadToAgent
    case linkMergeRequest, refreshMergeRequests, toggleBabysit, showFailingJobLog, sendFailureToAgent, retryFailedJob, playManualJob
    case openMergeRequestInGitLab, unlinkMergeRequest, approveMergeRequest, mergeMergeRequest
    case showIssues, startThreadFromIssue, linkIssueToThread, showTodos, openTodo, markTodoDone
    /// Containers 3: Settings ▸ MCP Servers (docs/features/containers.md).
    case showMCPServers
    /// Settings ▸ Secrets (secret manager, docs/features/secrets.md).
    case showSecrets
    /// Settings ▸ Models: which model each task uses (docs/features/models.md).
    case showModelSettings
    /// Settings ▸ opencode, reload, and the command-line tool (docs/features/opencode-config.md).
    case showOpenCodeSettings, reloadOpenCode, installCommandLineTool, uninstallCommandLineTool
    // Containers 2: housekeeping (Settings ▸ Containers).
    case pruneContainerResources
    // Auto mode, risk notices and interrupts (docs/features/auto-mode.md, MainWindowController+Auto.swift).
    case modeAsk, modeAutoEdit, modeAuto, modeFullAccess, showAutoAudit, reviewRiskNotices, resumeInterrupted
    // Git parity (MainWindowController+Git.swift, docs/features/git-parity.md).
    case gitQuickAction, showGitActions, commitAndPush, pullBranch, pullRebase, fetchRemote, syncBranch, publishToGitLab
    case switchRemoteToHTTPS, abortGitOperation, restoreStashedChanges, cloneFromGitLab, newGitProject, moveToNewWorktree, editFromHere
    case toggleAutoPull, toggleCleanupOnSettle, toggleCleanupOnArchive

    @MainActor var selector: Selector {
        switch self {
        case .newThread: #selector(MainWindowController.newThread(_:))
        case .addProject: #selector(MainWindowController.addProject(_:))
        case .renameThread: #selector(MainWindowController.renameThread(_:))
        case .archiveThread: #selector(MainWindowController.archiveThread(_:))
        case .deleteThread: #selector(MainWindowController.deleteThread(_:))
        case .markUnread: #selector(MainWindowController.markUnread(_:))
        case .togglePinProject: #selector(MainWindowController.togglePinProject(_:))
        case .removeProject: #selector(MainWindowController.removeProject(_:))
        case .revealInFinder: #selector(MainWindowController.revealInFinder(_:))
        case .copyPath: #selector(MainWindowController.copyPath(_:))
        case .nextNeedsAttention: #selector(MainWindowController.nextNeedsAttention(_:))
        case .focusComposer: #selector(MainWindowController.focusComposer(_:))
        case .focusNextRegion: #selector(MainWindowController.focusNextRegion(_:))
        case .focusPreviousRegion: #selector(MainWindowController.focusPreviousRegion(_:))
        case .toggleTerminal: #selector(MainWindowController.toggleTerminal(_:))
        case .sendMessage: #selector(MainWindowController.sendPrompt(_:))
        case .queueFollowUp: #selector(MainWindowController.queuePrompt(_:))
        case .steerFollowUp: #selector(MainWindowController.steerPrompt(_:))
        case .stopRun: #selector(MainWindowController.stopAgent(_:))
        case .retryUnconfirmed: #selector(MainWindowController.retryUnconfirmedSend(_:))
        case .chooseModel: #selector(MainWindowController.chooseModel(_:))
        case .permissionMode: #selector(MainWindowController.choosePermissionMode(_:))
        case .togglePlan: #selector(MainWindowController.togglePlanMode(_:))
        case .allowOnce: #selector(MainWindowController.allowRequestOnce(_:))
        case .allowAlways: #selector(MainWindowController.allowRequestAlways(_:))
        case .denyRequest: #selector(MainWindowController.denyRequest(_:))
        case .submitAnswer: #selector(MainWindowController.submitRequestAnswer(_:))
        case .previousRequest: #selector(MainWindowController.showPreviousRequest(_:))
        case .nextRequest: #selector(MainWindowController.showNextRequest(_:))
        // The transcript's table answers these itself when focused; the window forwards them otherwise.
        case .findInThread: #selector(MainWindowController.findInTranscript(_:))
        case .findNext: #selector(MainWindowController.findNextInTranscript(_:))
        case .findPrevious: #selector(MainWindowController.findPreviousInTranscript(_:))
        case .useSelectionForFind: #selector(MainWindowController.useSelectionForTranscriptFind(_:))
        case .copyMessage: #selector(MainWindowController.copyTranscriptMessage(_:))
        case .copyAsMarkdown: #selector(MainWindowController.copyTranscriptMarkdown(_:))
        case .copyCode: #selector(MainWindowController.copyTranscriptCode(_:))
        case .jumpToLatest: #selector(MainWindowController.jumpToLatestOutput(_:))
        case .previousTurn: #selector(MainWindowController.showPreviousTurn(_:))
        case .nextTurn: #selector(MainWindowController.showNextTurn(_:))
        case .lastFailure: #selector(MainWindowController.showLastFailure(_:))
        case .showSettings: #selector(AppDelegate.showSettings(_:))
        case .connectProvider: #selector(AppDelegate.connectProvider(_:))
        case .showWelcome: #selector(AppDelegate.showWelcome(_:))
        case .newTerminal: #selector(MainWindowController.newTerminal(_:))
        case .closeTerminal: #selector(MainWindowController.closeTerminal(_:))
        case .splitTerminal: #selector(MainWindowController.splitTerminal(_:))
        case .nextTerminal: #selector(MainWindowController.selectNextTerminal(_:))
        case .previousTerminal: #selector(MainWindowController.selectPreviousTerminal(_:))
        // The focused terminal answers these two itself (same selectors on TerminalPaneView).
        case .clearTerminal: #selector(MainWindowController.clearTerminal(_:))
        case .renameTerminal: #selector(MainWindowController.renameTerminal(_:))
        case .restartTerminal: #selector(MainWindowController.restartTerminal(_:))
        case .moveTerminal: #selector(MainWindowController.moveTerminal(_:))
        case .sendTerminalSelection: #selector(MainWindowController.sendTerminalSelectionToComposer(_:))
        case .togglePinThread: #selector(MainWindowController.togglePinThread(_:))
        case .settleThread: #selector(MainWindowController.settleThread(_:))
        case .snoozeLaterToday: #selector(MainWindowController.snoozeLaterToday(_:))
        case .snoozeTomorrow: #selector(MainWindowController.snoozeTomorrow(_:))
        case .snoozeNextWeek: #selector(MainWindowController.snoozeNextWeek(_:))
        case .snoozeUntil: #selector(MainWindowController.snoozeUntil(_:))
        case .wakeThread: #selector(MainWindowController.wakeThread(_:))
        case .toggleNeverAutoSettle: #selector(MainWindowController.toggleNeverAutoSettle(_:))
        case .groupByProject: #selector(MainWindowController.groupThreadsByProject(_:))
        case .showThreadsByState: #selector(MainWindowController.showThreadsByState(_:))
        case .filterSidebar: #selector(MainWindowController.filterSidebar(_:))
        case .moveProjectUp: #selector(MainWindowController.moveProjectUp(_:))
        case .moveProjectDown: #selector(MainWindowController.moveProjectDown(_:))
        case .commandPalette: #selector(MainWindowController.showCommandPalette(_:))
        case .quickOpen: #selector(MainWindowController.showQuickOpen(_:))
        case .globalSearch: #selector(MainWindowController.showGlobalSearch(_:))
        case .goBack: #selector(MainWindowController.goBackInHistory(_:))
        case .goForward: #selector(MainWindowController.goForwardInHistory(_:))
        case .reopenClosedThread: #selector(MainWindowController.reopenClosedThread(_:))
        // Answered by the app delegate (works with no window open).
        case .newWindow: #selector(AppDelegate.newMainWindow(_:))
        // A focused diff answers the navigation and comment selectors itself (DiffKit's DiffContentView).
        case .showChanges: #selector(MainWindowController.showChanges(_:))
        case .showAgents: #selector(MainWindowController.showAgents(_:))
        case .nextAgent: #selector(MainWindowController.selectNextAgent(_:))
        case .previousAgent: #selector(MainWindowController.selectPreviousAgent(_:))
        case .openAgent: #selector(MainWindowController.openSelectedAgent(_:))
        case .followUpAgent: #selector(MainWindowController.followUpSelectedAgent(_:))
        case .stopAgentTree: #selector(MainWindowController.stopSelectedAgentTree(_:))
        case .openParentThread: #selector(MainWindowController.openParentThread(_:))
        case .showMergeRequests: #selector(MainWindowController.showMergeRequests(_:))
        case .reviewMergeRequest: #selector(MainWindowController.gitLabReviewMergeRequest(_:))
        case .submitReview: #selector(MainWindowController.gitLabSubmitReview(_:))
        case .discardReviewDrafts: #selector(MainWindowController.gitLabDiscardReviewDrafts(_:))
        case .closeReview: #selector(MainWindowController.gitLabCloseReview(_:))
        case .nextReviewThread: #selector(MainWindowController.gitLabNextReviewThread(_:))
        case .previousReviewThread: #selector(MainWindowController.gitLabPreviousReviewThread(_:))
        case .replyToReviewThread: #selector(MainWindowController.gitLabReplyToReviewThread(_:))
        case .toggleReviewThreadResolved: #selector(MainWindowController.gitLabToggleReviewThreadResolved(_:))
        case .addReviewThreadToAgent: #selector(MainWindowController.gitLabAddReviewThreadToAgent(_:))
        case .linkMergeRequest: #selector(MainWindowController.gitLabLinkMergeRequest(_:))
        case .refreshMergeRequests: #selector(MainWindowController.gitLabRefreshMergeRequests(_:))
        case .toggleBabysit: #selector(MainWindowController.gitLabToggleBabysit(_:))
        case .showFailingJobLog: #selector(MainWindowController.gitLabShowFailingJobLog(_:))
        case .sendFailureToAgent: #selector(MainWindowController.gitLabSendFailureToAgent(_:))
        case .retryFailedJob: #selector(MainWindowController.gitLabRetryFailedJob(_:))
        case .playManualJob: #selector(MainWindowController.gitLabPlayManualJob(_:))
        case .openMergeRequestInGitLab: #selector(MainWindowController.gitLabOpenMergeRequest(_:))
        case .unlinkMergeRequest: #selector(MainWindowController.gitLabUnlinkMergeRequest(_:))
        case .approveMergeRequest: #selector(MainWindowController.gitLabApproveMergeRequest(_:))
        case .mergeMergeRequest: #selector(MainWindowController.gitLabMergeMergeRequest(_:))
        case .showIssues: #selector(MainWindowController.gitLabShowIssues(_:))
        case .startThreadFromIssue: #selector(MainWindowController.gitLabStartThreadFromIssue(_:))
        case .linkIssueToThread: #selector(MainWindowController.gitLabLinkIssueToThread(_:))
        case .showTodos: #selector(MainWindowController.gitLabShowTodos(_:))
        case .openTodo: #selector(MainWindowController.gitLabOpenTodo(_:))
        case .markTodoDone: #selector(MainWindowController.gitLabMarkTodoDone(_:))
        // Answered by the app delegate (works with no window open).
        case .showScheduledTasks: #selector(AppDelegate.showScheduledTasks(_:))
        case .showContainers: #selector(AppDelegate.showContainers(_:))
        case .showEnvironment: #selector(AppDelegate.showEnvironment(_:))
        case .showMCPServers: #selector(AppDelegate.showMCPServers(_:))
        case .showOpenCodeSettings: #selector(AppDelegate.showOpenCodeSettings(_:))
        case .reloadOpenCode: #selector(AppDelegate.reloadOpenCode(_:))
        case .installCommandLineTool: #selector(AppDelegate.installCommandLineTool(_:))
        case .uninstallCommandLineTool: #selector(AppDelegate.uninstallCommandLineTool(_:))
        case .showSecrets: #selector(AppDelegate.showSecrets(_:))
        case .showModelSettings: #selector(AppDelegate.showModelSettings(_:))
        case .verifyIsolation: #selector(AppDelegate.verifyIsolation(_:))
        case .gitQuickAction: #selector(MainWindowController.gitQuickAction(_:))
        case .showGitActions: #selector(MainWindowController.showGitActions(_:))
        case .commitAndPush: #selector(MainWindowController.commitAndPush(_:))
        case .pullBranch: #selector(MainWindowController.pullBranch(_:))
        case .pullRebase: #selector(MainWindowController.pullRebase(_:))
        case .fetchRemote: #selector(MainWindowController.fetchRemote(_:))
        case .syncBranch: #selector(MainWindowController.syncBranch(_:))
        case .publishToGitLab: #selector(MainWindowController.publishToGitLab(_:))
        case .switchRemoteToHTTPS: #selector(MainWindowController.switchRemoteToHTTPS(_:))
        case .abortGitOperation: #selector(MainWindowController.abortGitOperation(_:))
        case .restoreStashedChanges: #selector(MainWindowController.restoreStashedChanges(_:))
        case .cloneFromGitLab: #selector(MainWindowController.cloneFromGitLab(_:))
        case .newGitProject: #selector(MainWindowController.newGitProject(_:))
        case .moveToNewWorktree: #selector(MainWindowController.moveToNewWorktree(_:))
        case .editFromHere: #selector(MainWindowController.editFromHere(_:))
        case .toggleAutoPull: #selector(MainWindowController.toggleAutoPull(_:))
        case .toggleCleanupOnSettle: #selector(MainWindowController.toggleCleanupOnSettle(_:))
        case .toggleCleanupOnArchive: #selector(MainWindowController.toggleCleanupOnArchive(_:))
        case .pruneContainerResources: #selector(AppDelegate.pruneContainerResources(_:))
        case .modeAsk: #selector(MainWindowController.setModeAsk(_:))
        case .modeAutoEdit: #selector(MainWindowController.setModeAutoEdit(_:))
        case .modeAuto: #selector(MainWindowController.setModeAuto(_:))
        case .modeFullAccess: #selector(MainWindowController.setModeFullAccess(_:))
        case .showAutoAudit: #selector(MainWindowController.showAutoAudit(_:))
        case .reviewRiskNotices: #selector(MainWindowController.reviewRiskNotices(_:))
        case .resumeInterrupted: #selector(MainWindowController.resumeInterruptedThread(_:))
        case .nextChange: #selector(MainWindowController.nextDiffHunk(_:))
        case .previousChange: #selector(MainWindowController.previousDiffHunk(_:))
        case .nextChangedFile: #selector(MainWindowController.nextDiffFile(_:))
        case .previousChangedFile: #selector(MainWindowController.previousDiffFile(_:))
        case .addReviewComment: #selector(MainWindowController.addDiffComment(_:))
        case .openInEditor: #selector(MainWindowController.openChangedFileInEditor(_:))
        case .revertHunk: #selector(MainWindowController.revertDiffHunk(_:))
        case .revertFile: #selector(MainWindowController.revertChangedFile(_:))
        case .revertTurn: #selector(MainWindowController.revertTurnChanges(_:))
        case .commitChanges: #selector(MainWindowController.commitChanges(_:))
        case .pushBranch: #selector(MainWindowController.pushBranch(_:))
        case .createMergeRequest: #selector(MainWindowController.createMergeRequest(_:))
        case .toggleDiffLayout: #selector(MainWindowController.toggleDiffLayout(_:))
        case .toggleDiffWhitespace: #selector(MainWindowController.toggleDiffWhitespace(_:))
        case .toggleDiffWrap: #selector(MainWindowController.toggleDiffWrap(_:))
        case .chooseWorkspace: #selector(MainWindowController.chooseWorkspace(_:))
        case .chooseBranch: #selector(MainWindowController.chooseBranch(_:))
        case .removeWorktree: #selector(MainWindowController.removeWorktree(_:))
        }
    }

    @MainActor static func command(for selector: Selector) -> ShellCommand? {
        allCases.first { $0.selector == selector }
    }

    var title: String {
        switch self {
        case .newThread: "New Thread"
        case .addProject: "Add Project…"
        case .renameThread: "Rename Thread"
        case .archiveThread: "Archive Thread"
        case .deleteThread: "Delete Thread"
        case .markUnread: "Mark as Unread"
        case .togglePinProject: "Pin Project"
        case .removeProject: "Archive Project"
        case .revealInFinder: "Reveal in Finder"
        case .copyPath: "Copy Path"
        case .nextNeedsAttention: "Next Needs Attention"
        case .focusComposer: "Focus Composer"
        case .focusNextRegion: "Move Focus to Next Region"
        case .focusPreviousRegion: "Move Focus to Previous Region"
        case .toggleTerminal: "Show Terminal"
        case .sendMessage: "Send"
        case .queueFollowUp: "Queue After This Turn"
        case .steerFollowUp: "Steer at Next Step"
        case .stopRun: "Stop Agent"
        case .retryUnconfirmed: "Retry Unconfirmed Message"
        case .chooseModel: "Choose Model…"
        case .permissionMode: "Permission Mode…"
        case .togglePlan: "Plan Mode"
        case .allowOnce: "Allow Once"
        case .allowAlways: "Always Allow"
        case .denyRequest: "Deny or Dismiss"
        case .submitAnswer: "Submit Answer"
        case .previousRequest: "Previous Request"
        case .nextRequest: "Next Request"
        case .findInThread: "Find in Thread…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .useSelectionForFind: "Use Selection for Find"
        case .copyMessage: "Copy Message"
        case .copyAsMarkdown: "Copy as Markdown"
        case .copyCode: "Copy Code"
        case .jumpToLatest: "Jump to Latest"
        case .previousTurn: "Previous Prompt"
        case .nextTurn: "Next Prompt"
        case .lastFailure: "Go to Last Failure"
        case .showSettings: "Settings…"
        case .connectProvider: "Connect Provider…"
        case .showWelcome: "Welcome to BelloCode…"
        case .newTerminal: "New Terminal"
        case .closeTerminal: "Close Terminal"
        case .splitTerminal: "Split Terminal"
        case .nextTerminal: "Next Terminal"
        case .previousTerminal: "Previous Terminal"
        case .clearTerminal: "Clear Terminal"
        case .renameTerminal: "Rename Terminal…"
        case .restartTerminal: "Restart Terminal"
        case .moveTerminal: "Move Terminal to Right Panel"
        case .sendTerminalSelection: "Send Selection to Composer"
        case .togglePinThread: "Pin Thread"
        case .settleThread: "Settle Thread"
        case .snoozeLaterToday: "Snooze Until Later Today"
        case .snoozeTomorrow: "Snooze Until Tomorrow"
        case .snoozeNextWeek: "Snooze Until Next Week"
        case .snoozeUntil: "Snooze Until…"
        case .wakeThread: "Wake Now"
        case .toggleNeverAutoSettle: "Never Auto-Settle"
        case .groupByProject: "Group Threads by Project"
        case .showThreadsByState: "Show All Threads by State"
        case .filterSidebar: "Filter Threads…"
        case .moveProjectUp: "Move Project Up"
        case .moveProjectDown: "Move Project Down"
        case .commandPalette: "Command Palette…"
        case .quickOpen: "Quick Open…"
        case .globalSearch: "Search Messages…"
        case .goBack: "Back"
        case .goForward: "Forward"
        case .reopenClosedThread: "Reopen Closed Thread"
        case .newWindow: "New Window"
        case .showChanges: "Show Changes"
        case .showAgents: "Show Agents"
        case .nextAgent: "Select Next Agent"
        case .previousAgent: "Select Previous Agent"
        case .openAgent: "Open Selected Agent"
        case .followUpAgent: "Follow Up Selected Agent…"
        case .stopAgentTree: "Stop Selected Agent and Its Tasks"
        case .openParentThread: "Go to Parent Thread"
        case .showMergeRequests: "Show Merge Requests"
        case .showScheduledTasks: "Scheduled Tasks…"
        case .showContainers: "Containers…"
        case .showEnvironment: "Project Environment…"
        case .showMCPServers: "MCP Servers…"
        case .showOpenCodeSettings: "opencode…"
        case .reloadOpenCode: "Reload opencode Configuration"
        case .installCommandLineTool: "Install Command Line Tool…"
        case .uninstallCommandLineTool: "Uninstall Command Line Tool…"
        case .showSecrets: "Secrets…"
        case .showModelSettings: "Models…"
        case .verifyIsolation: "Verify Container Isolation"
        case .pruneContainerResources: "Prune BelloCode Resources…"
        case .modeAsk: "Ask Every Time"
        case .modeAutoEdit: "Auto-Accept Edits"
        case .modeAuto: "Auto"
        case .modeFullAccess: "Full Access"
        case .showAutoAudit: "Show Auto Audit Log"
        case .reviewRiskNotices: "Mark Risk Notices Reviewed"
        case .resumeInterrupted: "Resume Interrupted Thread"
        case .gitQuickAction: "Run Suggested Git Action"
        case .showGitActions: "Git Actions…"
        case .commitAndPush: "Commit and Push…"
        case .pullBranch: "Pull"
        case .pullRebase: "Pull with Rebase"
        case .fetchRemote: "Fetch"
        case .syncBranch: "Sync"
        case .publishToGitLab: "Publish to GitLab…"
        case .switchRemoteToHTTPS: "Switch Remote to HTTPS"
        case .abortGitOperation: "Abort Merge or Rebase…"
        case .restoreStashedChanges: "Restore Stashed Changes"
        case .cloneFromGitLab: "Clone from GitLab…"
        case .newGitProject: "New Project…"
        case .moveToNewWorktree: "Move Changes to New Worktree…"
        case .editFromHere: "Edit Last Prompt from Here…"
        case .toggleAutoPull: "Automatically Pull Default Branch"
        case .toggleCleanupOnSettle: "Remove Clean Worktrees When Settled"
        case .toggleCleanupOnArchive: "Remove Clean Worktrees When Archived"
        case .nextChange: "Next Change"
        case .previousChange: "Previous Change"
        case .nextChangedFile: "Next Changed File"
        case .previousChangedFile: "Previous Changed File"
        case .addReviewComment: "Add Review Comment…"
        case .openInEditor: "Open in Editor"
        case .revertHunk: "Revert Hunk"
        case .revertFile: "Revert File…"
        case .revertTurn: "Revert Turn…"
        case .commitChanges: "Commit…"
        case .pushBranch: "Push"
        case .createMergeRequest: "Create Merge Request"
        case .toggleDiffLayout: "Side-by-Side Diff"
        case .toggleDiffWhitespace: "Ignore Whitespace"
        case .toggleDiffWrap: "Wrap Lines"
        case .chooseWorkspace: "Choose Workspace…"
        case .chooseBranch: "Choose Branch…"
        case .removeWorktree: "Remove Worktree…"
        case .reviewMergeRequest: "Review Merge Request Diff"
        case .submitReview: "Submit Review…"
        case .discardReviewDrafts: "Discard Review Drafts"
        case .closeReview: "Close Review"
        case .nextReviewThread: "Next Review Thread"
        case .previousReviewThread: "Previous Review Thread"
        case .replyToReviewThread: "Reply to Thread…"
        case .toggleReviewThreadResolved: "Resolve Thread"
        case .addReviewThreadToAgent: "Add Thread to Agent Context"
        case .linkMergeRequest: "Link Merge Request…"
        case .refreshMergeRequests: "Refresh Merge Requests"
        case .toggleBabysit: "Babysit Merge Request"
        case .showFailingJobLog: "Show Failing Job Log"
        case .sendFailureToAgent: "Send Failure to Agent"
        case .retryFailedJob: "Retry Failed Job"
        case .playManualJob: "Run Manual Job…"
        case .openMergeRequestInGitLab: "Open Merge Request in GitLab"
        case .unlinkMergeRequest: "Unlink Merge Request"
        case .approveMergeRequest: "Approve Merge Request"
        case .mergeMergeRequest: "Merge…"
        case .showIssues: "Show Issues"
        case .startThreadFromIssue: "Start Thread from Issue…"
        case .linkIssueToThread: "Link Issue to Thread"
        case .showTodos: "Show To-dos"
        case .openTodo: "Open To-do"
        case .markTodoDone: "Mark To-do Done"
        }
    }

    /// Key equivalent and modifiers. Empty key: no shortcut (still reachable from the menu, and by keyboard in the
    /// sidebar where noted in docs/features/shell.md). Request and picker shortcuts are AgentUI's (`AgentShortcut`).
    var shortcut: (key: String, modifiers: NSEvent.ModifierFlags) {
        let f6 = String(UnicodeScalar(UInt16(NSF6FunctionKey))!)
        let backspace = String(UnicodeScalar(UInt16(NSBackspaceCharacter))!)
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        func agent(_ shortcut: AgentShortcut) -> (String, NSEvent.ModifierFlags) {
            (shortcut.menuKeyEquivalent, shortcut.menuModifierMask)
        }
        return switch self {
        case .newThread: ("n", .command)
        case .addProject: ("o", [.command, .shift])
        case .renameThread: ("", [])
        case .archiveThread: (backspace, .command)
        case .deleteThread: (backspace, [.command, .option])
        case .markUnread: ("u", [.command, .shift])
        case .togglePinProject, .removeProject: ("", [])
        case .revealInFinder: ("r", [.command, .option])
        case .copyPath: ("c", [.command, .control, .shift])
        case .nextNeedsAttention: ("a", [.command, .option])
        case .focusComposer: ("m", [.command, .option])
        case .focusNextRegion: (f6, [])
        case .focusPreviousRegion: (f6, .shift)
        case .toggleTerminal: ("`", .control)
        // While the composer has focus it handles ⌘↩ itself (its send-key policy); this applies elsewhere.
        case .sendMessage: ("\r", .command)
        // No default shortcut (research 03, section D): Return/⌘↩ in the composer do the default follow-up.
        case .queueFollowUp, .steerFollowUp: ("", [])
        // Not Escape: Escape only dismisses transient UI.
        case .stopRun: (".", .command)
        case .chooseModel: agent(.modelPicker)
        case .permissionMode: agent(.permissionMode)
        case .togglePlan: agent(.togglePlan)
        case .allowOnce: agent(.allowOnce)
        case .allowAlways: agent(.allowAlways)
        case .denyRequest: agent(.deny)
        case .submitAnswer: agent(.submitAnswer)
        case .previousRequest: agent(.previousRequest)
        case .nextRequest: agent(.nextRequest)
        case .findInThread: ("f", .command)
        case .findNext: ("g", .command)
        case .findPrevious: ("g", [.command, .shift])
        case .useSelectionForFind: ("e", .command)
        case .copyMessage, .copyCode: ("", [])
        case .copyAsMarkdown: ("c", [.command, .option, .shift])
        case .jumpToLatest: ("j", [.command, .shift])
        case .previousTurn: (up, [.command, .option])
        case .nextTurn: (down, [.command, .option])
        case .lastFailure: ("l", [.command, .option])
        case .showSettings: (",", .command)
        case .connectProvider, .showWelcome, .retryUnconfirmed: ("", [])
        // Terminal.app's keys where they exist; all use ⌘ so a focused terminal keeps its control sequences.
        case .newTerminal: ("t", .command)
        case .closeTerminal: ("w", [.command, .shift])
        case .splitTerminal: ("d", .command)
        case .nextTerminal: ("}", .command)
        case .previousTerminal: ("{", .command)
        case .clearTerminal: ("k", .command)
        case .sendTerminalSelection: ("l", [.command, .shift])
        case .renameTerminal, .restartTerminal, .moveTerminal: ("", [])
        // T3 Code's keys where they do not collide (research 04, section 3).
        case .togglePinThread: ("p", [.command, .shift])
        case .settleThread: ("s", [.command, .shift])
        case .snoozeUntil: ("s", [.command, .option])
        case .snoozeLaterToday, .snoozeTomorrow, .snoozeNextWeek, .wakeThread, .toggleNeverAutoSettle: ("", [])
        case .groupByProject, .showThreadsByState, .moveProjectUp, .moveProjectDown: ("", [])
        case .filterSidebar: ("f", [.command, .option])
        // ⌘K is shared with Clear Terminal, focus-aware: exactly one of the two is enabled at a time (see
        // `CommandContext.isEnabled`); a focused terminal keeps ⌘K as in Terminal.app.
        case .commandPalette: ("k", .command)
        case .quickOpen: ("p", .command)
        case .globalSearch: ("f", [.command, .shift])
        case .goBack: ("[", .command)
        case .goForward: ("]", .command)
        case .reopenClosedThread: ("t", [.command, .shift])
        case .newWindow: ("n", [.command, .shift])
        // ⌃⌘ arrows: free in text views, terminals and the transcript (which uses ⌥⌘↑/↓).
        case .showChanges: ("d", [.command, .shift])
        case .showAgents: ("a", [.command, .control])
        case .nextAgent: (down, [.command, .control, .option])
        case .previousAgent: (up, [.command, .control, .option])
        case .openAgent: ("o", [.command, .control])
        case .followUpAgent: ("", [])
        case .stopAgentTree: (".", [.command, .control])
        case .openParentThread: ("u", [.command, .control])
        case .showMergeRequests: ("m", [.command, .control])
        case .showScheduledTasks: ("e", [.command, .control])
        case .showContainers, .showEnvironment, .verifyIsolation, .showMCPServers, .showSecrets: ("", [])
        case .showModelSettings: ("m", [.command, .control, .option])
        case .showOpenCodeSettings, .reloadOpenCode, .installCommandLineTool, .uninstallCommandLineTool: ("", [])
        case .pruneContainerResources: ("", [])
        case .modeAsk: ("1", [.command, .control, .option])
        case .modeAutoEdit: ("2", [.command, .control, .option])
        case .modeAuto: ("3", [.command, .control, .option])
        case .modeFullAccess: ("4", [.command, .control, .option])
        case .showAutoAudit: ("j", [.command, .control])
        case .reviewRiskNotices: ("", [])
        case .resumeInterrupted: ("p", [.command, .control, .option])
        // Git parity: ⌃⌘ letters free elsewhere (⌃⌘F full screen, ⌃⌘Q lock and ⌃⌘D look up are avoided).
        case .gitQuickAction: ("\r", [.command, .control])
        case .showGitActions: ("g", [.command, .control])
        case .pullBranch: ("l", [.command, .control])
        case .fetchRemote: ("r", [.command, .control])
        case .pushBranch: ("p", [.command, .control])
        case .commitAndPush, .pullRebase, .syncBranch, .publishToGitLab, .switchRemoteToHTTPS, .abortGitOperation, .restoreStashedChanges,
            .cloneFromGitLab, .newGitProject, .moveToNewWorktree, .editFromHere, .toggleAutoPull, .toggleCleanupOnSettle, .toggleCleanupOnArchive:
            ("", [])
        case .nextChange: (down, [.command, .control])
        case .previousChange: (up, [.command, .control])
        case .nextChangedFile: (String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!), [.command, .control])
        case .previousChangedFile: (String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!), [.command, .control])
        case .addReviewComment: ("k", [.command, .shift])
        case .openInEditor: ("o", .command)
        case .chooseWorkspace: ("e", [.command, .shift])
        case .chooseBranch: ("b", [.command, .shift])
        // GitLab 2: the review and the panel's sections; the rest are menu and palette actions.
        // ⌃⌘R and ⌃⌘↩ belong to git (Fetch, Suggested Git Action); the review uses ⌃⌥⌘.
        case .reviewMergeRequest: ("r", [.command, .control, .option])
        case .submitReview: ("\r", [.command, .control, .option])
        case .nextReviewThread: ("]", [.command, .control, .option])
        case .previousReviewThread: ("[", [.command, .control, .option])
        case .showIssues: ("i", [.command, .control])
        case .showTodos: ("y", [.command, .control])
        case .linkMergeRequest, .discardReviewDrafts, .closeReview, .replyToReviewThread, .toggleReviewThreadResolved, .addReviewThreadToAgent, .refreshMergeRequests,
            .toggleBabysit, .showFailingJobLog, .sendFailureToAgent, .retryFailedJob, .playManualJob, .openMergeRequestInGitLab, .unlinkMergeRequest,
            .approveMergeRequest, .mergeMergeRequest, .startThreadFromIssue, .linkIssueToThread, .openTodo, .markTodoDone:
            ("", [])
        // Reverting is never a single keystroke (research 03, section D); the rest are menu and panel actions.
        case .revertHunk, .revertFile, .revertTurn, .commitChanges, .createMergeRequest, .toggleDiffLayout,
            .toggleDiffWhitespace, .toggleDiffWrap, .removeWorktree:
            ("", [])
        }
    }

    /// Commands that act on several selected sidebar threads at once.
    var actsOnSelection: Bool {
        switch self {
        case .archiveThread, .deleteThread, .markUnread, .togglePinThread, .settleThread, .snoozeLaterToday, .snoozeTomorrow,
            .snoozeNextWeek, .snoozeUntil, .wakeThread, .toggleNeverAutoSettle:
            true
        default: false
        }
    }

    /// Shortcuts without ⌘ that still reach the app while a terminal has focus. Every other non-⌘ key (F6 for
    /// region cycling included) goes to the program in the terminal (AGENTS.md UX rule 2); leave a terminal with ⌃`
    /// or ⌥⌘M (Focus Composer).
    var isKeptWhileTerminalFocused: Bool { self == .toggleTerminal }

    /// Shortcuts that are also text-editing keys: disabled while a text view has focus so text keeps them
    /// (AGENTS.md UX rule 2). A disabled menu item does not consume its key equivalent.
    var conflictsWithTextEditing: Bool {
        switch self {
        case .archiveThread, .deleteThread: true
        default: false
        }
    }

    /// Checkmark state in menus (nil: no checkmark).
    func isChecked(in context: CommandContext) -> Bool? {
        switch self {
        case .toggleNeverAutoSettle: context.targetsNeverAutoSettle
        case .toggleAutoPull: context.git.autoPull
        case .toggleCleanupOnSettle: context.git.cleanupOnSettle
        case .toggleCleanupOnArchive: context.git.cleanupOnArchive
        case .groupByProject: context.grouping == .byProject
        case .showThreadsByState: context.grouping == .byState
        default: nil
        }
    }

    /// The AgentUI request action behind a request command.
    var requestCommand: RequestCommand? {
        switch self {
        case .allowOnce: .allowOnce
        case .allowAlways: .allowAlways
        case .denyRequest: .deny
        case .submitAnswer: .submitAnswer
        case .previousRequest: .previous
        case .nextRequest: .next
        default: nil
        }
    }
}

/// What a command would act on: the clicked row (context menu) or the selection.
enum CommandTarget: Equatable, Sendable {
    case thread(SessionID, directory: String, isRunning: Bool)
    case project(directory: String, isPinned: Bool)
    /// The new-thread draft of a project.
    case draft(directory: String, isPinned: Bool)

    var directory: String {
        switch self {
        case .thread(_, let directory, _), .project(let directory, _), .draft(let directory, _): directory
        }
    }

    var threadID: SessionID? {
        if case .thread(let id, _, _) = self { id } else { nil }
    }
}

/// Inputs to menu validation, gathered by the window from its current state. Pure, so validation is tested.
struct CommandContext: Equatable, Sendable {
    var hasProjects = false
    var target: CommandTarget?
    /// The project directory a thread target belongs to is pinned (for the Pin/Unpin title).
    var targetProjectPinned = false
    var textInputFocused = false
    var attentionCount = 0
    var composerVisible = false
    var composerHasText = false
    /// The displayed thread runs (the composer offers queue, steer and stop).
    var composerRunning = false
    var isTerminalVisible = false
    /// The displayed thread has a send whose delivery is unknown (Retry checks and resends under the same ID).
    var hasUnconfirmedSend = false
    /// Request commands the displayed thread's front request accepts now.
    var availableRequestCommands: Set<RequestCommand> = []
    /// A thread or draft is displayed and the terminals are bound (New Terminal can act).
    var terminalAvailable = false
    /// The terminal surface commands act on has a selected terminal.
    var terminalSelected = false
    var terminalHasSelectedText = false
    var terminalSplit = false
    /// The terminal commands act on is in the right panel.
    var terminalInPanel = false
    /// Transcript commands the displayed transcript can run now.
    var availableTranscriptCommands: Set<ShellCommand> = []
    /// Keyboard focus is inside a terminal (it keeps ⌘K for Clear).
    var terminalFocused = false
    /// Threads a selection command acts on (the sidebar's multi-selection, else the target).
    var selectedThreadCount = 0
    /// Organisation of the targeted threads: all pinned / settled / snoozed / never auto-settle.
    var targetsPinned = false
    var targetsSettled = false
    var targetsSnoozed = false
    var targetsNeverAutoSettle = false
    var grouping: SidebarGrouping = .byProject
    var canGoBack = false
    var canGoForward = false
    var canReopenClosedThread = false
    var projectCanMoveUp = false
    var projectCanMoveDown = false
    /// The Changes tab's state (M2-C).
    var changes = ChangesCommandState()
    /// The Agents panel's state (M3-A).
    var agents = AgentsCommandState()
    /// The Merge Requests tab's state (GitLab 2).
    var gitLab = GitLabCommandState()
    /// Auto mode, notices and interrupts for the shown thread.
    var auto = AutoCommandState()
    /// Git parity: the displayed checkout's git actions.
    var git = GitCommandState()

    func isEnabled(_ command: ShellCommand) -> Bool {
        if command.conflictsWithTextEditing, textInputFocused { return false }
        switch command {
        case .newThread: return hasProjects
        case .addProject, .focusNextRegion, .focusPreviousRegion, .toggleTerminal: return true
        case .renameThread, .archiveThread, .deleteThread, .markUnread: return target?.threadID != nil
        case .togglePinProject, .removeProject, .revealInFinder, .copyPath: return target != nil
        case .nextNeedsAttention: return attentionCount > 0
        case .focusComposer: return composerVisible
        case .sendMessage: return composerVisible && composerHasText
        case .queueFollowUp, .steerFollowUp: return composerVisible && composerHasText && composerRunning
        case .stopRun:
            if case .thread(_, _, true) = target { return true }
            return false
        case .retryUnconfirmed: return hasUnconfirmedSend
        case .chooseModel, .permissionMode, .togglePlan: return composerVisible
        case .allowOnce, .allowAlways, .denyRequest, .submitAnswer, .previousRequest, .nextRequest:
            return command.requestCommand.map(availableRequestCommands.contains) ?? false
        case .findInThread, .findNext, .findPrevious, .useSelectionForFind, .copyMessage, .copyAsMarkdown, .copyCode, .jumpToLatest,
            .previousTurn, .nextTurn, .lastFailure:
            return availableTranscriptCommands.contains(command)
        case .showSettings, .connectProvider, .showWelcome: return true
        case .newTerminal, .splitTerminal: return terminalAvailable
        // Clear Terminal owns ⌘K only while a terminal has focus (the palette has it elsewhere).
        case .clearTerminal: return terminalSelected && terminalFocused
        case .closeTerminal, .nextTerminal, .previousTerminal, .renameTerminal, .restartTerminal, .moveTerminal:
            return terminalSelected
        case .sendTerminalSelection: return terminalHasSelectedText && composerVisible
        case .togglePinThread, .settleThread, .snoozeLaterToday, .snoozeTomorrow, .snoozeNextWeek, .snoozeUntil,
            .toggleNeverAutoSettle:
            return target?.threadID != nil || selectedThreadCount > 0
        case .wakeThread: return targetsSnoozed
        case .groupByProject, .showThreadsByState: return true
        case .filterSidebar: return hasProjects
        case .moveProjectUp: return projectCanMoveUp
        case .moveProjectDown: return projectCanMoveDown
        // Focus-aware ⌘K: the palette steps aside while a terminal has focus.
        case .commandPalette: return !terminalFocused
        case .quickOpen, .globalSearch, .newWindow: return true
        case .goBack: return canGoBack
        case .goForward: return canGoForward
        case .reopenClosedThread: return canReopenClosedThread
        case .showChanges, .toggleDiffLayout, .toggleDiffWhitespace, .toggleDiffWrap: return changes.available
        case .showAgents: return agents.available
        case .nextAgent, .previousAgent: return agents.available
        case .openAgent: return agents.selectionIsOther
        case .followUpAgent: return agents.selectionIsChild
        case .stopAgentTree: return agents.canStopSelection
        case .openParentThread: return agents.hasParent
        case .showMergeRequests: return agents.available
        case .showScheduledTasks: return true
        case .showContainers, .showEnvironment, .verifyIsolation, .showMCPServers, .showSecrets, .showModelSettings: return true
        case .showOpenCodeSettings, .reloadOpenCode, .installCommandLineTool, .uninstallCommandLineTool: return true
        case .pruneContainerResources: return true
        case .modeAsk, .modeAutoEdit, .modeAuto, .modeFullAccess: return composerVisible
        case .showAutoAudit: return target?.threadID != nil
        case .reviewRiskNotices: return auto.noticesPending
        case .resumeInterrupted: return auto.canResume
        case .nextChange, .previousChange: return changes.hasHunks
        case .nextChangedFile, .previousChangedFile: return changes.fileCount > 1
        case .addReviewComment: return changes.hasSelection && composerVisible
        case .openInEditor: return changes.hasTargetFile
        case .revertHunk: return changes.canRevertHunk
        case .revertFile: return changes.revertFileTitle != nil
        case .revertTurn: return changes.canRevertTurn
        case .commitChanges: return changes.isRepository
        case .pushBranch, .createMergeRequest: return changes.hasBranch
        case .chooseWorkspace, .chooseBranch: return changes.isDraft && changes.isRepository
        case .removeWorktree: return changes.isWorktree && !changes.isDraft
        case .reviewMergeRequest, .openMergeRequestInGitLab, .unlinkMergeRequest, .refreshMergeRequests: return gitLab.hasMergeRequest
        case .submitReview: return gitLab.reviewOpen && gitLab.reviewSendable && gitLab.writes
        case .discardReviewDrafts: return gitLab.reviewOpen && gitLab.reviewHasDrafts
        case .closeReview: return gitLab.reviewOpen
        case .nextReviewThread, .previousReviewThread, .replyToReviewThread, .addReviewThreadToAgent: return gitLab.reviewOpen && gitLab.reviewHasThreads
        case .toggleReviewThreadResolved: return gitLab.reviewOpen && gitLab.currentThreadResolvable && gitLab.writes
        case .toggleBabysit: return gitLab.hasMergeRequest && gitLab.hasThread
        case .linkMergeRequest: return gitLab.configured && gitLab.hasThread
        case .showFailingJobLog, .sendFailureToAgent: return gitLab.hasFailedJob
        case .retryFailedJob: return gitLab.hasFailedJob && gitLab.writes
        case .playManualJob: return gitLab.hasManualJob && gitLab.writes
        case .approveMergeRequest, .mergeMergeRequest: return gitLab.hasMergeRequest && gitLab.approveAndMerge
        case .showIssues, .showTodos: return gitLab.configured && agents.available
        case .startThreadFromIssue: return gitLab.issueSelected
        case .linkIssueToThread: return gitLab.issueSelected && gitLab.hasThread
        case .openTodo: return gitLab.todoSelected
        case .markTodoDone: return gitLab.todoSelected && gitLab.todoWrites
        case .gitQuickAction: return git.quickAction != nil
        case .showGitActions: return git.isRepository
        case .commitAndPush: return git.enabled.contains(.commitAndPush)
        case .pullBranch: return git.enabled.contains(.pull)
        case .pullRebase: return git.enabled.contains(.pullRebase)
        case .fetchRemote: return git.enabled.contains(.fetch)
        case .syncBranch: return git.enabled.contains(.sync)
        case .publishToGitLab: return git.enabled.contains(.publish)
        case .switchRemoteToHTTPS: return git.enabled.contains(.switchRemoteToHTTPS)
        case .abortGitOperation: return git.enabled.contains(.abortOperation)
        case .restoreStashedChanges: return git.hasParkedStash
        case .cloneFromGitLab, .newGitProject: return true
        case .moveToNewWorktree: return git.canHandoff
        case .editFromHere: return git.canRewind
        case .toggleAutoPull: return true
        case .toggleCleanupOnSettle, .toggleCleanupOnArchive: return git.isRepository
        }
    }

    /// Why a command is disabled, for the palette (nil when enabled).
    func disabledReason(for command: ShellCommand) -> String? {
        guard !isEnabled(command) else { return nil }
        if command.conflictsWithTextEditing, textInputFocused { return "Text editing uses this key" }
        switch command {
        case .newThread, .filterSidebar: return "Add a project first"
        case .renameThread, .archiveThread, .deleteThread, .markUnread, .togglePinThread, .settleThread, .snoozeLaterToday,
            .snoozeTomorrow, .snoozeNextWeek, .snoozeUntil, .toggleNeverAutoSettle:
            return "Select a thread"
        case .wakeThread: return "The thread is not snoozed"
        case .togglePinProject, .removeProject, .revealInFinder, .copyPath: return "Select a project or thread"
        case .moveProjectUp, .moveProjectDown: return "Select a project that can move"
        case .nextNeedsAttention: return "Nothing needs you"
        case .focusComposer, .chooseModel, .permissionMode, .togglePlan: return "Open a thread"
        case .modeAsk, .modeAutoEdit, .modeAuto, .modeFullAccess: return "Open a thread"
        case .showAutoAudit: return "Select a thread"
        case .reviewRiskNotices: return "No risk notices to review in this thread"
        case .resumeInterrupted: return "This thread was not stopped by another agent"
        case .sendMessage: return composerVisible ? "The composer is empty" : "Open a thread"
        case .queueFollowUp, .steerFollowUp: return composerRunning ? "The composer is empty" : "The agent is not running"
        case .stopRun: return "The agent is not running"
        case .retryUnconfirmed: return "No message is waiting for confirmation"
        case .allowOnce, .allowAlways, .denyRequest, .submitAnswer, .previousRequest, .nextRequest:
            return "No approval or question is pending"
        case .findInThread, .findNext, .findPrevious, .useSelectionForFind, .copyMessage, .copyAsMarkdown, .copyCode,
            .jumpToLatest, .previousTurn, .nextTurn, .lastFailure:
            return "Open a thread with messages"
        case .newTerminal, .splitTerminal: return "Open a thread"
        case .clearTerminal: return terminalSelected ? "Click in the terminal first (⌘K clears it there)" : "No terminal is open"
        case .closeTerminal, .nextTerminal, .previousTerminal, .renameTerminal, .restartTerminal, .moveTerminal:
            return "No terminal is open"
        case .sendTerminalSelection: return "Select text in a terminal"
        case .commandPalette: return "A terminal has focus (⌘K clears it); use ⌘P and type >"
        case .goBack: return "No earlier thread"
        case .goForward: return "No later thread"
        case .reopenClosedThread: return "No thread was closed"
        case .reviewMergeRequest, .openMergeRequestInGitLab, .unlinkMergeRequest, .refreshMergeRequests, .toggleBabysit, .approveMergeRequest,
            .mergeMergeRequest:
            if command == .approveMergeRequest || command == .mergeMergeRequest, gitLab.hasMergeRequest { return "Approve and Merge are off (Settings ▸ GitLab)" }
            return "Open a thread with a linked merge request"
        case .submitReview, .discardReviewDrafts, .closeReview, .nextReviewThread, .previousReviewThread, .replyToReviewThread,
            .toggleReviewThreadResolved, .addReviewThreadToAgent:
            if !gitLab.reviewOpen { return "Open a review (Review Merge Request Diff)" }
            if command == .submitReview || command == .toggleReviewThreadResolved, !gitLab.writes { return "GitLab write actions are off (Settings ▸ GitLab)" }
            return command == .submitReview ? "No drafts to send" : "No review threads"
        case .showFailingJobLog, .sendFailureToAgent, .retryFailedJob: return gitLab.hasFailedJob ? "GitLab write actions are off (Settings ▸ GitLab)" : "No failed job"
        case .playManualJob: return gitLab.hasManualJob ? "GitLab write actions are off (Settings ▸ GitLab)" : "No manual job"
        case .showIssues, .showTodos: return "Connect GitLab in Settings ▸ GitLab"
        case .linkMergeRequest: return gitLab.configured ? "Open a thread" : "Connect GitLab in Settings ▸ GitLab"
        case .startThreadFromIssue, .linkIssueToThread: return "Select an issue in Issues"
        case .openTodo, .markTodoDone: return gitLab.todoSelected ? "GitLab write actions are off (Settings ▸ GitLab)" : "Select a to-do"
        case .gitQuickAction: return git.quickHint ?? "Nothing to do"
        case .commitAndPush, .pullBranch, .pullRebase, .fetchRemote, .syncBranch, .publishToGitLab, .switchRemoteToHTTPS, .abortGitOperation:
            return git.reasons[command.rawValue] ?? (git.isRepository ? "Not available now" : "Open a thread in a git repository")
        case .moveToNewWorktree: return "Open a thread in a local checkout with uncommitted changes"
        case .editFromHere: return "Open a thread with a sent prompt that is not running"
        default: return "Not available now"
        }
    }

    /// Titles that depend on state ("Unpin Project", "Hide Terminal").
    func title(for command: ShellCommand) -> String {
        switch command {
        case .togglePinProject: targetProjectPinned ? "Unpin Project" : "Pin Project"
        case .toggleTerminal: isTerminalVisible ? "Hide Terminal" : "Show Terminal"
        case .splitTerminal: terminalSplit ? "Unsplit Terminal" : "Split Terminal"
        case .moveTerminal: terminalInPanel ? "Move Terminal to Drawer" : "Move Terminal to Right Panel"
        case .togglePinThread:
            (targetsPinned ? "Unpin " : "Pin ") + (selectedThreadCount > 1 ? "\(selectedThreadCount) Threads" : "Thread")
        case .settleThread:
            (targetsSettled ? "Un-settle " : "Settle ") + (selectedThreadCount > 1 ? "\(selectedThreadCount) Threads" : "Thread")
        case .archiveThread: selectedThreadCount > 1 ? "Archive \(selectedThreadCount) Threads" : command.title
        case .deleteThread: selectedThreadCount > 1 ? "Delete \(selectedThreadCount) Threads" : command.title
        case .revertFile: changes.revertFileTitle.map { $0 + "…" } ?? command.title
        case .toggleDiffLayout: changes.isSplit ? "Unified Diff" : "Side-by-Side Diff"
        case .toggleDiffWhitespace: changes.ignoresWhitespace ? "Show Whitespace Changes" : "Ignore Whitespace"
        case .toggleDiffWrap: changes.wraps ? "Don’t Wrap Lines" : "Wrap Lines"
        case .toggleBabysit: gitLab.babysitting ? "Stop Babysitting" : command.title
        case .toggleReviewThreadResolved: gitLab.currentThreadResolved ? "Reopen Thread" : command.title
        case .gitQuickAction: git.quickTitle.map { "Git: \($0)" } ?? command.title
        default: command.title
        }
    }
}

/// "Next needs attention": the item after `current` in the attention list, wrapping; the first when `current` is not
/// in the list.
func nextAttention(after current: SessionID?, in items: [SessionID]) -> SessionID? {
    guard !items.isEmpty else { return nil }
    guard let current, let index = items.firstIndex(of: current) else { return items.first }
    return items[(index + 1) % items.count]
}

/// What the GitLab commands can act on now: the Merge Requests tab's expanded MR, its open review, the selected issue
/// and to-do (gathered by the window; pure, so validation is tested).
struct GitLabCommandState: Equatable, Sendable {
    /// At least one GitLab instance is configured.
    var configured = false
    var hasThread = false
    /// The tab's focused (expanded or only) linked MR.
    var hasMergeRequest = false
    var babysitting = false
    var hasFailedJob = false
    var hasManualJob = false
    /// Write actions are on for the MR's instance.
    var writes = false
    var approveAndMerge = false
    var reviewOpen = false
    var reviewHasDrafts = false
    var reviewSendable = false
    var reviewHasThreads = false
    var currentThreadResolvable = false
    var currentThreadResolved = false
    var issueSelected = false
    var todoSelected = false
    /// Write actions are on for the selected to-do's instance.
    var todoWrites = false
}

/// What the Changes commands can act on now (gathered by the window; pure, so validation is tested).
struct ChangesCommandState: Equatable, Sendable {
    /// A Changes model exists (a thread or draft is displayed).
    var available = false
    var isRepository = false
    var isDraft = false
    var isWorktree = false
    var hasBranch = false
    var hasHunks = false
    var fileCount = 0
    var hasSelection = false
    var hasTargetFile = false
    var canRevertHunk = false
    /// "Revert This Turn’s Changes to Login.swift"; nil when the scope cannot revert files.
    var revertFileTitle: String?
    var canRevertTurn = false
    var isSplit = false
    var ignoresWhitespace = false
    var wraps = false
}

/// What the Auto commands can act on in the shown thread (gathered by the window; pure, so validation is tested).
struct AutoCommandState: Equatable, Sendable {
    /// The thread has unreviewed Full-access risk notices.
    var noticesPending = false
    /// Another agent stopped the thread and its work is held.
    var canResume = false
}

/// Git parity: what the Git commands can act on now (from `GitActionPlanner` on the displayed checkout).
struct GitCommandState: Equatable, Sendable {
    var isRepository = false
    var quickAction: GitAction?
    var quickTitle: String?
    var quickHint: String?
    var enabled: Set<GitAction> = []
    /// Disabled reasons by ShellCommand raw value.
    var reasons: [String: String] = [:]
    var hasParkedStash = false
    var canHandoff = false
    var canRewind = false
    var autoPull = false
    var cleanupOnSettle = false
    var cleanupOnArchive = false
}
