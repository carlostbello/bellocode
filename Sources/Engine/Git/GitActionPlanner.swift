import Foundation

/// The git actions BelloCode offers (header button, Git menu, palette).
public enum GitAction: String, Sendable, Hashable, CaseIterable {
    case commit, commitAndPush, commitPushAndCreateMergeRequest
    case push, pushAndCreateMergeRequest, createMergeRequest, openMergeRequest
    case pull, pullRebase, fetch, sync
    case publish, switchRemoteToHTTPS, abortOperation

    public var title: String {
        switch self {
        case .commit: "Commit…"
        case .commitAndPush: "Commit and Push…"
        case .commitPushAndCreateMergeRequest: "Commit, Push and Create Merge Request…"
        case .push: "Push"
        case .pushAndCreateMergeRequest: "Push and Create Merge Request…"
        case .createMergeRequest: "Create Merge Request…"
        case .openMergeRequest: "Open Merge Request"
        case .pull: "Pull"
        case .pullRebase: "Pull with Rebase"
        case .fetch: "Fetch"
        case .sync: "Sync"
        case .publish: "Publish to GitLab…"
        case .switchRemoteToHTTPS: "Switch Remote to HTTPS"
        case .abortOperation: "Abort"
        }
    }

    /// The short label for the header's quick-action button.
    public var shortTitle: String {
        switch self {
        case .commit: "Commit"
        case .commitAndPush: "Commit & Push"
        case .commitPushAndCreateMergeRequest: "Commit, Push & MR"
        case .push: "Push"
        case .pushAndCreateMergeRequest: "Push & Create MR"
        case .createMergeRequest: "Create MR"
        case .openMergeRequest: "Open MR"
        case .pull: "Pull"
        case .pullRebase: "Pull (Rebase)"
        case .fetch: "Fetch"
        case .sync: "Sync"
        case .publish: "Publish"
        case .switchRemoteToHTTPS: "Use HTTPS"
        case .abortOperation: "Abort"
        }
    }

    public var symbolName: String {
        switch self {
        case .commit, .commitAndPush, .commitPushAndCreateMergeRequest: "checkmark.circle"
        case .push, .pushAndCreateMergeRequest: "arrow.up"
        case .createMergeRequest, .openMergeRequest: "arrow.triangle.pull"
        case .pull, .pullRebase: "arrow.down"
        case .fetch: "arrow.clockwise"
        case .sync: "arrow.up.arrow.down"
        case .publish: "icloud.and.arrow.up"
        case .switchRemoteToHTTPS: "lock"
        case .abortOperation: "xmark.octagon"
        }
    }

    /// Whether the action pushes (pushing to the default branch is confirmed first).
    public var pushes: Bool { [.commitAndPush, .commitPushAndCreateMergeRequest, .push, .pushAndCreateMergeRequest, .sync].contains(self) }
    public var commits: Bool { [.commit, .commitAndPush, .commitPushAndCreateMergeRequest].contains(self) }
}

/// Everything the planner needs, gathered from the repository model (pure, so every state is tested).
public struct GitActionInput: Sendable, Hashable {
    public var status: GitStatus?
    public var isBusy = false
    /// The branch is the repository's default branch (`main`).
    public var isDefaultBranch = false
    /// An `origin` remote exists.
    public var hasRemote = true
    /// `origin` is on a configured GitLab instance over HTTPS (MRs, publish, authentication).
    public var remoteOnGitLab = true
    /// `origin` uses SSH on a configured instance (the owner chose HTTPS: offer the switch).
    public var remoteIsSSHOnGitLab = false
    /// A GitLab instance is configured with a token (Publish needs one).
    public var canPublish = false
    public var hasOpenMergeRequest = false
    /// Commits on the branch not on the default branch (nil: unknown, use `ahead`).
    public var aheadOfDefault: Int?

    public init(status: GitStatus?) { self.status = status }
}

