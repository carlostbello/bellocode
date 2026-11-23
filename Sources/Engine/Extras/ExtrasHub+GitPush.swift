import BelloCore
import Foundation
import OpenCodeKit

/// The agent's way to push (docs/features/git-parity.md row 28). The agent's shell runs in the container without
/// credentials, so `git push` there cannot reach GitLab; this tool runs the push on the Mac with the person's token
/// (through the app's credential helper) after an approval card that shows the remote, branch, the commits being sent
/// and whether it would force. Never force-pushes without a separate force-push card; warns before pushing to a branch
/// GitLab reports as protected; there is no "Always".
public enum GitPushTool {
    public static let push = "git_push"
    public static let all = [push]
    public static let definitions: [ClientMCPTool] = [
        ClientMCPTool(
            name: push,
            description:
                "Push this thread's current branch to origin (GitLab over HTTPS with the user's token; your shell has no git credentials). The user approves a card showing the remote, branch and commits unless policy allows it; you are woken with the result. force: replace the remote branch (a separate force-push card; uses --force-with-lease). End your turn after calling this.",
            inputSchema: ExtrasTools.object(["force": ExtrasTools.boolean("Overwrite the remote branch's history (default false).")])),
    ]
}

/// A push an agent asked for, waiting on its card (in memory; a relaunch makes it stale).
struct PendingGitPush: Sendable {
    var sessionID: SessionID
    var directory: String
    var plan: GitPushPlan
    var force: Bool
    var digest: String
}

extension ExtrasHub {
    static let maxPendingGitPushes = 8

