import Foundation

/// What sits at a path: a regular file, or a symbolic link (whose `data` is its target path, never followed). With
/// no data, `regular` (or `symlink`) means nothing is there; the other kinds describe an entry whose content a file
/// operation cannot take: a directory, something else (a FIFO, a socket, a path that goes through a link), or an
/// entry that could not be read. Missing, unreadable and unsupported entries are kept apart (A14).
public enum FileEntryKind: Sendable, Hashable {
    case regular
    case symlink
    case directory
    case unsupported
    case unreadable
}

/// A file's bytes at one moment (nil: the file did not exist), for version checks and Undo.
public struct FileSnapshot: Sendable, Hashable {
    /// Repository-relative path.
    public var path: String
    public var data: Data?
    public var permissions: Int?
    public var kind: FileEntryKind = .regular

    public init(path: String, data: Data?, permissions: Int?, kind: FileEntryKind = .regular) {
        self.path = path
        self.data = data
        self.permissions = permissions
        self.kind = kind
    }

    public var exists: Bool { data != nil }
    /// Something is at the path that has no content a file operation can take (a directory, a special file, a path
    /// through a link, an unreadable entry).
    public var isOpaque: Bool { data == nil && (kind == .directory || kind == .unsupported || kind == .unreadable) }

    /// The state compared by the compare-and-swap: content and kind, or what kind of opaque entry, or missing.
    var state: State {
        if let data { return .content(data, kind) }
        switch kind {
        case .directory, .unsupported, .unreadable: return .opaque(kind)
        case .regular, .symlink: return .missing
        }
    }

    enum State: Hashable {
        case missing
        case content(Data, FileEntryKind)
        case opaque(FileEntryKind)
    }
    public var text: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
}

/// One planned file change: from `before` (verified again just before writing) to `after` (nil deletes the file).
/// `afterKind` and `afterPermissions` carry a Git entry's type and mode (a symlink, the executable bit); nil
/// permissions keep the current file's (R26).
public struct FileChangePlan: Sendable, Hashable {
    public var before: FileSnapshot
    public var after: Data?
    public var afterKind: FileEntryKind = .regular
    public var afterPermissions: Int?
    public var path: String { before.path }

    public init(before: FileSnapshot, after: Data?, afterKind: FileEntryKind = .regular, afterPermissions: Int? = nil) {
        self.before = before
        self.after = after
        self.afterKind = afterKind
        self.afterPermissions = afterPermissions
    }

    /// Whether writing this plan changes anything (bytes, entry type, or mode).
    public var changesSomething: Bool {
        guard let after else { return before.data != nil && before.kind != .directory }
        guard let old = before.data else { return true }
        if old != after || before.kind != afterKind { return true }
        if afterKind == .regular, let afterPermissions, let current = before.permissions { return (afterPermissions & 0o7777) != (current & 0o7777) }
        return false
    }

    /// The plan that puts `before` back where this plan's result now is.
    var inverse: FileChangePlan {
        FileChangePlan(
            before: FileSnapshot(path: path, data: after, permissions: afterPermissions ?? before.permissions, kind: afterKind),
            after: before.data, afterKind: before.kind, afterPermissions: before.permissions)
    }
}

public enum WorkingCopyError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The file changed after it was read; nothing was written.
    case changedOnDisk(String)
    /// The file is not UTF-8 text (hunk operations need text).
    case notText(String)
    case tooLarge(String)
    /// One or more hunks no longer match the file.
    case hunks(path: String, HunkApplyError)
    case writeFailed(String)
    /// The path goes through a link or holds something that is not a file; nothing was written there (A05).
    case unsupported(String)

    public var description: String { userMessage }

    public var userMessage: String {
        switch self {
        case .changedOnDisk(let path): "\(path) changed on disk; refresh and try again."
        case .notText(let path): "\(path) is not a text file."
        case .tooLarge(let path): "\(path) is too large to edit here."
        case .hunks(let path, let error): "\(path): \(error.description) Refresh the diff and try again."
        case .writeFailed(let path): "\(path) could not be written."
        case .unsupported(let path): "\(path) goes through a link or is not a regular file, so BelloCode will not write it."
        }
    }
}

