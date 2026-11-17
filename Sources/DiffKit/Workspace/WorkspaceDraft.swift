import BelloCore
import Engine
import Foundation
import Observation

/// A new thread's workspace choice before its first send: the project's main checkout, a new worktree on a new branch
/// (from a base branch, optionally fetched from origin), or an existing worktree. On send, `prepare` creates the
/// worktree if needed and returns the directory the thread is created in.
///
/// Threading: `@MainActor`, `@Observable`. Branch and worktree lists load off the main actor and are cached by the
/// repository model.
@MainActor
@Observable
public final class WorkspaceDraft {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Creating the worktree (and running its setup script).
        case preparing(String)
        case failed(String)
    }

    public let projectDirectory: String
    public let projectID: ProjectID?
    public let repository: GitRepositoryModel
    public var mode: WorkspacePreferences.Mode = .local { didSet { if mode != oldValue { savePreferences() } } }
    /// The base for a new worktree (nil: the repository's base).
    public var baseBranch: String? { didSet { if baseBranch != oldValue { savePreferences() } } }
    public var startFromOrigin = false { didSet { if startFromOrigin != oldValue { savePreferences() } } }
    /// The new branch's name; empty: generated from the prompt when the thread is created.
    public var branchName = ""
    /// The chosen existing worktree.
    public var existingWorktree: GitWorktree?
    public private(set) var worktrees: [GitWorktree] = []
    public private(set) var phase: Phase = .idle
    public private(set) var preferences = WorkspacePreferences()
    /// Bumped to open the pickers from menu commands.
    public private(set) var workspaceOpenRequests = 0
    public private(set) var branchOpenRequests = 0
    /// Makes a branch name from the prompt (the generated-name hook; a plain slug for now).
    @ObservationIgnored public var branchNameGenerator: @MainActor (String) -> String = { WorktreeService.slug($0) }
    @ObservationIgnored private let git: GitService
    @ObservationIgnored private var loaded = false

    public init(git: GitService, projectDirectory: String, projectID: ProjectID?) {
        self.git = git
        self.projectDirectory = projectDirectory
        self.projectID = projectID
        repository = git.repository(for: projectDirectory)
    }

    /// Loads the project's saved defaults and its worktrees (once).
    public func load() {
        guard !loaded else { return }
        loaded = true
        Task {
            let saved = await git.preferences(projectDirectory: projectDirectory)
            preferences = saved
            isRestoring = true
            mode = saved.mode == .existingWorktree ? .local : saved.mode
            baseBranch = saved.baseBranch
            startFromOrigin = saved.startFromOrigin
            isRestoring = false
            await reloadWorktrees()
        }
    }

    @ObservationIgnored private var isRestoring = false

    public func reloadWorktrees() async {
        let repository = repository.repository
        worktrees = (try? await repository.worktrees())?.filter { !$0.isMain && !$0.isPrunable } ?? []
    }

    private func savePreferences() {
        guard loaded, !isRestoring else { return }
        var value = preferences
        value.mode = mode
        value.baseBranch = baseBranch
        value.startFromOrigin = startFromOrigin
        preferences = value
        let git = git
        let directory = projectDirectory
        Task { await git.setPreferences(value, projectDirectory: directory) }
    }

    public func requestWorkspacePicker() { workspaceOpenRequests += 1 }
    public func requestBranchPicker() { branchOpenRequests += 1 }

    /// The base used for a new worktree.
    public var effectiveBase: String { baseBranch ?? repository.baseBranch ?? repository.status?.branch ?? "main" }

    /// "Local checkout", "New worktree", "Worktree · feature/x".
    public var workspaceLabel: String {
        switch mode {
        case .local: "Local"
        case .newWorktree: "New worktree"
        case .existingWorktree: existingWorktree.map { "Worktree · \($0.branch ?? ($0.path as NSString).lastPathComponent)" } ?? "Existing worktree"
        }
    }

    /// The branch control's label: the current branch (local), "from main" (new worktree), the worktree's branch.
    public var branchLabel: String {
        switch mode {
        case .local:
            if let branch = repository.status?.branch { return branch }
            if let head = repository.status?.head { return "Detached \(head.prefix(7))" }
            return repository.phase == .notRepository ? "No git" : "…"
        case .newWorktree:
            let name = branchName.isEmpty ? "new branch" : branchName
            return "\(name) from \(startFromOrigin ? "origin/" : "")\(effectiveBase)"
        case .existingWorktree:
            return existingWorktree?.branch ?? "Detached"
        }
    }

    /// Selects an existing worktree.
    public func chooseWorktree(_ worktree: GitWorktree) {
        existingWorktree = worktree
        mode = .existingWorktree
    }

    /// Local mode: switches the main checkout to `branch` (git refuses when that would overwrite changes), or creates
    /// it from the current HEAD.
    public func switchLocalBranch(to branch: String, create: Bool) async throws {
        let repository = repository.repository
        _ = try await repository.git(create ? ["switch", "-c", branch] : ["switch", branch])
        self.repository.refresh()
        self.repository.loadBranches(force: true)
    }

    // MARK: Prepare

    /// Returns the directory to create the thread in, creating the worktree first for `newWorktree`. `prompt` names
    /// the branch when no name was typed.
    public func prepare(prompt: String) async throws -> (directory: String, created: CreatedWorktree?) {
        switch mode {
        case .local:
            return (projectDirectory, nil)
        case .existingWorktree:
            guard let worktree = existingWorktree else { return (projectDirectory, nil) }
            return (worktree.path, nil)
        case .newWorktree:
            let requested = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = requested.isEmpty ? branchNameGenerator(prompt) : requested
            phase = .preparing("Creating worktree…")
            do {
                let branch = try await git.worktrees.uniqueBranchName(base, in: projectDirectory)
                var script = preferences.setupScript
                if script == nil { script = await git.projectStartCommand(projectID: projectID) }
                if script != nil { phase = .preparing("Creating worktree and running its setup script…") }
                let request = WorktreeCreation(
                    projectDirectory: projectDirectory, branch: branch, base: effectiveBase, startFromOrigin: startFromOrigin,
                    parentDirectory: preferences.parentDirectory(projectDirectory: projectDirectory), copyOnWrite: preferences.copyOnWrite,
                    setupScript: script)
                let created = try await git.createWorktree(request, projectID: projectID)
                phase = .idle
                if let setup = created.setup, !setup.succeeded {
                    // The worktree exists and the thread starts there, but the person learns the script failed (with
                    // the start of its output, where the first error usually is; a cut is marked in the output).
                    let first = setup.output.split(separator: "\n").first.map(String.init) ?? ""
                    phase = .failed("The worktree was created, but its setup script failed (exit \(setup.exitCode))\(setup.omittedBytes > 0 ? ", output shortened" : ""): \(first.prefix(160))")
                }
                branchName = ""
                await reloadWorktrees()
                return (created.directory, created)
            } catch {
                phase = .failed((error as? WorktreeError)?.userMessage ?? (error as? GitError)?.userMessage ?? "The worktree could not be created.")
                throw error
            }
        }
    }

    public func clearFailure() { if case .failed = phase { phase = .idle } }
}
