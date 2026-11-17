import Darwin
import Foundation

/// What to create: a new branch from a base (or an existing branch) checked out in its own folder.
public struct WorktreeCreation: Sendable, Hashable {
    /// The project's main checkout.
    public var projectDirectory: String
    /// The branch to create (or check out, with `useExistingBranch`).
    public var branch: String
    /// The base branch or ref the new branch starts from (`main`).
    public var base: String
    /// Fetch the base from `origin` first and start from `origin/<base>`.
    public var startFromOrigin: Bool
    /// The folder that receives the worktree (a subfolder named after the branch is created in it).
    public var parentDirectory: String
    /// Clone unchanged files with APFS copy-on-write when the base is the main checkout's HEAD.
    public var copyOnWrite: Bool
    /// Runs in the new worktree after checkout (`zsh -lc`), for example "npm install".
    public var setupScript: String?
    public var useExistingBranch: Bool

    public init(
        projectDirectory: String, branch: String, base: String, startFromOrigin: Bool = false, parentDirectory: String,
        copyOnWrite: Bool = true, setupScript: String? = nil, useExistingBranch: Bool = false
    ) {
        self.projectDirectory = projectDirectory
        self.branch = branch
        self.base = base
        self.startFromOrigin = startFromOrigin
        self.parentDirectory = parentDirectory
        self.copyOnWrite = copyOnWrite
        self.setupScript = setupScript
        self.useExistingBranch = useExistingBranch
    }
}

/// The outcome of a setup script.
public struct WorktreeSetupResult: Sendable, Hashable {
    public var exitCode: Int32
    /// The last 8 KB of combined output.
    public var output: String
    public var duration: Duration
    public var succeeded: Bool { exitCode == 0 }
}

public struct CreatedWorktree: Sendable, Hashable {
    public var directory: String
    public var branch: String
    /// The ref the branch started from (`main` or `origin/main`).
    public var baseRef: String
    public var baseCommit: String
    /// Files cloned copy-on-write (0 when a normal checkout was used).
    public var clonedFiles: Int
    public var setup: WorktreeSetupResult?
    public var duration: Duration
}

/// A removed worktree, with what is needed to bring it back (Undo).
public struct RemovedWorktree: Sendable, Hashable {
    public var directory: String
    public var projectDirectory: String
    public var branch: String?
    public var head: String
    public var branchDeleted: Bool
}

public enum WorktreeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The worktree holds uncommitted or untracked files; removing it would lose them (needs `force`).
    case uncommittedChanges(count: Int)
    case branchExists(String)
    case directoryExists(String)
    case baseNotFound(String)
    case fetchFailed(String)
    case notAWorktree(String)

    public var description: String { userMessage }

    public var userMessage: String {
        switch self {
        case .uncommittedChanges(let count): "The worktree has \(count) uncommitted file\(count == 1 ? "" : "s")."
        case .branchExists(let name): "A branch named “\(name)” already exists."
        case .directoryExists(let path): "A folder already exists at \((path as NSString).abbreviatingWithTildeInPath)."
        case .baseNotFound(let ref): "The base “\(ref)” was not found."
        case .fetchFailed(let message): "Could not fetch from origin: \(message)"
        case .notAWorktree: "This folder is not a worktree of the project."
        }
    }
}

/// Creates and removes worktrees with git directly (not opencode's worktree API, which always checks out a detached
/// HEAD in a randomly named folder and cannot start a new branch from a chosen base or from origin; see
/// docs/features/diff-git.md). Callers ask opencode to `refreshWorktrees` afterwards so it adopts the folder.
public struct WorktreeService: Sendable {
    public let runner: GitRunner

    public init(runner: GitRunner = GitRunner()) { self.runner = runner }

    // MARK: Names