/// Reads and writes files of one working tree for revert operations. Writes are all-or-nothing across files and each
/// is a compare-and-swap against the bytes the plan was made from (see `replace`), so a concurrent edit (by the user
/// or an agent) is never overwritten, including one saved after the preflight check. Synchronous: call it from off-main work (`@concurrent` helpers below).
public struct WorkingCopy: Sendable {
    public let root: String
    /// Files above this size are refused for text operations.
    public static let textLimit = 16 << 20

    /// Test seam: runs just before each file is replaced (after the preflight check), so tests can force a
    /// concurrent edit deterministically. Nil in production.
    let beforeReplace: (@Sendable (String) -> Void)?

    public init(root: String) { self.init(root: root, beforeReplace: nil) }

    init(root: String, beforeReplace: (@Sendable (String) -> Void)?) {
        self.root = root
        self.beforeReplace = beforeReplace
    }

    /// The entry at `path`, never following a symbolic link (a link's data is its target path). The path is walked
    /// from the root one directory at a time without following links: a path through a link snapshots as
    /// `unsupported`, never as the file the link leads to.
    public func snapshot(_ path: String) -> FileSnapshot {
        switch entry(path) {
        case .regular(let data, let permissions): FileSnapshot(path: path, data: data, permissions: permissions, kind: .regular)
        case .symlink(let target): FileSnapshot(path: path, data: Data(target.utf8), permissions: nil, kind: .symlink)
        case .missing: FileSnapshot(path: path, data: nil, permissions: nil)
        case .directory: FileSnapshot(path: path, data: nil, permissions: nil, kind: .directory)
        case .other: FileSnapshot(path: path, data: nil, permissions: nil, kind: .unsupported)
        case .unreadable: FileSnapshot(path: path, data: nil, permissions: nil, kind: .unreadable)
        }
    }

    private func entry(_ path: String) -> ConfinedDirectory.Entry {
        guard let components = ConfinedDirectory.components(path) else { return .other }
        switch ConfinedDirectory.open(root: root, components.dropLast(), create: false) {
        case .success(let parent): return parent.entry(components[components.count - 1])
        case .failure(.missing): return .missing
        case .failure(.link): return .other
        case .failure(.unreadable): return .unreadable
        }
    }

    /// The file's text and its snapshot; throws for non-UTF-8 or oversized files.
    public func text(_ path: String) throws -> (String, FileSnapshot) {
        let snapshot = snapshot(path)
        guard let data = snapshot.data else { return ("", snapshot) }
        guard data.count <= Self.textLimit else { throw WorkingCopyError.tooLarge(path) }
        guard let text = String(data: data, encoding: .utf8) else { throw WorkingCopyError.notText(path) }
        return (text, snapshot)
    }

    /// A plan that reverts `hunks` (changes present in the file) and keeps every other line, including the user's.
    public func planHunkRevert(path: String, hunks: [PatchHunk]) throws -> FileChangePlan {
        let (current, snapshot) = try text(path)
        do {
            let reverted = try HunkApplier.revert(hunks, in: current)
            return FileChangePlan(before: snapshot, after: Data(reverted.utf8))
        } catch let error as HunkApplyError {
            throw WorkingCopyError.hunks(path: path, error)
        }
    }

    /// A plan that sets the file to `content` (nil deletes it).
    public func planRestore(path: String, to content: Data?) -> FileChangePlan {
        FileChangePlan(before: snapshot(path), after: content)
    }