    func handleGitPush(_ arguments: JSONValue, _ caller: ExtrasCaller) async throws -> ClientMCPResult {
        let force = arguments["force"]?.boolValue ?? false
        let runner = engine?.git.runner ?? GitRunner()
        let repository = GitRepository(directory: caller.directory, runner: runner)
        // Fetch first so the card shows what origin has now (a failure is not fatal: the plan says what is known).
        _ = try? await repository.fetch(remote: "origin")
        guard let plan = try await repository.pushPlan(remote: "origin") else {
            throw ExtrasError("Nothing to push: this thread's checkout has no branch (detached HEAD) or no origin remote.")
        }
        if plan.commits.isEmpty && plan.remoteBranchExists && !plan.needsForce { return ClientMCPResult(text: "Nothing to push: origin/\(plan.branch) already has every commit.") }
        if plan.needsForce && !force {
            throw ExtrasError("origin/\(plan.branch) has commits this branch does not (history was rewritten or someone else pushed). Pull and rebase, or ask for force: true (the user must confirm a force push separately).")
        }
        let instance = ForgeProject.resolve(remote: plan.remoteURL, instances: mergeRequests.instances)
        var warnings: [String] = []
        var isProtected = false
        if let instance {
            if let protection = try? await mergeRequests.provider.branchProtection(instance.instance, project: instance.projectPath, branch: plan.branch),
               protection.protected
            {
                isProtected = true
                warnings.append("⚠ \(plan.branch) is a protected branch on GitLab\(protection.canPush == false ? " and your account may not push to it" : "").")
            }
            if let scopes = engine?.git.tokenScopes(instance.instance.baseURL), let problem = GitTokenScopes.problem(.write, scopes: scopes) { throw ExtrasError(problem) }
        } else if !plan.remoteURL.lowercased().hasPrefix("https://") {
            warnings.append("The remote is not HTTPS on a configured GitLab instance: git uses your own credentials for it.")
        }
        let isDefault = (try? await repository.defaultRemoteBranch(remote: "origin")) == plan.branch
        if isDefault { warnings.append("⚠ \(plan.branch) is the repository's default branch.") }
        let localHead = plan.localHead
        let remoteHead = plan.remoteHead
        let commitLines = plan.commits.prefix(20).map { "  \($0.shortHash) \(String($0.subject.prefix(100)))" }.joined(separator: "\n")
        let more = plan.commits.count > 20 || plan.moreCommits > 0 ? "\n  … and \(plan.moreCommits + max(0, plan.commits.count - 20)) more" : ""
        let detail = """
            Remote: \(plan.remoteURL)
            Branch: \(plan.branch) → origin/\(plan.branch)\(plan.remoteBranchExists ? "" : " (new on the remote)")\(plan.setsUpstream ? ", sets upstream" : "")
            Commit: \(localHead)
            Force: \(force ? "YES: replaces origin/\(plan.branch) (\(remoteHead ?? "none")) with \(localHead.prefix(12)) (--force-with-lease)" : "no")
            Commits (\(plan.commits.count + plan.moreCommits)):
            \(commitLines.isEmpty ? "  (none)" : commitLines)\(more)
            \(warnings.joined(separator: "\n"))
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256Hex.of(detail)
        let pending = PendingGitPush(sessionID: caller.sessionID, directory: caller.directory, plan: plan, force: force, digest: digest)
        // Full access acts at once only for an ordinary push to a non-default, unprotected branch.
        if caller.permissionMode == .fullAccess, !force, !isProtected, !isDefault {
            return ClientMCPResult(text: try await executeGitPush(pending))
        }
        if pendingGitPushes.count >= Self.maxPendingGitPushes, let oldest = pendingGitPushes.keys.sorted().first { pendingGitPushes[oldest] = nil }
        let subject = AppRequest.makeID("gps")
        pendingGitPushes[subject] = pending
        let title = force ? "Force push \(plan.branch) (rewrites origin/\(plan.branch))" : "Push \(plan.branch) to origin"
        await core.putAppRequest(
            AppRequest(
                id: AppRequest.makeID("gps"), sessionID: caller.sessionID,
                kind: .approval(AppApproval(
                    action: force ? .gitForcePush : .gitPush, title: title, detail: detail, scope: plan.remoteURL, subjectID: subject, allowsAlways: false,
                    digest: digest)),
                received: .now))
        return ClientMCPResult(text: "Asked the user to approve this push (a card shows the remote, branch and commits). Nothing was pushed yet. You are woken with the result; end your turn now.")
    }

    /// Pushes once, exactly what the card showed (AF06): the card's commit to the card's resolved URL, after checking
    /// the branch, HEAD and the remote's push URL are unchanged (and, for a force push, with a lease on the remote head
    /// the card showed). A remote repointed meanwhile invalidates the card instead of receiving the push.
    func executeGitPush(_ pending: PendingGitPush) async throws -> String {
        let runner = engine?.git.runner ?? GitRunner()
        let repository = GitRepository(directory: pending.directory, runner: runner)
        do {
            try await repository.push(pending.plan, force: pending.force)
        } catch let changed as GitPushPlanError {
            throw ExtrasError(changed == .branchChanged ? "The branch changed since the card was shown. Nothing was pushed; ask again." : changed.userMessage)
        }
        engine?.git.refreshAll(under: pending.directory)
        return "Pushed \(pending.plan.branch) to origin (\(pending.plan.commits.count + pending.plan.moreCommits) commit\(pending.plan.commits.count + pending.plan.moreCommits == 1 ? "" : "s"))\(pending.force ? " with --force-with-lease" : "")."
    }

    func respondGitPush(_ approval: AppApproval, _ response: AppRequestResponse) async throws {
        guard let pending = pendingGitPushes.removeValue(forKey: approval.subjectID), pending.digest == approval.digest else {
            throw ExtrasError("This push is no longer pending (BelloCode was restarted, or it was answered). Nothing was pushed; the agent can ask again.")
        }
        let text: String
        if case .approve = response {
            do {
                text = "[BelloCode git] Approved by the user. " + (try await executeGitPush(pending))
            } catch {
                text = "[BelloCode git] Approved, but the push failed: \((error as? GitError)?.userMessage ?? ExtrasError.message(error))"
            }
        } else {
            text = "[BelloCode git] The user declined the push of \(pending.plan.branch). Nothing was pushed. Do not retry the same push; ask what they want instead."
        }
        try await core.postSynthetic(pending.sessionID, text: text, metadata: .object(["bellocode": .object(["wake": .string("git")])]))
    }
}
