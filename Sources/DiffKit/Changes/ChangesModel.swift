import BelloCore
import Engine
import Foundation
import Observation
import OpenCodeKit
import os

/// What the Changes panel compares.
public enum ChangesScope: Sendable, Hashable {
    /// One turn's own changes (opencode's per-turn snapshots); nil: the newest turn.
    case turn(MessageID?)
    /// Everything on the branch since its merge base with the base branch, working copy included (opencode).
    case branch
    /// Uncommitted changes (HEAD → working tree), with staged and unstaged state per file (git).
    case uncommitted
    /// One commit (git).
    case commit(String)

    public var title: String {
        switch self {
        case .turn: "This Turn"
        case .branch: "Branch"
        case .uncommitted: "Uncommitted"
        case .commit: "Commit"
        }
    }
}

/// A turn of the thread, for the turn picker.
public struct ChangesTurn: Sendable, Hashable, Identifiable {
    public var id: MessageID
    /// The prompt's first line.
    public var title: String
    public var index: Int
    public init(id: MessageID, title: String, index: Int) {
        self.id = id
        self.title = title
        self.index = index
    }
}

/// A changed file in the tree.
public struct ChangedFile: Sendable, Hashable, Identifiable {
    public var path: String
    public var oldPath: String?
    public var status: PatchFile.Status
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool
    /// Uncommitted scope: whether the file has staged changes, unstaged changes, is untracked.
    public var staged: GitChangeKind?
    public var unstaged: GitChangeKind?
    public var id: String { path }

    /// Status for display (letter + word, never colour alone).
    public var statusLetter: String {
        if unstaged == .untracked { return "?" }
        switch status {
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .modified: return "M"
        }
    }

    public var statusWord: String {
        if unstaged == .untracked { return "Untracked" }
        switch status {
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .renamed: return "Renamed"
        case .copied: return "Copied"
        case .modified: return "Modified"
        }
    }
}

/// A completed change the host can offer to undo (it registers it with the window's undo manager and toast).
public struct ReversibleChange: Sendable {
    /// "Revert Hunk".
    public var name: String
    /// "Reverted a hunk in Login.swift".
    public var message: String
    public var undo: @MainActor @Sendable () async throws -> Void
    public var redo: @MainActor @Sendable () async throws -> Void
}

/// The Changes panel's state for one thread or draft: scope, loaded files and diffs (kept visible while reloading),
/// and the actions on them. Loads off the main actor with cancellation and a generation check; refreshes when the
/// repository's status revision changes (file system watching) and after each turn.
///
/// Threading: `@MainActor`, `@Observable`.
@MainActor
@Observable
public final class ChangesModel {
    public enum Phase: Sendable, Equatable {
        case idle, loading, ready
        case failed(String)
    }

    public let directory: String
    public let sessionID: SessionID?
    public let repository: GitRepositoryModel
    public private(set) var scope: ChangesScope
    public private(set) var phase: Phase = .idle
    /// Last loaded files (kept while a reload runs; `isStale` says so).
    public private(set) var files: [ChangedFile] = []
    public private(set) var diffFiles: [DiffFile] = []
    public private(set) var isStale = false
    public private(set) var loadedAt: Date?
    public private(set) var commits: [GitCommit] = []
    /// The base the branch scope compares against.
    public var baseBranch: String? { repository.baseBranch }
    /// The paths whose hunks can be reverted in this scope.
    public var revertablePaths: Set<String> {
        switch scope {
        case .commit: []
        default: Set(diffFiles.filter { $0.content == .text }.map(\.path))
        }
    }
    /// Errors from actions (shown inline; the content stays).
    public var actionError: String?
    /// Busy action ("Committing…", "Pushing…").
    public private(set) var busy: String?
    public var commitMessage = ""
    /// Called after every completed reversible change.
    @ObservationIgnored public var onReversibleChange: (@MainActor (ReversibleChange) -> Void)?
    @ObservationIgnored public var turns: @MainActor () -> [ChangesTurn] = { [] }

