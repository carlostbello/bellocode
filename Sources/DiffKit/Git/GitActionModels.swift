import BelloCore
import DesignSystem
import Engine
import Foundation
import Observation

/// What the git surfaces need from the app: a merge-request opener, a generator through the session's model, a
/// confirmation for pushes to the default branch and force pushes, and a notice/toast sink.
@MainActor
public struct GitActionHost {
    /// Opens the create-merge-request form (GitLab 1) for the current branch.
    public var createMergeRequest: @MainActor () -> Void
    public var openMergeRequest: @MainActor () -> Void
    /// Text from the session's model (`session.generate`); nil for a draft (no session yet).
    public var generate: (@MainActor (String) async throws -> String)?
    /// Asks the person to confirm `message` (title, detail, confirm button). Returns true to go ahead.
    public var confirm: @MainActor (String, String, String) async -> Bool
    public var notice: @MainActor (String) -> Void
    public var publish: @MainActor () -> Void

    public init(
        createMergeRequest: @escaping @MainActor () -> Void, openMergeRequest: @escaping @MainActor () -> Void,
        generate: (@MainActor (String) async throws -> String)?, confirm: @escaping @MainActor (String, String, String) async -> Bool,
        notice: @escaping @MainActor (String) -> Void, publish: @escaping @MainActor () -> Void
    ) {
        self.createMergeRequest = createMergeRequest
        self.openMergeRequest = openMergeRequest
        self.generate = generate
        self.confirm = confirm
        self.notice = notice
        self.publish = publish
    }
}

/// The git actions control (header quick action + menu, Git menu, palette): T3 Code's `GitActionsControl` on
/// `GitActionPlanner`, running each action on the repository model and reporting the outcome.
@MainActor
@Observable
public final class GitActionsModel {
    public let repository: GitRepositoryModel
    @ObservationIgnored public var host: GitActionHost
    public var hasOpenMergeRequest = false
    public private(set) var aheadOfDefault: Int?
    public private(set) var lastError: String?
    /// The commit form, when open.
    public var commit: GitCommitModel?

    public init(repository: GitRepositoryModel, host: GitActionHost) {
        self.repository = repository
        self.host = host
    }

    public var input: GitActionInput { repository.actionInput(hasOpenMergeRequest: hasOpenMergeRequest, aheadOfDefault: aheadOfDefault) }
    public var quickAction: GitQuickAction { GitActionPlanner.quickAction(input) }
    public var items: [GitActionItem] { GitActionPlanner.menu(input) }

    /// Status for the menu's header: "main ↑2 ↓1 · fetched 3 min ago" (words for VoiceOver in `accessibleStatus`).
    public var statusLine: String {
        guard let status = repository.status else { return repository.phase == .notRepository ? "Not a git repository" : "Reading git status…" }
        var parts = [status.branch ?? status.head.map { "Detached at \($0.prefix(7))" } ?? "…"]
        if let operation = status.operation { parts.append("\(operation.label) in progress") }
        if !status.conflictedFiles.isEmpty { parts.append("\(status.conflictedFiles.count) conflicted") }
        if status.upstream == nil, status.branch != nil { parts.append("not published") }
        if status.ahead > 0 { parts.append("↑\(status.ahead) to push") }
        if status.behind > 0 { parts.append("↓\(status.behind) to pull") }
        if status.ahead == 0, status.behind == 0, status.upstream != nil { parts.append("up to date") }
        if let fetched = repository.lastFetched { parts.append("fetched \(RelativeTime.short(fetched)) ago") }
        if let problem = repository.fetchProblem { parts.append("fetch failed: \(problem)") }
        return parts.joined(separator: " · ")
    }

    /// Reads remotes and the commit count beyond the default branch (for Create MR).
    public func reload() async {
        await repository.loadRemotes()
        if let base = repository.baseBranch, let branch = repository.status?.branch, branch != base {
            let remoteBase = (try? await repository.repository.resolves("refs/remotes/origin/\(base)")) == true ? "origin/\(base)" : base
            aheadOfDefault = try? await repository.repository.count("\(remoteBase)..HEAD")
        } else {
            aheadOfDefault = 0
        }
    }

