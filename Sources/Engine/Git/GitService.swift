import BelloCore
import CryptoKit
import Foundation
import Observation
import OpenCodeKit
import os

/// Per-project workspace defaults (app-owned; `app_preference` key `workspace.<project directory>`, no migration).
public struct WorkspacePreferences: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable, Hashable, CaseIterable {
        /// The repository's main checkout.
        case local
        /// A new worktree on a new branch.
        case newWorktree
        /// A worktree that already exists.
        case existingWorktree

        public var label: String {
            switch self {
            case .local: "Local checkout"
            case .newWorktree: "New worktree"
            case .existingWorktree: "Existing worktree"
            }
        }
    }

    public var mode: Mode = .local
    /// Base branch for new worktrees; nil uses opencode's base (reflog or default branch).
    public var baseBranch: String?
    public var startFromOrigin = false
    /// Where new worktrees go; nil uses `~/.bellocode/worktrees/<project name>-<path hash>`.
    public var worktreeParent: String?
    public var copyOnWrite = true
    /// Runs in each new worktree; nil uses the project's opencode start command, if any.
    public var setupScript: String?
    public var branchPrefix = "bellocode/"
    /// Git parity: automatic cleanup of this project's worktrees (optional so older saved preferences still decode).
    public var cleanup: WorktreeCleanupPolicy?
    /// Git parity: propose worktree branch names with the session's model (the slug is used until it answers).
    public var generateBranchNames: Bool?

    public init() {}

    public func parentDirectory(projectDirectory: String) -> String {
        if let worktreeParent { return worktreeParent }
        return Self.defaultParent(projectDirectory: projectDirectory)
    }

    /// `~/.bellocode/worktrees/<name>-<first 8 hex of SHA-256 of the project's real path>`: unique per project, so two
    /// projects with the same folder name never share a folder (or a container mount; M5 in
    /// docs/reviews/M3-M6-review.md).
    public static func defaultParent(projectDirectory: String, home: String = NSHomeDirectory()) -> String {
        let name = (projectDirectory as NSString).lastPathComponent
        let real = URL(filePath: projectDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        let hash = SHA256.hash(data: Data(real.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return (home as NSString).appendingPathComponent(".bellocode/worktrees/\(name)-\(hash)")
    }

    /// The folder earlier versions used (`~/.bellocode/worktrees/<name>`), shared by every project with that name.
    /// Worktrees already there keep working; only this project's own are mounted into its container.
    public static func legacyParent(projectDirectory: String, home: String = NSHomeDirectory()) -> String {
        (home as NSString).appendingPathComponent(".bellocode/worktrees/\((projectDirectory as NSString).lastPathComponent)")
    }

    /// The worktrees of `projectDirectory` directly inside `folder`: a subfolder counts only when its `.git` file
    /// points into the project's `.git/worktrees/<id>` and that entry's `gitdir` points back at it (the project's own
    /// record, which another project's container cannot write). Read from files; no git process. At most 500 entries.
    public static func ownWorktrees(in folder: String, projectDirectory: String) -> [String] {
        let fileManager = FileManager.default
        let project = URL(filePath: projectDirectory).resolvingSymlinksInPath().standardizedFileURL.path
        guard let names = try? fileManager.contentsOfDirectory(atPath: folder) else { return [] }
        var result: [String] = []
        for name in names.sorted().prefix(500) {
            let candidate = (folder as NSString).appendingPathComponent(name)
            guard let link = try? String(contentsOfFile: candidate + "/.git", encoding: .utf8), link.hasPrefix("gitdir:") else { continue }
            let gitdir = URL(filePath: link.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().standardizedFileURL.path
            guard gitdir.hasPrefix(project + "/.git/worktrees/"),
                  let back = try? String(contentsOfFile: gitdir + "/gitdir", encoding: .utf8)
            else { continue }
            let backPath = URL(filePath: back.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().standardizedFileURL.path
            let candidateGit = URL(filePath: candidate + "/.git").resolvingSymlinksInPath().standardizedFileURL.path
            if backPath == candidateGit { result.append(candidate) }
        }
        return result
    }
}

/// The app's git integration (docs/features/diff-git.md). One per engine (`Engine.git`).
///
/// - Status, branches, commits, staged/unstaged diffs, stage, commit, push: git directly (`GitRepository`), because
///   opencode's VCS endpoints do not distinguish staged from unstaged changes, report no upstream or ahead/behind,
///   and offer no index or commit operations.
/// - Branch diffs vs base, the base itself, per-turn diffs and turn revert: opencode (`/api/vcs/*`,
///   `/api/session/{id}/diff`, `/api/session/{id}/revert/*`).
/// - Worktrees: git (`WorktreeService`), then `POST /api/worktree/refresh` so opencode adopts them.
///
/// Threading: `@MainActor`; all git and file work runs off the main actor and returns `Sendable` values.
@MainActor
public final class GitService {
    /// The configured GitLab instances (Create Merge Request), set by the engine from Settings ▸ GitLab.
    public var forgeInstances: @MainActor () -> [GitLabInstance] = { [] }
    /// Token scopes per instance base URL when GitLab reported them (git parity: HTTPS scope checks).
    public var tokenScopes: @MainActor (String) -> [String]? = { _ in nil }
    /// Background fetch interval for watched repositories (nil: off). Failures back off to `autoFetchMaxInterval`.
    public var autoFetchInterval: Duration? = .seconds(300)
    public var autoFetchMaxInterval: Duration = .seconds(3_600)
    /// Fast-forward the default branch after a fetch when the checkout is clean (T3 Code "Automatically pull").
    public var autoPullDefaultBranch = false {
        didSet {
            guard autoPullDefaultBranch != oldValue, let store else { return }
            let value = autoPullDefaultBranch
            Task { try? await store.setPreference("git.autoPull", value) }
        }
    }

    /// Loads the app-wide git preferences (Automatically Pull Default Branch) from the store.
    public func loadGlobalPreferences() async {
        if let value = try? await store?.preference("git.autoPull", as: Bool.self) { autoPullDefaultBranch = value }
    }

    /// Repository models kept (least recently used dropped beyond this; their watchers stop).
    public static let repositoryLimit = 24

    public private(set) var runner: GitRunner
    /// Settable inside the module so tests can route removed worktree files away from the real Trash.
    public internal(set) var worktrees: WorktreeService
    let client: @Sendable () async throws -> OpenCodeClient
    let store: ProjectionStore?
    private var models: [String: GitRepositoryModel] = [:]
    private var recency: [String] = []
    private var preferenceCache: [String: WorkspacePreferences] = [:]
    static let log = Logger(subsystem: "dev.bellocode.engine", category: "git")

    public init(client: @escaping @Sendable () async throws -> OpenCodeClient, store: ProjectionStore?, runner: GitRunner = GitRunner()) {
        self.client = client
        self.store = store
        self.runner = runner
        worktrees = WorktreeService(runner: runner)
    }

    /// The model for a directory (same instance while cached). It loads on first use; call `refresh()` to update.
    public func repository(for directory: String) -> GitRepositoryModel {
        recency.removeAll { $0 == directory }
        recency.append(directory)
        if let model = models[directory] { return model }
        let model = GitRepositoryModel(directory: directory, service: self)
        models[directory] = model
        while recency.count > Self.repositoryLimit {
            let evicted = recency.removeFirst()
            models.removeValue(forKey: evicted)?.shutdown()
        }
        model.refresh()
        return model
    }

    /// Git parity: HTTPS authentication to the configured GitLab instances with the Keychain token, through the app's
    /// credential helper (docs/features/git-parity.md). Applies to every git process started afterwards.
    public func configureCredentials(_ credentials: GitCredentials?) {
        runner.credentials = credentials
        worktrees.runner.credentials = credentials
    }

    public var credentials: GitCredentials? { runner.credentials }

    /// Tests: another runner environment (a test CA, local remotes), keeping the configured credentials.
    func replaceRunner(_ replacement: GitRunner) {
        var next = replacement
        next.credentials = runner.credentials
        runner = next
        worktrees.runner = next
    }

    /// The model of `directory` only if it is already cached (sidebar rows never create models).
    public func cachedRepository(for directory: String) -> GitRepositoryModel? { models[directory] }

    /// Refreshes every cached model of `directory` and below (after a turn, a commit or a worktree change).
    public func refreshAll(under directory: String? = nil) {
        for (key, model) in models where directory == nil || key == directory || key.hasPrefix(directory! + "/") { model.refresh() }
    }

    /// Stops every watcher (app quit).
    public func shutdown() {
        for model in models.values { model.shutdown() }
        models.removeAll()
        recency.removeAll()
    }

    // MARK: Preferences

    /// The preferences if already loaded, else the defaults (synchronous; for the worktree folder mounted in containers).
    public func cachedPreferences(projectDirectory: String) -> WorkspacePreferences {
        preferenceCache[projectDirectory] ?? WorkspacePreferences()
    }

    public func preferences(projectDirectory: String) async -> WorkspacePreferences {
        if let cached = preferenceCache[projectDirectory] { return cached }
        let loaded = (try? await store?.preference("workspace.\(projectDirectory)", as: WorkspacePreferences.self)) ?? nil
        let value = loaded ?? WorkspacePreferences()
        preferenceCache[projectDirectory] = value
        return value
    }

    public func setPreferences(_ value: WorkspacePreferences, projectDirectory: String) async {
        preferenceCache[projectDirectory] = value
        try? await store?.setPreference("workspace.\(projectDirectory)", value)
    }

    // MARK: opencode-backed reads

    /// The branch a checkout compares against: opencode's base (reflog, else the default branch), else nil.
    public func base(directory: String) async -> VcsBase? {
        try? await client().vcsBase(directory: directory)
    }

    /// The branch's changes since its merge base with `base` (working copy included), from opencode.
    public func branchDiff(directory: String, base: String?, context: Int = 3) async throws -> [FileDiffInfo] {
        try await client().vcsDiff(directory: directory, mode: .branch, base: base, context: context, untracked: .files)
    }

    /// The files a turn changed (its user message `from`), from opencode's snapshots.
    public func turnDiff(sessionID: SessionID, from messageID: MessageID?, context: Int? = 3) async throws -> [FileDiffInfo] {
        try await client().sessionDiff(sessionID: sessionID.rawValue, from: messageID?.rawValue, context: context)
    }

    // MARK: Worktrees

    /// Creates a worktree (git), runs the setup script, and asks opencode to adopt it. `projectID` is opencode's
    /// project (for the refresh; skipped when nil).
    public func createWorktree(_ request: WorktreeCreation, projectID: ProjectID?) async throws -> CreatedWorktree {
        let created = try await worktrees.create(request)
        await adoptWorktrees(projectID: projectID)
        refreshAll(under: request.projectDirectory)
        return created
    }

    public func removeWorktree(directory: String, projectDirectory: String, projectID: ProjectID?, deleteBranch: Bool, force: Bool) async throws
        -> RemovedWorktree
    {
        let removed = try await worktrees.remove(directory: directory, projectDirectory: projectDirectory, deleteBranch: deleteBranch, force: force)
        models.removeValue(forKey: removed.directory)?.shutdown()
        recency.removeAll { $0 == removed.directory }
        await adoptWorktrees(projectID: projectID)
        refreshAll(under: projectDirectory)
        return removed
    }

    public func restoreWorktree(_ removed: RemovedWorktree, projectID: ProjectID?) async throws {
        try await worktrees.restore(removed)
        await adoptWorktrees(projectID: projectID)
        refreshAll(under: removed.projectDirectory)
    }

    func adoptWorktrees(projectID: ProjectID?) async {
        guard let projectID else { return }
        do {
            try await client().refreshWorktrees(projectID: projectID.rawValue)
        } catch {
            Self.log.notice("worktree refresh failed: \((error as? OpenCodeError)?.logSummary ?? "error", privacy: .public)")
        }
    }

    /// The project's opencode start command (run in new worktrees when no setup script is configured).
    public func projectStartCommand(projectID: ProjectID?) async -> String? {
        guard let projectID, let projects = try? await client().projects() else { return nil }
        return projects.first { $0.id == projectID.rawValue }?.commands?.start
    }

    // MARK: Turn revert

    /// What reverting a turn would do, checked against the working copy before anything is touched.
    public struct TurnRevertPlan: Sendable {
        public var sessionID: SessionID
        public var messageID: MessageID
        public var directory: String
        /// Files the turn changed whose current content is exactly what the turn left (only agent changes).
        public var agentOnly: [String]
        /// Files edited after the turn (by the user or a later turn): restoring them whole would discard those edits.
        public var editedSince: [String]
        /// Current content of every affected file (the Undo state).
        public var snapshots: [FileSnapshot]
        /// Hunks of the turn per file (3 lines of context), for "agent changes only".
        public var hunks: [String: [PatchHunk]]

        public var files: [String] { agentOnly + editedSince }
    }

    /// Fetches the turn's diff and compares each file with what the turn left. Nothing is changed.
    public func planTurnRevert(sessionID: SessionID, messageID: MessageID, directory: String) async throws -> TurnRevertPlan {
        let client = try await client()
        async let fullRequest = client.sessionDiff(sessionID: sessionID.rawValue, from: messageID.rawValue)
        async let contextRequest = client.sessionDiff(sessionID: sessionID.rawValue, from: messageID.rawValue, context: 3)
        let full = try await fullRequest
        let withContext = try await contextRequest
        let copy = WorkingCopy(root: directory)
        let paths = full.map(\.file)
        let snapshots = await copy.snapshotOffMain(paths)
        let comparison = await Self.compare(full, snapshots)
        var hunks: [String: [PatchHunk]] = [:]
        for file in withContext { hunks[file.file] = UnifiedPatchParser.parse(file.patch).first?.hunks ?? [] }
        return TurnRevertPlan(
            sessionID: sessionID, messageID: messageID, directory: directory, agentOnly: comparison.agentOnly,
            editedSince: comparison.edited, snapshots: snapshots, hunks: hunks)
    }

    /// A file is "agent only" when the full-file patch's new side equals its current text exactly. Anything unprovable
    /// (truncated patch, binary, several hunks) counts as edited, the safe side.
    @concurrent
    static func compare(_ diffs: [FileDiffInfo], _ snapshots: [FileSnapshot]) async -> (agentOnly: [String], edited: [String]) {
        var agentOnly: [String] = []
        var edited: [String] = []
        for (diff, snapshot) in zip(diffs, snapshots) {
            let file = UnifiedPatchParser.parse(diff.patch).first
            let expected: String?? = {
                guard let file, !file.isBinary else { return .none }
                if file.status == .deleted || diff.status == .deleted { return .some(nil) }
                if file.hunks.isEmpty { return .none }
                guard file.hunks.count == 1, let hunk = file.hunks.first, hunk.newStart <= 1 else { return .none }
                let last = hunk.lines.last { $0.kind != .removed }
                let body = hunk.newLines.joined(separator: "\n")
                return .some(body.isEmpty ? "" : body + ((last?.noNewlineAtEnd ?? false) ? "" : "\n"))
            }()
            switch expected {
            case .some(.none):
                if snapshot.exists { edited.append(diff.file) } else { agentOnly.append(diff.file) }
            case .some(.some(let text)):
                if snapshot.text == text { agentOnly.append(diff.file) } else { edited.append(diff.file) }
            case .none: edited.append(diff.file)
            }
        }
        return (agentOnly, edited)
    }

    /// The outcome of a turn revert, kept for Undo.
    public struct AppliedTurnRevert: Sendable {
        public enum Method: Sendable { case opencodeSnapshot, agentHunks }
        public var plan: TurnRevertPlan
        public var method: Method
        /// For `agentHunks`: the files written (their `before` is the Undo state).
        public var written: [FileChangePlan]
    }

    /// Reverts the whole turn through opencode's revert (files restored to the turn's start; files edited since lose
    /// those edits, which `undoTurnRevert` restores from the plan's snapshots).
    public func revertTurnWithSnapshot(_ plan: TurnRevertPlan) async throws -> AppliedTurnRevert {
        _ = try await client().stageRevert(sessionID: plan.sessionID.rawValue, messageID: plan.messageID.rawValue, files: true)
        refreshAll(under: plan.directory)
        return AppliedTurnRevert(plan: plan, method: .opencodeSnapshot, written: [])
    }

    /// Reverts only the turn's own hunks, keeping later edits; throws (writing nothing) when a hunk no longer matches.
    public func revertTurnAgentChanges(_ plan: TurnRevertPlan) async throws -> AppliedTurnRevert {
        let copy = WorkingCopy(root: plan.directory)
        var plans: [FileChangePlan] = []
        for path in plan.files {
            guard let hunks = plan.hunks[path], !hunks.isEmpty else { continue }
            plans.append(try await copy.planHunkRevertOffMain(path: path, hunks: hunks))
        }
        let written = try await copy.applyOffMain(plans)
        refreshAll(under: plan.directory)
        return AppliedTurnRevert(plan: plan, method: .agentHunks, written: written)
    }

    /// Undo: clears opencode's staged boundary (snapshot method), then puts back every file's pre-revert bytes.
    public func undoTurnRevert(_ applied: AppliedTurnRevert) async throws {
        let copy = WorkingCopy(root: applied.plan.directory)
        switch applied.method {
        case .agentHunks:
            try await copy.undoOffMain(applied.written)
        case .opencodeSnapshot:
            try await client().clearRevert(sessionID: applied.plan.sessionID.rawValue)
            // opencode restores its end snapshot, which lacks edits made after the turn: write the exact bytes back.
            let current = await copy.snapshotOffMain(applied.plan.snapshots.map(\.path))
            let fixes = zip(current, applied.plan.snapshots).compactMap { now, wanted in
                now.data == wanted.data ? nil : FileChangePlan(before: now, after: wanted.data)
            }
            _ = try await copy.applyOffMain(fixes)
        }
        refreshAll(under: applied.plan.directory)
    }
}

/// One directory's git state, observable by views: status (kept while refreshing, so views never blank), branches
/// (cached), base, and a revision that increases whenever status changed.
@MainActor
@Observable
public final class GitRepositoryModel {
    public enum Phase: Sendable, Equatable {
        case loading
        case ready
        case notRepository
        case failed(String)
    }

    public let directory: String
    public private(set) var phase: Phase = .loading
    public private(set) var location: GitLocation?
    public private(set) var status: GitStatus?
    public private(set) var isRefreshing = false
    public private(set) var refreshedAt: Date?
    public private(set) var branches: [GitBranch] = []
    public private(set) var branchesLoadedAt: Date?
    public private(set) var isLoadingBranches = false
    /// The comparison base (`main`), from opencode, else the remote default or `main`.
    public private(set) var baseBranch: String?
    /// Increases when status changes (diff views reload on it).
    public private(set) var revision = 0

    public var workspaceKind: GitWorkspaceKind { location?.kind ?? (phase == .notRepository ? .notRepository : .mainCheckout) }
    public var repository: GitRepository { GitRepository(directory: directory, runner: service?.runner ?? GitRunner()) }

    @ObservationIgnored weak var service: GitService?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var branchTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watcher: FileSystemWatcher?
    @ObservationIgnored private var watchCount = 0
    static let signposter = OSSignposter(subsystem: "dev.bellocode.engine", category: .pointsOfInterest)

    init(directory: String, service: GitService) {
        self.directory = directory
        self.service = service
    }

    // Git parity (GitRepositoryModel+Parity.swift): fetch schedule and action state.
    @ObservationIgnored var fetchTask: Task<Void, Never>?
    public internal(set) var lastFetched: Date?
    public internal(set) var fetchProblem: String?
    public internal(set) var isFetching = false
    /// The running git action ("Pushing…"), nil when idle.
    public internal(set) var activity: String?
    public internal(set) var remotes: [GitRemote] = []
    /// Stashes made by "Stash and Switch", by the branch they came from (in memory; the stash itself stays in git).
    public internal(set) var parkedStashes: [String: String] = [:]

    isolated deinit {
        refreshTask?.cancel()
        branchTask?.cancel()
        fetchTask?.cancel()
        watcher?.stop()
    }

    func shutdown() {
        refreshTask?.cancel()
        branchTask?.cancel()
        stopAutoFetch()
        watcher?.stop()
        watcher = nil
        watchCount = 0
    }

    // MARK: Refresh

    /// Re-reads status off the main actor. Calls while a refresh runs coalesce into one more afterwards.
    public func refresh() {
        if refreshTask != nil {
            refreshAgain = true
            return
        }
        generation += 1
        let generation = generation
        let repository = repository
        let needsLocation = location == nil
        isRefreshing = true
        refreshTask = Task { [weak self] in
            let interval = Self.signposter.beginInterval("gitStatus")
            defer { Self.signposter.endInterval("gitStatus", interval) }
            let result: Result<(GitLocation?, GitStatus?), any Error>
            do {
                let location = needsLocation ? try await repository.location() : nil
                if needsLocation, location == nil {
                    result = .success((nil, nil))
                } else {
                    result = .success((location, try await repository.status()))
                }
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled, self.generation == generation else { return }
            self.apply(result, locationWasNeeded: needsLocation)
        }
    }

    private func apply(_ result: Result<(GitLocation?, GitStatus?), any Error>, locationWasNeeded: Bool) {
        refreshTask = nil
        isRefreshing = false
        refreshedAt = Date()
        switch result {
        case .success((let location, let status)):
            if locationWasNeeded, location == nil {
                if phase != .notRepository { phase = .notRepository }
            } else {
                if let location { self.location = location }
                if self.status != status {
                    self.status = status
                    revision += 1
                }
                if phase != .ready { phase = .ready }
                if baseBranch == nil { loadBase() }
            }
        case .failure(let error):
            if case GitError.notARepository = error {
                phase = .notRepository
            } else if !(error is CancellationError) {
                // Keep the last status visible; say it is stale.
                phase = .failed((error as? GitError)?.userMessage ?? "Could not read git status.")
            }
        }
        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    private func loadBase() {
        let directory = directory
        guard let service else { return }
        Task { [weak self] in
            let base = await service.base(directory: directory)
            guard let self else { return }
            if let base { self.baseBranch = base.name } else if self.baseBranch == nil { self.baseBranch = "main" }
        }
    }

    /// Overrides the comparison base (Changes panel base picker).
    public func setBaseBranch(_ name: String) {
        guard baseBranch != name else { return }
        baseBranch = name
        revision += 1
    }

    // MARK: Watching

    /// Starts watching the working tree and its git directory (reference counted; pair with `endWatching`).
    public func beginWatching() {
        watchCount += 1
        startAutoFetch()
        guard watcher == nil else { return }
        startWatcherWhenLocated()
    }

    public func endWatching() {
        watchCount = max(0, watchCount - 1)
        if watchCount == 0 {
            watcher?.stop()
            watcher = nil
            stopAutoFetch()
        }
    }

    public var isWatching: Bool { watcher?.isRunning ?? false }

    private func startWatcherWhenLocated() {
        guard watchCount > 0, watcher == nil else { return }
        guard let location else {
            // Located by the first refresh; try again when it lands.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.phase == .loading || self.location != nil else { return }
                self.startWatcherWhenLocated()
            }
            return
        }
        var paths = [location.root]
        if !location.gitDirectory.hasPrefix(location.root + "/") { paths.append(location.gitDirectory) }
        if location.commonDirectory != location.gitDirectory, !location.commonDirectory.hasPrefix(location.root + "/") {
            paths.append((location.commonDirectory as NSString).appendingPathComponent("refs"))
        }
        let watcher = FileSystemWatcher(paths: paths) { [weak self] in self?.refresh() }
        watcher.start()
        self.watcher = watcher
    }

    // MARK: Branches

    /// Loads branches off the main actor (cached for 30 s unless `force`).
    public func loadBranches(force: Bool = false) {
        if !force, let loaded = branchesLoadedAt, Date().timeIntervalSince(loaded) < 30 { return }
        guard branchTask == nil else { return }
        isLoadingBranches = true
        let repository = repository
        branchTask = Task { [weak self] in
            let result = try? await repository.branches()
            guard let self, !Task.isCancelled else { return }
            self.branchTask = nil
            self.isLoadingBranches = false
            if let result {
                self.branches = result
                self.branchesLoadedAt = Date()
            }
        }
    }

    // MARK: Commands

    /// Stages paths, then refreshes. Throws `GitError` (status is refreshed either way).
    public func stage(_ paths: [String]) async throws {
        defer { refresh() }
        try await repository.stage(paths)
    }

    public func unstage(_ paths: [String]) async throws {
        defer { refresh() }
        try await repository.unstage(paths)
    }

    @discardableResult
    public func commit(message: String) async throws -> String {
        defer { refresh() }
        return try await repository.commit(message: message)
    }

    public func push() async throws {
        defer { refresh() }
        try await repository.push()
    }

    /// GitLab's "new merge request" page for the current branch (into the base branch), or nil: detached HEAD, or an
    /// `origin` that is not on one of `instances` (Settings ▸ GitLab).
    public func newMergeRequestURL(instances: [GitLabInstance]) async -> URL? {
        guard let branch = status?.branch, let remote = try? await repository.remoteURL(),
            let project = ForgeProject.resolve(remote: remote, instances: instances)
        else { return nil }
        return project.newMergeRequestURL(branch: branch, target: baseBranch)
    }
}
