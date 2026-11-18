import Foundation

// Git parity (docs/features/git-parity.md rows 14–18, 21, 23, 24): the git actions on one repository model, the
// background fetch schedule, and the inputs of `GitActionPlanner`. Every git call runs off the main actor
// (`GitRepository`); results are applied here on the main actor with a refresh.
extension GitRepositoryModel {
    // MARK: Planner input

    /// The planner's input from the current status, remotes and configured instances.
    public func actionInput(hasOpenMergeRequest: Bool = false, aheadOfDefault: Int? = nil) -> GitActionInput {
        var input = GitActionInput(status: status)
        input.isBusy = activity != nil
        let origin = remotes.first { $0.name == "origin" } ?? remotes.first
        input.hasRemote = origin != nil
        let instances = service?.forgeInstances() ?? []
        let parsed = origin.flatMap { GitRemoteURL($0.pushURL) }
        let instance = parsed.flatMap { url in instances.first { $0.host.lowercased() == url.host } }
        input.remoteOnGitLab = instance != nil && parsed?.scheme == "https"
        input.remoteIsSSHOnGitLab = instance != nil && parsed?.isSSH == true
        input.canPublish = !instances.isEmpty
        input.hasOpenMergeRequest = hasOpenMergeRequest
        input.aheadOfDefault = aheadOfDefault
        if let branch = status?.branch, let base = baseBranch { input.isDefaultBranch = branch == base }
        return input
    }

    /// The configured instance `origin` belongs to (SSH or HTTPS), if any.
    public var originInstance: GitLabInstance? {
        let origin = remotes.first { $0.name == "origin" } ?? remotes.first
        guard let url = origin.flatMap({ GitRemoteURL($0.pushURL) }) else { return nil }
        return (service?.forgeInstances() ?? []).first { $0.host.lowercased() == url.host }
    }

    public func loadRemotes() async {
        if let loaded = try? await repository.remotes() { remotes = loaded }
    }

    // MARK: Actions

    /// Runs `work` as the model's one git action, labelled `label` ("Pushing…"), refreshing afterwards.
    func run<T: Sendable>(_ label: String, _ work: @Sendable (GitRepository) async throws -> T) async throws -> T {
        guard activity == nil else { throw GitError.failed(command: "busy", status: 1, message: "Another git action is running.") }
        activity = label
        defer {
            activity = nil
            refresh()
        }
        return try await work(repository)
    }

    /// Fails early with a clear sentence when the instance reported scopes that cannot do `need` over HTTPS.
    func checkScopes(_ need: GitTokenScopes.Need) throws {
        guard let instance = originInstance, let problem = GitTokenScopes.problem(need, scopes: service?.tokenScopes(instance.baseURL)) else { return }
        throw GitError.authenticationFailed(problem)
    }

    public func fetchNow() async throws {
        try checkScopes(.read)
        isFetching = true
        defer { isFetching = false }
        do {
            try await run("Fetching…") { try await $0.fetch(remote: nil) }
            lastFetched = Date()
            fetchProblem = nil
        } catch {
            fetchProblem = (error as? GitError)?.userMessage ?? "Fetch failed."
            throw error
        }
    }

    public func pull(rebase: Bool = false) async throws {
        try checkScopes(.read)
        try await run(rebase ? "Pulling with rebase…" : "Pulling…") { rebase ? try await $0.pullRebase() : try await $0.pullFastForward() }
    }

    /// Fetch, fast-forward when behind, push when ahead (refuses when diverged).
    public func sync() async throws {
        try checkScopes(.write)
        try await run("Syncing…") { repository in
            try await repository.fetch(remote: nil)
            let status = try await repository.status(limit: 1)
            if status.ahead > 0 && status.behind > 0 {
                throw GitError.failed(command: "sync", status: 1, message: "The branch has diverged from its upstream. Use Pull with Rebase.")
            }
            if status.behind > 0 { try await repository.pullFastForward() }
            if status.ahead > 0, let branch = status.branch { try await repository.push(branch: branch, setUpstream: false) }
        }
        lastFetched = Date()
    }

    /// Commits (everything when nothing is staged) with `message`; returns the new commit.
    @discardableResult
    public func commitAll(message: String) async throws -> String {
        try await run("Committing…") { try await $0.commitAll(message: message) }
    }