    /// Runs one action. Commit actions open the commit form (`commit`), which calls `finishCommit`.
    public func perform(_ action: GitAction) async {
        lastError = nil
        do {
            switch action {
            case .commit, .commitAndPush, .commitPushAndCreateMergeRequest:
                let form = GitCommitModel(repository: repository, generate: host.generate)
                form.followUp = action
                commit = form
                await form.load()
            case .push, .pushAndCreateMergeRequest:
                guard try await push() else { return }
                if action == .pushAndCreateMergeRequest { host.createMergeRequest() }
            case .createMergeRequest: host.createMergeRequest()
            case .openMergeRequest: host.openMergeRequest()
            case .pull:
                try await repository.pull()
                host.notice("Pulled \(repository.status?.branch ?? "the branch")")
            case .pullRebase:
                try await repository.pull(rebase: true)
                host.notice(repository.status?.operation == .rebase ? "Rebase stopped with conflicts" : "Rebased \(repository.status?.branch ?? "the branch")")
            case .fetch:
                try await repository.fetchNow()
                host.notice("Fetched")
            case .sync:
                if repository.status?.ahead ?? 0 > 0, try await !confirmDefaultBranchPush() { return }
                try await repository.sync()
                host.notice("Synced \(repository.status?.branch ?? "the branch")")
            case .publish: host.publish()
            case .switchRemoteToHTTPS:
                let url = try await repository.switchOriginToHTTPS()
                host.notice("origin now uses \(url)")
            case .abortOperation:
                let label = repository.status?.operation?.label ?? "Operation"
                guard await host.confirm(
                    "Abort the \(label.lowercased())?", "Your working tree returns to how it was before the \(label.lowercased()) started. Conflict resolutions you made are lost.",
                    "Abort \(label)")
                else { return }
                try await repository.abortOperation()
                host.notice("\(label) aborted")
            }
            await reload()
        } catch {
            lastError = (error as? GitError)?.userMessage ?? (error as? GitPushPlanError)?.userMessage
                ?? (error as? GitSwitchError).map { _ in "Local changes are in the way." } ?? "The git action failed."
            host.notice(lastError ?? "")
        }
    }

    /// Pushes the current branch after the confirmations T3 Code asks for: pushing to the default branch, and a force
    /// push (never without its own confirmation). Returns false when the person cancelled.
    @discardableResult
    func push() async throws -> Bool {
        let plan = try await repository.pushPlan()
        guard let plan else { throw GitError.failed(command: "push", status: 1, message: "Nothing to push: detached HEAD or no origin.") }
        if try await !confirmDefaultBranchPush() { return false }
        var force = false
        if plan.needsForce {
            guard await host.confirm(
                "Force push \(plan.branch)?",
                "origin/\(plan.branch) has commits your branch does not. A force push replaces origin/\(plan.branch) at \(plan.remoteHead.map { String($0.prefix(12)) } ?? "(none)") with \(plan.localHead.prefix(12)) on \(plan.remoteURL) (sent with --force-with-lease on that commit, so it fails if someone pushed meanwhile).",
                "Force Push")
            else { return false }
            force = true
        }
        // Exactly what was confirmed: the plan's commit, destination and (for a force push) remote head (AF21).
        try await repository.push(plan, force: force)
        host.notice("Pushed \(plan.branch)\(plan.commits.isEmpty ? "" : " (\(plan.commits.count + plan.moreCommits) commit\(plan.commits.count + plan.moreCommits == 1 ? "" : "s"))")")
        return true
    }

    func confirmDefaultBranchPush() async throws -> Bool {
        guard let branch = repository.status?.branch, branch == repository.baseBranch else { return true }
        return await host.confirm(
            "Push to \(branch)?", "\(branch) is the repository's default branch. The commits go straight to origin/\(branch) without a merge request.", "Push to \(branch)")
    }

    /// Called by the commit form: commits, then pushes and opens the MR form as the chosen action says. A failed
    /// commit stays in the form; once the commit is made the form is closed, so a failed push is reported like any
    /// other action's failure (`lastError` and a notice), never only in the closed form (NF05).
    public func finishCommit(_ form: GitCommitModel, as action: GitAction) async {
        let message = form.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        lastError = nil
        do {
            try await repository.commitAll(message: message)
        } catch {
            form.error = (error as? GitError)?.userMessage ?? "The commit failed."
            return
        }
        commit = nil
        let branch = repository.status?.branch ?? "HEAD"
        host.notice("Committed to \(branch)")
        if action == .commitAndPush || action == .commitPushAndCreateMergeRequest {
            do {
                guard try await push() else { return }
                if action == .commitPushAndCreateMergeRequest { host.createMergeRequest() }
            } catch {
                let reason = (error as? GitError)?.userMessage ?? (error as? GitPushPlanError)?.userMessage ?? "The push failed."
                lastError = "Committed to \(branch), but the push failed: \(reason)"
                host.notice(lastError ?? "")
            }
        }
        await reload()
    }
}

/// The commit form (T3 Code's commit dialog, as a popover): message, generated through the session's model from
/// the staged (or all) changes and the repository's recent subjects.
@MainActor
@Observable
public final class GitCommitModel {
    public let repository: GitRepositoryModel
    @ObservationIgnored let generate: (@MainActor (String) async throws -> String)?
    public var message = ""
    public var followUp: GitAction = .commit
    public private(set) var isGenerating = false
    public var error: String?
    /// The provider refused the generation (usage limit, sign-in, model gone): the form links to Settings ▸ Models.
    public private(set) var modelProblem: BackgroundModelError?
    public private(set) var summary = ""

