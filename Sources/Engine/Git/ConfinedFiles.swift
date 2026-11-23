import Darwin
import Foundation

/// File operations confined beneath one directory (A05). Every operation walks the relative path one component at a
/// time from a descriptor of the root, opening each directory with `O_NOFOLLOW`, and acts on the leaf through the
/// parent's descriptor (`openat`, `fstatat`, `renameatx_np`, `unlinkat`, `symlinkat`). A link, or a directory
/// replaced by a link, anywhere below the root is refused instead of being followed, so nothing is ever read, created,
/// renamed or removed outside the root. The root itself is trusted (it may sit behind a link such as `/var`).
final class ConfinedDirectory {
    let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { close(descriptor) }

    /// Why a path could not be opened beneath the root.
    enum Refusal: Error, Equatable {
        /// A component is missing (or, for an ancestor, is a file: the leaf cannot exist).
        case missing
        /// A component is a link, or the path is not a plain relative path: never followed.
        case link
        /// Any other error (permissions, I/O).
        case unreadable
    }

    /// The components of a repository-relative path, or nil when it is empty, absolute or has `.`/`..` components.
    static func components(_ path: String) -> [String]? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts
    }

    /// Opens `root`, then each of `components` beneath it as a directory without following links. With `create`,
    /// missing directories are made (each also without following links).
    static func open(root: String, _ components: ArraySlice<String>, create: Bool) -> Result<ConfinedDirectory, Refusal> {
        var current = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return .failure(errno == ENOENT ? .missing : .unreadable) }
        for component in components {
            var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, create {
                if mkdirat(current, component, 0o755) == 0 || errno == EEXIST {
                    next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            if next < 0 {
                let code = errno
                let refusal: Refusal
                switch code {
                case ENOENT: refusal = .missing
                case ELOOP: refusal = .link
                case ENOTDIR:
                    // A link (to anything) or a file. A link is refused; a file means the leaf does not exist.
                    var info = stat()
                    refusal = fstatat(current, component, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFLNK ? .link : .missing
                default: refusal = .unreadable
                }
                close(current)
                return .failure(refusal)
            }
            close(current)
            current = next
        }
        return .success(ConfinedDirectory(descriptor: current))
    }

    /// What is at `name` in this directory, never following a link.
    enum Entry: Equatable {
        case missing
        case regular(Data, permissions: Int)
        case symlink(String)
        case directory
        case other
        case unreadable
    }

    func entry(_ name: String) -> Entry {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlinkat(descriptor, name, &buffer, buffer.count - 1)
            guard count >= 0 else { return .unreadable }
            return .symlink(String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self))
        case S_IFDIR:
            return .directory
        case S_IFREG:
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { return errno == ENOENT ? .missing : .unreadable }
            var opened = stat()
            // The same file that was examined (not one swapped in between).
            guard fstat(file, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev, (opened.st_mode & S_IFMT) == S_IFREG else {
                close(file)
                return .unreadable
            }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            guard let data = try? handle.readToEnd() else { return .unreadable }
            return .regular(data, permissions: Int(opened.st_mode & 0o7777))
        default:
            return .other
        }
    }

    /// What a bounded preview of `name` finds (`preview`).
    enum Preview: Equatable {
        /// A regular file of at most the size limit: its first `prefix` bytes.
        case regular(Data)
        /// A link: its text, never its target.
        case symlink(String)
        /// Missing, too large, unreadable, or not a file or link.
        case skipped
    }

    /// The start of `name` without following a link: a regular file's first `prefix` bytes, read only when its size
    /// (checked on the opened descriptor, before anything is allocated) is below `maxSize`; a link's text.
    func preview(_ name: String, maxSize: Int, prefix: Int) -> Preview {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .skipped }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            if case .symlink(let text) = entry(name) { return .symlink(text) }
            return .skipped
        case S_IFREG:
            let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { return .skipped }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            var opened = stat()
            guard fstat(file, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG, opened.st_size < maxSize else { return .skipped }
            do {
                // nil at end of file: an empty file.
                return .regular(try handle.read(upToCount: max(1, prefix)) ?? Data())
            } catch {
                return .skipped
            }
        default:
            return .skipped
        }
    }

    /// Creates `name` (which must not exist) holding `data`, or a link to `link` when given.
    func create(_ name: String, data: Data, permissions: Int, link: String?) -> Bool {
        if let link {
            guard !link.isEmpty, !link.contains("\0") else { return false }
            return symlinkat(link, descriptor, name) == 0
        }
        let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            guard fchmod(file, mode_t(permissions & 0o7777)) == 0 else { throw CocoaError(.fileWriteUnknown) }
            try handle.close()
            return true
        } catch {
            unlinkat(descriptor, name, 0)
            return false
        }
    }

    /// `renameatx_np` within this directory; returns errno (0 on success).
    func rename(_ from: String, _ to: String, flags: UInt32) -> Int32 {
        renameatx_np(descriptor, from, descriptor, to, flags) == 0 ? 0 : errno
    }

    @discardableResult
    func remove(_ name: String) -> Bool { unlinkat(descriptor, name, 0) == 0 }

    /// Removes the directory `name` if it holds only empty directories (never a file or link); true when gone.
    func removeEmptyTree(_ name: String, depth: Int = 0) -> Bool {
        guard depth < 64 else { return false }
        let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { return errno == ENOENT }
        let directory = ConfinedDirectory(descriptor: child)
        guard let names = directory.names() else { return false }
        for entry in names {
            guard case .directory = directory.entry(entry), directory.removeEmptyTree(entry, depth: depth + 1) else { return false }
        }
        return unlinkat(descriptor, name, AT_REMOVEDIR) == 0
    }

    /// The names in this directory (without `.` and `..`), or nil when it cannot be read.
    func names() -> [String]? {
        let copy = dup(descriptor)
        guard copy >= 0, let stream = fdopendir(copy) else { return nil }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }
}
