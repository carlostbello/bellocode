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
    /// Where the worktree's own files (uncommitted, untracked and ignored) were moved on removal, normally a folder in
    /// the Trash; `restore` moves them back. Nil when the worktree held nothing beyond its commits.
    public var heldContents: String? = nil
}

/// Files in a worktree that exist nowhere else: uncommitted changes (including untracked files) and ignored files
/// such as `.env`, local databases or build output.
public struct WorktreeContents: Sendable, Hashable {
    public var uncommitted: Int
    /// Ignored entries; an ignored folder counts once.
    public var ignored: Int
    /// A few of the paths, for the confirmation.
    public var examples: [String]
    public var isEmpty: Bool { uncommitted == 0 && ignored == 0 }

    /// "2 uncommitted files and 1 ignored item".
    public var summary: String {
        var parts: [String] = []
        if uncommitted > 0 { parts.append("\(uncommitted) uncommitted file\(uncommitted == 1 ? "" : "s")") }
        if ignored > 0 { parts.append("\(ignored) ignored item\(ignored == 1 ? "" : "s")") }
        return parts.isEmpty ? "no files of its own" : parts.joined(separator: " and ")
    }
}

public enum WorktreeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The worktree holds uncommitted, untracked or ignored files; removing it needs `force` (they go to the Trash).
    case filesAtRisk(WorktreeContents)
    /// The worktree was restored, but the files moved aside at removal are gone (the Trash was emptied).
    case heldContentsMissing(String)
    case branchExists(String)
    case directoryExists(String)
    case baseNotFound(String)
    case fetchFailed(String)
    case notAWorktree(String)

    public var description: String { userMessage }

    public var userMessage: String {
        switch self {
        case .filesAtRisk(let contents): "The worktree has \(contents.summary)."
        case .heldContentsMissing(let path):
            "The checkout was restored, but its own files are no longer at \((path as NSString).abbreviatingWithTildeInPath)."
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
    /// Moves a folder somewhere recoverable and returns its new location. Defaults to the Trash; tests use a holding
    /// folder of their own.
    let recycle: @Sendable (URL) throws -> URL
    /// Runs setup scripts somewhere other than the host: the engine routes them into the project's container
    /// (docs/features/containers.md). Nil only without container execution (mock mode, tests).
    public var setupRunner: (@Sendable (_ script: String, _ worktree: String, _ project: String) async throws -> WorktreeSetupResult)?

    public init(runner: GitRunner = GitRunner()) {
        self.init(runner: runner, recycle: WorktreeService.moveToTrash)
    }

    init(runner: GitRunner, recycle: @escaping @Sendable (URL) throws -> URL) {
        self.runner = runner
        self.recycle = recycle
    }

    static func moveToTrash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

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

    /// Runs a setup script in the project's container (`setupRunner`), or, without container execution, with `zsh -lc`
    /// in the worktree (10 minutes at most).
    public func runSetup(_ script: String, in directory: String, projectDirectory: String) async throws -> WorktreeSetupResult {
        if let setupRunner { return try await setupRunner(script, directory, projectDirectory) }
        let start = ContinuousClock.now
        let output = try await runner.runProgram(
            URL(filePath: "/bin/zsh"), ["-lc", script], in: directory,
            environment: ["BELLOCODE_WORKTREE_PATH": directory, "BELLOCODE_PROJECT_ROOT": projectDirectory], timeout: .seconds(600))
        let combined = String(decoding: output.stdout + output.stderr, as: UTF8.self)
        return WorktreeSetupResult(exitCode: output.status, output: String(combined.suffix(8_192)), duration: ContinuousClock.now - start)
    }

    // MARK: Remove and restore

    /// What removing the worktree would take away besides its commits (uncommitted, untracked and ignored files).
    public func contents(of directory: String) async throws -> WorktreeContents {
        let worktree = GitRepository(directory: directory, runner: runner)
        let dirty = GitStatusParser.split(try await worktree.git(["status", "--porcelain", "-z", "--untracked-files=all"]).stdout)
            .filter { $0.count > 3 && $0.dropFirst(2).first == " " }
        // Ignored folders are listed once ("build/"), which keeps the listing small for node_modules and friends.
        let ignored = GitStatusParser.split(
            try await worktree.git(["status", "--porcelain", "-z", "--ignored=traditional", "--untracked-files=normal"]).stdout
        ).filter { $0.hasPrefix("!! ") }
        let examples = (dirty + ignored).prefix(5).map { String($0.dropFirst(3)) }
        return WorktreeContents(uncommitted: dirty.count, ignored: ignored.count, examples: examples)
    }

    /// Removes a worktree folder (and optionally its branch). A worktree holding uncommitted, untracked or ignored files
    /// is refused without `force` (`WorktreeError.filesAtRisk`, nothing touched); with `force` those files are moved
    /// to the Trash first (`RemovedWorktree.heldContents`), so `restore` can put them back.
    public func remove(directory: String, projectDirectory: String, deleteBranch: Bool, force: Bool) async throws -> RemovedWorktree {
        let project = GitRepository(directory: projectDirectory, runner: runner)
        let known = try await project.worktrees()
        let standardized = (directory as NSString).standardizingPath
        guard let entry = known.first(where: { ($0.path as NSString).standardizingPath == standardized || realPath($0.path) == realPath(directory) }),
              !entry.isMain
        else { throw WorktreeError.notAWorktree(directory) }
        var held: URL?
        if FileManager.default.fileExists(atPath: entry.path) {
            let contents = try await contents(of: entry.path)
            if !contents.isEmpty {
                guard force else { throw WorktreeError.filesAtRisk(contents) }
                held = try holdContents(of: entry.path)
            }
        }
        let head = entry.head ?? ""
        do {
            _ = try await project.git(["worktree", "remove"] + (force ? ["--force"] : []) + [entry.path], timeout: .seconds(120))
        } catch {
            if let held { try? putBack(held, into: entry.path) }
            throw error
        }
        var deleted = false
        if deleteBranch, let branch = entry.branch {
            _ = try await project.git(["branch", "-D", branch])
            deleted = true
        }
        return RemovedWorktree(
            directory: entry.path, projectDirectory: projectDirectory, branch: entry.branch, head: head, branchDeleted: deleted,
            heldContents: held?.path)
    }

    /// Moves everything in the worktree except its `.git` link into a sibling folder (a rename on the same volume),
    /// then recycles that folder. Any failure puts the files back and throws.
    private func holdContents(of directory: String) throws -> URL {
        let fileManager = FileManager.default
        let root = URL(filePath: directory, directoryHint: .isDirectory)
        // Named after the worktree, so it is recognisable in the Trash.
        let staging = root.deletingLastPathComponent().appending(
            path: "\(root.lastPathComponent) (removed worktree \(UUID().uuidString.prefix(8)))", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for name in try fileManager.contentsOfDirectory(atPath: directory) where name != ".git" {
                try fileManager.moveItem(at: root.appending(path: name), to: staging.appending(path: name))
            }
            return try recycle(staging)
        } catch {
            try? putBack(staging, into: directory)
            throw error
        }
    }

    /// Moves every item of `held` into `directory`, replacing what is there, then removes the emptied `held`.
    private func putBack(_ held: URL, into directory: String) throws {
        let fileManager = FileManager.default
        let root = URL(filePath: directory, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        for name in try fileManager.contentsOfDirectory(atPath: held.path) where name != ".git" {
            let destination = root.appending(path: name)
            if (try? fileManager.attributesOfItem(atPath: destination.path)) != nil { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: held.appending(path: name), to: destination)
        }
        try? fileManager.removeItem(at: held)
    }

    /// Undo of `remove`: recreates the branch at its old commit if it was deleted, checks it out again in the same
    /// folder, then moves the files held at removal (uncommitted, untracked, ignored) back over the checkout. Their
    /// bytes come back exactly; what was staged in the index comes back as unstaged changes. Throws
    /// `heldContentsMissing` (after restoring the checkout) when those files were deleted from the Trash.
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
        guard let held = removed.heldContents else { return }
        guard FileManager.default.fileExists(atPath: held) else { throw WorktreeError.heldContentsMissing(held) }
        try putBack(URL(filePath: held, directoryHint: .isDirectory), into: removed.directory)
    }

    private func realPath(_ path: String) -> String {
        URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