    public init(repository: GitRepositoryModel, generate: (@MainActor (String) async throws -> String)?) {
        self.repository = repository
        self.generate = generate
    }

    public var canGenerate: Bool { generate != nil && !isGenerating }
    public var stagedOnly: Bool { !(repository.status?.stagedFiles.isEmpty ?? true) }

    public func load() async {
        guard let status = repository.status else { return }
        let files = stagedOnly ? status.stagedFiles : status.files
        let added = files.reduce(0) { $0 + ((stagedOnly ? $1.stagedStats : $1.totalStats)?.additions ?? 0) }
        let removed = files.reduce(0) { $0 + ((stagedOnly ? $1.stagedStats : $1.totalStats)?.deletions ?? 0) }
        summary = "\(files.count) file\(files.count == 1 ? "" : "s")\(stagedOnly ? " staged" : "") · +\(added) −\(removed)"
    }

    /// Proposes a message (replaces the field only if the person has not typed one meanwhile).
    public func generateMessage() async {
        guard let generate, !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }
        modelProblem = nil
        let typed = message
        do {
            let context = try await repository.repository.commitContext()
            let subjects = (try? await repository.repository.recentSubjects()) ?? []
            let reply = try await generate(GitTextGeneration.commitPrompt(stat: context.stat, patch: context.patch, recentSubjects: subjects))
            guard let proposal = GitTextGeneration.commitMessage(from: reply) else {
                error = "The model did not propose a usable message."
                return
            }
            if message == typed { message = proposal }
        } catch let refusal as BackgroundModelError {
            modelProblem = refusal
            self.error = "Could not generate a message: \(refusal.message)"
        } catch {
            let detail = (error as? GitError)?.userMessage ?? (error as? EngineError)?.userMessage ?? String(describing: type(of: error))
            self.error = "Could not generate a message: \(detail)"
        }
    }
}

/// "Clone from GitLab" (T3 Code Add Project ▸ clone): an instance, a searchable list of the person's projects (or a
/// pasted URL), and the destination folder. The clone runs in the background; the project opens at once.
@MainActor
@Observable
public final class GitCloneModel {
    public let instances: [GitLabInstance]
    public var instance: GitLabInstance?
    public var query = ""
    public private(set) var projects: [GitLabProjectSummary] = []
    public private(set) var isSearching = false
    public var selected: GitLabProjectSummary? { didSet { if let selected { destination = GitProjectService.defaultDestination(for: selected.httpURL) ?? destination } } }
    public var pastedURL = ""
    public var destination = ""
    public var error: String?
    @ObservationIgnored let search: @MainActor (GitLabInstance, String) async throws -> [GitLabProjectSummary]
    @ObservationIgnored let start: @MainActor (String, String) throws -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    public init(
        instances: [GitLabInstance], search: @escaping @MainActor (GitLabInstance, String) async throws -> [GitLabProjectSummary],
        start: @escaping @MainActor (String, String) throws -> Void
    ) {
        self.instances = instances
        instance = instances.first
        self.search = search
        self.start = start
    }

    /// The URL that would be cloned: a pasted HTTPS URL, else the selected project's.
    public var url: String? {
        let pasted = pastedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty { return pasted }
        return selected?.httpURL
    }

    public var canClone: Bool { url != nil && !destination.trimmingCharacters(in: .whitespaces).isEmpty }

    public func refresh() {
        searchTask?.cancel()
        guard let instance else { return }
        let query = query
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled else { return }
            do {
                let found = try await self.search(instance, query)
                guard !Task.isCancelled else { return }
                self.projects = found
                self.error = nil
            } catch {
                self.error = (error as? ForgeError)?.description ?? "GitLab could not be searched."
            }
            self.isSearching = false
        }
    }

    public func pastedChanged() {
        if let url = url, selected == nil || !pastedURL.isEmpty, let destination = GitProjectService.defaultDestination(for: url) { self.destination = destination }
    }

    /// Starts the clone; returns true when it started.
    public func clone() -> Bool {
        guard let url else { return false }
        if url.lowercased().hasPrefix("git@") || url.lowercased().hasPrefix("ssh://") {
            error = "BelloCode clones over HTTPS. Use the project's HTTPS URL (https://…)."
            return false
        }
        do {
            try start(url, (destination as NSString).expandingTildeInPath)
            return true
        } catch {
            self.error = (error as? GitError)?.userMessage ?? "The clone could not start."
            return false
        }
    }

    /// Test and snapshot seam: shows `projects` without searching.
    public func setProjects(_ projects: [GitLabProjectSummary]) { self.projects = projects }
}