    /// What `pushCurrentBranch` would send.
    public func pushPlan() async throws -> GitPushPlan? { try await repository.pushPlan() }

    /// Pushes the current branch to `origin` (sets the upstream the first time). Never forces unless `force`.
    public func pushCurrentBranch(force: Bool = false) async throws {
        try checkScopes(.write)
        guard let branch = status?.branch else { throw GitError.failed(command: "push", status: 1, message: "Detached HEAD: switch to a branch before pushing.") }
        let setUpstream = status?.upstream == nil
        try await run(force ? "Force pushing…" : "Pushing…") { try await $0.push(branch: branch, setUpstream: setUpstream, force: force) }
    }

    /// Points `origin` at the HTTPS URL of the same project on its configured instance (the owner chose HTTPS).
    public func switchOriginToHTTPS() async throws -> String {
        guard let instance = originInstance, let origin = remotes.first(where: { $0.name == "origin" }) ?? remotes.first,
              let https = GitRemoteURL(origin.fetchURL)?.httpsEquivalent(on: instance)
        else { throw GitError.failed(command: "remote", status: 1, message: "The remote is not an SSH remote on a configured GitLab instance.") }
        try await run("Switching remote…") { try await $0.setRemoteURL(origin.name, url: https) }
        await loadRemotes()
        return https
    }

    public func abortOperation() async throws {
        guard let operation = status?.operation else { return }
        try await run("Aborting \(operation.label.lowercased())…") { try await $0.abort(operation) }
    }

    /// Switches branches; `GitSwitchError.localChanges` when local changes are in the way (the caller offers to stash).
    public func switchBranch(_ name: String, create: Bool) async throws {
        try await run("Switching branch…") { try await $0.switchBranch(name, create: create) }
        loadBranches(force: true)
    }

    /// "Stash and Switch": stashes everything under a recognisable message, switches, and returns the stash's hash
    /// (shown with "Restore stashed changes" when the person comes back).
    public func stashAndSwitch(to name: String, create: Bool) async throws -> String? {
        let from = status?.branch ?? "HEAD"
        let hash = try await run("Stashing changes…") { try await $0.stash(message: "bellocode: changes on \(from)") }
        do {
            try await switchBranch(name, create: create)
        } catch {
            if let hash { try? await repository.applyStash(hash); try? await repository.dropStash(hash) }
            refresh()
            throw error
        }
        return hash
    }

    /// Re-applies a stash made by `stashAndSwitch` and drops it when it applied cleanly.
    public func restoreStash(_ hash: String) async throws {
        try await run("Restoring stashed changes…") { repository in
            try await repository.applyStash(hash)
            try await repository.dropStash(hash)
        }
    }

    // MARK: Background fetch

    func startAutoFetch() {
        guard fetchTask == nil, let interval = service?.autoFetchInterval else { return }
        let maximum = service?.autoFetchMaxInterval ?? .seconds(3_600)
        fetchTask = Task { [weak self] in
            var delay = Duration.seconds(5)
            var failures = 0
            while !Task.isCancelled {
                // ContinuousClock (AGENTS.md rule 21): fires in an idle process.
                try? await Task.sleep(for: delay, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                let succeeded = await self.backgroundFetch()
                failures = succeeded ? 0 : failures + 1
                delay = succeeded ? interval : min(maximum, interval * (1 << min(failures, 4)))
            }
        }
    }

    func stopAutoFetch() {
        fetchTask?.cancel()
        fetchTask = nil
    }

    /// One scheduled fetch (skipped while another action runs or without a remote), then the optional
    /// fast-forward of a clean default branch. Returns false on failure.
    func backgroundFetch() async -> Bool {
        guard phase == .ready, activity == nil else { return true }
        if remotes.isEmpty { await loadRemotes() }
        guard !remotes.isEmpty else { return true }
        do {
            try await fetchNow()
        } catch {
            return false
        }
        if service?.autoPullDefaultBranch == true, let status, let branch = status.branch, branch == baseBranch, status.files.isEmpty,
           status.ahead == 0, status.behind > 0, status.upstream != nil, status.operation == nil
        {
            try? await pull()
        }
        return true
    }
}
