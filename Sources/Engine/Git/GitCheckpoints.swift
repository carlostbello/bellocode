import BelloCore
import Foundation

/// Per-turn checkpoints (T3 Code: "hidden-ref snapshot per turn"): before a turn starts, the whole working tree,
/// untracked files included and ignored files excluded, is written as a commit under
/// `refs/bellocode/checkpoints/<session>/<message>` without touching the real index, HEAD or any branch (a temporary
/// index inside the git directory). Rewinding with "Revert Files Too" restores the tree of the checkpoint taken before
/// the chosen message; every file is written with `WorkingCopy`'s compare-and-swap, so an edit saved while the restore
/// runs is never overwritten (the restore fails and puts back what it wrote), and the state just before the restore is
/// itself captured so Undo returns it byte for byte.
public enum GitCheckpoints {
    public static let refPrefix = "refs/bellocode/checkpoints/"

    public static func ref(session: SessionID, message: MessageID) -> String {
        refPrefix + safe(session.rawValue) + "/" + safe(message.rawValue)
    }

    static func safe(_ component: String) -> String {
        String(component.unicodeScalars.map { scalar -> Character in
            let character = Character(scalar)
            return character.isLetter || character.isNumber || character == "_" || character == "-" ? character : "_"
        }.prefix(80))
    }

    /// Captures the working tree of `directory` under `ref`; returns the checkpoint commit (nil outside a repository).
    @concurrent
    public static func capture(directory: String, ref: String, runner: GitRunner) async throws -> String? {
        let repository = GitRepository(directory: directory, runner: runner)
        guard let location = try await repository.location() else { return nil }
        let index = (location.gitDirectory as NSString).appendingPathComponent("bellocode-checkpoint-\(UUID().uuidString).index")
        defer { try? FileManager.default.removeItem(atPath: index) }
        var scoped = runner
        scoped.environment["GIT_INDEX_FILE"] = index
        for (key, value) in ["GIT_AUTHOR_NAME": "BelloCode", "GIT_AUTHOR_EMAIL": "checkpoint@bellocode.invalid",
                             "GIT_COMMITTER_NAME": "BelloCode", "GIT_COMMITTER_EMAIL": "checkpoint@bellocode.invalid"] {
            scoped.environment[key] = value
        }
        let temporary = GitRepository(directory: location.root, runner: scoped)
        let head = try await repository.revParse("HEAD")
        _ = try await temporary.git(head == nil ? ["read-tree", "--empty"] : ["read-tree", "HEAD"])
        _ = try await temporary.git(["add", "-A", "--", "."], timeout: .seconds(120))
        let tree = try await temporary.git(["write-tree"]).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try await temporary.git(
            ["commit-tree", tree] + (head.map { ["-p", $0] } ?? []), input: Data("BelloCode checkpoint\n".utf8)
        ).text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await repository.git(["update-ref", ref, commit])
        return commit
    }

    /// The checkpoint commit of `ref`, if it exists.
    public static func resolve(_ ref: String, directory: String, runner: GitRunner) async -> String? {
        try? await GitRepository(directory: directory, runner: runner).revParse(ref)
    }

    /// Deletes every checkpoint of `session` (thread deleted).
    public static func deleteAll(session: SessionID, directory: String, runner: GitRunner) async {
        let repository = GitRepository(directory: directory, runner: runner)
        let prefix = refPrefix + safe(session.rawValue) + "/"
        guard let refs = try? await repository.git(["for-each-ref", "--format=%(refname)", prefix]).text else { return }
        for ref in refs.split(separator: "\n").prefix(2_000) { _ = try? await repository.git(["update-ref", "-d", String(ref)]) }
    }

    // MARK: Restore

    /// What restoring a checkpoint would write, checked against the working copy before anything is touched.
    public struct RestorePlan: Sendable {
        public var directory: String
        public var checkpoint: String
        /// The state just before the restore (captured; Undo writes it back).
        public var undoCheckpoint: String
        public var changes: [FileChangePlan]
        public var paths: [String] { changes.map(\.path) }
    }

    /// Plans restoring `checkpoint`: captures the current state (`undoRef`), lists the files that differ and reads
    /// both sides. Nothing in the working tree changes.
    @concurrent
    public static func planRestore(directory: String, checkpoint: String, undoRef: String, runner: GitRunner) async throws -> RestorePlan {
        guard let current = try await capture(directory: directory, ref: undoRef, runner: runner) else { throw GitError.notARepository(directory) }
        let repository = GitRepository(directory: directory, runner: runner)
        guard let root = try await repository.location()?.root else { throw GitError.notARepository(directory) }
        let names = try await repository.git(["diff", "--name-only", "-z", "--no-renames", checkpoint, current]).stdout
        let copy = WorkingCopy(root: root)
        var changes: [FileChangePlan] = []
        for path in GitStatusParser.split(names).prefix(5_000) {
            try Task.checkCancellation()
            let target = try await repository.content(at: checkpoint, path: path)
            changes.append(copy.planRestore(path: path, to: target))
        }
        return RestorePlan(directory: root, checkpoint: checkpoint, undoCheckpoint: current, changes: changes)
    }

    /// Writes the plan (all or nothing, compare-and-swap per file). Returns what was written (the Undo state).
    public static func apply(_ plan: RestorePlan) async throws -> [FileChangePlan] {
        try await WorkingCopy(root: plan.directory).applyOffMain(plan.changes)
    }

    /// Undo of `apply`: each file gets its exact earlier bytes back, only where it still holds what the restore wrote.
    public static func undo(_ written: [FileChangePlan], directory: String) async throws {
        try await WorkingCopy(root: directory).undoOffMain(written)
    }
}
