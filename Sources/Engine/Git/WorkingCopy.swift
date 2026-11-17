import Foundation

/// A file's bytes at one moment (nil: the file did not exist), for version checks and Undo.
public struct FileSnapshot: Sendable, Hashable {
    /// Repository-relative path.
    public var path: String
    public var data: Data?
    public var permissions: Int?

    public var exists: Bool { data != nil }
    public var text: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
}

/// One planned file change: from `before` (verified again just before writing) to `after` (nil deletes the file).
public struct FileChangePlan: Sendable, Hashable {
    public var before: FileSnapshot
    public var after: Data?
    public var path: String { before.path }
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
/// is preceded by a check that the file still holds the bytes the plan was made from, so a concurrent edit (by the
/// user or an agent) is never overwritten. Synchronous: call it from off-main work (`@concurrent` helpers below).
public struct WorkingCopy: Sendable {
    public let root: String
    /// Files above this size are refused for text operations.
    public static let textLimit = 16 << 20

    public init(root: String) { self.root = root }

    func url(_ path: String) -> URL { URL(filePath: root, directoryHint: .isDirectory).appending(path: path) }

    public func snapshot(_ path: String) -> FileSnapshot {
        let url = url(path)
        let data = try? Data(contentsOf: url)
        let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        return FileSnapshot(path: path, data: data, permissions: permissions)
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

    /// Applies plans: verifies every file first, then writes; if a write fails, the files already written are put back.
    /// Returns the plans that changed something (their `before` is the Undo state).
    @discardableResult
    public func apply(_ plans: [FileChangePlan]) throws -> [FileChangePlan] {
        for plan in plans where snapshot(plan.path).data != plan.before.data { throw WorkingCopyError.changedOnDisk(plan.path) }
        var written: [FileChangePlan] = []
        do {
            for plan in plans where plan.before.data != plan.after {
                try write(plan.path, plan.after, permissions: plan.before.permissions)
                written.append(plan)
            }
        } catch {
            for plan in written.reversed() { try? write(plan.path, plan.before.data, permissions: plan.before.permissions) }
            throw error
        }
        return written
    }

    /// Undo of `apply`: restores each file's `before`, but only where the file still holds what was written.
    public func undo(_ applied: [FileChangePlan]) throws {
        let inverse = applied.map { plan in
            FileChangePlan(before: FileSnapshot(path: plan.path, data: plan.after, permissions: plan.before.permissions), after: plan.before.data)
        }
        try apply(inverse)
    }

    private func write(_ path: String, _ data: Data?, permissions: Int?) throws {
        let url = url(path)
        do {
            if let data {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
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
