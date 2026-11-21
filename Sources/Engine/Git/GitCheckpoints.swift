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

    /// The most files one restore plans. Beyond it the plan is refused (never silently cut, R26).
    public static let restoreLimit = 5_000

    /// Plans restoring `checkpoint`: captures the current state (`undoRef`), lists the entries that differ and reads
    /// both sides. Modes are checked on both sides first, and missing, unreadable and unsupported entries are told
    /// apart. Nothing in the working tree changes. The plan is complete or it throws (`RestoreError`): every
    /// differing path is planned with the checkpoint's entry type and mode (regular, executable, symlink), and
    /// entries a file restore cannot reproduce (submodules) or more than `restoreLimit` paths are refused, so the
    /// conversation is never rewound over a partial restore (R26).
    @concurrent
    public static func planRestore(directory: String, checkpoint: String, undoRef: String, runner: GitRunner,
                                   limit: Int = restoreLimit) async throws -> RestorePlan {
        guard let current = try await capture(directory: directory, ref: undoRef, runner: runner) else { throw GitError.notARepository(directory) }
        let repository = GitRepository(directory: directory, runner: runner)
        guard let root = try await repository.location()?.root else { throw GitError.notARepository(directory) }
        // `--raw`: ":<checkpoint mode> <current mode> <sha> <sha> <status>\0<path>\0" per entry.
        let raw = try await repository.git(["diff", "--raw", "-z", "--no-renames", "--no-abbrev", checkpoint, current]).stdout
        let entries = try RawDiffEntry.parse(raw)
        guard entries.count <= limit else { throw RestoreError.tooManyFiles(count: entries.count, limit: limit) }
        // Both sides are checked before anything is read: an entry a file restore cannot reproduce or remove (a
        // submodule added since the checkpoint as much as one deleted) refuses the whole plan (A14, N17).
        for entry in entries {
            for mode in [entry.targetMode, entry.currentMode] where !Self.fileModes.contains(mode) {
                throw RestoreError.unsupportedEntry(path: entry.path, mode: mode)
            }
        }
        let copy = WorkingCopy(root: root)
        var changes: [FileChangePlan] = []
        for entry in entries {
            try Task.checkCancellation()
            let before = copy.snapshot(entry.path)
            switch before.kind {
            case .unreadable:
                throw RestoreError.unreadable(entry.path)
            case .unsupported:
                throw RestoreError.notAFile(entry.path)
            case .directory where entry.currentMode != "000000" || entry.targetMode == "000000":
                throw RestoreError.notAFile(entry.path)
            default:
                // A directory here is a file↔directory change: its files are other entries of this plan, deleted
                // before the file is written (`WorkingCopy.apply`).
                break
            }
            switch entry.targetMode {
            case "000000":
                changes.append(FileChangePlan(before: before, after: nil))
            case "100644", "100755", "120000":
                guard let target = try await repository.content(at: checkpoint, path: entry.path) else {
                    throw RestoreError.unreadable(entry.path)
                }
                if entry.targetMode == "120000" {
                    changes.append(FileChangePlan(before: before, after: target, afterKind: .symlink))
                } else {
                    let executable = entry.targetMode == "100755"
                    changes.append(FileChangePlan(
                        before: before, after: target, afterKind: .regular,
                        afterPermissions: Self.permissions(executable: executable, current: before.kind == .regular ? before.permissions : nil)))
                }
            default:
                throw RestoreError.unsupportedEntry(path: entry.path, mode: entry.targetMode)
            }
        }
        return RestorePlan(directory: root, checkpoint: checkpoint, undoCheckpoint: current, changes: changes)
    }

    /// The entry modes a file restore reproduces: none, regular, executable, symlink.
    static let fileModes: Set<String> = ["000000", "100644", "100755", "120000"]

    /// Git records only the executable bit: keep the file's other bits, add or remove execute where it is readable.
    static func permissions(executable: Bool, current: Int?) -> Int {
        guard let current else { return executable ? 0o755 : 0o644 }
        let base = current & 0o7666
        return executable ? base | ((current & 0o444) >> 2) | 0o100 : base
    }

    /// One entry of `git diff --raw -z`.
    struct RawDiffEntry: Equatable {
        var targetMode: String
        var currentMode: String
        var path: String

        static func parse(_ data: Data) throws -> [RawDiffEntry] {
            let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            var entries: [RawDiffEntry] = []
            var index = 0
            while index < fields.count {
                let header = fields[index]
                if header.isEmpty { index += 1; continue }
                guard header.hasPrefix(":"), index + 1 < fields.count else { throw RestoreError.unreadable(header) }
                let parts = header.dropFirst().split(separator: " ")
                guard parts.count >= 5 else { throw RestoreError.unreadable(header) }
                entries.append(RawDiffEntry(targetMode: String(parts[0]), currentMode: String(parts[1]), path: fields[index + 1]))
                index += 2
            }
            return entries
        }
    }

    public enum RestoreError: Error, Sendable, Equatable, CustomStringConvertible {
        case tooManyFiles(count: Int, limit: Int)
        case unsupportedEntry(path: String, mode: String)
        case unreadable(String)
        /// The path holds something that is not a file, or goes through a link.
        case notAFile(String)

        public var description: String { userMessage }

        public var userMessage: String {
            switch self {
            case .tooManyFiles(let count, let limit):
                "\(count) files differ from the checkpoint, more than BelloCode restores at once (\(limit)). Nothing was changed; rewind without restoring files, or restore them with git."
            case .unsupportedEntry(let path, let mode):
                "\(path) is a \(mode == "160000" ? "submodule" : "Git entry of mode \(mode)") that a file restore cannot reproduce. Nothing was changed; rewind without restoring files."
            case .unreadable(let path):
                "\(path) could not be read from the checkpoint. Nothing was changed."
            case .notAFile(let path):
                "\(path) is not a regular file or goes through a link, so a file restore cannot reproduce it. Nothing was changed; rewind without restoring files."
            }
        }
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