    /// Applies plans: verifies every file first, then replaces each with a compare-and-swap (`replace`), so an edit
    /// made after the preflight check is never overwritten. If a file changed or a write fails, the files already
    /// written are put back with the same check: a file edited again since we wrote it keeps that edit.
    /// Returns the plans that changed something (their `before` is the Undo state).
    ///
    /// Deletions run first, deepest path first, then writes, shallowest first, so a file can replace a directory whose
    /// files are deleted in the same batch (and the other way round), and a rollback undoes them in reverse (N17).
    @discardableResult
    public func apply(_ plans: [FileChangePlan]) throws -> [FileChangePlan] {
        let deleted = Set(plans.filter { $0.after == nil && $0.before.data != nil }.map(\.path))
        var plans = plans
        for index in plans.indices {
            let plan = plans[index]
            // An entry that is not a file (or goes through a link) is never written: refuse before anything changes.
            if plan.before.kind == .unsupported || plan.before.kind == .unreadable || ConfinedDirectory.components(plan.path) == nil {
                throw WorkingCopyError.unsupported(plan.path)
            }
            let now = snapshot(plan.path)
            if now.state == plan.before.state { continue }
            // A file planned where a directory now is (the Undo of a directory→file restore): accepted when this batch
            // deletes files below it; the directory is removed only once nothing but empty directories is left.
            if plan.before.state == .missing, plan.after != nil, now.kind == .directory, deleted.contains(where: { $0.hasPrefix(plan.path + "/") }) {
                plans[index].before = FileSnapshot(path: plan.path, data: nil, permissions: plan.before.permissions, kind: .directory)
                continue
            }
            throw WorkingCopyError.changedOnDisk(plan.path)
        }
        let depth = { (plan: FileChangePlan) in plan.path.split(separator: "/").count }
        let deletions = plans.filter { $0.after == nil }.sorted { depth($0) > depth($1) }
        let writes = plans.filter { $0.after != nil }.sorted { depth($0) < depth($1) }
        var written: [FileChangePlan] = []
        do {
            for plan in deletions + writes where plan.changesSomething {
                beforeReplace?(plan.path)
                try replace(plan)
                written.append(plan)
            }
        } catch {
            for plan in written.reversed() { try? replace(plan.inverse) }
            throw error
        }
        return written
    }

    /// Undo of `apply`: restores each file's exact `before` bytes and permissions, but only where the file still holds
    /// what was written; otherwise it refuses and changes nothing.
    public func undo(_ applied: [FileChangePlan]) throws {
        try apply(applied.map(\.inverse))
    }