    @ObservationIgnored private let git: GitService
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observedRevision = -1
    static let signposter = OSSignposter(subsystem: "dev.bellocode.diffkit", category: .pointsOfInterest)

    public init(git: GitService, directory: String, sessionID: SessionID?, scope: ChangesScope? = nil) {
        self.git = git
        self.directory = directory
        self.sessionID = sessionID
        repository = git.repository(for: directory)
        self.scope = scope ?? (sessionID == nil ? .uncommitted : .turn(nil))
    }

    isolated deinit { loadTask?.cancel() }

    // MARK: Loading

    public func setScope(_ scope: ChangesScope) {
        guard scope != self.scope else { return }
        self.scope = scope
        diffFiles = []
        files = []
        load()
    }

    /// Reloads when the repository's status changed since the last load (call from an observation loop).
    public func reloadIfRepositoryChanged() {
        let revision = repository.revision
        guard revision != observedRevision else { return }
        observedRevision = revision
        if loadedAt != nil { load() }
    }

    /// (Re)loads the scope. The previous files stay visible and are marked stale until the new ones arrive.
    public func load() {
        generation += 1
        let generation = generation
        loadTask?.cancel()
        isStale = loadedAt != nil
        phase = .loading
        observedRevision = repository.revision
        let scope = scope
        let directory = directory
        let sessionID = sessionID
        let git = git
        let repository = repository.repository
        let base = repository.directory == directory ? self.repository.baseBranch : nil
        let needsCommits: Bool = if case .commit = scope { true } else { false }
        loadTask = Task { [weak self] in
            let interval = Self.signposter.beginInterval("changesLoad")
            defer { Self.signposter.endInterval("changesLoad", interval) }
            do {
                let result = try await Self.fetch(scope: scope, directory: directory, sessionID: sessionID, base: base, git: git, repository: repository)
                let commits = needsCommits ? (try? await repository.commits(base.map { "\($0)..HEAD" } ?? "HEAD", limit: 100)) ?? [] : nil
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                // The diff lists files in the tree's order (folders first, by name).
                let order = Dictionary(FileTree.build(result.files).flatMap(\.files).enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
                self.diffFiles = result.diffs.sorted { (order[$0.path] ?? .max) < (order[$1.path] ?? .max) }
                self.files = result.files
                if let commits { self.commits = commits.isEmpty ? (try? await repository.commits("HEAD", limit: 100)) ?? [] : commits }
                self.isStale = false
                self.loadedAt = Date()
                self.phase = .ready
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == generation else { return }
                self.phase = .failed(Self.describe(error))
            }
        }
    }

    nonisolated static func describe(_ error: any Error) -> String {
        if let error = error as? GitError { return error.userMessage }
        if let error = error as? OpenCodeError {
            if error.status == 404 { return "This turn's changes are not available." }
            if case .transport = error { return "opencode is not reachable; showing the last loaded changes." }
            return "opencode could not compute the diff."
        }
        if error is EngineError { return "Not connected to opencode." }
        return "The changes could not be loaded."
    }

    struct Fetched: Sendable {
        var diffs: [DiffFile]
        var files: [ChangedFile]
    }

    /// Full texts are fetched for at most this many files (context expansion); larger sets show hunks only.
    nonisolated static let fullTextFileLimit = 40
    nonisolated static let fullTextByteLimit = 1 << 20

    @concurrent
    static func fetch(
        scope: ChangesScope, directory: String, sessionID: SessionID?, base: String?, git: GitService, repository: GitRepository
    ) async throws -> Fetched {
        switch scope {
        case .turn(let messageID):
            guard let sessionID else { return Fetched(diffs: [], files: []) }
            let infos = try await git.turnDiff(sessionID: sessionID, from: messageID, context: nil)
            var diffs: [DiffFile] = []
            for info in infos {
                try Task.checkCancellation()
                diffs.append(fullFileDiff(info))
            }
            return Fetched(diffs: diffs, files: diffs.map { changedFile($0) })
        case .branch:
            let infos = try await git.branchDiff(directory: directory, base: base)
            let diffs = infos.flatMap { info in UnifiedPatchParser.parse(info.patch).map { DiffFile.from($0) } }
            return Fetched(diffs: diffs, files: diffs.map { changedFile($0) })
        case .commit(let hash):
            let text = try await repository.diff(.commit(hash))
            let diffs = UnifiedPatchParser.parse(text).map { DiffFile.from($0) }
            return Fetched(diffs: diffs, files: diffs.map { changedFile($0) })
        case .uncommitted:
            async let statusRequest = repository.status()
            let hasHead = try await repository.resolves("HEAD")
            let from = hasHead ? "HEAD" : "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
            let text = try await repository.diff(.workingTree(from: from))
            let status = try await statusRequest
            var diffs: [DiffFile] = []
            for (index, patch) in UnifiedPatchParser.parse(text).enumerated() {
                try Task.checkCancellation()
                if index < fullTextFileLimit, !patch.isBinary, let full = try await fullTexts(patch, from: hasHead ? "HEAD" : nil, directory: directory, repository: repository) {
                    var file = DiffFile.compute(path: patch.path, old: full.old, new: full.new)
                    file.oldPath = patch.status == .renamed ? patch.oldPath : nil
                    if patch.status == .renamed { file.status = .renamed }
                    diffs.append(file)
                } else {
                    diffs.append(DiffFile.from(patch))
                }
            }
            let byPath = Dictionary(status.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
            let files = diffs.map { diff -> ChangedFile in
                var file = changedFile(diff)
                file.staged = byPath[diff.path]?.staged
                file.unstaged = byPath[diff.path]?.unstaged
                return file
            }
            return Fetched(diffs: diffs, files: files)
        }
    }

    /// Both sides of a file for the uncommitted scope: `from:path` and the working copy (nil when absent or too big).
    nonisolated static func fullTexts(_ patch: PatchFile, from revision: String?, directory: String, repository: GitRepository) async throws -> (old: String?, new: String?)? {
        var old: String?
        if let revision, let oldPath = patch.oldPath, patch.status != .added {
            guard let data = try await repository.content(at: revision, path: oldPath, limit: fullTextByteLimit), let text = String(data: data, encoding: .utf8) else { return nil }
            old = text
        }
        var new: String?
        if patch.status != .deleted, let newPath = patch.newPath {
            let url = URL(filePath: directory).appending(path: newPath)
            guard let data = try? Data(contentsOf: url), data.count <= fullTextByteLimit, let text = String(data: data, encoding: .utf8) else { return nil }
            new = text
        }
        return (old, new)
    }

    /// A per-turn diff without context is a full-file patch: rebuild both texts and diff locally (expandable
    /// context). Anything else (truncated, binary, several hunks) is shown as given.
    nonisolated static func fullFileDiff(_ info: FileDiffInfo) -> DiffFile {
        guard let patch = UnifiedPatchParser.parse(info.patch).first else {
            return DiffFile(path: info.file, status: info.status == .added ? .added : info.status == .deleted ? .deleted : .modified, hunks: [])
        }
        guard !patch.isBinary, info.more != true, patch.hunks.count == 1, let hunk = patch.hunks.first, hunk.oldStart <= 1, hunk.newStart <= 1 else {
            return DiffFile.from(patch)
        }
        func text(_ lines: [String], noNewline: Bool) -> String { lines.isEmpty ? "" : lines.joined(separator: "\n") + (noNewline ? "" : "\n") }
        let lastOld = hunk.lines.last { $0.kind != .added }
        let lastNew = hunk.lines.last { $0.kind != .removed }
        let old = patch.status == .added ? nil : text(hunk.oldLines, noNewline: lastOld?.noNewlineAtEnd ?? false)
        let new = patch.status == .deleted ? nil : text(hunk.newLines, noNewline: lastNew?.noNewlineAtEnd ?? false)
        var file = DiffFile.compute(path: patch.path, old: old, new: new)
        if patch.status == .renamed {
            file.status = .renamed
            file.oldPath = patch.oldPath
        }
        return file
    }

    nonisolated static func changedFile(_ diff: DiffFile) -> ChangedFile {
        ChangedFile(
            path: diff.path, oldPath: diff.oldPath, status: diff.status, additions: diff.additions, deletions: diff.deletions,
            isBinary: diff.content != .text)
    }

    // MARK: Summary

    public var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    public var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// "3 files · +40 −12".
    public var summary: String {
        files.isEmpty ? "No changes" : "\(files.count) file\(files.count == 1 ? "" : "s") · +\(totalAdditions) −\(totalDeletions)"
    }

    // MARK: Revert

    /// What "Revert" does to a file in the current scope, stated before it runs (menu titles and the toast).
    public func revertTitle(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        switch scope {
        case .turn: return "Revert This Turn’s Changes to \(name)"
        case .branch: return "Restore \(name) to \(baseBranch ?? "Base")"
        case .uncommitted: return "Discard Uncommitted Changes to \(name)"
        case .commit: return nil
        }
    }

    /// Reverts one hunk of a file (shown in this scope) in the working copy, verified against the file's current text.
    /// A stale hunk throws and changes nothing; the diff reloads.
    public func revertHunk(_ hunkIndex: Int, in file: DiffFile) async throws {
        guard file.hunks.indices.contains(hunkIndex) else { return }
        let hunk = file.hunks[hunkIndex]
        let copy = WorkingCopy(root: directory)
        do {
            let plan = try await copy.planHunkRevertOffMain(path: file.path, hunks: [hunk])
            let written = try await copy.applyOffMain([plan])
            reportChange(name: "Revert Hunk", message: "Reverted a change in \((file.path as NSString).lastPathComponent)", copy: copy, written: written)
        } catch {
            load()
            throw error
        }
    }

    /// Reverts a file in the current scope (see `revertTitle`). Turn scope reverts only the turn's hunks, keeping
    /// later edits; uncommitted restores HEAD; branch restores the merge-base version.
    public func revertFile(_ path: String) async throws {
        guard let file = diffFiles.first(where: { $0.path == path }) else { return }
        let copy = WorkingCopy(root: directory)
        let plan: FileChangePlan
        do {
            switch scope {
            case .commit:
                return
            case .turn:
                plan = try await copy.planHunkRevertOffMain(path: path, hunks: file.hunks)
            case .uncommitted:
                try await verifyUnchanged(file, copy: copy)
                let hasHead = try await repository.repository.resolves("HEAD")
                let original = hasHead && file.status != .added ? try await repository.repository.content(at: "HEAD", path: file.oldPath ?? path) : nil
                plan = copy.planRestore(path: path, to: original)
            case .branch:
                try await verifyUnchanged(file, copy: copy)
                guard let base = baseBranch, let mergeBase = try await repository.repository.mergeBase(base, "HEAD") else {
                    throw GitError.failed(command: "merge-base", status: 1, message: "The base branch was not found.")
                }
                let original = file.status == .added ? nil : try await repository.repository.content(at: mergeBase, path: file.oldPath ?? path)
                plan = copy.planRestore(path: path, to: original)
            }
            let written = try await copy.applyOffMain([plan])
            reportChange(name: "Revert File", message: "\(revertTitle(for: path) ?? "Reverted") — done", copy: copy, written: written)
        } catch {
            load()
            throw error
        }
    }

    /// The working copy must still hold the new side the diff showed (else the user changed it since: refresh).
    private func verifyUnchanged(_ file: DiffFile, copy: WorkingCopy) async throws {
        guard let lines = file.newLines else { return }
        let snapshot = await copy.snapshotOffMain([file.path])[0]
        let shown = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        if let text = snapshot.text, text != shown, text.trimmingCharacters(in: .newlines) != shown.trimmingCharacters(in: .newlines) {
            throw WorkingCopyError.changedOnDisk(file.path)
        }
    }

    private func reportChange(name: String, message: String, copy: WorkingCopy, written: [FileChangePlan]) {
        repository.refresh()
        load()
        guard !written.isEmpty else { return }
        let reapply = written
        onReversibleChange?(
            ReversibleChange(
                name: name, message: message,
                undo: { [weak self] in
                    try await copy.undoOffMain(reapply)
                    self?.repository.refresh()
                    self?.load()
                },
                redo: { [weak self] in
                    _ = try await copy.applyOffMain(reapply)
                    self?.repository.refresh()
                    self?.load()
                }))
    }

    // MARK: Turn revert

    /// Plans reverting a whole turn (nothing changes yet).
    public func planTurnRevert(_ messageID: MessageID) async throws -> GitService.TurnRevertPlan {
        guard let sessionID else { throw EngineError.offline }
        return try await git.planTurnRevert(sessionID: sessionID, messageID: messageID, directory: directory)
    }

    /// Performs a planned turn revert: `agentChangesOnly` keeps later edits (hunk revert), otherwise opencode's
    /// snapshot revert restores whole files. Either way Undo puts back the exact pre-revert bytes.
    public func performTurnRevert(_ plan: GitService.TurnRevertPlan, agentChangesOnly: Bool) async throws {
        let applied = try await agentChangesOnly ? git.revertTurnAgentChanges(plan) : git.revertTurnWithSnapshot(plan)
        repository.refresh()
        load()
        let git = git
        onReversibleChange?(
            ReversibleChange(
                name: "Revert Turn", message: "Reverted the turn (\(plan.files.count) file\(plan.files.count == 1 ? "" : "s"))",
                undo: { [weak self] in
                    try await git.undoTurnRevert(applied)
                    self?.load()
                },
                redo: { [weak self] in
                    _ = try await agentChangesOnly ? git.revertTurnAgentChanges(plan) : git.revertTurnWithSnapshot(plan)
                    self?.load()
                }))
    }

    // MARK: Stage, commit, push

    public func setStaged(_ paths: [String], staged: Bool) async {
        do {
            if staged { try await repository.stage(paths) } else { try await repository.unstage(paths) }
            load()
            onReversibleChange?(
                ReversibleChange(
                    name: staged ? "Stage" : "Unstage", message: "\(staged ? "Staged" : "Unstaged") \(paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "\(paths.count) files")",
                    undo: { [weak self] in
                        if staged { try await self?.repository.unstage(paths) } else { try await self?.repository.stage(paths) }
                        self?.load()
                    },
                    redo: { [weak self] in
                        if staged { try await self?.repository.stage(paths) } else { try await self?.repository.unstage(paths) }
                        self?.load()
                    }))
        } catch {
            actionError = Self.describe(error)
        }
    }

    public var canCommit: Bool {
        busy == nil && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.contains { $0.staged != nil }
    }

    /// Commits the staged changes with `commitMessage` (the message's first line is the subject).
    @discardableResult
    public func commit() async -> Bool {
        guard canCommit else { return false }
        busy = "Committing…"
        defer { busy = nil }
        do {
            try await repository.commit(message: commitMessage)
            commitMessage = ""
            load()
            return true
        } catch {
            actionError = Self.describe(error)
            return false
        }
    }

    /// The default commit message (a hook for a generated one later): the staged files' names.
    public func suggestedCommitMessage() -> String {
        let staged = files.filter { $0.staged != nil }.map { ($0.path as NSString).lastPathComponent }
        guard !staged.isEmpty else { return "" }
        return "Update " + (staged.count <= 3 ? staged.joined(separator: ", ") : "\(staged.prefix(2).joined(separator: ", ")) and \(staged.count - 2) more")
    }

    public func push() async -> Bool {
        busy = "Pushing…"
        defer { busy = nil }
        do {
            try await repository.push()
            return true
        } catch {
            actionError = Self.describe(error)
            return false
        }
    }

    public func pullRequestURL() async -> URL? { await repository.pullRequestURL() }
}