/// "Publish to GitLab": creates a private project on the instance and pushes the repository (T3 Code Publish
/// Repository).
@MainActor
@Observable
public final class GitPublishModel {
    public let instances: [GitLabInstance]
    public var instance: GitLabInstance?
    public var name: String
    public var path: String
    public private(set) var namespaces: [GitLabNamespace] = []
    public var namespaceID: Int?
    public private(set) var isPublishing = false
    public var error: String?
    public private(set) var published: GitLabProjectSummary?
    @ObservationIgnored let loadNamespaces: @MainActor (GitLabInstance) async throws -> [GitLabNamespace]
    @ObservationIgnored let run: @MainActor (GitLabInstance, String, String, Int?) async throws -> GitLabProjectSummary

    public init(
        instances: [GitLabInstance], directory: String, loadNamespaces: @escaping @MainActor (GitLabInstance) async throws -> [GitLabNamespace],
        publish: @escaping @MainActor (GitLabInstance, String, String, Int?) async throws -> GitLabProjectSummary
    ) {
        self.instances = instances
        instance = instances.first
        name = (directory as NSString).lastPathComponent
        path = WorktreeService.slug((directory as NSString).lastPathComponent, prefix: "")
        self.loadNamespaces = loadNamespaces
        run = publish
    }

    public func load() async {
        guard let instance else { return }
        namespaces = (try? await loadNamespaces(instance)) ?? []
        if namespaceID == nil { namespaceID = namespaces.first?.id }
    }

    public var canPublish: Bool { instance != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && GitTextGeneration.isValidBranchName(path) && !isPublishing }

    public func publish() async -> Bool {
        guard let instance, canPublish else { return false }
        isPublishing = true
        defer { isPublishing = false }
        do {
            published = try await run(instance, name, path, namespaceID)
            return true
        } catch {
            self.error = (error as? GitError)?.userMessage ?? (error as? ForgeError)?.description ?? "Publishing failed."
            return false
        }
    }

    public func setNamespaces(_ namespaces: [GitLabNamespace]) {
        self.namespaces = namespaces
        namespaceID = namespaces.first?.id
    }
}

/// "Edit from Here" (T3 Code composer.md): rewinds the conversation to before a message; optionally restores the
/// files to the checkpoint from before it.
@MainActor
@Observable
public final class RewindModel {
    public let prompt: String
    public var revertFiles = false
    public private(set) var plan: RewindPlan?
    public private(set) var isPlanning = false
    public private(set) var isRewinding = false
    public var error: String?
    @ObservationIgnored let makePlan: @MainActor (Bool) async throws -> RewindPlan
    @ObservationIgnored let perform: @MainActor (RewindPlan) async throws -> Void

    public init(prompt: String, plan: @escaping @MainActor (Bool) async throws -> RewindPlan, perform: @escaping @MainActor (RewindPlan) async throws -> Void) {
        self.prompt = prompt
        makePlan = plan
        self.perform = perform
    }

    /// The files a file restore would change, or why it cannot.
    public var filesLine: String {
        guard revertFiles else { return "Files stay as they are now." }
        if isPlanning { return "Checking the checkpoint…" }
        if let reason = plan?.filesUnavailable { return reason }
        guard let files = plan?.files else { return "" }
        if files.changes.isEmpty { return "The files already match the checkpoint." }
        let names = files.paths.prefix(4).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        return "\(files.changes.count) file\(files.changes.count == 1 ? "" : "s") go back to before this message (\(names)\(files.changes.count > 4 ? ", …" : "")). This also undoes edits you made yourself; Undo restores them."
    }

    public func setRevertFiles(_ value: Bool) async {
        revertFiles = value
        await replan()
    }

    public func replan() async {
        isPlanning = true
        defer { isPlanning = false }
        do {
            plan = try await makePlan(revertFiles)
            error = nil
        } catch {
            // A plan for the other choice must not stay actionable (it would rewind without the files asked for).
            plan = nil
            self.error = (error as? GitError)?.userMessage ?? "The rewind could not be planned."
        }
    }

    public func rewind() async -> Bool {
        guard let plan, !isRewinding else { return false }
        isRewinding = true
        defer { isRewinding = false }
        do {
            try await perform(plan)
            return true
        } catch let error as WorkingCopyError {
            self.error = error.userMessage + " Nothing was rewound."
        } catch {
            self.error = (error as? GitError)?.userMessage ?? "The rewind failed. Nothing was changed."
        }
        return false
    }

    /// Snapshot seam.
    public func setPlan(_ plan: RewindPlan) { self.plan = plan }
}