    /// A branch-name slug from free text: lowercase ASCII letters, digits and dashes, at most 48 characters, with an
    /// optional prefix ("bellocode/fix-login-bug"). Empty text gives "<prefix>work".
    public static func slug(_ text: String, prefix: String = "bellocode/") -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var slug = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                if pendingDash, !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
                if slug.count >= 48 { break }
            } else {
                pendingDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return prefix + (slug.isEmpty ? "work" : slug)
    }

    /// `name`, or `name-2`, `name-3`… when a local branch with that name exists.
    public func uniqueBranchName(_ name: String, in projectDirectory: String) async throws -> String {
        let repository = GitRepository(directory: projectDirectory, runner: runner)
        var candidate = name
        var suffix = 2
        while try await repository.resolves("refs/heads/\(candidate)") {
            candidate = "\(name)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// The folder for a branch's worktree: `<parent>/<branch with / replaced by ->`.
    public static func folder(for branch: String, in parent: String) -> String {
        (parent as NSString).appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
    }

    // MARK: Create

    public func create(_ request: WorktreeCreation) async throws -> CreatedWorktree {
        let start = ContinuousClock.now
        let project = GitRepository(directory: request.projectDirectory, runner: runner)
        let directory = Self.folder(for: request.branch, in: request.parentDirectory)
        if FileManager.default.fileExists(atPath: directory) { throw WorktreeError.directoryExists(directory) }
        if !request.useExistingBranch, try await project.resolves("refs/heads/\(request.branch)") {
            throw WorktreeError.branchExists(request.branch)
        }
        var baseRef = request.useExistingBranch ? request.branch : request.base
        if request.startFromOrigin, !request.useExistingBranch {
            do {
                _ = try await project.git(["fetch", "--quiet", "origin", request.base], timeout: .seconds(90))
            } catch let error as GitError {
                throw WorktreeError.fetchFailed(error.userMessage)
            }
            baseRef = "origin/\(request.base)"
        }
        guard let baseCommit = try await project.revParse(baseRef) else { throw WorktreeError.baseNotFound(baseRef) }
        try FileManager.default.createDirectory(atPath: request.parentDirectory, withIntermediateDirectories: true)

        // Copy-on-write applies when the main checkout's HEAD is the base commit: its clean files are byte-identical.
        let sourceHead = try await project.revParse("HEAD")
        let cloneable = request.copyOnWrite && sourceHead == baseCommit
        var arguments = ["worktree", "add", "--quiet"]
        if cloneable { arguments.append("--no-checkout") }
        if request.useExistingBranch {
            arguments += [directory, request.branch]
        } else {
            arguments += ["-b", request.branch, directory, baseCommit]
        }
        _ = try await project.git(arguments, timeout: .seconds(300))
        var cloned = 0
        if cloneable {
            do {
                cloned = try await cloneCheckout(from: request.projectDirectory, to: directory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not APFS, a cross-volume path or a clone error: fall back to a normal checkout of the files.
                cloned = 0
            }
            let worktree = GitRepository(directory: directory, runner: runner)
            _ = try await worktree.git(["reset", "--quiet"], timeout: .seconds(300))
            _ = try await worktree.git(["update-index", "-q", "--refresh"], timeout: .seconds(300), allowFailure: true)
            let stale = try await worktree.git(["ls-files", "-z", "--deleted", "--modified"]).stdout
            if !stale.isEmpty {
                _ = try await worktree.git(["checkout", "--pathspec-from-file=-", "--pathspec-file-nul", "--"], input: stale, timeout: .seconds(300))
            }
        }
        var setup: WorktreeSetupResult?
        if let script = request.setupScript?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
            setup = try await runSetup(script, in: directory, projectDirectory: request.projectDirectory)
        }
        return CreatedWorktree(
            directory: directory, branch: request.branch, baseRef: baseRef, baseCommit: baseCommit, clonedFiles: cloned, setup: setup,
            duration: ContinuousClock.now - start)
    }

    /// Clones every clean tracked file of `source` into `destination` with `clonefile(2)`. Throws on the first clone
    /// failure (for example `ENOTSUP` off APFS); the caller then checks out what is missing.
    @concurrent
    func cloneCheckout(from source: String, to destination: String) async throws -> Int {
        let repository = GitRepository(directory: source, runner: runner)
        let listing = try await repository.git(["ls-files", "-z", "--stage"]).stdout
        let dirty = try await repository.git(["diff", "--name-only", "-z", "HEAD"], allowFailure: true).stdout
        let dirtySet = Set(GitStatusParser.split(dirty))
        var count = 0
        var createdDirectories: Set<String> = []
        for entry in GitStatusParser.split(listing) {
            // "<mode> <object> <stage>\t<path>"; gitlinks (160000) are submodules: skipped.
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let mode = entry.prefix(6)
            let path = String(entry[entry.index(after: tab)...])
            guard mode != "160000", !dirtySet.contains(path) else { continue }
            if count % 256 == 0 { try Task.checkCancellation() }
            let target = (destination as NSString).appendingPathComponent(path)
            let parent = (target as NSString).deletingLastPathComponent
            if !createdDirectories.contains(parent) {
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                createdDirectories.insert(parent)
            }
            let from = (source as NSString).appendingPathComponent(path)
            if clonefile(from, target, UInt32(CLONE_NOFOLLOW)) != 0 {
                let code = errno
                if code == ENOENT { continue }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            count += 1
        }
        return count
    }

    /// Runs a setup script with `zsh -lc` in the worktree (10 minutes at most).
    public func runSetup(_ script: String, in directory: String, projectDirectory: String) async throws -> WorktreeSetupResult {
        let start = ContinuousClock.now
        let output = try await runner.runProgram(
            URL(filePath: "/bin/zsh"), ["-lc", script], in: directory,
            environment: ["BELLOCODE_WORKTREE_PATH": directory, "BELLOCODE_PROJECT_ROOT": projectDirectory], timeout: .seconds(600))
        let combined = String(decoding: output.stdout + output.stderr, as: UTF8.self)
        return WorktreeSetupResult(exitCode: output.status, output: String(combined.suffix(8_192)), duration: ContinuousClock.now - start)
    }

    // MARK: Remove and restore

    /// Removes a worktree folder (and optionally its branch). Without `force`, a worktree holding uncommitted or
    /// untracked files is refused with `WorktreeError.uncommittedChanges`; nothing is touched.
    public func remove(directory: String, projectDirectory: String, deleteBranch: Bool, force: Bool) async throws -> RemovedWorktree {
        let project = GitRepository(directory: projectDirectory, runner: runner)
        let known = try await project.worktrees()
        let standardized = (directory as NSString).standardizingPath
        guard let entry = known.first(where: { ($0.path as NSString).standardizingPath == standardized || realPath($0.path) == realPath(directory) }),
              !entry.isMain
        else { throw WorktreeError.notAWorktree(directory) }
        let worktree = GitRepository(directory: entry.path, runner: runner)
        if FileManager.default.fileExists(atPath: entry.path) {
            let dirty = try await worktree.git(["status", "--porcelain", "-z", "--untracked-files=all"]).stdout
            let count = GitStatusParser.split(dirty).count
            if count > 0, !force { throw WorktreeError.uncommittedChanges(count: count) }
        }
        let head = entry.head ?? ""
        _ = try await project.git(["worktree", "remove"] + (force ? ["--force"] : []) + [entry.path], timeout: .seconds(120))
        var deleted = false
        if deleteBranch, let branch = entry.branch {
            _ = try await project.git(["branch", "-D", branch])
            deleted = true
        }
        return RemovedWorktree(directory: entry.path, projectDirectory: projectDirectory, branch: entry.branch, head: head, branchDeleted: deleted)
    }

    /// Undo of `remove`: recreates the branch at its old commit if it was deleted, then checks it out again in the
    /// same folder. Uncommitted files of a forced removal cannot be restored.
    public func restore(_ removed: RemovedWorktree) async throws {
        let project = GitRepository(directory: removed.projectDirectory, runner: runner)
        if removed.branchDeleted, let branch = removed.branch {
            _ = try await project.git(["branch", branch, removed.head])
        }
        _ = try await project.git(["worktree", "prune"], allowFailure: true)
        if let branch = removed.branch {
            _ = try await project.git(["worktree", "add", "--quiet", removed.directory, branch], timeout: .seconds(300))
        } else {
            _ = try await project.git(["worktree", "add", "--quiet", "--detach", removed.directory, removed.head], timeout: .seconds(300))
        }
    }

    private func realPath(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