/// One menu row: the action, whether it can run now, and why not.
public struct GitActionItem: Sendable, Hashable, Identifiable {
    public var action: GitAction
    public var title: String
    public var isEnabled: Bool
    public var disabledReason: String?
    public var id: GitAction { action }
}

/// The header's primary button: the action T3 Code would suggest now, or a hint when nothing applies.
public struct GitQuickAction: Sendable, Hashable {
    public var action: GitAction?
    public var label: String
    public var hint: String?
    public var isEnabled: Bool { action != nil }
}

/// T3 Code's git-actions logic (`GitActionsControl.logic.ts`: `resolveQuickAction`, menu items and disabled reasons),
/// with merge requests on GitLab, Pull/Fetch/Sync always in the menu, honest conflict and detached-HEAD states, and the
/// HTTPS switch for SSH remotes.
public enum GitActionPlanner {
    public static func quickAction(_ input: GitActionInput) -> GitQuickAction {
        if input.isBusy { return GitQuickAction(action: nil, label: "Commit", hint: "A git action is running.") }
        guard let status = input.status else { return GitQuickAction(action: nil, label: "Commit", hint: "Git status is unavailable.") }
        if let operation = status.operation {
            return GitQuickAction(action: .abortOperation, label: "Abort \(operation.label)", hint: "\(operation.label) stopped with conflicts. Resolve them, or abort.")
        }
        if !status.conflictedFiles.isEmpty {
            return GitQuickAction(action: nil, label: "Commit", hint: "Resolve \(status.conflictedFiles.count) conflicted file\(status.conflictedFiles.count == 1 ? "" : "s") first.")
        }
        if input.remoteIsSSHOnGitLab { return GitQuickAction(action: .switchRemoteToHTTPS, label: GitAction.switchRemoteToHTTPS.shortTitle, hint: nil) }
        guard status.branch != nil else {
            return GitQuickAction(action: nil, label: "Commit", hint: "Detached HEAD: create or switch to a branch before committing or pushing.")
        }
        let hasChanges = status.isDirty
        let isAhead = status.ahead > 0
        let isBehind = status.behind > 0
        let hasUpstream = status.upstream != nil
        let canMR = input.remoteOnGitLab
        let defaultDelta = (input.aheadOfDefault ?? status.ahead) > 0
        if hasChanges {
            if isBehind || !input.hasRemote { return quick(.commit) }
            if input.hasOpenMergeRequest || input.isDefaultBranch || !canMR { return quick(.commitAndPush) }
            return quick(.commitPushAndCreateMergeRequest)
        }
        if !hasUpstream {
            if !input.hasRemote {
                return input.canPublish ? quick(.publish) : GitQuickAction(action: nil, label: "Push", hint: "Add a GitLab instance in Settings to publish this repository.")
            }
            if !isAhead && !defaultDelta { return GitQuickAction(action: nil, label: "Push", hint: "No local commits to push.") }
            if input.hasOpenMergeRequest || input.isDefaultBranch || !canMR { return quick(.push) }
            return quick(.pushAndCreateMergeRequest)
        }
        if isAhead && isBehind {
            return GitQuickAction(action: nil, label: "Sync", hint: "The branch has diverged from its upstream. Pull with Rebase from the menu, or merge.")
        }
        if isBehind { return quick(.pull) }
        if isAhead {
            if input.hasOpenMergeRequest || input.isDefaultBranch || !canMR { return quick(.push) }
            return quick(.pushAndCreateMergeRequest)
        }
        if input.hasOpenMergeRequest { return quick(.openMergeRequest) }
        if defaultDelta && !input.isDefaultBranch && canMR { return quick(.createMergeRequest) }
        return GitQuickAction(action: nil, label: "Commit", hint: "The branch is up to date. Nothing to do.")
    }

    static func quick(_ action: GitAction) -> GitQuickAction { GitQuickAction(action: action, label: action.shortTitle, hint: nil) }

