import Foundation

/// What sits at a path: a regular file, or a symbolic link (whose `data` is its target path, never followed).
public enum FileEntryKind: Sendable, Hashable {
    case regular
    case symlink
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
        guard let after else { return before.data != nil }
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

    public var description: String { userMessage }

    public var userMessage: String {
        switch self {
        case .changedOnDisk(let path): "\(path) changed on disk; refresh and try again."
        case .notText(let path): "\(path) is not a text file."
        case .tooLarge(let path): "\(path) is too large to edit here."
        case .hunks(let path, let error): "\(path): \(error.description) Refresh the diff and try again."
        case .writeFailed(let path): "\(path) could not be written."
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

    func url(_ path: String) -> URL { URL(filePath: root, directoryHint: .isDirectory).appending(path: path) }

    /// The entry at `path`, never following a symbolic link (a link's data is its target path).
    public func snapshot(_ path: String) -> FileSnapshot {
        let entry = Self.entry(at: url(path))
        return FileSnapshot(path: path, data: entry?.data, permissions: entry?.permissions, kind: entry?.kind ?? .regular)
    }

    static func entry(at url: URL) -> (kind: FileEntryKind, data: Data, permissions: Int?)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let permissions = attributes[.posixPermissions] as? Int
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
            return (.symlink, Data(destination.utf8), nil)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular, let data = try? Data(contentsOf: url) else { return nil }
        return (.regular, data, permissions)
    }

    /// Whether `url` holds exactly `data` as an entry of `kind` (a link is compared by its target, not followed).
    private static func holds(_ url: URL, _ data: Data, kind: FileEntryKind) -> Bool {
        guard let entry = entry(at: url) else { return false }
        return entry.kind == kind && entry.data == data
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
    @discardableResult
    public func apply(_ plans: [FileChangePlan]) throws -> [FileChangePlan] {
        for plan in plans {
            let now = snapshot(plan.path)
            if now.data != plan.before.data || (now.data != nil && now.kind != plan.before.kind) { throw WorkingCopyError.changedOnDisk(plan.path) }
        }
        var written: [FileChangePlan] = []
        do {
            for plan in plans where plan.changesSomething {
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
    private func replace(_ plan: FileChangePlan) throws {
        let target = url(plan.path)
        let directory = target.deletingLastPathComponent()
        let aside = directory.appending(path: ".\(target.lastPathComponent).bellocode-\(UUID().uuidString)")
        switch (plan.before.data, plan.after) {
        case (nil, nil):
            return
        case (nil, let new?):
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch {
                throw WorkingCopyError.writeFailed(plan.path)
            }
            try writeTemporary(new, kind: plan.afterKind, to: aside, permissions: plan.afterPermissions ?? plan.before.permissions, path: plan.path)
            if rename(aside, target, flags: UInt32(RENAME_EXCL)) != 0 {
                let code = errno
                try? FileManager.default.removeItem(at: aside)
                throw code == EEXIST ? WorkingCopyError.changedOnDisk(plan.path) : WorkingCopyError.writeFailed(plan.path)
            }
        case (let old?, let new?):
            try writeTemporary(new, kind: plan.afterKind, to: aside, permissions: plan.afterPermissions ?? plan.before.permissions, path: plan.path)
            if rename(aside, target, flags: UInt32(RENAME_SWAP)) != 0 {
                let code = errno
                try? FileManager.default.removeItem(at: aside)
                throw code == ENOENT ? WorkingCopyError.changedOnDisk(plan.path) : WorkingCopyError.writeFailed(plan.path)
            }
            // `aside` now holds what was at the path an instant ago.
            if !Self.holds(aside, old, kind: plan.before.kind) {
                _ = rename(aside, target, flags: UInt32(RENAME_SWAP))
                // Drop our bytes only if `aside` really holds them again; otherwise keep it for recovery.
                if Self.holds(aside, new, kind: plan.afterKind) { try? FileManager.default.removeItem(at: aside) }
                throw WorkingCopyError.changedOnDisk(plan.path)
            }
            try? FileManager.default.removeItem(at: aside)
        case (let old?, nil):
            if rename(target, aside, flags: UInt32(RENAME_EXCL)) != 0 {
                throw errno == ENOENT ? WorkingCopyError.changedOnDisk(plan.path) : WorkingCopyError.writeFailed(plan.path)
            }
            if !Self.holds(aside, old, kind: plan.before.kind) {
                // Put it back; if something new appeared at the path meanwhile, both are kept (`aside` stays).
                _ = rename(aside, target, flags: UInt32(RENAME_EXCL))
                throw WorkingCopyError.changedOnDisk(plan.path)
            }
            try? FileManager.default.removeItem(at: aside)
        }
    }

    private func rename(_ from: URL, _ to: URL, flags: UInt32) -> Int32 {
        from.withUnsafeFileSystemRepresentation { source in
            to.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { errno = EINVAL; return -1 }
                return renamex_np(source, destination, flags)
            }
        }
    }

    private func writeTemporary(_ data: Data, kind: FileEntryKind, to url: URL, permissions: Int?, path: String) throws {
        do {
            if kind == .symlink {
                guard let destination = String(data: data, encoding: .utf8), !destination.isEmpty, !destination.contains("\0") else {
                    throw WorkingCopyError.writeFailed(path)
                }
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
                return
            }
            try data.write(to: url, options: .withoutOverwriting)
            if let permissions { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw WorkingCopyError.writeFailed(path)
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