    /// Replaces one file only if it still holds `plan.before`, as a compare-and-swap built on `renamex_np`:
    /// - create: the new file is renamed into place with `RENAME_EXCL`, which fails if anything appeared at the path;
    /// - replace: the new file is atomically swapped with the current one (`RENAME_SWAP`), and the bytes swapped out are
    ///   compared with `before`; on a mismatch they are swapped back, so the other writer's version stays;
    /// - delete: the file is renamed aside, compared, and renamed back (`RENAME_EXCL`) on a mismatch.
    /// Every write that completed before the swap is detected. A writer that still holds the old file open and writes
    /// into it after the swap cannot be serialized without its cooperation (editors and agents do not coordinate); the
    /// window is the few microseconds between the swap and the comparison.
    ///
    /// Every step acts through a descriptor of the file's parent directory, reached from the root without following
    /// links (`ConfinedDirectory`), so a directory swapped for a link after planning is refused, never written through
    /// (A05). A directory planned to be replaced by a file is removed only while it holds nothing but empty
    /// directories.
    private func replace(_ plan: FileChangePlan) throws {
        guard let components = ConfinedDirectory.components(plan.path) else { throw WorkingCopyError.unsupported(plan.path) }
        let name = components[components.count - 1]
        let aside = ".\(name).bellocode-\(UUID().uuidString)"
        let creating = plan.before.data == nil
        let parent: ConfinedDirectory
        switch ConfinedDirectory.open(root: root, components.dropLast(), create: creating && plan.after != nil) {
        case .success(let directory): parent = directory
        case .failure(.link): throw WorkingCopyError.unsupported(plan.path)
        case .failure(.missing): if plan.after == nil { return } else { throw WorkingCopyError.changedOnDisk(plan.path) }
        case .failure(.unreadable): throw WorkingCopyError.writeFailed(plan.path)
        }
        func holds(_ entry: String, _ data: Data, kind: FileEntryKind) -> Bool {
            switch parent.entry(entry) {
            case .regular(let bytes, _): kind == .regular && bytes == data
            case .symlink(let target): kind == .symlink && Data(target.utf8) == data
            default: false
            }
        }
        func writeTemporary(_ data: Data) throws {
            let link: String?
            if plan.afterKind == .symlink {
                guard let target = String(data: data, encoding: .utf8) else { throw WorkingCopyError.writeFailed(plan.path) }
                link = target
            } else {
                link = nil
            }
            let permissions = plan.afterPermissions ?? plan.before.permissions ?? 0o644
            guard parent.create(aside, data: data, permissions: permissions, link: link) else { throw WorkingCopyError.writeFailed(plan.path) }
        }
        switch (plan.before.data, plan.after) {
        case (nil, nil):
            return
        case (nil, let new?):
            if plan.before.kind == .directory {
                // Files below it were deleted first; only empty directories may remain.
                guard parent.removeEmptyTree(name) else { throw WorkingCopyError.changedOnDisk(plan.path) }
            }
            try writeTemporary(new)
            let code = parent.rename(aside, name, flags: UInt32(RENAME_EXCL))
            if code != 0 {
                parent.remove(aside)
                throw code == EEXIST ? WorkingCopyError.changedOnDisk(plan.path) : WorkingCopyError.writeFailed(plan.path)
            }
        case (let old?, let new?):
            try writeTemporary(new)
            let code = parent.rename(aside, name, flags: UInt32(RENAME_SWAP))
            if code != 0 {
                parent.remove(aside)
                throw code == ENOENT ? WorkingCopyError.changedOnDisk(plan.path) : WorkingCopyError.writeFailed(plan.path)
            }
            // `aside` now holds what was at the path an instant ago.
            if !holds(aside, old, kind: plan.before.kind) {
                _ = parent.rename(aside, name, flags: UInt32(RENAME_SWAP))
                // Drop our bytes only if `aside` really holds them again; otherwise keep it for recovery.
                if holds(aside, new, kind: plan.afterKind) { parent.remove(aside) }
                throw WorkingCopyError.changedOnDisk(plan.path)
            }
            parent.remove(aside)
        case (let old?, nil):
            let code = parent.rename(name, aside, flags: UInt32(RENAME_EXCL))
            if code != 0 { throw code == ENOENT ? WorkingCopyError.changedOnDisk(plan.path) : WorkingCopyError.writeFailed(plan.path) }
            if !holds(aside, old, kind: plan.before.kind) {
                // Put it back; if something new appeared at the path meanwhile, both are kept (`aside` stays).
                _ = parent.rename(aside, name, flags: UInt32(RENAME_EXCL))
                throw WorkingCopyError.changedOnDisk(plan.path)
            }
            parent.remove(aside)
        }
    }
}

extension WorkingCopy {
    @concurrent public func snapshotOffMain(_ paths: [String]) async -> [FileSnapshot] { paths.map(snapshot) }
    @concurrent public func applyOffMain(_ plans: [FileChangePlan]) async throws -> [FileChangePlan] { try apply(plans) }
    @concurrent public func undoOffMain(_ applied: [FileChangePlan]) async throws { try undo(applied) }
    @concurrent public func planHunkRevertOffMain(path: String, hunks: [PatchHunk]) async throws -> FileChangePlan {
        try planHunkRevert(path: path, hunks: hunks)
    }
}