    /// Every action, in menu order, with its state.
    public static func menu(_ input: GitActionInput) -> [GitActionItem] {
        GitAction.allCases.compactMap { action in
            let reason = disabledReason(action, input)
            if reason == hidden { return nil }
            return GitActionItem(action: action, title: action.title, isEnabled: reason == nil, disabledReason: reason)
        }
    }

    static let hidden = "\u{0}hidden"

    /// nil: enabled; `hidden`: not shown in this state.
    public static func disabledReason(_ action: GitAction, _ input: GitActionInput) -> String? {
        if input.isBusy { return "A git action is running." }
        guard let status = input.status else { return "Git status is unavailable." }
        let branch = status.branch
        let conflicted = !status.conflictedFiles.isEmpty || status.operation != nil
        switch action {
        case .abortOperation:
            return status.operation == nil ? hidden : nil
        case .switchRemoteToHTTPS:
            return input.remoteIsSSHOnGitLab ? nil : hidden
        case .publish:
            if input.hasRemote { return hidden }
            return input.canPublish ? nil : "Add a GitLab instance with a token in Settings ▸ GitLab."
        case .openMergeRequest:
            return input.hasOpenMergeRequest ? nil : hidden
        default:
            break
        }
        if conflicted { return status.operation.map { "\($0.label) in progress: resolve the conflicts or abort." } ?? "Resolve the conflicted files first." }
        if action.commits {
            if !status.isDirty { return "Nothing to commit: the working tree is clean." }
            if branch == nil && action != .commit { return "Detached HEAD: switch to a branch before pushing." }
            if action.pushes && !input.hasRemote { return "Add a remote (or publish) before pushing." }
            if action.pushes && status.behind > 0 { return "The branch is behind its upstream. Pull first." }
            if action == .commitPushAndCreateMergeRequest {
                if !input.remoteOnGitLab { return "The remote is not on a configured GitLab instance." }
                if input.hasOpenMergeRequest { return "This branch already has an open merge request." }
            }
            return nil
        }
        switch action {
        case .push, .pushAndCreateMergeRequest:
            guard branch != nil else { return "Detached HEAD: switch to a branch before pushing." }
            if !input.hasRemote { return "Add a remote (or publish) before pushing." }
            if status.behind > 0 { return "The branch is behind its upstream. Pull first." }
            if status.upstream != nil && status.ahead == 0 { return "No local commits to push." }
            if status.upstream == nil && status.ahead == 0 && (input.aheadOfDefault ?? 1) == 0 { return "No local commits to push." }
            if action == .pushAndCreateMergeRequest {
                if !input.remoteOnGitLab { return "The remote is not on a configured GitLab instance." }
                if input.hasOpenMergeRequest { return "This branch already has an open merge request." }
            }
            return nil
        case .createMergeRequest:
            guard branch != nil else { return "Detached HEAD: switch to a branch first." }
            if !input.remoteOnGitLab { return "The remote is not on a configured GitLab instance." }
            if input.hasOpenMergeRequest { return "This branch already has an open merge request." }
            if input.isDefaultBranch { return "You are on the default branch. Create a branch for the merge request." }
            if (input.aheadOfDefault ?? status.ahead) <= 0 { return "No commits to include in a merge request." }
            if status.behind > 0 { return "The branch is behind its upstream. Pull first." }
            return nil
        case .pull, .pullRebase:
            guard branch != nil else { return "Detached HEAD: switch to a branch before pulling." }
            if status.upstream == nil { return "The branch has no upstream to pull from." }
            if action == .pull && status.ahead > 0 && status.behind > 0 { return "The branch has diverged: use Pull with Rebase." }
            if status.behind == 0 { return "Already up to date with the last fetch. Fetch to check again." }
            return nil
        case .fetch:
            return input.hasRemote ? nil : "The repository has no remote."
        case .sync:
            guard branch != nil else { return "Detached HEAD: switch to a branch first." }
            if status.upstream == nil { return "The branch has no upstream yet: push it first." }
            if status.ahead > 0 && status.behind > 0 { return "The branch has diverged: use Pull with Rebase." }
            return nil
        default:
            return nil
        }
    }
}
